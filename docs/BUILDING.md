# Building, testing and packaging ClipDesk

## Toolchain

- Swift 6 (language mode 6) and the macOS 14+ SDK. Deployment target: **macOS 14.0**.
- Works with full Xcode 16+ or with only the Command Line Tools. The local development machine used CLT 26.5 with Swift 6.3.3, without Xcode.
- No third-party packages.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/test.sh` | Runs `swift test`. With only the Command Line Tools installed, it adds the framework and rpath flags SwiftPM needs to find Swift Testing; with Xcode it is plain `swift test`. |
| `scripts/build-app.sh [--debug] [--universal] [--output DIR]` | Builds the `ClipDesk` product per architecture (`--triple <arch>-apple-macosx14.0`), `lipo`s a universal binary when asked, then assembles `ClipDesk.app` from `Resources/Info.plist` (version from `VERSION`, build number from the commit count) and `Resources/AppIcon.icns`. It assembles and signs the bundle in a temporary directory, verifies it with `codesign --verify --strict`, then copies it to `build/`. |
| `scripts/package-dmg.sh [app] [outdir]` | Stages the app (without extended attributes) with an `/Applications` link and an install note, then creates a compressed HFS+ DMG named "ClipDesk <version>". It verifies the image (`hdiutil verify`), mounts it read-only, checks the app binary, the link, the strict signature and the bundle version, and writes a `.sha256`. |
| `scripts/make-icon.sh` | Regenerates `Resources/AppIcon.icns` and `AppIcon-1024.png` from `scripts/generate-icon.swift`, which draws the icon with AppKit. |
| `scripts/ci-select-xcode.sh` | CI only: selects the newest stable Xcode on the runner and fails if it is older than 16. |

### Signing

`build-app.sh` signs ad-hoc (`-`) with the hardened runtime by default. Set `CODESIGN_IDENTITY` to a Developer ID Application identity to sign for distribution; a secure timestamp is then added, and `package-dmg.sh` signs the DMG too. No Developer ID identity is configured for this repository.

### Building inside iCloud-synced folders

If the project lives in a folder managed by iCloud Drive (for example Desktop & Documents sync), the system attaches Finder and file-provider extended attributes to build products. `codesign` rejects these ("resource fork, Finder information, or similar detritus not allowed"). The build script therefore signs in a temporary directory, and the DMG script strips extended attributes when staging.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes to `main`, on pull requests and on manual dispatch:

1. Check out the repository (full history, for the build number).
2. Select the newest stable Xcode (`scripts/ci-select-xcode.sh`).
3. Run the tests (`scripts/test.sh`).
4. Build a universal Release app.
5. Package and verify the DMG: checksum, mount, `Applications` link, strict signature, architectures.
6. Upload the DMG and checksum as the `ClipDesk-dmg` artifact, kept for 30 days.

**Runner:** `macos-26`, a GitHub-hosted Apple-silicon image listed in GitHub's "Choose the runner for a job" documentation. It is pinned rather than `macos-latest` so image upgrades are deliberate. Xcode is selected at run time instead of hard-coding a version that might not be installed.

### Releases

`.github/workflows/release.yml` runs when a `v*.*.*` tag is pushed (or manually for an existing tag). It:

- checks that the tag matches `VERSION`;
- runs the tests;
- builds and packages the app;
- publishes a GitHub release with the DMG and checksum.

Developer ID signing and notarization steps run **only if** these repository secrets exist:

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `DEVELOPER_ID_IDENTITY` | Import the certificate into a temporary keychain and sign. |
| `NOTARIZATION_APPLE_ID`, `NOTARIZATION_TEAM_ID`, `NOTARIZATION_APP_PASSWORD` | `notarytool submit --wait`, then `stapler staple`. |

None of these secrets are configured, so these steps have never been exercised. The release notes state whether a build is ad-hoc signed, Developer ID signed, or notarized.

To cut a release: update `VERSION`, commit, then `git tag v<version> && git push origin v<version>`.
