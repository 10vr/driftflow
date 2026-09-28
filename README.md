# Driftflow

On-device dictation: hold a key, speak, and your words appear where you're typing. Nothing leaves the computer.

| Platform | Folder | Stack | Build |
|---|---|---|---|
| macOS 15+ (Apple Silicon) | [`macos/`](macos/) | Swift, SwiftUI/AppKit, Parakeet on the Neural Engine (FluidAudio), Apple Speech and Apple Intelligence | `cd macos && ./build.sh --install` |
| Windows 10/11 (x64) | [`windows/`](windows/) | Rust + Tauri 2, React UI, Parakeet via ONNX Runtime | GitHub Actions (**Windows build**) → download the **Driftflow-Windows** installer; locally `cd windows && bun install && bun run tauri dev` |

The two apps share a design and behaviour, not code: each is native to its platform. What Driftflow does is described in [`macos/README.md`](macos/README.md), and the Windows app follows it.

The Windows app started from [Handy](https://github.com/cjpais/Handy) (MIT licence), version 0.9.7 at commit `8f9cf53`. See [`windows/UPSTREAM.md`](windows/UPSTREAM.md).
