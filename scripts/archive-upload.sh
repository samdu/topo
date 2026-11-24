#!/usr/bin/env bash
# Archives Topo for the App Store and, when asked, sends it to TestFlight.
#
#   scripts/archive-upload.sh                 # archive and export, nothing leaves this Mac
#   scripts/archive-upload.sh --upload        # ... and upload to App Store Connect
#   scripts/archive-upload.sh --validate      # ... and ask App Store Connect whether it would take it
#   scripts/archive-upload.sh --upload --voice  # ... and the voice's asset pack before the build
#   scripts/archive-upload.sh --upload --ear    # ... and the ear's asset pack before the build
#   BUILD=42 scripts/archive-upload.sh        # a build number of your choosing
#
# The archive needs a Distribution certificate and an App Store provisioning
# profile for the team in Distribution/ExportOptions.plist; Xcode makes both
# on its own the first time somebody signed into the account archives here.
# The upload needs an App Store Connect API key, and docs/testflight.md says
# where to get one.
#
# The voice's weights are never in the archive: they are the Apple-hosted asset
# pack `phonon-40m-en`, which App Store Connect keeps apart from the builds.
# `--voice` packages it (scripts/phonon-bundles.sh) and, with `--upload`, sends
# it as a new version of the pack before the build; it is wanted only when the
# bundle has changed, since a build uses the pack's current version. The ear's
# weights are the pack `parakeet-ultra` the same way, and `--ear`
# packages it (scripts/ear-bundle.sh) and, with `--upload`, sends it.
# `--upload` without one of them is refused before anything is built unless
# App Store Connect serves the version of that pack Distribution/asset-packs.json
# records for the bundle its script pins, and the refusal names the flag to add.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# Both xcodebuilds run with every exported variable whose name says it holds a secret taken out
# of their environment, which xcodebuild writes into the archive's build description.
source "$root/scripts/secret-env.sh"

scheme=Topo
project=Topo.xcodeproj
out="$root/build"
archive="$out/$scheme.xcarchive"
export_options="$root/Distribution/ExportOptions.plist"

upload=no
validate=no
voice=no
ear=no
apple_id=6826966978
for argument in "$@"; do
  case "$argument" in
    --upload) upload=yes ;;
    --validate) validate=yes ;;
    --voice) voice=yes ;;
    --ear) ear=yes ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

# TestFlight only insists on one thing: the build number goes up. Seconds
# since 2026 is monotonic, short enough to read, and needs nothing kept
# between runs.
build="${BUILD:-$(( ($(date +%s) - 1767225600) / 60 ))}"
echo "==> build $build"

# The About screen names the commit this build is as its corresponding source, which is only
# true of a clean tree whose commit is on GitHub.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "the tree has uncommitted changes; a build shipped from it has no commit that is its source" >&2
  exit 1
fi
commit="$(git rev-parse HEAD)"
[ -n "$(git branch -r --contains "$commit")" ] \
  || { echo "$commit is on no remote branch; push it first, since the About screen points at it" >&2; exit 1; }

