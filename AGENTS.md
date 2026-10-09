# Repository Guidelines

## Project Structure

Crisp is a native macOS menu-bar app built as a Swift Package (no external dependencies). `Package.swift` declares macOS 14+ and one `Crisp` executable target. `Sources/Crisp/main.swift` is the entrypoint: `@MainActor AppDelegate` builds the status item and owns `CrispController`, which is the hub for `HyperRemap`, `SpaceSwitcher`, and `WindowManager`. `Model.swift` holds `CrispConfig` (the defaults and persistence) plus `Shortcut`/`Layout` types; `SettingsView.swift` is SwiftUI; `CrashLog.swift` records why the process exited. Tests live in `Tests/CrispTests/` (`ModelTests.swift`, using `@testable import Crisp`). Generated output and SwiftPM state are in `build/` and `.build/` (both git-ignored — never commit them). `init.lua` is reference only, not loaded. Licensing is MIT except `SpaceSwitcher.swift`, which is MPL-2.0 from Space Rabbit; do not relicense or refactor that file without reading `SPACE-RABBIT-LICENSE.md`.

The app runs as an accessory (`LSUIElement`), so it has no main window; everything is driven from the status-bar menu and the settings window it opens.

## Build and Development

- `swift test -j 2` runs the XCTest suite. Single test: `swift test -j 2 --filter ModelTests/<testName>`.
- `swift build -c release -j 2` builds the release executable.
- `zsh scripts/build-app.sh` runs tests, builds the app bundle into `build/Crisp.app` (bundle id `com.nils.crisp`), signs it with the first Apple Development identity it finds (`codesign --force --sign`), then verifies the signature and Info.plist. It exits non-zero if no signing identity exists. Requires macOS.

The script also copies `SPACE-RABBIT-LICENSE.md` and `FASTER-SWIPER-LICENSE` plus `Resources/MenuBarSupra*.png` into the bundle Resources, and builds `Resources/AppIcon.iconset` into `AppIcon.icns` with `iconutil`; all of those files must exist or the script fails before signing. `scripts/extract-menubar-icon.py` regenerates the menu bar glyph from the supra icon (white car on a black tile, canvas corners excluded) — run it after replacing the icon, then rebuild. The user can switch the menu bar glyph back to the `hare.fill` symbol at runtime via **Menu Bar Icon → Rabbit** (`CrispConfig.menuBarIcon`, default `.supra`, older configs decode to it).

For desktop testing, use the signed `build/Crisp.app`; `swift run` does not give the executable bundle identity or Accessibility/Input Monitoring behavior. Install to `~/Applications/Crisp.app` via `ditto` and keep that path stable: TCC permissions and login items are tied to the code identity and path. Quit the installed app before replacing it.

## Config and Behavior Notes

- Config persists as JSON in UserDefaults under the key `crisp.config` (`CrispController.swift`). `CrispConfig.initial` defines the default 7 app bindings and 17 layouts; tests assert those exact counts, so intentional default changes must update the tests too.
- Shortcut handling must stay off the hot path's slow paths: `ShortcutResolver` in `Model.swift` holds the prebuilt `[Shortcut: Action]` index plus per-shortcut layout lists and is rebuilt in `config.didSet`; `WindowManager` caches `NSScreen` frames/`visibleFrame` for one runloop turn and drops the cache on the next turn. Never scan `config.layouts`/`apps` or `NSScreen.screens` inside the event-tap handler. Patterns taken from Rectangle (dictionary shortcut map, per-action screen snapshot invalidated via `DispatchQueue.main.async`, skip the write when the frame already matches).
- The app starts with instant Spaces off and Hyper off, so it does not claim keys until the user enables a feature.
- Layout dimensions are normalized 0-1; the parser accepts both `.` and `,` decimal separators and intentionally tolerates invalid intermediate geometry as a draft (single-source parsing logic lives in `LayoutDimensions`, fully covered by tests).
- README describes older menu contents in places; `main.swift` and the controller are the source of truth.
- Settings rows are addressed by **id, never by index**. Every binding in `SettingsView` (`appField`, `layoutField`, `numericField`, `screenSizeField`) resolves its row with `first(where: { $0.id == id })` on both read and write and falls back when the row is gone. Capturing an index is a hard crash, not a silent failure: after a row is deleted, SwiftUI still evaluates the previous frame's bindings during the layout pass that follows, and `config.apps[index]` raises `Fatal error: Index out of range` (signal 5). Verified via `~/Library/Caches/com.nils.crisp/exit.log`. When a settings list row is deleted, clear the `@State` selection and cancel any shortcut recording before shrinking the array; the shortcut recorder writes through `CrispController.assignShortcut(_:to:kind:)` so no AppKit closure captures a row `Binding`.
- Exactly one Crisp runs per login session: `main.swift` hands over to an existing `com.nils.crisp` instance and exits. Rebuild+`ditto`+`open` replaces the bundle, which cleanly exits the running instance, so concurrent sessions can make Crisp "vanish" without any crash. If it ever disappears, read `~/Library/Caches/com.nils.crisp/exit.log`: `CrashLog` records signal/exception backtraces and a `clean exit` marker on normal termination; an unchanged or missing file means the process was killed from outside.

## Style and Naming

Swift style already in use: four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, XCTest names beginning with `test`. Keep code in the existing feature-oriented files unless a new responsibility warrants its own file. No formatter, linter, or CI is configured; match surrounding formatting and keep changes focused.

## Tests and Manual Checks

Add XCTest cases in `Tests/CrispTests/` for model and configuration behavior (`LayoutDimensions` parsing, cycle order, screen-size classification are exercised there). Spaces switching, Hyper key remapping, window placement, signing, and app lifecycle rest on undocumented SkyLight/HID/CGEventTap interfaces that unit tests cannot cover: these need the physical macOS checks in README's "Manual acceptance checks" section on this Mac, including both internal and external keyboards. A macOS update can break the SkyLight/Dock interfaces used by `SpaceSwitcher.swift` (code adapted from Space Rabbit, MPL-2.0).

## Commits and Pull Requests

This checkout is not a Git repository, so no project-specific conventions exist. Use concise imperative commit subjects (for example, `Fix shortcut recording`) and explain user-visible behavior in the body. Call out required macOS permissions and manual acceptance steps for hardware-dependent changes.
