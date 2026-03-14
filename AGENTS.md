# AGENTS.md

## Cursor Cloud specific instructions

### Platform constraint

This is an **iOS-only** Swift SDK. The `Package.swift` declares `.iOS(.v15)` as the sole platform. The SDK imports Apple-only frameworks (`UIKit`, `SwiftUI`, `StoreKit`, `WebKit`), so **`swift build` and `swift test` will fail on Linux** with "no such module" errors. This is expected — not a bug.

- **Full builds, unit tests, and UI tests require macOS with Xcode** (the CI uses `warp-macos-26-arm64-6x` runners).
- On Linux, you can still validate the package manifest with `swift package resolve` and `swift package describe`.

### What works on Linux (Cursor Cloud)

| Command | Works? | Notes |
|---------|--------|-------|
| `swift package resolve` | Yes | No external dependencies to fetch (all vendored) |
| `swift package describe` | Yes | Validates manifest structure |
| `swift package dump-package` | Yes | Outputs JSON package definition |
| `swift build` | No | Requires Apple frameworks (StoreKit, SwiftUI, UIKit, WebKit) |
| `swift test` | No | Tests depend on the Helium module which requires Apple frameworks |

### Development workflow

- See `CONTRIBUTING.md` for release and CI/CD process.
- See `CLAUDE.md` for project structure, conventions, and key principles.
- No lint tools (SwiftLint/SwiftFormat) are configured in this repo.
- No external SPM dependencies — all third-party code is vendored in `Sources/Helium/HeliumCore/`.

### Unit tests (macOS only)

Tests live in `Tests/helium-swiftTests/` and test the SDK internals (identity, events, paywall logic, etc.). They import `@testable import Helium` and therefore require the full SDK to compile.

### UI tests (macOS only)

UI tests in `HeliumExample/HeliumExampleUITests/` require `HELIUM_API_KEY` and `HELIUM_TRIGGER_KEY` environment variables plus an iOS simulator.

### Swift toolchain

The update script installs Swift 6.0.3 for Ubuntu 24.04 into `/opt/swift`. The `PATH` is configured in `~/.bashrc`. The project requires Swift 5.10+ (see `Package.swift` tools version).