# The key: from the environment, the login keychain or 1Password, in that order,
# and in whatever shape it was kept (scripts/asc-pem.sh). Over ssh the keychain
# answers nothing and exits 0, so an empty answer is what sends the read on to
# the item `Topo App Store Connect` in the Homelab vault, asked only with a
# service account in the environment, through dotfiles' op shim where there is
# one. Nothing here writes it anywhere but a folder of its own, which is where
# altool looks and which is taken away on the way out. With it xcodebuild
# registers a new target's App ID and makes its profile with no Apple ID signed
# in to Xcode; without it the archive is whatever Xcode's own accounts allow,
# and there is no upload.
#
# 1Password is asked through dotfiles' op shim where it is installed: run headless, the real op can stop
# on a consent prompt for the 1Password app's container that nobody sees, and
# the shim keeps it off that container (dotfiles shims/op).
asc_op() { if [ -x "$HOME/.local/shims/op" ]; then printf '%s' "$HOME/.local/shims/op"; else printf op; fi; }
asc_part() { # asc_part <the environment's value> <keychain service> <1Password field>
  local got="$1"
  [ -n "$got" ] || got="$(security find-generic-password -s "$2" -w 2>/dev/null || true)"
  if [ -z "$got" ] && [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    got="$("$(asc_op)" read "op://Homelab/Topo App Store Connect/$3" 2>/dev/null || true)"
  fi
  printf '%s' "$got"
}
key_id="$(asc_part "${ASC_KEY_ID:-}" topo-asc-key-id key_id)"
issuer="$(asc_part "${ASC_ISSUER_ID:-}" topo-asc-issuer-id issuer_id)"
private_key="$(asc_part "${ASC_PRIVATE_KEY:-}" topo-asc-private-key private_key)"
# A key found in part is said, not taken for no key.
missing="$([ -n "$key_id" ] || printf ' key id')$([ -n "$issuer" ] || printf ' issuer id')$([ -n "$private_key" ] || printf ' private key')"
if [ -n "$key_id$issuer$private_key" ] && [ -n "$missing" ]; then
  echo "the App Store Connect API key is incomplete: the environment, the keychain and 1Password gave no$missing" >&2
  exit 1
fi

auth=()
if [ -n "$key_id" ] && [ -n "$issuer" ] && [ -n "$private_key" ]; then
  keys="$(mktemp -d)"
  trap 'rm -rf "$keys"' EXIT
  ( umask 077; printf '%s' "$private_key" | scripts/asc-pem.sh > "$keys/AuthKey_$key_id.p8" ) \
    || { echo "the App Store Connect API key is not a .p8 in any shape scripts/asc-pem.sh reads" >&2; exit 1; }
  export API_PRIVATE_KEYS_DIR="$keys"
  auth=(-authenticationKeyPath "$keys/AuthKey_$key_id.p8" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
elif [ "$upload" = yes ] || [ "$validate" = yes ]; then
  cat >&2 <<'MISSING'
No App Store Connect API key.

Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the .p8's contents), or
put them in the login keychain as topo-asc-key-id, topo-asc-issuer-id and
topo-asc-private-key. Over ssh the keychain answers nothing: there, set
OP_SERVICE_ACCOUNT_TOKEN and the key is read from 1Password's item
"Topo App Store Connect" (Homelab). docs/testflight.md says how to make one.
MISSING
  exit 1
fi

# Every TestFlight build is served each pack's internal beta version, whichever build it is, so a
# build uploaded without a pack gets whatever version App Store Connect has. No content of a
# version can be read back (`ba-package` makes a different .aar of the same files each time), so
# Distribution/asset-packs.json records which bundle each pack's version was uploaded from: the
# sha256 of the bundle.json it carries, which `<script> pin` prints without fetching. An upload is
# refused, before anything is built, unless for each pack not uploaded with it the pin names the
# recorded bundle and App Store Connect's internal beta version is the recorded one, its internal
# beta release READY_FOR_TESTING (a version's own state also moves with its external review). A pack uploaded with the build is recorded after its upload, read back from App Store
# Connect, which numbers it; the record is then a change to commit before the next upload.
packs="$root/Distribution/asset-packs.json"
refuse() { printf '%s\n' "$@" >&2; exit 1; }
pack_listing() { # pack_listing <pack>: altool's JSON of its versions, empty where it has none; what it said in $listing_err
  xcrun altool --list-asset-pack-versions --apple-id "$apple_id" --asset-pack-identifier "$1" \
    --apiKey "$key_id" --apiIssuer "$issuer" --output-format json 2>"$listing_err"
}
# A listing is read whole or not at all: one JSON document, its internal beta version named by an
# id that exactly one listed version carries, every version with an id; jq fails on anything else.
pack_served() { # pack_served <listing>: "<version> <internal beta release state> <highest version> <id>" of the internal beta version
  jq -rs 'if length != 1 then error("not one document") else .[0] end
    | (.assetPack.relationships.internalBetaVersion.data.id) as $id
    | ([.assetPackVersions[].version | tonumber] | max) as $top
    | [.assetPackVersions[] | select(.assetPackVersionID == $id)]
    | if length != 1 then error("internal beta version not listed once") else .[0] end
    | "\(.version) \(.internalBetaReleaseState) \($top) \($id)"' <<<"$1" 2>/dev/null
}
pack_ids() { # pack_ids <listing>: the id of every version it lists
  jq -rs 'if length != 1 then error("not one document") else .[0] end
    | .assetPackVersions[] | .assetPackVersionID
    | if type == "string" and . != "" then . else error("a version with no id") end' <<<"$1" 2>/dev/null
}
pack_read() { # pack_read <pack> <what has happened>: sets version, state, top, id and ids, or refuses; 1 where it has no version
  local listing served
  listing="$(pack_listing "$1")" \
    || refuse "$1: App Store Connect's versions of the pack could not be read: $(sed '/^[[:space:]]*$/d' "$listing_err" | tail -1)" "$2"
  [ -n "$listing" ] || return 1
  served="$(pack_served "$listing")" && ids="$(pack_ids "$listing")" && [ -n "$served" ] \
    || refuse "$1: App Store Connect's listing of the pack is not one document naming an internal beta version it lists once, every version with an id." "$2"
  read -r version state top id <<<"$served"
}
pack_check() { # pack_check <pack> <flag> <script>
  local pack="$1" flag="$2" script="$3" bundle recorded recorded_bundle
  local instead="scripts/archive-upload.sh --validate --upload $flag" nothing="Nothing was built."
  bundle="$("$root/scripts/$script" pin)" || refuse "$pack: scripts/$script pin failed. $nothing"
  recorded="$(jq -r --arg p "$pack" '.[$p].version // empty' "$packs")"
  recorded_bundle="$(jq -r --arg p "$pack" '.[$p].bundle // empty' "$packs")"
  [ -n "$recorded" ] && [ "$bundle" = "$recorded_bundle" ] \
    || refuse "$pack: the bundle scripts/$script pins ($bundle) is not the one Distribution/asset-packs.json records${recorded:+ version $recorded} as uploaded from, so a build uploaded without the pack would be served another bundle. $nothing" \
              "Run instead: $instead"
  pack_read "$pack" "$nothing" \
    || refuse "$pack: App Store Connect has no version of the pack, so a fresh install of this build would have none. $nothing" \
              "Run instead: $instead"
  [ "$version" = "$recorded" ] \
    || refuse "$pack: App Store Connect serves version $version (the highest is $top) and Distribution/asset-packs.json records version $recorded as this pin's. $nothing" \
              "If version $version was uploaded from this pin, record it and commit that; otherwise run instead: $instead"
  case "$state" in
    READY_FOR_TESTING) ;;
    FAILED) refuse "$pack: version $version on App Store Connect FAILED. $nothing" "Run instead: $instead" ;;
    *) refuse "$pack: version $version on App Store Connect is $state, not READY_FOR_TESTING. $nothing Run this again once it is." ;;
  esac
  echo "==> $pack: version $version on App Store Connect is this pin's"
}
pack_known() { # pack_known <pack>: the ids of the versions App Store Connect lists now, before an upload
  local listing
  listing="$(pack_listing "$1")" \
    || refuse "$1: App Store Connect's versions of the pack could not be read before its upload: $(sed '/^[[:space:]]*$/d' "$listing_err" | tail -1)" \
              "The archive was built; neither the pack nor the build was uploaded."
  [ -z "$listing" ] || pack_ids "$listing" \
    || refuse "$1: App Store Connect's listing of the pack before its upload is not one this reads." "The archive was built; neither the pack nor the build was uploaded."
}
pack_record() { # pack_record <pack> <script> <ids listed before its upload>: the version just uploaded, into the record
  local pack="$1" bundle after="The pack was uploaded and the build was not; the pack's new version is not recorded. Read it with altool --list-asset-pack-versions and record it in Distribution/asset-packs.json if it is this pin's."
  bundle="$("$root/scripts/$2" pin)" || refuse "$pack: scripts/$2 pin failed." "$after"
  pack_read "$pack" "$after" || refuse "$pack: App Store Connect lists no version of the pack after its upload." "$after"
  # Exactly one version is new since the listing before the upload, so it is this upload's; with
  # two, another upload landed between the listings and which bundle each holds is unknown.
  local new
  new="$(grep -vxF -f <(printf '%s\n' "$3") <<<"$ids" || true)"
  [ "$new" = "$id" ] && [ "$version" = "$top" ] && [ "$state" = READY_FOR_TESTING ] \
    || refuse "$pack: after its upload App Store Connect serves version $version ($state), $(grep -qxF "$id" <<<"$3" && echo "a version listed before the upload" || echo "a new one"), its highest is $top, and $(grep -c . <<<"$new" || true) version(s) are new since the listing before it." "$after"
  jq --arg p "$pack" --arg v "$version" --arg b "$bundle" '.[$p] = { version: $v, bundle: $b }' "$packs" > "$packs.new"
  mv "$packs.new" "$packs"
  echo "==> $pack: version $version recorded in Distribution/asset-packs.json; commit it before the next upload"
}
if [ "$upload" = yes ]; then
  listing_err="$(mktemp)"
  trap 'rm -rf "$keys"; rm -f "$listing_err"' EXIT
  jq -se 'length == 1 and (.[0] | type == "object")' "$packs" >/dev/null 2>&1 \
    || refuse "Distribution/asset-packs.json is missing or not one JSON object, so no pack's version can be judged. Nothing was built."
  [ "$ear" = yes ] || pack_check parakeet-ultra --ear ear-bundle.sh
  [ "$voice" = yes ] || pack_check phonon-40m-en --voice phonon-bundles.sh
