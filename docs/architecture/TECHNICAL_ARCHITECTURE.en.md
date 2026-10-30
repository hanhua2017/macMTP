# macMTP Technical Architecture

**中文基线：[TECHNICAL_ARCHITECTURE.md](TECHNICAL_ARCHITECTURE.md)**

## Overview

macMTP is a SwiftUI macOS application. The Swift layer owns presentation, state, navigation, transfer orchestration, and localization. A small C bridge exposes the isolated LibMTP runtime to Swift.

## Main layers

- **Views:** SwiftUI panes, navigation, storage selection, transfer progress, preferences, and dialogs.
- **Models:** File nodes, transfer items, device information, version data, and layout state.
- **Services:** File transfer, upload verification, USB watching, logging, and clipboard handling.
- **MTP bridge:** Swift protocols and factories isolate the LibMTP implementation and make test fixtures possible.
- **C bridge:** `Sources/CLibMTPBridge` contains the narrow C interface and module map.

## Data flow

1. USB events update the device manager.
2. The bridge enumerates devices and storage into model values.
3. Views request navigation and transfer operations through service/bridge protocols.
4. Transfer results update observable state and are verified before terminal success is reported.

## Concurrency rules

UI state is MainActor isolated. Foundation callbacks such as `NSItemProvider` may arrive on background queues and must only collect Sendable values there. UI state and callbacks must be returned to the main actor explicitly with `Task { @MainActor in ... }`. Shared mutable transfer fixtures use synchronization or an explicit unchecked-Sendable wrapper.

## Runtime dependencies

LibMTP, libusb, libgcrypt, and libgpg-error are built into architecture-specific macOS 14 runtime prefixes. The app bundle carries the required dynamic libraries and license texts. The build scripts validate architecture, minimum OS version, and library references before packaging.

## Build and release

```bash
./scripts/download.sh
bash scripts/build-runtime.sh "$(uname -m)"
bash scripts/build.sh release --arch "$(uname -m)"
bash scripts/release.sh 1.0.6 --arch "$(uname -m)"
```

GitHub Actions selects Xcode 16.2, builds arm64 and x86_64 packages, validates the artifacts, and generates release notes when a `v*` tag is pushed. The source code, tests, and current regression reports are authoritative for implementation details.
