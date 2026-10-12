# TestFlight

Everything that can be ready is in the repository: the privacy manifests, the usage strings, the export options, and `scripts/archive-upload.sh`, which archives Topo for the App Store and can upload it. What is left needs Sam, because it needs an Apple account, and this is the list with what to click.

Of the steps below, the schema (4) is deployed for `iCloud.zone.hexagon.topo`. The archive and export have been run on buddybox and produce a signed App Store build; the upload has not been attempted.

## What is already handled

- **Privacy manifests.** `Apps/Shared/PrivacyInfo.xcprivacy` and `Womble/Sources/App/PrivacyInfo.xcprivacy`: nothing collected, nothing tracked, and the two required-reason APIs declared (user defaults, and the monotonic clock the lease is judged on).
- **Usage strings.** The microphone, on the iOS app, in `project.yml`; it is the only one the app needs, since the words are turned into text on the phone. Womble's local network and `_topo._tcp` are in its `Info.plist`. The client app gains those two when the LAN work lands — a usage string for something the binary cannot do invites a question at review, so they arrive with the code.
- **Export compliance.** `ITSAppUsesNonExemptEncryption` is `false` on every app target: Topo uses HTTPS and Apple's own frameworks and no cryptography of its own, so TestFlight stops asking per build.
- **Build numbers.** The script sets `CURRENT_PROJECT_VERSION` to the minutes since the start of 2026. TestFlight insists on one thing, which is that the number goes up, and this needs nothing kept between runs.

## 1. The App ID and the containers

Automatic signing has already registered `zone.hexagon.topo` and made a team provisioning profile, so the App ID exists. What has to match it is the iCloud containers: [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) → the `zone.hexagon.topo` identifier → **iCloud** → make sure both `iCloud.zone.hexagon.topo` and `iCloud.zone.hexagon.topo.board` are ticked. Create the second with **iCloud Containers** → **+** if it is not there.

The entitlements name both. A container in the entitlements that does not exist for the team is a rejected upload rather than a warning.

The same identifier needs **Push Notifications** ticked. The iOS target's entitlements (`Apps/TopoiOS.entitlements`) carry `aps-environment` for the silent CloudKit push that wakes the primary when a limb writes a turn, and a profile without the capability cannot sign it. The file says `development`, which is what a debug build is signed with; the App Store export signs with `production` from the distribution profile, so nothing is edited per build. CloudKit sends the push itself, so there is no APNs key or certificate to make. The watch and TV entitlements carry no push.

## 2. The App Store Connect record