fi

# The guest's kernel is built from the fork at its pin, never committed; the archive links it.
"$(dirname "${BASH_SOURCE[0]}")/build-ish.sh"
# The voice's compiled core, fetched by checksum and never committed; the archive links it.
"$(dirname "${BASH_SOURCE[0]}")/fetch-phonon.sh"

# The packages resolve into build/packages, kept for the pins they were resolved from and made
# afresh for any other, never into the derived data Xcode shares between builds: Xcode 27.2
# carries the package traits of the last resolution into the next, so a state that last saw one
# version of a package refuses or misbuilds another (docs/testing.md). The pins are compared
# as JSON without the originHash field a resolution rewrites (a copy that is missing, empty or not
# JSON names no pins), and the copy goes before the tree, so a removal cut short is finished by
# the next run.
pins=Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
packages="$out/packages"
pins_now="$(jq -cS 'del(.originHash)' "$pins" 2>/dev/null)" && pins_kept="$(jq -cS 'del(.originHash)' "$packages/Package.resolved" 2>/dev/null)" \
  && [ -n "$pins_now" ] && [ "$pins_now" = "$pins_kept" ] \
  || { rm -f "$packages/Package.resolved"; rm -rf "$packages"; }
mkdir -p "$packages"
cp "$pins" "$packages/Package.resolved" 2>/dev/null || true

