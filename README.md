<p align="center">
  <img src="app/assets/brand/windfull-mark.svg" width="72" height="72" alt="WindFull logo">
</p>

<h1 align="center">WindFull</h1>

<p align="center">Control a Samsung WindFree air conditioner from Android through a Windows system-tray host on your local network.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-3C9827" alt="GNU GPL v3.0 or later"></a>
  <img src="https://img.shields.io/badge/Android-client-3DDC84?logo=android&amp;logoColor=white" alt="Android client">
  <img src="https://img.shields.io/badge/Windows-host-0078D4?logo=windows&amp;logoColor=white" alt="Windows host">
</p>

## Controls

- Power on and off
- Target temperature
- Operating mode and fan speed
- WindFree

Controls are shown according to the capabilities reported by the air conditioner.

## Connect

1. Start the WindFull host on Windows and connect the PC, phone and air conditioner to the same local network.
2. Open the Android app and select the discovered PC. If discovery is blocked, enter the PC's IPv4 address.
3. Compare the six-digit code in the app with the code shown on the PC, then approve the phone in the Windows host.

Pairing is saved for future connections.

## How it works

The Android app discovers Windows hosts over UDP and communicates with the host through a local HTTPS API. First-time pairing requires PC approval and a matching six-digit code. The app pins the host's SHA-256 TLS certificate fingerprint and stores its pairing credential in Android secure storage.

The Windows host uses a Rust bridge to communicate with the air conditioner through Samsung OCF over CoAP and DTLS. The bridge discovers device resources at runtime and exposes only the controls the appliance advertises.

The air conditioner must be onboarded in Samsung SmartThings once to provision local OCF access. After that, WindFull communicates with it on the LAN without calling SmartThings cloud APIs.

## Build and develop

Install Flutter 3.44.1 and the Android SDK for the client. Windows builds also require Node.js/npm, Rust stable for the MSVC target, Visual Studio Build Tools with the **Desktop development with C++** workload and Windows SDK, Strawberry Perl for the OpenSSL bridge build, and the .NET 8 SDK for Velopack packaging. The Windows build script detects common Strawberry Perl installations or accepts `-PerlBin`.

Build the Windows package from the repository root:

```powershell
.\scripts\build_windows.ps1
```

The Windows ZIP and checksums are written to `output/windows/`. Android APK packaging and release verification are documented in [`docs/releasing.md`](docs/releasing.md).

Run the Android client from `app/`:

```powershell
flutter pub get
flutter run
```

Run the Tauri tray host from source:

```powershell
Push-Location server
npm --prefix web ci
npx --prefix web --no-install tauri dev --config src-tauri\tauri.conf.json
Pop-Location
```

The host uses Rust for its tray lifecycle, local HTTPS API and Windows storage, and React/TypeScript for its compact panel. Run the host checks and build the Samsung bridge with:

```powershell
cargo check --locked --manifest-path server/src-tauri/Cargo.toml
npm --prefix server/web ci
npm --prefix server/web run build
cargo build --locked --manifest-path server/native/samsung/Cargo.toml
cargo test --locked --manifest-path server/native/samsung/Cargo.toml
```

Run `flutter analyze` from `app/` to check the Android client.

## Repository

| Path | Purpose |
| --- | --- |
| `app/` | Flutter Android client: discovery, pairing, device state and controls |
| `server/src-tauri/` | Tauri/Rust Windows tray host, local HTTPS API, secure storage and device approval |
| `server/web/` | React/TypeScript interface for the Windows tray panel |
| `server/native/samsung/` | Rust OCF/CoAP/DTLS bridge for Samsung air conditioners |
| `scripts/` | Windows and Android build and verification scripts |
| `docs/releasing.md` | Release build and verification workflow |

For protocol and device integration details, see [`server/native/samsung/README.md`](server/native/samsung/README.md).

## References

- [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) — command-line interface for SmartThings APIs.

Licensed under the [GNU General Public License v3.0 or later](LICENSE).
