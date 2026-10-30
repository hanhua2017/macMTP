# macMTP

[English](README.md) · [简体中文](README.zh-CN.md)

<p align="center"><img src="assets/icon.png" width="112" alt="macMTP icon"></p>

A native macOS file manager for transferring files between a Mac and Android/MTP devices over USB. Built with SwiftUI, AppKit and LibMTP through a C bridge. No Go toolchain or OpenMTP checkout is required.

## Screenshots

Current 1.0.6 interface, captured on macOS on 2026-10-29. The main-window screenshot was refreshed using a temporary demonstration directory, with an MTP device connected; personal home-directory paths are not shown.

<p align="center"><img src="assets/screenshots/main-window.jpg" width="900" alt="Dual-pane file browser using a temporary demonstration directory"></p>

| Preferences | About |
| --- | --- |
| <img src="assets/screenshots/preferences.jpg" width="360" alt="Language, device detection and file explorer preferences"> | <img src="assets/screenshots/about.jpg" width="360" alt="macMTP 1.0.6 powered by LibMTP"> |

<details>
<summary>New folder dialog</summary>

<img src="assets/screenshots/new-folder.jpg" width="360" alt="New folder name dialog">
</details>

Screenshot files and capture notes: [assets/screenshots](assets/screenshots/README.md).

## Features

- USB MTP detection and automatic connection; choose storage when a device exposes multiple storages.
- Dual-pane local/device browsing and a device-only single-pane layout; list/icon views, filtering, sorting, hidden files, breadcrumbs and a local navigation sidebar.
- Batch uploads/downloads of files and directory trees, including empty directories. Multi-file drag and drop into the app; copy/cut/paste between panes.
- Transfer queue with progress, cancellation and pause/resume between queued operations. Pause is not byte-range resume of a file already being transferred.
- Conflict handling: overwrite, skip, or size-based choices. Equal size does **not** prove equal content.
- Cut-source cleanup only after every queued item under that selection completes; skipped/failed trees remain at the source. Missing sources and transfer failures appear in the app.
- New folder, rename and delete. Local deletion uses Trash; deletion on the MTP device is not recoverable through the app.
- Device-internal copy/move when the device advertises `CopyObject`/`MoveObject`. Such operations show indeterminate progress because the device does not report byte-level progress.
- English and Simplified Chinese, panel swapping and font-size preferences.

Device support varies. Special filenames may be rejected by the device; an upload is not marked successful when the expected destination name/size does not match. Dragging device files directly into Finder, hot-unplug behavior and the full device matrix still require additional validation; see the [test reports](docs/test-reports/README.md).

## Requirements

- Deployment target: macOS 14.0+. The current local build was verified on Apple Silicon/macOS 26.6.2; macOS 14 and Intel hardware have not been runtime-tested in this round.
- An Android or other MTP device, a data-capable USB cable, and **File Transfer / MTP** mode enabled on the device.
- For development: Xcode with Swift 6.0+ and a macOS SDK, `pkg-config`, `make`, `curl`, `tar` and `shasum`.

## Build and run

From the repository root:

```bash
brew install pkg-config
./scripts/download.sh
bash scripts/build.sh release --arch "$(uname -m)"
open macMTP.app
```

The build script creates isolated runtime dependencies under `thirdparty/runtime/<arch>-macos14` when missing, then builds, bundles and ad-hoc signs `macMTP.app`. It does not modify Homebrew libraries. Dependencies are downloaded from pinned, SHA-256-checked source archives:

| Library | Version |
| --- | --- |
| libmtp | 1.1.23 |
| libusb | 1.0.29 |
| libgcrypt | 1.11.2 |
| libgpg-error | 1.58 |

All bundled runtime libraries are checked for architecture and a minimum macOS version of 14.0 or earlier. `libgpg-error` is built without NLS, so no gettext/libintl runtime is required. The application still provides both UI languages.

For development and packaging:

```bash
bash scripts/build.sh debug --arch "$(uname -m)"
# Legacy packaging entry point; also copies the bundle to .build/macMTP.app
bash scripts/package.sh --arch "$(uname -m)"
# Creates DMG, ZIP and checksums in release/; replaces that directory's contents
bash scripts/release.sh 1.0.6 --arch "$(uname -m)"
```

