# Peel

[中文说明](README_zh.md)

**Peel** is a lightweight JSON formatter and editor for macOS. It is a native app built with SwiftUI, AppKit editor/window bridges, Scintilla Cocoa, SQLite and a disposable JavaScriptCore helper. It targets macOS 14+ on Apple Silicon and runs without WebView or Node. See [native build, migration and verification instructions](apps/native-macos/README.md).

```bash
bash apps/native-macos/scripts/build.sh
open "apps/native-macos/build/Peel Native.app"
```

## Features

- **Scintilla-based editing** with syntax highlighting, validation, and familiar shortcuts
- **Automatic paste formatting** for valid JSON; non-JSON text is kept as-is
- **Extraction** via JavaScript or **JSONPath**
- **History sidebar**: create, search, pin, rename, and delete records; edits persist automatically
- **Import / export**: open JSON files and export
- **Theme**: system, light, or dark, with a matching `{ ... }` app icon

## Repository layout

| Path | Description |
|------|-------------|
| [`apps/native-macos/`](apps/native-macos/) | Native macOS app (Swift 6, SwiftUI, AppKit, Scintilla) |
| [`packages/shared/`](packages/shared/) | **Platform-agnostic** JSON utilities, extraction logic, types, and history helpers (`@peel/shared`) |
| `apps/extension/` | Reserved for a future **browser extension** (reuses `@peel/shared` only) |

## Common scripts

Run from the repo root (`npm install` first):

| Command | Purpose |
|--------|---------|
| `npm run build` / `npm run native:build` | Build the native app |
| `npm run dev:native` | Build and open the native app |
| `npm run native:test` | Run native tests |
| `npm run build:shared` | Build the `@peel/shared` package |
| `npm run lint` / `test` / `typecheck` | Run in all workspaces that define them |

## App icons

`apps/native-macos/Resources/IconSource/` holds the SVG sources (`AppIcon.svg` for dark, `AppIconLight.svg` for light). The app switches `AppIcon.icns` / `AppIconLight.icns` with the current appearance.
