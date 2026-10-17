# Developing Peel

Peel is a native macOS 14+ / Apple Silicon JSON editor built with SwiftUI, a narrow AppKit editor/window bridge, Scintilla Cocoa and SQLite. JavaScriptCore runs extraction expressions in disposable helper processes.

## Build and run

Requires Xcode with the macOS SDK and command-line tools. Native builds use the checked-in JavaScript bundle and do not require Node.js.

```bash
make build
open build/Peel.app
```

The build downloads Scintilla 5.6.7 and Lexilla 5.5.4 from their official source, verifies SHA-256 checksums, compiles the selected JSON/JavaScript lexers, and creates an ad-hoc signed app for local use. Downloaded sources and build products are ignored by Git. This build is not signed or notarized for public distribution.

Use `make run` to build and open the app, or `make run CONFIGURATION=debug` for a debug build. Open the root `Package.swift` in Xcode to work with the Swift package directly; run `bash scripts/prepare-dependencies.sh` before opening a fresh checkout.

## Rebuild the extraction runtime

Node.js 18+ is only required after changing `tools/runtime/runtime-entry.js` or updating JSONPath Plus. The bundling tools have their own package manifest and lockfile in `tools/runtime/`. From the repository root, run:

```bash
make runtime
```

Commit the regenerated `Sources/PeelScript/Resources/runtime.js` with any source or dependency changes, then run the native tests and rebuild the app. Regular native builds use this checked-in bundle.

## Features

- JSON and JavaScript highlighting, line numbers, folding, undo/redo and native text selection.
- Strict JSON validation with byte-accurate editor markers and line/column error messages.
- Format, compact, and pasted string-wrapped / backslash-escaped JSON conversion. Formatting preserves numeric spelling and property order; valid `null` stays `null`.
- JavaScript `data` expressions, pure JavaScript Promises, and JSONPath Plus queries. Browser APIs such as `fetch` are unavailable.
- Automatic extraction after 400 ms idle for documents up to 1 MiB; larger documents run manually. Superseded tasks are cancelled, scripts time out after approximately 1.2 seconds, and results over 16 MiB are rejected. At most two helper processes run concurrently across the app.
- History title/body substring search, rename, pin, delete and automatic per-record saving. Lists are paged and contain metadata only; document bodies load on demand. The selected document is restored when reopening the workspace.
- File import/export, native Edit menu commands, Find/Replace, appearance/font settings, menu-bar entry, configurable global Quick Paste shortcut, and independent scratch windows.
- Closing the main window saves before closing and releases its workspace. The menu bar and shortcut remain available; scratch windows have Save/Cancel/Discard handling.

## Data migration

Native data lives in `~/Library/Application Support/PeelNative/history.sqlite`. First launch imports supported schema 1/2 snapshots from `peeldesktop`, `@peel/desktop`, and `Peel` Application Support directories, in that order. Each source is imported transactionally once; invalid sources are reported and can be retried after repair. Old Electron files are never modified. Existing titles, content, IDs, timestamps, pin state, extraction expressions and settings are retained. Unsupported global shortcut spellings are reported rather than silently rewritten.

History search keeps case-insensitive substring behavior, including Unicode, rather than switching to token-based full-text search. JSON formatting deliberately preserves large-number lexemes and source key order; JavaScript extraction continues to use JavaScript Number semantics.

## Verification

Automated tests cover JSON processing, history persistence/migration/search, settings and process-backed extraction. The test script builds `PeelScript` and passes its path to the tests. Editor/system integration is verified with the actual app.

```bash
make test
make test TEST_ARGS="--filter ExtractionRunnerTests"
```

Performance tools use synthetic data and isolated temporary stores:

```bash
make benchmark
```

The report includes process-start-to-ready time, physical footprint including helper processes during sampled peaks, idle/closed-window footprint, and editor insertion plus AppKit redraw P95. This editing metric excludes keyboard-event dispatch and physical display scan-out; it is a diagnostic proxy, not a complete input-to-photon measurement.

`PeelBench` also measures 1/10 MiB JSON validation and formatting or seeds large history fixtures through the public storage interface:

```bash
swift run -c release PeelBench
```

For an isolated manual session, set `PEEL_DATA_DIRECTORY` to a temporary directory and `PEEL_SKIP_MIGRATION=1`. `PEEL_METRICS=1` prints startup timing. `PEEL_BENCHMARK=1` drives a synthetic editing benchmark, closes its window, reports memory and exits; use it only with an isolated store.

Measured implementation results and remaining limits are recorded in [the implementation report](history/native-macos-implementation.md) and [the SwiftUI migration report](history/native-macos-swiftui.md).

The target is macOS 14; actual execution has currently been checked on macOS 27 / Apple M3 Max. Testing the minimum OS and a full end-to-end latency measurement remain separate validation tasks.

## Components and licenses

Scintilla and Lexilla use their permissive Scintilla license. JSONPath Plus uses MIT; its license is checked in and bundled with the app. The generated `runtime.js` retains upstream legal comments. Sources used by the native build are version- and checksum-pinned in `scripts/prepare-dependencies.sh`.
