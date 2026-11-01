# TestFlight

Everything that can be ready is in the repository: the privacy manifests, the usage strings, the export options, and `scripts/archive-upload.sh`, which archives Topo for the App Store and can upload it. What is left needs Sam, because it needs an Apple account, and this is the list with what to click.

Of the steps below, 1 to 4 are done: the App IDs and profiles exist, the app record exists (Apple ID 6826966978), and the schema (4) is deployed for `iCloud.zone.hexagon.topo`. Builds are uploaded from buddybox with the one command in *5. Upload*, and *6. Testers* says who can install one.

## What is already handled

- **Privacy manifests.** `Apps/Shared/PrivacyInfo.xcprivacy` and `Womble/Sources/App/PrivacyInfo.xcprivacy`: nothing collected, nothing tracked, and the two required-reason APIs declared (user defaults, and the monotonic clock the lease is judged on).
- **Usage strings.** The microphone, on the iOS app, in `project.yml`; it is the only one the app needs, since the words are turned into text on the phone. Womble's local network and `_topo._tcp` are in its `Info.plist`. The client app gains those two when the LAN work lands — a usage string for something the binary cannot do invites a question at review, so they arrive with the code.
- **Export compliance.** `ITSAppUsesNonExemptEncryption` is `false` on every app target of `Topo.xcodeproj` (Womble's project does not set it), so TestFlight stops asking per build. That value holds while Topo is not on the App Store in France; why, and what changes if it is, is *Export compliance* below.
- **Opaque icons.** App Store Connect refuses an app icon with an alpha channel, even one whose every pixel is opaque (90717), so `Design/make-icons.swift` writes the full-bleed icons with none.
- **Build numbers.** The script sets `CURRENT_PROJECT_VERSION` to the minutes since the start of 2026. TestFlight insists on one thing, which is that the number goes up, and this needs nothing kept between runs.

## 1. The App ID and the containers

Automatic signing has registered `zone.hexagon.topo` and the extensions' App IDs (`.widgets`, `.share`, `.broadcast`). The archive, given the API key, made a cloud-managed Apple Distribution certificate and an App Store profile for each of the four; no distribution certificate or private key is in the keychain, so the archive and export need no GUI login, only the login keychain unlocked for the API key. What has to match it is the iCloud containers: [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) → the `zone.hexagon.topo` identifier → **iCloud** → make sure both `iCloud.zone.hexagon.topo` and `iCloud.zone.hexagon.topo.board` are ticked. Create the second with **iCloud Containers** → **+** if it is not there.

The entitlements name both. A container in the entitlements that does not exist for the team is a rejected upload rather than a warning.

The same identifier needs **Push Notifications** ticked. The iOS target's entitlements (`Apps/TopoiOS.entitlements`) carry `aps-environment` for the silent CloudKit push that wakes the primary when a limb writes a turn, and a profile without the capability cannot sign it. The file says `development`, which is what a debug build is signed with; the App Store export signs with `production` from the distribution profile, so nothing is edited per build. CloudKit sends the push itself, so there is no APNs key or certificate to make. The watch's entitlements (`Apps/TopoWatch.entitlements`) carry `aps-environment` too, for the silent `Surface` push that wakes it to fetch the slots sooner than its background refresh, so `zone.hexagon.topo.watch` needs **Push Notifications** ticked as well; the watch never answers a turn. The watch app rides inside the phone app's archive as its companion (`docs/install.md`, *The watch*), so the export signs `zone.hexagon.topo.watch` and `zone.hexagon.topo.watch.widgets` with App Store profiles of their own, beside the phone's, and one upload carries both apps. The TV's entitlements carry no push.

## 2. The App Store Connect record

The record exists: Topo, `zone.hexagon.topo`, SKU `topo`, English (UK), Apple ID 6826966978. Its settings, as [App Store Connect](https://appstoreconnect.apple.com/apps) → **Apps** → **+** → **New App** asks for them:

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

From a worktree of `origin/main` on buddybox, at the commit to ship:

```
scripts/archive-upload.sh --validate --upload
```

It refuses a tree with uncommitted changes and a commit on no remote branch, since the About screen names the commit as its source. The schema is judged at that commit first (4, *Proving it*): a commit whose diff since the last check adds a record type, a field, a query or a subscription predicate needs its deploy before the build goes out.

App Store Connect's validation reads the whole archive, the watch app included, so a key it refuses in any bundle (90362, an Info.plist value) is found here and nowhere earlier: `scripts/check-built-plist.sh` reads what the product must carry, not what the store refuses. Processing takes a few minutes, and the build then appears under **TestFlight** in the app record and in every internal group that has access to all builds. A debug build on the phone is signed out and deleted before the TestFlight build is installed (4).

The App Store Connect API answers the rest with the same key (`appstoreconnect-v1` JWT, ES256, from the keychain's three items): the build's `processingState`, the groups, the testers, and a build's beta review submission.

## 6. Testers

Two groups exist on the app record.

- **House**, internal, with access to every build: each upload reaches it as soon as it is processed, with no review. An internal tester is a user of the team (Users and Access), and the invitation goes to that user's email; TestFlight on the phone has to be signed in as that Apple ID (Settings → the account → Media & Purchases) and the invitation accepted once from the email, after which every build appears in the app by itself. The API refuses a team invitation to an email with a `+` in it ("Email format not valid"), and refuses to add an email that is not a team user's to an internal group ("Tester(s) cannot be assigned"), so an Apple ID of that shape cannot be an internal tester; Sam's phone is signed into TestFlight as `samdurose@mac.com` for this reason.
- **Household**, external, with a public link (shown on the group in App Store Connect; ten seats, and this repository is public, so the link is not written here): anyone with the link, any Apple ID. It offers a build only once Beta App Review has passed it, a day or so for the first, and tapping the link before that is an error rather than a waiting list. The submission (`betaAppReviewSubmissions`) wants the review contact (`betaAppReviewDetail`: name, email, phone) and the test information (`betaAppLocalizations`, set: what to test, feedback address `samdurose@mac.com`), and the build's own what-to-test line.

## What the script does not do

It does not create anything in App Store Connect, and it does not promote a schema. Both are one-time, both are irreversible in the sense that they are awkward to undo, and neither should happen because a script ran.

## Licences and App Review

What Topo ships, what it downloads, and what each asks of a build that leaves Sam's own devices. `THIRD-PARTY` is the per-piece record (licence, source, pin, what it does) and carries the licence texts that have to travel with the binary; this section is what those licences and Apple's and Anthropic's terms mean for a TestFlight or App Store build.

### What is in the bundle and what is downloaded

In the iOS app's bundle: Topo's own code (GPL-3.0, `LICENSE`); the iSH fork with Topo's fourteen patches and libarchive, through `Packages/TopoUserland` (GPL-3.0 with iSH's App Store waiver; BSD); FluidAudio 0.17.7, the one SwiftPM dependency in `Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, with what it compiles in (Apache-2.0; the NemoTextProcessing xcframework and its Rust crates, Apache-2.0 and MIT; fastcluster, BSD-2-Clause), less its two LuxTTS resources, which the build strips (below); and `THIRD-PARTY` and `LICENSE` themselves. Markdown is Foundation's `AttributedString(markdown:)` (`Apps/Client/Markdown.swift`), so no parser of anyone else's is in it. The app's extensions (the widgets, the share sheet, the broadcast) are inside its bundle and link none of the borrowed code. The watch, TV and Womble bundles carry Topo's own code and `THIRD-PARTY` and link none of it either, and the hub is Topo's own code and packages alone, with no Claude Code.

Downloaded on the phone after install, from the maker's own server at the pin in `Apps/Topo/Resources/models.json`, into Application Support: the Parakeet and Pocket TTS weights (CC-BY-4.0), the Alpine 3.22.6 minirootfs (BusyBox, apk-tools and the base layout GPL-2.0-only, musl MIT, OpenSSL 3.5.8 Apache-2.0, `ca-certificates-bundle` MPL-2.0 and MIT, zlib), Alpine's bash, readline and ncurses (GPL-3.0-or-later and X11), Claude Code (Anthropic's terms) and the 1Password CLI (AgileBits' terms).

### GPL-3.0 and the App Store

The conflict is section 10 of the GPL against the App Store's Usage Rules. GPL-3.0 §10 (https://www.gnu.org/licenses/gpl-3.0.txt): "You may not impose any further restrictions on the exercise of the rights granted or affirmed under this License." Apple's Media Services Terms (https://www.apple.com/legal/internet-services/itunes/us/terms.html) license every app "as permitted by the Usage Rules" of its Standard EULA (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/), which limit use to personal, noncommercial use on the buyer's own devices and forbid redistribution; the Terms let a developer's Custom EULA override the Standard EULA, and the Standard EULA excepts what open-source licences permit, but the store's own rules still attach to the download. This is what the FSF raised over GNU Go in May 2010 (https://www.fsf.org/news/2010-05-app-store-compliance, "forbidden by section 6 of GPLv2", after which Apple removed it), and what removed VLC for iOS in January 2011 on a VLC copyright holder's notice (https://mailman.videolan.org/pipermail/vlc-devel/2010-October/076868.html; https://www.videolan.org/news.html, 2011-01-09). VLC returned in July 2013 relicensed so that a licence without the conflict applies on the store: "bi-licensed under both the Mozilla Public License Version 2 as well as the GNU General Public License Version 2 or later. The MPLv2 is applicable for distribution on the App Store" (https://www.videolan.org/press/ios2out.html).

The conflict is the copyright holders' to raise, so it is judged per holder of GPL code in the bundle:

- **Topo's own code.** Sam is its one copyright holder, so his own distribution of it through the store breaches nothing. Anyone else putting a fork of Topo on the store needs his permission as well as iSH's, because `LICENSE` is the plain GPL-3.0 with no additional permission under §7.
- **The iSH fork.** Its `LICENSE.md` makes the additional terms in `LICENSE.IOS` part of its licence, and `LICENSE.IOS` is the waiver `THIRD-PARTY` quotes: iSH's holders will not pursue a violation "that results solely from the conflict between the GNU GPLv2 or v3 and the Apple App Store terms of service", "as long as you comply with the GPL in all other respects, including its requirements to provide users with source code and the text of the license". It is the pattern VLC's relicensing and others' App Store exceptions follow, written as a covenant rather than as a §7 permission. The ish-arm64 contributors after the fork have signed nothing of their own; their code is covered because the fork they publish carries `LICENSE.md` and `LICENSE.IOS` unchanged (and `README_arm64.md`: "Same as upstream iSH").
- **No other GPL code is in the bundle.** `scripts/build-ish.sh` refuses a checkout with the fork's `deps/linux` (Linux, GPL-2.0-only) or `deps/libapps` (the terminal), which the waiver does not cover; the fork's offload test handlers, which carry translated CPython functions, are off in its meson options and not compiled. FluidAudio's own resources are a LuxTTS lexicon and its table (`luxtts_en_us_lexicon.tsv.zz`, `luxtts_en_us_g2p_aux.json`), pronunciations harvested by running espeak-ng, GPL-3.0 with no waiver, and they are not in the bundle: the iOS target's last build phase (`scripts/strip-luxtts.sh`) removes both from the app's copy of `FluidAudio_FluidAudio.bundle` and signs that bundle again with the app's identity, since a removed file breaks the seal its own signature made, and `scripts/check-built-plist.sh` fails a product that carries a `luxtts_` file in any bundle. The bundle itself stays, so FluidAudio finds it; its LuxTTS loader throws when the files are missing, and nothing in Topo calls it.

What the waiver asks in return is the rest of the GPL, and for an object-code app that is §4 to §6:

- **The licence's text** goes with every copy: `LICENSE` is a resource of the iOS app, shown on the About screen, and `scripts/check-built-plist.sh` fails a product without it.
- **The Corresponding Source** is offered under §6(d), from "a designated place" with "clear directions next to the object code saying where to find the Corresponding Source". The About screen names https://github.com/samdu/topo (public) and the commit the build was cut from (`TopoSourceCommit`, written by `scripts/archive-upload.sh`), and that commit holds the fork's pin, its patches and the script that builds it. FluidAudio and libarchive are at their pins on GitHub. The fork's own source is at https://github.com/samdu/ish-arm64, a GitHub fork of OpenMinis' repository with the pin tagged `topo-pin-e1d5794`, because §6(d) says "you remain obligated to ensure that it is available for as long as needed to satisfy these requirements" and a tag in Topo's own repository keeps the commit when the upstream rewrites or deletes it. A new pin in `scripts/build-ish.sh` takes a tag of its own there.
- **Modified files** carry "prominent notices stating that you modified it, and giving a relevant date" (§5(a)): `THIRD-PARTY`'s `Modified` line under the fork names each patch, what it touches and the dates of the commits that added and changed it; `topo_ish.c` and `topo_vaultfs.m` say in their heads which of the fork's files they follow and under what terms.
- **Installation Information** is not owed. §6 asks for it only when the object code is conveyed "as part of a transaction in which the right of possession and use of the User Product is transferred to the recipient", and an app download transfers no device.

What Topo downloads it does not convey: the phone fetches each piece from the maker's server, so the source offer for BusyBox, apk-tools, bash and the rest is Alpine's (https://gitlab.alpinelinux.org/alpine/aports, 3.22-stable), and the device builds its fakefs from them for its own use. That holds only while they stay downloads. None of the GPL-2.0-only pieces has a waiver, so the rootfs or the shell moved into the bundle is GPL code under the store's terms with nobody's permission.

### The permissive licences and the model weights

Apache-2.0 §4 asks for a copy of the licence and, where a NOTICE file exists, its attributions; BSD-2-Clause and BSD-3-Clause ask for the copyright notice, the conditions and the disclaimer "in the documentation and/or other materials provided with the distribution"; MIT asks for the notice "in all copies or substantial portions of the Software". `THIRD-PARTY` is in every bundle, and holds the Apache-2.0 text, the MIT text with the copyright lines of the MIT-only crates and ports, libarchive's BSD texts in each of their wordings with the copyright lines of every file `scripts/build-ish.sh` compiles, fastcluster's, and FluidAudio's `ThirdPartyLicenses/KokoroANE-v3/NOTICE` whole, which asks to be kept.

Parakeet (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2, https://huggingface.co/nvidia/parakeet-tdt_ctc-110m) and Pocket TTS (https://huggingface.co/kyutai/pocket-tts-without-voice-cloning) are CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/legalcode). The licence permits sharing in any medium, adapted or not, for any purpose including commercial, and Topo is not for profit in any case. §3(a) asks for the creator, the copyright notice, a notice of the licence and of its disclaimer, a URI to it, and an indication of any change; each model's entry in `THIRD-PARTY` names the four, and Pocket TTS's says what Sam changed and when. https://huggingface.co/samthehugenerd/Marius-Topo, the pack Topo downloads, is published under the same licence with the same credit. Kyutai's repository is gated by a prohibited-use statement (no impersonation, deception or unlawful content); that was a condition of downloading the weights from Kyutai, which Sam accepted, and is not a term of CC-BY-4.0, whose §2(a)(5)(B) forbids adding restrictions downstream, so Marius-Topo is ungated. The `marius` voice is a CC0 donation (`voice-donations/` in https://huggingface.co/kyutai/tts-voices).

Claude Code (https://code.claude.com/docs/en/legal-and-compliance) and the 1Password CLI (https://1password.com/legal/terms-of-service) are proprietary and are not redistributed: each is fetched from its maker at a pin. Anthropic's conditions on a product running Claude Code are that "the Claude Code binary must not be modified" and that "each end user must authenticate with their own Anthropic API key, Claude subscription plan credentials, or 3P inference provider credential", with the usage billed to them; the guest runs the published binary unmodified, with its updater off through its environment, on the person's own login.

### Export compliance

Apple: "If your app uses, accesses, contains, implements, or incorporates encryption, this is considered an export of encryption software" (https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations). Topo contains a standard algorithm outside Apple's operating system: the fork's Asbestos engine implements the ARMv8 cryptographic instructions in software (`asbestos/guest-arm64/crypto_helpers.c`, AES rounds, SHA-1 and SHA-256), so guest code that uses them runs. It also accesses OpenSSL in the rootfs, BoringSSL in Claude Code and Go's TLS in `op`, all downloaded. Its own TLS and hashing are Apple's (`URLSession`, `Network`, `CryptoKit`). Nothing in it is proprietary or non-standard.

So App Store Connect's encryption declaration (App Information → App Encryption Documentation) answers that Topo uses "standard encryption algorithms instead of, or in addition to, using or accessing the encryption in Apple's operating systems" (`containsThirdPartyCryptography`, https://developer.apple.com/documentation/appstoreconnectapi/appencryptiondeclaration/attributes), with no proprietary cryptography. Apple's table for that answer (https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption): "Upload your French encryption declaration in App Store Connect", and its footnote: "French encryption declaration form is only required if you're distributing your app on the App Store in France." No CCATS, which is for proprietary algorithms.

These are two separate acts. The declaration is filed once, by hand, in App Store Connect, with that answer, no proprietary cryptography, and the France question answered as the availability is. The Info.plist key only keeps the per-build question away, and answers nothing itself.

- **Not on the App Store in France** (TestFlight, and a store release that leaves France out of its availability): no documentation is required, and `ITSAppUsesNonExemptEncryption` stays `false`.
- **On the App Store in France:** a declaration to ANSSI is made and uploaded, and once Apple approves it (about two business days, and before a build goes to TestFlight App Review) the key becomes `true` with `ITSEncryptionExportComplianceCode` set to the code Apple issues.

Under US law the app is mass-market software using standard cryptography (ECCN 5D992.c, Note 3 to Category 5 Part 2), exported under License Exception ENC. No annual self-classification report is due: BIS's 2021 rule "eliminates the self-classification reporting requirement for certain 'mass market' encryption products under Sec. 740.17(b)(1)" (86 FR 16482, https://www.federalregister.gov/documents/2021/03/29/2021-05481), and the requirement that is left, §740.17(e)(3) (https://www.ecfr.gov/current/title-15/section-740.17), applies to mass-market components and 'executable software' from a hardware component, which an app is not. BIS's own explainer pages still describe the pre-2021 report; the regulation is what binds. Source and object code that are published and use only standard cryptography are outside the EAR altogether, with no email notification (§734.3(b)(3), §734.7, §742.15(b)), although BIS's note that "a new item with encryption functionality has been created which would need to be evaluated as a whole" means the mass-market reading is the one relied on.

### App Review and Anthropic's terms

Ordered by the chance each one stops a build.

- **Downloaded code.** Guideline 2.5.2: apps may not "download, install, or execute code which introduces or changes features or functionality of the app", with an exception for educational apps that teach programming and make the code "completely viewable and editable by the user". Guideline 4.7 lets an app offer software not in its binary only for mini apps and games, streaming games, chatbots, plug-ins, and games in emulators. Topo downloads a Linux userland, Claude Code and `op` and runs them, which the text of 2.5.2 forbids and 4.7 does not cover. iSH and a-Shell are on the store doing the same kind of thing. In October 2020 App Review told iSH it broke 2.5.2 because it "is not self-contained and has remote package updating functionality", then accepted its appeal (https://ish.app/app-store-removal); the same page says review had earlier found iSH in breach "because it could download Linux executable code", and iSH took `apk` out to pass. So the precedent is that a terminal-shaped app is admitted, and that downloading executables is what review looks at. Topo is not shaped like a terminal: nothing about the guest is visible, and the downloaded programs are its features. Internal TestFlight testers get a build with no review, so this decides only external testing and the store.
- **The audio background mode.** Guideline 2.5.4: "Multitasking apps may only use background services for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc." Topo holds `audio` while it reads a reply aloud, and keeps a silent player node running under the play queue from the release of the press until the reply has been heard (`docs/voice.md`); a reviewer who sees silence played behind the lock reads it as keeping the process alive. What answers it is that the hold lasts one spoken reply and no longer.
- **Sign in with Claude.** Anthropic's terms for Claude Code (https://code.claude.com/docs/en/legal-and-compliance, *Authentication and credential use*): "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow". What it permits is "an end user signing in to the unmodified Claude Code binary with their own Claude subscription", and that is what Topo's sign-in is (`docs/auth.md`): `claude auth login --claudeai` runs in the guest's unmodified `claude`, whose OAuth client, redirect, code exchange and stored credential are all Claude Code's; Topo opens the URL the CLI hands it in a browser sheet, or writes the `code#state` Claude's own code page shows to the CLI's stdin when the loopback cannot be reached, and holds no Claude.ai token, and the guest's API requests carry the credential Claude Code wrote, which the proxy passes through unchanged. App Review's guideline 5.2.2 (https://developer.apple.com/app-store/review/guidelines/) asks of an app using a third-party service that "you are specifically permitted to do so under the service's terms of use. Authorization must be provided upon request"; the permission is that sentence of Anthropic's page. The feature's name uses Anthropic's mark *Claude*, which is judged under Anthropic's trademark guidelines (https://www.anthropic.com/legal/trademark-guidelines); the same page forbids only the Claude Code and Anthropic names "as part of your own product, feature, or company name".
- **Export compliance** stops a build only if it reaches the French store without the declaration (above).
