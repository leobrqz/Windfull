# WindFull release procedure

An ordinary source change does not create a version. When a release is requested, publish only after both clients are built and `scripts/verify_release.ps1` validates the package metadata, signatures and checksums.

## Version and signing identity

- Keep `app/pubspec.yaml` at `MAJOR.MINOR.PATCH+BUILD`; this is the Android source version and `BUILD` increases for every distributed APK. The Windows host version comes from `server/src-tauri/Cargo.toml` as `MAJOR.MINOR.PATCH`. Keep its semantic version aligned with the Android version portion; `scripts/build_windows.ps1` passes it into Tauri's build config and Velopack. The GitHub tag uses the same `MAJOR.MINOR.PATCH`.
- Use semantic versions: patch for compatible fixes, minor for features and major for breaking changes. Before 1.0, use a minor bump for breaking changes.
- Sign every public APK with the same persistent Android key. `app/android/key.properties` is local and ignored; its keystore must remain outside Git and be backed up securely. The verifier compares the APK signer with that configured keystore and, when supplied, a previous release.
- `scripts/build_android.ps1 -AllowDebugSigning` is only for local checks. Never publish its output.
- A release tag is immutable. Do not replace a published tag or silently re-upload different bytes under an existing version.

## Update behavior

### Android

The app checks the latest non-draft GitHub release and matches `android-update.json` to the published APK asset digest, size, package ID, version and signing-certificate fingerprint. Download begins only after the user approves it. The app verifies the APK checksum, package, version and signing certificate before handing installation to Android. Android shows its own final installation confirmation; WindFull cannot silently install APKs.

The first official APK establishes the permanent signing identity. A copy installed with another signing key cannot be upgraded in place; Android requires that copy to be removed before the official APK is installed. Existing local server pairings can then be approved again. Later APKs update in place with the same key.

### Windows

The Tauri host uses the pinned Velopack CLI and Rust SDK (`1.2.161`) to create a managed portable package and a full update feed. It checks the latest non-draft GitHub release from the existing `win-x64` channel. The update screen shows the version and release notes; the user must approve both download and apply/restart. Velopack validates the official feed and package hash. Before downloading, the host checks that the install folder is writable and that enough disk space is available. Updates replace only the managed application files; pairing, server identity and settings remain in the Windows user data directory.

The first managed ZIP is a one-time migration from earlier plain ZIP builds. Close the old host, extract the managed ZIP into a user-writable folder, and launch its root WindFull launcher. Keep the launcher, `Update.exe`, `current/` and `packages/` together. Pairings, server identity and user settings remain in the Windows user data directory and survive this migration and later updates.

The Windows package distributes Velopack under its MIT license. Preserve the notice at `server/src-tauri/LICENSE.velopack`; the build includes it in both the portable ZIP and the full update package.

## Build and validate

Required Windows tools: Flutter for Android, Rust stable for `x86_64-pc-windows-msvc`, Node.js/npm, Strawberry Perl, and the .NET 8 SDK. Rust must have the MSVC target and Windows SDK/build tools available. `scripts/build_windows.ps1` also checks for the portable Perl copy at `%LOCALAPPDATA%\WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin`. The build uses the frontend's locked Tauri CLI, the pinned Velopack tool manifest, and the existing Samsung OCF Rust bridge.

From the repository root:

```powershell
Push-Location app
flutter pub get
flutter analyze
Pop-Location

Push-Location server
cargo check --locked --manifest-path src-tauri/Cargo.toml
Pop-Location

Push-Location server\web
npm ci
npm run build
Pop-Location

.\scripts\build_android.ps1
.\scripts\build_windows.ps1
.\scripts\verify_release.ps1
```

The Android build produces `output/android/Windfull-Android-universal-release.apk`, its `android-update.json` catalog and a checksum list. The Windows build compiles the Tauri host and Samsung OCF bridge, then produces the managed `output/windows/Windfull-Windows-x64.zip`, the full `.nupkg` and `releases.win-x64.json`. The portable package contains the Tauri host, `windfull-samsung-ocf.exe` and `current/LICENSE.velopack`; the full update package also contains the Velopack license notice. The verifier checks both builds, package/feed identities, required Windows payloads, signatures and checksums, then writes `output/release/SHA256SUMS.txt` for the five release artifacts.

If there is a previous public APK, download it and check signer continuity:

```powershell
gh release download <previous-tag> --pattern Windfull-Android-universal-release.apk --dir .codex\previous-release
.\scripts\verify_release.ps1 -PreviousApk .codex\previous-release\Windfull-Android-universal-release.apk
```

## Publish

1. Confirm the release version and build number, check that the matching tag and release do not already exist, and write concise release notes to an ignored temporary file such as `.codex/release-notes-v0.1.0.md`.
2. Review the worktree and commit the intended source changes on `main`. Create an annotated `vMAJOR.MINOR.PATCH` tag on that commit and push `main` and the tag.
3. Create a **draft** GitHub release using the tag and release notes. Attach these exact files:

   - `output/android/Windfull-Android-universal-release.apk`
   - `output/android/android-update.json`
   - `output/windows/Windfull-Windows-x64.zip`
   - `output/windows/io.github.leobrqz.windfull.windows-MAJOR.MINOR.PATCH-win-x64-full.nupkg`
   - `output/windows/releases.win-x64.json`
   - `output/release/SHA256SUMS.txt`

4. Download the draft attachments into a new verification directory. Compare their SHA-256 hashes with the local artifacts and the combined checksum file; confirm tag, title, notes and attachment names.
5. Publish the draft, then verify its URL, tag, title, state and assets with `gh release view`.

Keep keystores, `key.properties`, local release notes, caches and generated `output/` files out of Git.
