#!/usr/bin/env bash
# Builds ClipDesk.app from the Swift package.
#
# Usage: scripts/build-app.sh [--debug] [--universal] [--output DIR]
#   --debug      Build the debug configuration (default: release)
#   --universal  Build an arm64 + x86_64 universal binary (default: arm64 only)
#   --output     Output directory (default: build)
#
# Environment:
#   CODESIGN_IDENTITY  Signing identity (default "-" = ad-hoc). A Developer ID identity
#                      also enables a secure timestamp, required for notarization.
#   BUILD_NUMBER       CFBundleVersion (default: number of commits).
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="release"
archs=("arm64")
output_dir="build"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) configuration="debug" ;;
    --universal) archs=("arm64" "x86_64") ;;
    --output) output_dir="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

version="$(tr -d '[:space:]' < VERSION)"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
identity="${CODESIGN_IDENTITY:--}"
min_macos="14.0"

binaries=()
for arch in "${archs[@]}"; do
  triple="${arch}-apple-macosx${min_macos}"
  echo "==> Building ClipDesk ($configuration, $arch)"
  swift build -c "$configuration" --product ClipDesk --triple "$triple"
  bin_dir="$(swift build -c "$configuration" --product ClipDesk --triple "$triple" --show-bin-path)"
  binaries+=("$bin_dir/ClipDesk")
done

app="$output_dir/ClipDesk.app"
# Assemble and sign outside the project folder: in folders managed by a file provider
# (for example iCloud Desktop & Documents sync) the system can attach Finder metadata to the
# bundle at any moment, which makes codesign fail.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/ClipDesk.app"

echo "==> Assembling $app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
if [[ ${#binaries[@]} -gt 1 ]]; then
  lipo -create "${binaries[@]}" -output "$bundle/Contents/MacOS/ClipDesk"
else
  cp "${binaries[0]}" "$bundle/Contents/MacOS/ClipDesk"
fi
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" Resources/Info.plist > "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$bundle/Contents/PkgInfo"
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
xattr -cr "$bundle"

echo "==> Signing ($( [[ "$identity" == "-" ]] && echo "ad-hoc" || echo "$identity" ))"
sign_args=(--force --options runtime --sign "$identity")
if [[ "$identity" != "-" ]]; then
  sign_args+=(--timestamp)
fi
codesign "${sign_args[@]}" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"

mkdir -p "$output_dir"
rm -rf "$app"
ditto --norsrc --noextattr --noqtn "$bundle" "$app"
# Content signature check; extended attributes added later by Finder do not affect it.
codesign --verify --verbose=1 "$app"

echo "==> Built $app"
lipo -info "$app/Contents/MacOS/ClipDesk"
