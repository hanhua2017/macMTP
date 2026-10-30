# macMTP Product Requirements

**中文基线：[PRD.md](PRD.md)**

## Product goal

macMTP is an open-source macOS file manager for Android and other devices that expose Media Transfer Protocol (MTP). It provides a native SwiftUI interface without telemetry or an account service.

## Supported capabilities

- Discover and connect to MTP devices over USB.
- Browse device storage and switch between device storages.
- Upload and download files and directories.
- Create folders, rename items, and delete local or remote items.
- Copy or move items inside a device when the device advertises the capability.
- Drag and drop files between Finder, the local pane, and the device pane.
- Search, sort, switch list/icon layouts, and resize the interface text.
- English and Simplified Chinese localization.

## Integrity requirements

Transfers must report failures instead of claiming success when the remote name, size, or verification result does not match the source. A failed cut operation must preserve the source. Empty directories and nested directory trees must survive supported round trips.

## Platform requirements

- macOS 14.0 or later.
- A data-capable USB connection and a device configured for File Transfer/MTP.
- Apple Silicon and Intel release packages are built separately.

## Non-goals

The product does not include telemetry, crash upload, an account system, or an automatic update service. Complete device compatibility, Finder integration, and live-device coverage remain validation areas rather than universal guarantees.

## Acceptance

Every release must pass the Swift test suite, architecture/package checks, publication checks, and the release workflow for each supported architecture. Current behavior is defined by the code and the latest regression report.
