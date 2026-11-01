#!/usr/bin/env bash
# Takes FluidAudio's LuxTTS lexicon out of the built app. FluidAudio's resource bundle
# (`FluidAudio_FluidAudio.bundle`) holds `luxtts_en_us_lexicon.tsv.zz` and
# `luxtts_en_us_g2p_aux.json`, pronunciations FluidInference harvested by running espeak-ng
# (GPL-3.0), which carry no App Store waiver. Topo never reads them (nothing constructs
# `LuxTtsG2p`, whose loader throws when they are missing), so they are removed rather than shipped.
#
# The bundle stays, empty but for its Info.plist, so `Bundle.module` still finds it. When the
# bundle carries a signature of its own, removing files breaks its seal, and the app's signature
# seals the nested bundle as it finds it, so the bundle is signed again here with the identity the
# app is being signed with. With signing off (`CODE_SIGNING_ALLOWED=NO`) there is no seal to keep.
#
# Run by the Topo target's last build phase (project.yml); `scripts/check-built-plist.sh` reads the
# product and fails one that still carries a `luxtts_` file anywhere.
#
#   scripts/strip-luxtts.sh <path to FluidAudio_FluidAudio.bundle>
set -euo pipefail

bundle="${1:?usage: strip-luxtts.sh <FluidAudio_FluidAudio.bundle>}"
if [ ! -d "$bundle" ]; then
    echo "error: $bundle is not in the product; FluidAudio's resource bundle moved, and its LuxTTS lexicon is not stripped" >&2
    exit 1
fi

removed=0
for f in "$bundle"/luxtts_*; do
    [ -e "$f" ] || continue
    rm -f "$f"
    removed=1
done

if [ "$removed" = 1 ] && [ -d "$bundle/_CodeSignature" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$bundle"
fi
echo "strip-luxtts: $bundle carries no luxtts_ file"
