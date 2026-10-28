#!/usr/bin/env bash
# Selects the newest stable (non-beta) Xcode installed on a GitHub-hosted macOS runner
# and fails early if it is older than the minimum this project needs.
set -euo pipefail

minimum_major=16 # Swift 6 toolchain and macOS 14+ SDK

candidate="$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -vi beta | sort -V | tail -1 || true)"
if [[ -z "$candidate" && -d /Applications/Xcode.app ]]; then
  candidate=/Applications/Xcode.app
fi
if [[ -z "$candidate" ]]; then
  echo "::error::No Xcode installation found" >&2
  exit 1
fi

sudo xcode-select --switch "$candidate/Contents/Developer"
version="$(xcodebuild -version | head -1 | awk '{print $2}')"
if (( ${version%%.*} < minimum_major )); then
  echo "::error::Xcode $version is older than the required $minimum_major.0" >&2
  exit 1
fi

echo "Selected $candidate"
xcodebuild -version
swift --version
xcrun --show-sdk-version
