# Installing Topo on a phone

Topo is not in the App Store yet. The iOS app ships as a development-signed build for the devices enrolled on team 4A5NSJ6Y3G, so it runs only on those.

A fresh build reaches Sam's devices by push: buddybox is paired over the local network with his iPhone 15 Pro (the primary test device, Developer Mode on), his iPad and his Apple Watch, and `publish-topo.sh` (under Cutting a build) installs each build it cuts on the iPhone and the iPad when they are in reach, with no tap. The watch app rides inside the phone app as its companion (`Topo.app/Watch/TopoWatch.app`), so every build carries it, and the phone hands it to the watch (*The watch*, below). The same build is published to the install page, which is how a device buddybox is not paired with, or one that was away when the build was cut, gets it. **Every merge to main is cut and pushed**: the janitor (`docs/janitor.md`) runs `publish-topo.sh origin/main` within fifteen minutes of the page's commit falling behind origin/main.

## Install from the page

1. On the iPhone, open Safari (it must be Safari) at https://experiments.hexagon.zone/ota/files/623f17f9f38db5b81d0b/ and tap **Install Topo**, then **Install** on the system prompt.
2. Wait for the icon to finish loading on the Home Screen. A first install of an unsigned-by-the-store developer app may ask, on launch, to trust the developer: Settings › General › VPN & Device Management › Apple Development: Sam du Rose › Trust.
3. Open Topo. It reads the CloudKit container on the phone's iCloud account (`iCloud.zone.hexagon.topo`, development environment), so iCloud Drive must be on for the account, and the first device to launch becomes primary and shows Sign in with Claude.

Tapping the same link again installs the newer build over the old one; the page shows the commit it was built from, and `version.json` beside it carries the same.

## Cutting a build

`publish-topo.sh` in the `ota` experiment of samdu/experiments does it end to end on buddybox: archive and export the `Topo` scheme dev-signed from a detached checkout of the given ref (default `origin/main`), copy the ipa and `version.json` onto the `ota` pod's PVC under the slug, where they are served at once (no commit, no restart), and check the ipa URL answers 200. `--dev <PR>` (the number, or its branch) cuts an open PR's head into that PR's own dev slot instead, one per open PR, each with its own install button on the page and the newest shown as "Latest dev"; a branch with no open PR is refused, and so is a head whose newest `test` check (`pr-validate.yaml`'s gate, red while any suite status the PR's paths require is missing or failed) has not concluded `success`, before anything is built, and the page shows the PR, branch, build number and suite status of each. The archive is told the build number (minutes since 2026), the commit (`TOPO_SOURCE_COMMIT`) and the channel (`TOPO_CHANNEL`, `main` or `dev`), which the app hands the guest (`docs/guest.md`, *The resident process*).

With the publish done it pushes the ipa to the paired devices through `push-install.sh` beside it: `xcrun devicectl list devices` read live, then `xcrun devicectl device install app --device <udid> Topo.ipa` on each physical iPhone and iPad that is `available (paired)`, over Wi-Fi. It installs and does not launch: `devicectl device process launch` is a separate call, which `scripts/perf-run.sh` makes and this does not. It prints one line per device, `installed` or `skipped: <reason>` — a device off the home network, a watch buddybox cannot raise a tunnel to — and a skipped device never fails the publish. A watch is handed the watch app the ipa embeds, unpacked. A `--dev` build goes to Sam's iPhone, M4 iPad and Apple Watch only. Every build is the same app, one install per device, so a push of either kind skips a device that carries a dev build whose `Build N` issue in samdu/topo-link is open (`skipped: carries dev build N, under test`), unless it is that build, or, for a `--dev` build, an earlier build of the same PR, which a re-cut replaces: two PRs under test sit one per device, and a build that finds both held waits on the page until an issue closes. `--no-push`, as the first argument, publishes only.

It needs the login keychain, so run it from a GUI-session shell as buddy, not a bare ssh shell.

Signing is automatic with the team set in `project.yml`. The iCloud container and the App ID's capabilities are registered by Xcode from the entitlements when a project with a team is opened in it, which is how the container came to exist; `xcodebuild -allowProvisioningUpdates` alone creates the App ID and profile but not a container.

## A debug build on the test phone

A debug build, with the Tuning sliders and the Haiku pin, is the one build `publish-topo.sh` does not cut: build the `Topo` scheme Debug for `generic/platform=iOS`, then `xcrun devicectl device install app --device <udid> <path to Topo.app>` and `xcrun devicectl device process launch --device <udid> zone.hexagon.topo`, with the UDID from `xcrun devicectl list devices`. A device that is not `available (paired)` there is off the home network or locked past its pairing window. Like `publish-topo.sh`, the build needs the login keychain, so run it from a GUI-session shell as buddy.

## The watch

`TopoWatch` is the phone app's companion, not a watch-only app: its Info.plist names `zone.hexagon.topo` as `WKCompanionAppBundleIdentifier` and sets `WKRunsIndependentlyOfCompanionApp`, since it reads CloudKit itself and never asks the phone, and the `Topo` target embeds it under `Watch/`. Its versions are the phone app's, which the watch insists on; `scripts/check-built-plist.sh` reads all of it off the phone's product. The watch's App IDs, `zone.hexagon.topo.watch` and `zone.hexagon.topo.watch.widgets`, have their own profiles, which `-allowProvisioningUpdates` makes and keeps beside the phone's.

A watch gets a build two ways:

1. **Through the phone.** Once Topo is installed on the iPhone, from the push or the page, the Watch app on the phone lists Topo: under My Watch › Available Apps with an **Install** button, or installed already when Automatic App Install is on (My Watch › App Store). A newer build on the phone updates the watch the same way. This needs nothing of buddybox and is the route that always works.
2. **Direct from buddybox.** `push-install.sh` runs `xcrun devicectl device install app --device <watch udid> TopoWatch.app` with the app unpacked from the ipa. The watch is paired with buddybox over the local network (`manualPairing`, transport `localNetwork`) and is in every profile, so what stands between them is the tunnel CoreDevice raises to it: `devicectl list devices` can say `available (paired)` while `devicectl device info details --device <udid>` answers `A connection to this device could not be established`, and then the push's line for the watch is a skip naming the error. `devicectl device info details` is the read that says whether the tunnel comes up. An install then answers why: `The device rejected the Bluetooth connection attempt` (`RemotePairingError` 1035) is the watch having dropped its pairing with buddybox while buddybox still keeps its own, and the remedy CoreDevice names is pairing it again by connecting its iPhone to buddybox by cable, with the watch near it and unlocked. Developer Mode on the watch (Settings › Privacy & Security › Developer Mode) is what any install to it needs besides.

A debug build of the watch app goes the same two ways: the `Topo` scheme's Debug build embeds it, so installing that `Topo.app` on the phone offers it, and `xcrun devicectl device install app --device <watch udid> <Topo.app>/Watch/TopoWatch.app` pushes it straight to a watch that is reachable.

