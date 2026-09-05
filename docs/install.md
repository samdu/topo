# Installing Topo on a phone

Topo is not in the App Store yet. The iOS app ships over the air as a development-signed build for the devices enrolled on team 4A5NSJ6Y3G, so it runs only on those.

## Install

1. On the iPhone, open Safari (it must be Safari) at https://experiments.hexagon.zone/ota/files/623f17f9f38db5b81d0b/ and tap **Install Topo**, then **Install** on the system prompt.
2. Wait for the icon to finish loading on the Home Screen. A first install of an unsigned-by-the-store developer app may ask, on launch, to trust the developer: Settings › General › VPN & Device Management › Apple Development: Sam du Rose › Trust.
3. Open Topo. It reads the CloudKit container on the phone's iCloud account (`iCloud.zone.hexagon.topo`, development environment), so iCloud Drive must be on for the account, and the first device to launch becomes primary and shows Sign in with Claude.

Tapping the same link again installs the newer build over the old one; the page shows the commit it was built from, and `version.json` beside it carries the same.

## Cutting a build

`publish-topo.sh` in the `ota` experiment of samdu/experiments does it end to end on buddybox: archive and export the `Topo` scheme dev-signed from a detached checkout of the given ref (default `origin/main`), commit the ipa and `version.json` under the slug, and bounce the `ota` deployment. It needs the login keychain, so run it from a GUI-session shell as buddy, not a bare ssh shell.

Signing is automatic with the team set in `project.yml`. The iCloud container and the App ID's capabilities are registered by Xcode from the entitlements when a project with a team is opened in it, which is how the container came to exist; `xcodebuild -allowProvisioningUpdates` alone creates the App ID and profile but not a container.
