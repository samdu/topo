# TestFlight

Everything that can be ready is in the repository: the privacy manifests, the usage strings, the export options, and `scripts/archive-upload.sh`, which archives Topo for the App Store and can upload it. What is left needs Sam, because it needs an Apple account, and this is the list with what to click.

Nothing here has been done yet. The archive and export have been run on buddybox and produce a signed App Store build; the upload has not been attempted.

## What is already handled

- **Privacy manifests.** `Apps/Shared/PrivacyInfo.xcprivacy` and `Womble/Sources/App/PrivacyInfo.xcprivacy`: nothing collected, nothing tracked, and the two required-reason APIs declared (user defaults, and the monotonic clock the lease is judged on).
- **Usage strings.** The microphone and speech recognition, on the iOS app, in `project.yml`. Womble's local network and `_topo._tcp` are in its `Info.plist`. The client app gains those two when the LAN work lands — a usage string for something the binary cannot do invites a question at review, so they arrive with the code.
- **Export compliance.** `ITSAppUsesNonExemptEncryption` is `false` on every app target: Topo uses HTTPS and Apple's own frameworks and no cryptography of its own, so TestFlight stops asking per build.
- **Build numbers.** The script sets `CURRENT_PROJECT_VERSION` to the minutes since the start of 2026. TestFlight insists on one thing, which is that the number goes up, and this needs nothing kept between runs.

## 1. The App ID and the containers

Automatic signing has already registered `zone.hexagon.topo` and made a team provisioning profile, so the App ID exists. What has to match it is the iCloud containers: [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) → the `zone.hexagon.topo` identifier → **iCloud** → make sure both `iCloud.zone.hexagon.topo` and `iCloud.zone.hexagon.topo.board` are ticked. Create the second with **iCloud Containers** → **+** if it is not there.

The entitlements name both. A container in the entitlements that does not exist for the team is a rejected upload rather than a warning.

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

## 4. The CloudKit schema

Records written in development do not exist in production until the schema is promoted, and TestFlight builds talk to production. [CloudKit Console](https://icloud.developer.apple.com/dashboard/) → the container → **Schema** → **Deploy Schema Changes** → **Deploy** — for `iCloud.zone.hexagon.topo` and again for `iCloud.zone.hexagon.topo.board`.

Do this after running the app against development at least once, so there is a schema to promote: the record types and their fields are created by the first save of each. The reads ask by a field of ours rather than by record name, so the index that matters is the one behind `sequence`, which arrives with the field.

A tester whose app cannot read anything, on a build that works in the simulator, is almost always this step. Womble's self-test — five taps on its title — says which call failed and what CloudKit said, which is faster than guessing: a schema that was never promoted fails at the write, an entitlement that was never granted fails before that, at the account.

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
