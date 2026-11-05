#!/bin/bash
# Picks the Xcode the cloud builds use: the newest Xcode 27 on the runner (a release over a beta).
# iPhone Duo needs the iOS 27.1 SDK for full-screen layout and the fold APIs. When the chosen Xcode has it,
# this turns on Baget's DUO_SDK flag (BAGET_DUO_FLAG) for the rest of the job; otherwise Baget builds without
# the fold APIs and assumes a centered fold.
set -euo pipefail

pick() { ls -d /Applications/Xcode_27*.app 2>/dev/null | grep -v -i "$1" | sort -V | tail -1 || true; }
X=$(pick beta)
[ -z "$X" ] && X=$(pick '^$')
if [ -z "$X" ]; then echo "::error::No Xcode 27 on this runner"; ls -d /Applications/Xcode*; exit 1; fi
sudo xcode-select -s "$X"

SDK=$(xcrun --sdk iphoneos --show-sdk-version)
echo "::notice::Using $(xcodebuild -version | tr '\n' ' ')(iOS SDK $SDK)"
if python3 -c "import sys; v=[int(x) for x in sys.argv[1].split('.')[:2]]; sys.exit(0 if v >= [27, 1] else 1)" "$SDK"; then
  echo "BAGET_DUO_FLAG=DUO_SDK" >> "${GITHUB_ENV:-/dev/null}"
  echo "::notice::iPhone Duo: building with the fold APIs (iOS SDK $SDK)"
else
  echo "BAGET_DUO_FLAG=" >> "${GITHUB_ENV:-/dev/null}"
  echo "::warning::iPhone Duo: iOS SDK $SDK is older than 27.1, so Baget won't fill the Duo's screens or use the fold APIs. Available: $(ls -d /Applications/Xcode_27*.app 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
fi
