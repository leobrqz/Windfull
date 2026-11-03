# Samsung OCF local bridge

`windfull-samsung-ocf.exe` is a standalone local bridge for Samsung air conditioners that expose the OCF CoAP interface. It speaks CoAP over DTLS on the LAN, decodes OCF CBOR, and does not call SmartThings cloud services.

## Build on Windows

Requirements: Rust stable with the `x86_64-pc-windows-msvc` target, Microsoft C++ Build Tools, and Strawberry Perl. OpenSSL is built statically from its source by the Rust dependency. When NASM is absent, `openssl-src` disables assembly automatically.

Use Strawberry Perl for the build process only; this does not change the machine's global `PATH`:

```powershell
$strawberryPerl = 'C:\Users\Conta\AppData\Local\WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin'
$env:PATH = "$strawberryPerl;$env:PATH"
cargo test --locked --manifest-path server/native/samsung/Cargo.toml
cargo build --release --locked --manifest-path server/native/samsung/Cargo.toml
```

The resulting executable is `server/native/samsung/target/release/windfull-samsung-ocf.exe`. The Windows host must copy it beside `windfull_server.exe`. `target/` is generated output and is excluded from Git.

## Dart process contract

`SamsungOcfRepository` starts the executable with `--data-dir <directory>`. Requests and responses are one JSON object per line on stdin/stdout; diagnostics stay on stderr. The bridge handles `discover`, `connect`, `state`, `capabilities`, control operations, `disconnect` and `shutdown`. A persistent process retains one DTLS session; shutdown drops it. Network requests have bounded timeouts and return a stable error code and a redacted message.

The host should pass a stable user-local data directory, for example `%LOCALAPPDATA%\Windfull`. The bridge generates a fresh EC client certificate and private key there on first use and reuses them after updates. It also stores DTLS server certificate SHA-256 pins for both host and OCF device ID. The first successful OCF identity read establishes TOFU pins; later certificate or device-ID changes fail with `certificate_changed` or `device_changed`. The private key is never printed or included in the repository.

## Device compatibility

Discovery reads the OCF resource directory and its advertised secure endpoint, then probes the endpoint over DTLS and checks `/oic/d` for an `oic.d.airconditioner` device type. If multicast discovery is blocked, the repository also accepts a manually entered IPv4 address. It reads resource links, resource types, interfaces and representations at runtime; classic resources use their advertised `oic.if.a` interface and supported options before enabling writes.

Some Samsung firmware publishes only `/hass/state` and `/hass/command` in `/oic/res`; both may return `4.04`. The bridge then reads `/device/0`, a Samsung-specific compact list of `{href, rep}` records. The list has no interface metadata, so its entries do not by themselves prove write support. The bridge preserves these representations as raw resources and only maps known classic control paths. Sensitive fields such as serial numbers, SSIDs and MAC addresses are removed before raw data leaves the native process.

The client identity uses the Samsung OCF cloud-service UUID published by the MIT-licensed `SmartThings-Local` interoperability research. Appliances must have been onboarded in SmartThings at least once so their OCF ACL contains the identity. This certificate profile is not valid for every Samsung firmware generation: newer OCF-PKI profiles require a different authentication flow and are not claimed as supported. Resource names and controls also vary by firmware; the bridge only exposes controls that the appliance advertises. Model-specific limits and control behavior still need verification on each target appliance.

This implementation uses public CoAP/CBOR protocol definitions and independently authored code. It does not copy code from `c0dag/samsung-windfree-tray-app` (no license file was present) or the AGPL Home Assistant integration.

## Physical validation status

On the current LAN, the appliance identifies itself as `Samsung-Room-Air-Conditioner`, reports `oic.d.airconditioner`, and advertises secure UDP port `49154`. Its `/oic/res` is truncated: the operational tree is readable at `/device/0`, while `/hass/state` and `/hass/command` return `4.04`. The tree exposes a model number at `/information/vs/0`; its serial and network identifiers are intentionally omitted from logs and documentation.

The release bridge completed DTLS and read state through `/device/0`: power On, target 24 °C, ambient 27 °C, mode Wind, fan value `3` (High), and WindFree Off. It reports target limits 16–30 °C with a 1 °C increment. Same-value POSTs for power On, temperature 24 °C, and fan value `3` were accepted, and GET reads confirmed those values afterward. No state change was requested. Mode Wind and WindFree Off POSTs returned `invalid_response` because no matching CoAP response was received; those two writes remain disabled for this appliance. Swing, display, beep, auto-clean, filter and energy representations are readable, but their writes have not been validated and are not exposed as controls.

The exact device-specific interface is not yet proven for other Samsung models. Classic controls are enabled when a device advertises actuating interfaces; the compact `/device/0` fallback remains limited to resources and values read from that device, with unsupported writes disabled.
