# Installing Topo on a phone

Topo is not in the App Store yet. Sam's iPhone 15 Pro (`83FAFEC2-7326-5E79-A186-AB8E1B0A32E3`) is the primary test device: it is paired with buddybox over the local network with Developer Mode on, so it takes a debug build directly (below) as well as the over-the-air builds. His other devices are not paired for direct installs and get builds from the install page only, so **every merge to main republishes the install page** (`publish-topo.sh`, under Cutting a build).

Topo is not in the App Store yet. The iOS app ships over the air as a development-signed build for the devices enrolled on team 4A5NSJ6Y3G, so it runs only on those.

## Install

1. On the iPhone, open Safari (it must be Safari) at https://experiments.hexagon.zone/ota/files/623f17f9f38db5b81d0b/ and tap **Install Topo**, then **Install** on the system prompt.
2. Wait for the icon to finish loading on the Home Screen. A first install of an unsigned-by-the-store developer app may ask, on launch, to trust the developer: Settings › General › VPN & Device Management › Apple Development: Sam du Rose › Trust.
3. Open Topo. It reads the CloudKit container on the phone's iCloud account (`iCloud.zone.hexagon.topo`, development environment), so iCloud Drive must be on for the account, and the first device to launch becomes primary and shows Sign in with Claude.

Tapping the same link again installs the newer build over the old one; the page shows the commit it was built from, and `version.json` beside it carries the same.

## Cutting a build

`publish-topo.sh` in the `ota` experiment of samdu/experiments does it end to end on buddybox: archive and export the `Topo` scheme dev-signed from a detached checkout of the given ref (default `origin/main`), commit the ipa and `version.json` under the slug, and bounce the `ota` deployment. It needs the login keychain, so run it from a GUI-session shell as buddy, not a bare ssh shell.

Signing is automatic with the team set in `project.yml`. The iCloud container and the App ID's capabilities are registered by Xcode from the entitlements when a project with a team is opened in it, which is how the container came to exist; `xcodebuild -allowProvisioningUpdates` alone creates the App ID and profile but not a container.

## Direct install to the test phone

A debug build, with the Tuning sliders and the Haiku pin, goes straight to the phone from buddybox: build the `Topo` scheme Debug for `generic/platform=iOS`, then `xcrun devicectl device install app --device 83FAFEC2-7326-5E79-A186-AB8E1B0A32E3 <path to Topo.app>` and `xcrun devicectl device process launch --device <id> zone.hexagon.topo`. `xcrun devicectl list devices` shows the phone as `available (paired)` when it is reachable; if it is not listed, it is off the home network or locked past its pairing window, and the install page is the fallback. Like `publish-topo.sh`, the build needs the login keychain, so run it from a GUI-session shell as buddy.
