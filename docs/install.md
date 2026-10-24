# Installing Topo on a phone

Topo is not in the App Store yet. The iOS app ships as a development-signed build for the devices enrolled on team 4A5NSJ6Y3G, so it runs only on those.

A fresh build reaches Sam's devices by push: buddybox is paired over the local network with his iPhone 15 Pro (the primary test device, Developer Mode on), his iPad and his Apple Watch, and `publish-topo.sh` (under Cutting a build) installs each build it cuts on the iPhone and the iPad when they are in reach, with no tap. The watch gets nothing from it: Topo's ipa carries no watchOS app. The same build is published to the install page, which is how a device buddybox is not paired with, or one that was away when the build was cut, gets it. **Every merge to main is cut and pushed**: the janitor (`docs/janitor.md`) runs `publish-topo.sh origin/main` within fifteen minutes of the page's commit falling behind origin/main.

## Install from the page

1. On the iPhone, open Safari (it must be Safari) at https://experiments.hexagon.zone/ota/files/623f17f9f38db5b81d0b/ and tap **Install Topo**, then **Install** on the system prompt.
2. Wait for the icon to finish loading on the Home Screen. A first install of an unsigned-by-the-store developer app may ask, on launch, to trust the developer: Settings › General › VPN & Device Management › Apple Development: Sam du Rose › Trust.
3. Open Topo. It reads the CloudKit container on the phone's iCloud account (`iCloud.zone.hexagon.topo`, development environment), so iCloud Drive must be on for the account, and the first device to launch becomes primary and shows Sign in with Claude.

Tapping the same link again installs the newer build over the old one; the page shows the commit it was built from, and `version.json` beside it carries the same.

## Cutting a build

`publish-topo.sh` in the `ota` experiment of samdu/experiments does it end to end on buddybox: archive and export the `Topo` scheme dev-signed from a detached checkout of the given ref (default `origin/main`), copy the ipa and `version.json` onto the `ota` pod's PVC under the slug, where they are served at once (no commit, no restart), and check the ipa URL answers 200. `--dev <ref>` cuts a branch into the "Latest dev" slug instead. The archive is told the build number (minutes since 2026), the commit (`TOPO_SOURCE_COMMIT`) and the channel (`TOPO_CHANNEL`, `main` or `dev`), which the app hands the guest (`docs/guest.md`, *The resident process*).

With the publish done it pushes the ipa to the paired devices through `push-install.sh` beside it: `xcrun devicectl list devices` read live, then `xcrun devicectl device install app --device <udid> Topo.ipa` on each physical iPhone and iPad that is `available (paired)`, over Wi-Fi. It installs and does not launch: `devicectl device process launch` is a separate call, which `scripts/perf-run.sh` makes and this does not. It prints one line per device, `installed` or `skipped: <reason>` — a device off the home network, a watch when the ipa carries no watchOS app, which Topo's does not — and a skipped device never fails the publish. A main build and a `--dev` build are the same app, so the last one pushed is the one installed. `--no-push`, as the first argument, publishes only.

It needs the login keychain, so run it from a GUI-session shell as buddy, not a bare ssh shell.

Signing is automatic with the team set in `project.yml`. The iCloud container and the App ID's capabilities are registered by Xcode from the entitlements when a project with a team is opened in it, which is how the container came to exist; `xcodebuild -allowProvisioningUpdates` alone creates the App ID and profile but not a container.

## A debug build on the test phone

A debug build, with the Tuning sliders and the Haiku pin, is the one build `publish-topo.sh` does not cut: build the `Topo` scheme Debug for `generic/platform=iOS`, then `xcrun devicectl device install app --device <udid> <path to Topo.app>` and `xcrun devicectl device process launch --device <udid> zone.hexagon.topo`, with the UDID from `xcrun devicectl list devices`. A device that is not `available (paired)` there is off the home network or locked past its pairing window. Like `publish-topo.sh`, the build needs the login keychain, so run it from a GUI-session shell as buddy.