rm -rf "$archive"
"${scrubbed[@]}" xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -clonedSourcePackagesDirPath "$packages" \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
  CURRENT_PROJECT_VERSION="$build" \
  TOPO_SOURCE_COMMIT="$commit" \
  TOPO_CHANNEL=testflight

"${scrubbed[@]}" xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$out/export" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}

# The weights reach a TestFlight or App Store install as the asset pack and never in the app
# (docs/voice.md); the product is the proof, not the build setting.
scripts/check-built-assets.sh "$archive/Products/Applications/$scheme.app"

ipa="$(/usr/bin/find "$out/export" -maxdepth 1 -name '*.ipa' -print -quit)"
[ -n "$ipa" ] || { echo "no .ipa in $out/export" >&2; exit 1; }
echo "==> $ipa"

if [ "$voice" = yes ]; then
  echo "==> packaging the voice's asset pack"
  scripts/phonon-bundles.sh package "$out/phonon"
fi
if [ "$ear" = yes ]; then
  echo "==> packaging the ear's asset pack"
  scripts/ear-bundle.sh package "$out/ear"
fi

[ "$upload" = yes ] || [ "$validate" = yes ] || exit 0

if [ "$validate" = yes ]; then
  echo "==> validating"
  xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
fi

if [ "$upload" = yes ] && [ "$voice" = yes ]; then
  echo "==> uploading the voice's asset pack"
  known="$(pack_known phonon-40m-en)" || exit 1
  xcrun altool --upload-asset-pack "$out/phonon/phonon-40m-en.aar" --apple-id "$apple_id" --wait \
    --apiKey "$key_id" --apiIssuer "$issuer"
  pack_record phonon-40m-en phonon-bundles.sh "$known"
fi

if [ "$upload" = yes ] && [ "$ear" = yes ]; then
  echo "==> uploading the ear's asset pack"
  known="$(pack_known parakeet-ultra)" || exit 1
  xcrun altool --upload-asset-pack "$out/ear/parakeet-ultra.aar" --apple-id "$apple_id" --wait \
    --apiKey "$key_id" --apiIssuer "$issuer"
  pack_record parakeet-ultra ear-bundle.sh "$known"
fi

if [ "$upload" = yes ]; then
  echo "==> uploading"
  xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
  echo "==> uploaded. It appears in TestFlight once App Store Connect has processed it."
fi
