# Contributing to macMTP

## Development Environment

- macOS 14.0+ (Sonoma)
- Xcode with Swift 6.0+ and the macOS SDK
- `pkg-config`, `make`, `curl` and `shasum`; no Go or OpenMTP checkout is needed

## Build & Run

```bash
git clone <your-macmtp-repository-url> MacMTP
cd MacMTP

# Download pinned sources (Git-ignored)
./scripts/download.sh

# Build an app and isolated macOS 14 runtime dependencies
bash scripts/build.sh debug --arch "$(uname -m)"

# Run
open macMTP.app
```

## Code Style

- Follow existing patterns in the codebase.
- Mimic surrounding code for imports, naming, and formatting.
- No unnecessary comments.
- Use SwiftUI idioms — prefer `@State`, `@Binding`, `@Observable` over manual delegates.

## Pull Request Process

1. Fork the repo and create a feature branch (`feature/my-change`).
2. Make your changes.
3. Run `swift test` and `bash scripts/build.sh debug --arch "$(uname -m)"`. Device tests are opt-in; see the [README](README.md#testing).
4. Open a PR against `main`.
5. A maintainer will review within 7 days.
6. Address review feedback if requested.
7. Once approved and CI passes, a maintainer will merge.

## What to Work On

Check the issue tracker for labels such as:

- `good first issue`
- `help wanted`
- `bug`

Popular contribution areas: MTP device testing, UI polish, keyboard shortcuts, localization, tests.

## Reporting Issues

Include:

- macOS version
- Android device model and OS version
- macMTP version
- Steps to reproduce
- Logs from Console.app if applicable
