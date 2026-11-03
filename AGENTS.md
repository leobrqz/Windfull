# Windfull project guide

## Project scope

- Windfull is a personal Android remote for a Samsung WindFree air conditioner, with a Windows host on the local network.
- The Windows host is intended to be a desktop app with a system-tray experience inspired by the Samsung WindFree Tray App. Its own interface should provide appliance controls, configuration and approval of Android devices; the local server runs behind it. Do not replace this experience with a browser dashboard.
- The Windows interface should be a compact, frameless panel positioned beside the system-tray icon, following the upstream reference screenshot, rather than a large desktop window.
- The intended experience includes automatic host discovery, explicit approval on the PC, persistent device pairing and controls appropriate to the actual appliance. These features are not implemented in the initial scaffold.
- Plan for power, temperature, operating modes, WindFree and other functions the appliance actually exposes, from both the Windows tray app and Android client.
- Keep the Android-to-PC communication local. Investigate and verify appliance compatibility before committing to a specific Samsung integration or claiming that every setup works offline.
- Preserve pairing, server identity, user settings and Android signing-key continuity across updates. Never commit credentials, appliance keys, private keys or keystores.
- Consult the licenses of reference projects before incorporating their code.

## Layout

- `app/`: Flutter Android client.
- `server/`: Flutter Windows desktop host and future tray interface. Discovery, pairing and appliance integration belong here, separated into services and repositories.
- `scripts/`: PowerShell build and artifact-verification scripts.
- `docs/releasing.md`: durable release procedure. `.codex/workflows/github.md` is the local agent playbook.
- `output/`: generated artifacts, excluded from Git.

## Working conventions

- Communicate with the user in Portuguese and describe what was actually tested. Keep project documentation and release notes clear and consistent.
- Make focused changes and respect the user's requested boundaries. Do not create a version or publish a release for ordinary source changes.
- Run checks appropriate to each change. Use the build scripts when producing distribution artifacts and do not claim the scaffold already controls an appliance.
- Keep project-local `.codex/` ignored. The Flutter MCP can be restored by adding `[mcp_servers.flutter-dart]`, `command = "dart"`, and `args = ["mcp-server", "--force-roots-fallback"]` to `.codex/config.toml`, then restarting the session.
- A requested version delivery follows `docs/releasing.md`: synchronize versions, validate, build, verify signing and checksums, create an annotated tag and verify the published GitHub release. Honor any explicit instruction to pause before publication.