`MACMTP_RUNTIME_PREFIX` selects a compatible prebuilt dependency prefix. Advanced overrides include `MACMTP_LIBMTP_ROOT`, `MACMTP_LIBMTP_LIB_DIR` and `MACMTP_LIBUSB_LIB_DIR`.

Detailed download, SHA-256 verification, standalone compilation and vendored-source instructions: [LibMTP build guide](docs/development/LIBMTP_BUILD.md). All four dependencies live under [thirdparty](thirdparty/README.md); downloaded sources and build products are Git-ignored. Run `./scripts/download.sh` to restore the pinned sources.

### Intel and universal builds

```bash
bash scripts/build.sh release --arch x86_64
```

Apple Silicon Xcode supports x86_64 cross-compilation, but the dependencies must also be x86_64. The script has an architecture-specific dependency-build path; that end-to-end path has not been validated in this round. The verified local bundle is **arm64 only**.

`--universal` requires compatible arm64 and x86_64 slices in **every** runtime library; it does not automatically merge the isolated per-architecture dependency prefixes. CI builds/tests and tag releases currently target the runner's native architecture, not a universal release.

## Testing

```bash
# Build runtime dependencies before a direct SwiftPM build on a fresh checkout
bash scripts/build-runtime.sh "$(uname -m)"
swift test

# Close macMTP and connect an idle test device before opting in
MACMTP_RUN_DEVICE_TESTS=1 swift test --filter FileTransferDeviceRegressionTests
```

Device tests create and clean a dedicated UUID test directory. The default suite skips them. Following component cleanup, `swift test` discovered 38 tests: **37 passed, 1 skipped, 0 failures**. The previous eight-bug regression additionally passed 11 real-device checkpoints; those device checks were not rerun for this cleanup.

See [test cases](docs/testing/TEST_CASES.md), [test reports](docs/test-reports/README.md) and [cleanup notes](docs/maintenance/2026-10-29-project-refresh.md). CI test failures propagate normally; they are not converted into “no tests found”.

## Troubleshooting and privacy

1. Unlock the device, select MTP mode, and try another data cable/port.
2. Close other MTP clients that may hold the USB interface. Then reconnect or refresh.
3. If a transfer fails, read the in-app error and retain the source files until the destination has been checked.

No telemetry SDK, crash-report upload or automatic update service is included. The obsolete reporting toggle and consent prompt have been removed. Diagnostics are written locally to `/tmp/macmtp-debug.log`; the log may include filenames, paths and device errors. Review it before sharing it with an issue report.

## Project structure

```text
Sources/
├── CLibMTPBridge/    # LibMTP C ABI, USB operations and callbacks
└── macmtp/          # SwiftUI/AppKit UI, device actor, models and services
Tests/macmtpTests/   # Unit, transfer regression and opt-in device tests
Resources/          # App metadata, icon and en/zh-Hans translations
assets/             # README icon and current screenshots
docs/               # Product, architecture, testing, reports and archives
thirdparty/         # Dependency manifest; ignored downloads, sources and runtime libraries
scripts/            # Runtime dependency build, app build and packaging
```

`Go*` response-model names are legacy ABI/JSON compatibility names still used by the LibMTP bridge, not a Go backend. CKalam, the unused static archive, SentryStub and the no-op updater are no longer included.

## Documentation and contributing

- [Documentation index](docs/README.md)
- [Product requirements](docs/product/PRD.md) · [Technical architecture](docs/architecture/TECHNICAL_ARCHITECTURE.md)
- [Contributing](CONTRIBUTING.md) · [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md) · [Governance](GOVERNANCE.md) · [Maintainers](MAINTAINERS.md)

Thanks to [LibMTP](https://libmtp.sourceforge.net/) and [libusb](https://libusb.info/). macMTP is released under the [MIT License](LICENSE); bundled libraries retain their respective licenses.

## License

Original macMTP code is licensed under the [MIT License](LICENSE). See [Third-party notices](THIRD_PARTY_NOTICES.md) and [original license texts](LICENSES/README.md) for LibMTP, libusb, libgcrypt and libgpg-error. These components retain their own licenses; the app build includes the notices under `Contents/Resources/Licenses/`. Previously generated DMGs are unchanged.

For a clean source release, see the [open-source release guide](docs/development/OPEN_SOURCE_RELEASE.md). Run `python3 scripts/check-publication.py`; `--export .build/macMTP-source-release.tar.gz` creates a verified source snapshot without Git history or ignored local files.
