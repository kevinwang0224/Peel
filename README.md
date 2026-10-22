# Peel

[中文说明](README_zh.md)

**Peel** is a native JSON editor for macOS, built with SwiftUI, AppKit, Scintilla Cocoa, SQLite and JavaScriptCore. It targets macOS 14+ on Apple Silicon.

```bash
make run
```

## Features

- **Scintilla-based editing** with syntax highlighting, validation, and familiar shortcuts
- **Automatic paste formatting** for valid JSON; non-JSON text is kept as-is
- **Extraction** via JavaScript or **JSONPath**, with automatic formatting of string results containing valid JSON objects or arrays
- **JSON string navigation**: paths such as `data.value.msg[0].clazzId` support completion and extraction through nested JSON objects or arrays encoded as strings
- **History sidebar**: create, search, pin, rename, and delete records; edits persist automatically
- **Import / export**: open JSON files and export
- **Theme**: system, light, or dark, with a matching `{ ... }` app icon

## Repository layout

| Path | Description |
|------|-------------|
| [`Package.swift`](Package.swift) | Swift package and executable products |
| [`Sources/`](Sources/) | App, JSON core, native editor and extraction process |
| [`Tests/`](Tests/) | Native core tests, grouped by feature |
| [`Resources/`](Resources/) | App icons, source artwork and licenses |
| [`scripts/`](scripts/) | Build, test and dependency preparation |
| [`tools/`](tools/) | Benchmarks, editor diagnostics and extraction runtime bundling |
| [`docs/`](docs/) | Development, architecture and implementation history |

See [architecture](docs/architecture.md) for module responsibilities and [development](docs/development.md) for build requirements, data migration and verification.

## Common scripts

Run from the repo root. Building and testing require Xcode with the macOS SDK; Node.js is only needed to regenerate the bundled extraction runtime.

| Command | Purpose |
|--------|---------|
| `make build` | Build `build/Peel.app` |
| `make run` | Build and open Peel |
| `make test` | Run native tests |
| `make benchmark` | Build and benchmark Peel |
| `make runtime` | Regenerate the bundled extraction runtime (requires Node.js) |

Run `make` to list available commands. Optional Node.js tooling is isolated in `tools/runtime/`; normal builds and tests use the checked-in extraction bundle.

## App icons

`Resources/Icons/Source/` holds the SVG sources (`AppIcon.svg` for dark, `AppIconLight.svg` for light). The app switches `AppIcon.icns` / `AppIconLight.icns` with the current appearance.