[App Store Connect](https://appstoreconnect.apple.com/apps) → **Apps** → **+** → **New App**.

- **Platform:** iOS.
- **Name:** Topo. (It has to be unique across the store; if it is taken, the store name and the app's own name need not match.)
- **Primary language:** English (UK).
- **Bundle ID:** `zone.hexagon.topo` from the list.
- **SKU:** anything; `topo` will do. It is yours, not Apple's.
- **User access:** Full.

Nothing else is needed for TestFlight. Screenshots, description and the rest are for a store submission.

## 3. The API key

[Users and Access](https://appstoreconnect.apple.com/access/integrations/api) → **Integrations** → **App Store Connect API** → **Team Keys** → **+**.

- **Name:** buddybox.
- **Access:** App Manager.

Download the `.p8` when it appears — Apple gives it once and never again. Note the **Key ID** beside it and the **Issuer ID** above the list.

Then put all three in the login keychain, which is where the script looks:

```
security add-generic-password -a "$USER" -s topo-asc-key-id -w 'THEKEYID'
security add-generic-password -a "$USER" -s topo-asc-issuer-id -w 'THE-ISSUER-UUID'
security add-generic-password -a "$USER" -s topo-asc-private-key -w "$(cat ~/Downloads/AuthKey_THEKEYID.p8)"
rm ~/Downloads/AuthKey_THEKEYID.p8
```

`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_PRIVATE_KEY` in the environment work too, and win over the keychain.

The key is read in whatever shape it was kept (`scripts/asc-pem.sh`): the `.p8` as Apple gave it, the hex `security -w` prints for a secret that holds newlines, or the one line a password manager's field makes of it. Where the key is there, the archive and the export are given it too, so xcodebuild registers a new target's App ID and makes its profile with no Apple ID signed in to Xcode. A change to Apple's Program License Agreement stops that until the Account Holder has agreed to it at developer.apple.com/account.

## 4. The CloudKit schema

Records written in development do not exist in production until the schema is deployed, and TestFlight builds talk to production. Production refuses a save that carries a record type or a field it does not have, and what is deployed there is permanent: a record type's name, a field's name and a field's type cannot be changed or removed afterwards, and a later deploy can only add: a type, a field, an index. So the development schema is checked against the table in `docs/cloudkit.md` (*The schema*) before the deploy, and the deploy is Sam's.

**Reading the schema.** `cktool` reads a schema with a CloudKit management token, which is not the App Store Connect key: [CloudKit Console](https://icloud.developer.apple.com/dashboard/) → the account menu → **Settings** → **Tokens** → **Management Token**, kept in 1Password as `Topo CloudKit management token` in the Homelab vault.

```
set -e
export CLOUDKIT_MANAGEMENT_TOKEN="$(op read 'op://Homelab/Topo CloudKit management token/credential')"
mkdir -p build/schema
out="$(mktemp -d "build/schema/$(date -u +%Y%m%dT%H%M%SZ).XXXX")"
for c in iCloud.zone.hexagon.topo iCloud.zone.hexagon.topo.board; do for e in development production; do
  xcrun cktool export-schema --team-id 4A5NSJ6Y3G --container-id $c --environment $e --output-file "$out/$c.$e.ckdb"
done; done
```

Each run exports into a directory of its own and stops at the first export that fails, so a file compared is one that run wrote.

**Checking it.** The development export is compared with the table both ways, a `.ckdb` naming the table's types `STRING`, `INT64`, `TIMESTAMP`, `LIST<STRING>` and `LIST<ASSET>`. A row missing from it is a code path that has never run against development, which creates a type or a field at its first save and never sees an empty list, since the adapter leaves one off the wire:

- `Surface` exists once a widget slot has been set, its `cleared` once one has been cleared, and `imageNames` and `images` once one has been saved with an image.
- `Role` exists once a device has been made the primary from another.
- `Device` and its `endpoints`, and `PrimaryLease.endpoint`, exist once a hub signed with the iCloud entitlement has launched with a LAN address.
- `Turn.parents` and `Note.parents` exist once a second turn and a second revision have been written.
- `Card`, less its `parents`, exists once Womble's self-test has run.

Running the path on a debug build fills the gap and proves the type the code writes. No target calls the writer of `VaultRemote`, `CardWrite`, `Card.parents` or `Device.pairedWith`, so those, and an index, are added to the exported file and imported back into development:

```
xcrun cktool import-schema --team-id 4A5NSJ6Y3G --container-id <container> --environment development --validate --file <the export, with lines added>
```

An import can remove as well as add, and development holds the records of whoever runs debug builds, so the file imported is the whole export taken just before, with lines added, and its `diff` against that export is shown to Sam first: additions only, and a removed line is a stop. A record type or a field of ours in the export that the table does not have is removed from development before the deploy, since the deploy would make it permanent; what CloudKit put there itself stays: `Users`, the fields whose names begin `___`, the `GRANT` lines, and `cloudkit.share`, which development gains at the first share saved and the board container needs in production before `TopoBoard.share()` can save one.

**Deploying.** Console → the container → **Development** → **Schema** → **Deploy Schema Changes…**. The sheet lists what will change; it should list additions only. Then **Deploy**, once for each container that has changes. `cktool` has no deploy. **Reset Environment**, and `cktool reset-schema`, delete every record in development, which is the transcript and the memory of whoever runs debug builds.

**Proving it.** A production export taken after the deploy is compared with the development export, order aside, and with the table: the same record types, fields, types and indexes, and nothing else. `iCloud.zone.hexagon.topo` was deployed and compared this way on 2026-10-11, with the result in #381's Proof and in `progress-schema-prod.md`, the plan's ledger. `iCloud.zone.hexagon.topo.board` had no schema in either environment then, since nothing writes a card, and is deployed with the change that does. The archive is cut from the commit the table was checked at; at a later one, the diff between the two is read for record definitions, field mappings, queries and subscription predicates first.

Production starts with no records: nothing of a development transcript, memory or pairing is there, and since no target sets `com.apple.developer.icloud-container-environment` the environment follows the signing, so a TestFlight phone and a debug-built hub never see each other's records. A phone that has run a debug build is signed out in it, and the app deleted, before the TestFlight build is installed: the app's container, the zone's copy on disk included, otherwise carries over from one environment to the other.

A tester whose app cannot read anything, on a build that works in the simulator, is almost always this step. Womble's self-test — five taps on its title — says which call failed and what CloudKit said, which is faster than guessing: a schema that was never deployed fails at the write, an entitlement that was never granted fails before that, at the account. Its step *The board's container* saves a `Card`, so against production it fails there until the board container's schema is deployed; the steps before it are the ones that judge `iCloud.zone.hexagon.topo`. A push subscription that could not be saved shows no error at all: the build answers a limb's turn on the five-second loop alone, a note written on another device reaches the mirror at its next sync, and the watch fetches its surfaces only while open and on its refresh.

## 5. Upload

```
scripts/archive-upload.sh --validate     # asks App Store Connect whether it would take it
scripts/archive-upload.sh --upload
```

Processing takes a few minutes. The build then appears under **TestFlight** in the app record.

## 6. Testers

TestFlight → **Internal Testing** → a group → add people from Users and Access. Internal testers need no review and get the build as soon as it finishes processing. External testers do need a review, which is a day or so, and are not needed for a house.

## What the script does not do

It does not create anything in App Store Connect, and it does not promote a schema. Both are one-time, both are irreversible in the sense that they are awkward to undo, and neither should happen because a script ran.
