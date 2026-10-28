#!/usr/bin/env bash
# Packages ClipDesk.app into a compressed, verified DMG with an Applications shortcut.
#
# Usage: scripts/package-dmg.sh [path/to/ClipDesk.app] [output-dir]
# Environment:
#   CODESIGN_IDENTITY  When set to a real identity, the DMG is signed too.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/ClipDesk.app}"
output_dir="${2:-build}"
version="$(tr -d '[:space:]' < VERSION)"
dmg="$output_dir/ClipDesk-$version.dmg"
volume="ClipDesk $version"

if [[ ! -x "$app/Contents/MacOS/ClipDesk" ]]; then
  echo "error: $app is missing or incomplete. Run scripts/build-app.sh first." >&2
  exit 1
fi

staging="$(mktemp -d)"
mount_point="$(mktemp -d)"
cleanup() {
  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  rm -rf "$staging" "$mount_point"
}
trap cleanup EXIT

echo "==> Staging"
# Strip Finder/file-provider metadata (e.g. from iCloud-synced folders); it breaks strict signature checks.
ditto --norsrc --noextattr --noqtn "$app" "$staging/ClipDesk.app"
ln -s /Applications "$staging/Applications"
cp packaging/Install.txt "$staging/Install ClipDesk.txt"

echo "==> Creating $dmg"
mkdir -p "$output_dir"
rm -f "$dmg" "$dmg.sha256"
hdiutil create -volname "$volume" -srcfolder "$staging" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 -ov "$dmg" >/dev/null

if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$dmg"
fi

echo "==> Verifying"
hdiutil verify "$dmg" >/dev/null
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_point" -quiet
mounted_app="$mount_point/ClipDesk.app"
test -x "$mounted_app/Contents/MacOS/ClipDesk" || { echo "error: app binary missing in DMG" >&2; exit 1; }
test -L "$mount_point/Applications" || { echo "error: Applications link missing in DMG" >&2; exit 1; }
codesign --verify --strict "$mounted_app"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mounted_app/Contents/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mounted_app/Contents/Info.plist")"
if [[ "$bundle_version" != "$version" ]]; then
  echo "error: DMG contains version $bundle_version, expected $version" >&2
  exit 1
fi
echo "    contents: $(ls "$mount_point" | tr '\n' ' ')"
echo "    app: $bundle_id $bundle_version ($(lipo -archs "$mounted_app/Contents/MacOS/ClipDesk"))"
hdiutil detach "$mount_point" -quiet

(cd "$output_dir" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "==> Created $dmg ($(du -h "$dmg" | cut -f1))"
cat "$dmg.sha256"
