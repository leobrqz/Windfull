# WindFull releases

This procedure adapts the OpenRemoteControl GitHub release workflow to WindFull's Android client and Windows host. A normal source change does not create a version. A requested release is complete only after the commit, annotated tag, GitHub release and attachments have been verified. Respect any explicit request to pause before publication.

## Versions and signing

- Keep `app/pubspec.yaml` and `server/pubspec.yaml` at the same `MAJOR.MINOR.PATCH+BUILD`. Increase `BUILD` for every distributed version.
- Use semantic versions: patch for compatible fixes, minor for features and major for breaking changes; before 1.0, use a minor bump for breaking changes. Tag the release commit on `main` as `vMAJOR.MINOR.PATCH`.
- Configure an Android release keystore before the first distributed build. Copy `app/android/key.properties.example` to `app/android/key.properties`, supply your own key and passwords, and keep the keystore and properties outside version control. Back up the key securely; Android updates must use the same signing certificate.
- `-AllowDebugSigning` builds a test-only APK using the local debug key. Never use that switch for publication. If a release already exists, compare its APK certificate with the new APK using `-PreviousApk`.
- A Windows ZIP is currently a portable Flutter bundle, not an installer or an automatic-update package. Add update-specific artifacts only when the corresponding feature exists.
- Published tags and releases are immutable. Do not overwrite them to repair a release.

For a first release, create your own persistent key with `keytool` (the example below uses the JDK bundled with Android Studio; adjust its path if necessary):

```powershell
$signingDir = Join-Path $env:USERPROFILE '.windfull\signing'
New-Item -ItemType Directory -Force -Path $signingDir | Out-Null
& 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe' -genkeypair -v -keystore (Join-Path $signingDir 'windfull-release.jks') -alias windfull -keyalg RSA -keysize 3072 -validity 10000
```

The tool prompts for the key details and password. Point `key.properties` at the resulting keystore and keep both private. To inspect the expected certificate, run `keytool -list -v -keystore <keystore-path> -alias windfull` and compare its SHA-256 fingerprint with the verifier's output.

## Build and verify

### Windows build prerequisites

The official Windows build requires Flutter with Windows desktop support, Visual Studio Build Tools with the **Desktop development with C++** workload and Windows SDK, Rust stable using the `x86_64-pc-windows-msvc` toolchain, and Strawberry Perl. The Rust bridge builds OpenSSL statically through `openssl-src`; NASM is optional, and `openssl-src` selects its no-assembly build when NASM is not on `PATH`.

`scripts/build_windows.ps1` detects a standard Strawberry Perl installation or the portable copy at `%LOCALAPPDATA%\WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin`. To use another installation, pass either its `perl\bin` directory or the full path to `perl.exe`:

```powershell
.\scripts\build_windows.ps1 -PerlBin 'C:\Tools\strawberry-perl\perl\bin'
```

The script prepends that directory only to the build process's `PATH` and restores the original process value on exit. It runs `cargo build --release --locked --manifest-path server/native/samsung/Cargo.toml` before Flutter. A missing manifest, Perl installation, Cargo failure or missing bridge binary stops the build with an error. The resulting ZIP places `windfull-samsung-ocf.exe` beside `windfull_server.exe`.

For local Windows development, build the Debug bridge and then run the Flutter host. CMake installs an existing Debug or Release bridge beside the host executable; the optional install rule does not replace the required bridge build in the official release script.

```powershell
cargo build --locked --manifest-path server/native/samsung/Cargo.toml
cd server
flutter run -d windows
```

From the repository root on Windows:

```powershell
cd app
flutter pub get
flutter analyze
if (Test-Path test) { flutter test }
cd ../server
flutter pub get
flutter analyze
if (Test-Path test) { flutter test }
cd ..
.\scripts\build_windows.ps1
.\scripts\build_android.ps1
.\scripts\verify_release.ps1
```

Run tests when present; an empty scaffold may not yet have any. For all releases after the first, download the previous published APK and verify signer continuity:

```powershell
gh release download <previous-tag> --pattern Windfull-Android-universal-release.apk --dir <verification-directory>
.\scripts\verify_release.ps1 -PreviousApk <verification-directory>\Windfull-Android-universal-release.apk
```

The verifier checks synchronized versions, the APK version and signing certificate, the Windows executable version, the required `windfull-samsung-ocf.exe` bridge, both individual checksums and the contents of the Windows ZIP. It writes a combined `output/release/SHA256SUMS.txt` containing the two assets. Inspect the signer output and retain the previous certificate. `key.properties` must reference the intended, persistent release key.

## Publish a requested release

1. Review the current version, tags and intended changes. Write concise English release notes to a temporary UTF-8 Markdown file with real newlines. Mention issue or PR links only when relevant and verified.
2. Confirm the worktree contains only intended source changes, commit them on `main`, and confirm no matching local or remote tag or published release already exists.
3. Create the annotated `vMAJOR.MINOR.PATCH` tag on the release commit and push `main` and that tag. Create a **draft** GitHub release with the prepared title and notes; attach:
   - `output/android/Windfull-Android-universal-release.apk`
   - `output/windows/Windfull-Windows-x64.zip`
   - `output/release/SHA256SUMS.txt`
4. Download all three draft attachments to a fresh verification directory and compare each downloaded SHA-256 digest to the locally verified file and the combined checksum list. Equal digests establish that the verified versions, Windows metadata and APK signature are present in the downloaded assets. Check the title, notes, tag and exact asset names. Finish any failed upload before publishing.
5. Publish the draft, then verify it is no longer a draft and check its URL, tag, title and attachments with `gh release view`. Report the release URL.

Use `gh release create --draft --verify-tag --title <title> --notes-file <notes-file>` and `gh release upload` with explicit file paths. Keep notes, local signing configuration, caches and output artifacts out of Git.
