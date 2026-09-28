# Driftflow

On-device dictation: hold a key, speak, and your words appear where you're typing. Nothing leaves the computer.

| Platform | Folder | Stack | Build |
|---|---|---|---|
| macOS 15+ (Apple Silicon) | [`macos/`](macos/) | Swift, SwiftUI/AppKit, Parakeet on the Neural Engine (FluidAudio), Apple Speech and Apple Intelligence | `cd macos && ./build.sh --install` |
| Windows 10/11 (x64) | [`windows/`](windows/) | Rust + Tauri 2, React UI, Parakeet on the graphics card (Vulkan) | GitHub Actions (**Windows build**); locally `cd windows && bun install && bun run tauri dev` |

**Download:** the [latest release](https://github.com/10vr/driftflow/releases/latest) has both, with install steps: `Driftflow-…-macOS.zip` and `Driftflow-…-Windows-x64-setup.exe`. Both update themselves. To release a version of both, run `macos/release.sh <version> --notes "…"` (see [`macos/README.md`](macos/README.md)).

The two apps share a design and behaviour, not code: each is native to its platform. What Driftflow does is described in [`macos/README.md`](macos/README.md), and the Windows app follows it.

The Windows app started from [Handy](https://github.com/cjpais/Handy) (MIT licence), version 0.9.7 at commit `8f9cf53`. See [`windows/UPSTREAM.md`](windows/UPSTREAM.md); Handy's licence notice is kept in [`windows/LICENSE-HANDY`](windows/LICENSE-HANDY).

## Licence

Driftflow is free software under the [GNU General Public License v3.0](LICENSE). You may use, study, change and share it; copies you distribute, changed or not, must stay under the same licence with their source code available.
