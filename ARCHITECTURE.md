# GlassTerm — Architecture & API Contract (AUTHORITATIVE)

GlassTerm is a native macOS terminal emulator written in Swift + AppKit, with **zero external
dependencies** (no SwiftPM packages, no third-party code). Every file below is owned by exactly
one worker. Nothing outside your SCOPE may be edited.

## Hard build rules (do not change)

- Module: one flat module, all sources in `Sources/`, compiled in one `swiftc` invocation.
- **Swift 5 language mode** (`-swift-version 5`), deployment target `arm64-apple-macos13.0`.
  Do not use Swift 6 strict-concurrency annotations (`@Sendable`, `nonisolated(unsafe)`, etc.).
  Do not add `async`/`await` to AppKit code.
- AppKit + Foundation only. No SwiftUI (we need NSVisualEffectView + custom layer chrome).
- No nib/storyboard. UI is built in code. `main.swift` drives `NSApplication` manually.
- Every type that crosses file boundaries is declared `internal` (default) — do NOT mark public.
- File order on the command line is irrelevant; do not rely on it.
- Each file must typecheck standalone against the declared contract (`swiftc -typecheck -swift-version 5`).
- No `print()` noise in hot paths. Use `NSLog` only for genuine errors.

## File map (one owner each)

```
Sources/main.swift              A  app entry point
Sources/AppDelegate.swift       A  lifecycle + menu bar + Cmd+, wiring
Sources/Config.swift            B  GlassConfig, ConfigStore, NSColor hex helpers
Sources/PTY.swift               C  forkpty-based process + reader thread
Sources/TerminalCore.swift      D  VT100/xterm parser + screen buffer + scrollback
Sources/TerminalView.swift      E  renderer, keyboard/mouse input, PTY wiring
Sources/GlassChrome.swift       F  NSVisualEffectView stack, tint, blur radius, rounded corners
Sources/WindowController.swift  G  main window assembly
Sources/SettingsWindow.swift    H  native settings GUI with live preview
build.sh, Resources/            I  bundle assembly, Info.plist, icon
```

Config path: `~/.config/glassterm/config.json`.

---

## 1. `Config.swift` — owner B

```swift
import AppKit

struct GlassConfig: Codable, Equatable {
    var blurRadius: Double        // 0...120,  default 42
    var backgroundOpacity: Double // 0...1,    default 0.55  (glass tint alpha)
    var tintHex: String           // default "#1B1B2F"
    var textHex: String           // default "#F2F2F7"
    var saturation: Double        // 0...3,    default 1.35
    var materialIndex: Int        // 0...5 index into GlassConfig.materialNames
    var fontFamily: String        // default "Menlo"
    var fontSize: Double          // 9...48,   default 13
    var lineSpacing: Double       // 0.8...2.2 line-height multiplier, default 1.15
    var cursorStyleIndex: Int     // 0 block, 1 beam, 2 underline
    var cursorBlink: Bool         // default true
    var cornerRadius: Double      // 0...40,   default 14
    var innerPadding: Double      // 0...48,   default 12

    init()                        // all defaults above
    static let materialNames: [String]
    // ["Under Window", "HUD Window", "Sidebar", "Menu", "Popover", "Full Screen"]
    static let materialValues: [NSVisualEffectView.Material]
    // [.underWindowBackground, .hudWindow, .sidebar, .menu, .popover, .fullScreenUI]
    static let cursorStyleNames: [String]  // ["Block", "Beam", "Underline"]

    func clamped() -> GlassConfig  // clamps every numeric field to its stated range
}

extension Notification.Name {
    static let glassConfigDidChange = Notification.Name("GlassTermConfigDidChange")
}

final class ConfigStore {
    static let shared: ConfigStore
    var fileURL: URL { get }          // ~/.config/glassterm/config.json
    private(set) var config: GlassConfig

    func set(_ mutate: (inout GlassConfig) -> Void)
    // 1. copy config, 2. mutate, 3. clamp, 4. save, 5. post .glassConfigDidChange on main (object: self)
    func save()                        // atomic write, prettyPrinted + sortedKeys, create dir 0o700
    func reload()
    func resetToDefaults()             // set { $0 = GlassConfig() }
}

extension NSColor {
    convenience init?(hex: String)     // accepts "#RRGGBB", "RRGGBB", "#RRGGBBAA" (sRGB)
    var hexString: String { get }      // "#RRGGBB" uppercase, sRGB
}
```

Loading rules: missing/corrupt file → defaults, never crash. Unknown JSON keys ignored.
Saving happens on every `set` (debounce ≥ 120 ms is allowed but the file must be correct
within ~250 ms of the last change; flushing on `applicationWillTerminate` is the caller's job
via `ConfigStore.shared.save()`).

---

## 2. `PTY.swift` — owner C

```swift
import Foundation

enum PtyError: Error {
    case alreadyRunning
    case spawnFailed(Int32)      // errno
    case openFailed(Int32)
}

final class PtyProcess {
    private(set) var pid: pid_t
    var isRunning: Bool { get }
    var masterFD: Int32 { get }
    var onData: ((Data) -> Void)?    // ALWAYS delivered on the main queue
    var onExit: ((Int32) -> Void)?   // ALWAYS delivered on the main queue (status)

    init()
    func start(shell: String,
               args: [String],
               environment: [String: String],
               workingDirectory: String,
               cols: Int,
               rows: Int) throws
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)   // TIOCSWINSZ + SIGWINCH
    func terminate()                    // SIGHUP, then SIGKILL after grace; joins reader
}
```

Implementation notes (mandatory): `forkpty(&master, nil, &winsize, nil)` from `<util.h>`.
Child: `chdir(cwd)`, `execve(shell, argv, envp)` where `argv[0]` is the shell basename prefixed
with `-` (login shell), `argv[1]` = `"-l"`. On exec failure `_exit(127)`. Parent: set master
non-blocking, spawn a `Thread`/`DispatchQueue` reader that loops `read(2)` on the master FD,
dispatches `Data` to main, and on EOF/EIO reaps with `waitpid(WNOHANG)` and calls `onExit` once.
`write` must be partial-write safe. `terminate` is idempotent. No `Process`/`NSTask`.
Guard against double `onExit` and use-after-free races (read `masterFD` into a local before
closing; `O_CLOEXEC` not needed for master).

---

## 3. `TerminalCore.swift` — owner D

Pure Swift + Foundation. No AppKit. This is the emulator core.

```swift
enum TermColor: Equatable {
    case defaultColor
    case indexed(UInt8)          // 0-255, 256-colour palette
    case rgb(UInt8, UInt8, UInt8)
}

struct CellAttrs: OptionSet, Equatable {
    var rawValue: UInt8
    init(rawValue: UInt8)
    static let bold: CellAttrs          // 1 << 0
    static let dim: CellAttrs           // 1 << 1
    static let italic: CellAttrs        // 1 << 2
    static let underline: CellAttrs     // 1 << 3
    static let blink: CellAttrs         // 1 << 4
    static let reverse: CellAttrs       // 1 << 5
    static let strikethrough: CellAttrs // 1 << 6
    static let hidden: CellAttrs        // 1 << 7
}

struct Cell: Equatable {
    var text: String        // exactly one grapheme cluster, " " for blank
    var fg: TermColor       // .defaultColor
    var bg: TermColor       // .defaultColor
    var attrs: CellAttrs    // []
    var width: Int8         // 1 = normal, 2 = wide lead, 0 = wide tail (skip when drawing)
    init()                  // blank cell
}

final class Terminal {
    init(cols: Int, rows: Int)
    var cols: Int { get }
    var rows: Int { get }

    func feed(_ data: Data)                 // incremental, keeps state across calls (UTF-8 split safe)
    func resize(cols: Int, rows: Int)       // reflow-free: clamp/pad, keep cursor visible
    func reset()

    func grid() -> [[Cell]]                 // rows arrays of cols cells, [0] = top row
    func scrollbackLines(limit: Int) -> [[Cell]]  // oldest first, up to `limit` newest lines
    var scrollbackCount: Int { get }

    var cursorRow: Int { get }              // 0-based, within grid
    var cursorCol: Int { get }
    var cursorVisible: Bool { get }
    var cursorShapeHint: Int? { get }       // DECSCUSR 0-6 -> 0 block,1 block,2 block?, map: 0/1/2 block, 3/4 underline, 5/6 beam
    var applicationCursorKeys: Bool { get } // DECCKM
    var bracketedPaste: Bool { get }        // mode 2004
    var title: String? { get }              // OSC 0/2, nil until set
    var onTitleChange: ((String) -> Void)?
    var onBell: (() -> Void)?
}
```

Required VT coverage (this is the pass/fail list):
- Printable ASCII + UTF-8 (including multi-byte split across `feed` calls), wide chars (width 2),
  combining marks folded into the previous cell.
- Control: BEL BS HT LF VT FF CR SO SI.
- ESC: `7`/`8` save/restore cursor, `D` index, `E` NEL, `M` reverse index, `c` RIS reset,
  `=`/`>` keypad (track only if trivial), `#8` alignment test (fill E).
- CSI: CUU/CUD/CUF/CUB (`A B C D`), CNL/CPL (`E F`), CHA (`G`), CUP/HVP (`H f`), ED (`J` modes 0/1/2/3),
  EL (`K` modes 0/1/2), IL/DL (`L M`), ICH/DCH (`@ P`), ECH (`X`), SU/SD (`S T`), SGR (`m`),
  DECSTBM (`r`), `s`/`u` save/restore cursor, `h`/`l` private modes 1 (DECCKM), 7 (autowrap),
  25 (cursor visible), 1049/1047/47 (alternate screen), 2004 (bracketed paste), `q` cursor style,
  `n` device status (reply `ESC[0n` / `ESC[<row>;<col>R` for 6).
  DA (`c`) → reply `ESC[?1;2c`. Unknown CSI must be consumed and ignored, never printed.
- SGR: 0, 1, 2, 3, 4, 7, 8? (hidden=8), 9, 21/22, 23, 24, 27, 28? (strike=9/29), 30-37, 39,
  40-47, 49, 90-97, 100-107, 38;5;n / 48;5;n, 38;2;r;g;b / 48;2;r;g;b, 5 (blink).
- OSC: `0`/`2` title (terminated by BEL or ST), `4` palette set optional, `52` clipboard optional
  (ignore), unknown OSC swallowed up to BEL/ST. OSC/DCS/APC must never leak into the grid.
- Autowrap with deferred-wrap semantics, tab stops every 8 columns, scroll region respected,
  scrollback push only when the region is the full screen on LF at bottom.
- Alt screen: `?1049h` saves cursor+screen, `?1049l` restores; no scrollback while active.

Performance: `feed` must handle a 1 MB burst without quadratic copying (buffer scalars, mutate
in place). `grid()` may copy.

---

## 4. `TerminalView.swift` — owner E

Custom `NSView`, flipped (`isFlipped = true`), layer-backed, draws the terminal itself with
AppKit text drawing (no `NSTextView`). Owns the PTY and the `Terminal`.

```swift
final class TerminalView: NSView {
    init(frame: NSRect, config: GlassConfig)
    var config: GlassConfig { get private set }     // current appearance config
    var onTitleChange: ((String) -> Void)?
    var onBell: (() -> Void)?

    func apply(_ config: GlassConfig)               // font/metrics/colors change -> relayout + redraw
    func start(shell: String?, workingDirectory: String?)
    func focusTerminal()
    func updatePTYSize()                            // call after layout/resize

    func copySelection()
    func pasteFromPasteboard()
    func selectAll()
    func clearScreen()                              // sends ESC[2J ESC[H via terminal.reset()-ish path
    func increaseFontSize(); func decreaseFontSize(); func resetFontSize()

    var cellSize: CGSize { get }                    // current monospace cell metrics incl. padding-free
    func contentSize(forCols cols: Int, rows: Int) -> NSSize  // includes innerPadding on both axes
}
```

Rendering requirements:
- Monospace grid from `Terminal.grid()`; honour fg/bg/attrs (bold→NSFontManager bold or synthetic,
  italic, underline, strikethrough, reverse video, dim alpha, hidden).
- 16 ANSI colours + 256-colour cube/grayscale; `.defaultColor` fg = `config.textHex`,
  `.defaultColor` bg = **clear** so the glass shows through. Reverse video swaps them.
- Cursor: block/beam/underline per `config.cursorStyleIndex` (fallback to `cursorShapeHint` when
  the app requested one), blinking per `config.cursorBlink` on a 0.5 s timer that only redraws
  the cursor rect. Cursor is hidden while the view is not first responder (unless app hid it).
- Smooth scrolling: `scrollWheel` with momentum scrolls the viewport through scrollback
  (`Terminal.scrollbackLines`), sub-line pixel offset allowed; new output pins to bottom.
  Trackpad deltaY handling, no jitter, clamp to [0, scrollbackCount].
- Window resize: `setFrameSize`/`layout` recompute cols/rows from bounds minus padding,
  call `updatePTYSize()`, redraw. Never loop (guard against re-entrant layout).
- High-DPI: draw with `NSGraphicsContext.current` and let AppKit handle Retina; use
  `font.screenFont`-equivalent (`NSFont` at size), avoid bitmap caches that assume 1x.
- Selection: mouse drag selects cell rectangle (linear across wrapped rows), double-click word,
  Cmd+C copies selected text with trailing spaces trimmed and lines joined with `\n`.
- Keyboard: printable → UTF-8 encoded; Return `\r`, Backspace `0x7f`, Tab `\t`, Esc `0x1b`,
  Ctrl-A..Ctrl-Z → 0x01..0x1a, Ctrl-] 0x1d, Ctrl-\ 0x1c. Arrows/Home/End/PageUp/PageDown/
  Insert/Delete/F1–F12 in normal and application-cursor modes. Option = meta (ESC prefix),
  honour `Shift` for selection keys. Cmd+K clear, Cmd+C copy, Cmd+V paste, Cmd+A select all,
  Cmd+= / Cmd+- / Cmd+0 font size shortcuts, Cmd+Shift+K? no.
- Paste: if `terminal.bracketedPaste`, wrap with `ESC[200~ ... ESC[201~`. Strip bracketed-paste
  markers from incoming pasteboard text. Never paste control bytes other than \n/\t/\r.
- `start` uses `ProcessInfo.processInfo.environment["SHELL"]` when `shell == nil`, defaults
  `/bin/zsh`, cwd = `NSHomeDirectory()`, env = parent env + `TERM=xterm-256color`,
  `COLORTERM=truecolor`, `TERM_PROGRAM=GlassTerm`, `TERM_PROGRAM_VERSION=1.0.0`,
  `LANG` fallback `en_US.UTF-8`. PTY cols/rows derived from current bounds (min 20x5).
- `onData` → `terminal.feed` → coalesce redraws at ≤ 60 Hz (`needsDisplay` already coalesces;
  do not add a timer per byte). Title changes forwarded through `onTitleChange`.
- Deinit/`viewWillMove(toWindow:)` → `pty.terminate()` when removed permanently.

---

## 5. `GlassChrome.swift` — owner F

```swift
final class GlassBackgroundView: NSView {
    init(frame: NSRect)
    var materialIndex: Int { get }        // last applied
    func apply(_ config: GlassConfig)
    func attach(toWindow window: NSWindow?)   // called when the view moves to a window
}

final class RoundedClipView: NSView {      // clips its subtree to config.cornerRadius
    init(frame: NSRect, cornerRadius: CGFloat)
    var cornerRadius: CGFloat { get set }
    func apply(_ config: GlassConfig)
}
```

Requirements:
- `GlassBackgroundView` hosts an `NSVisualEffectView` (blendingMode `.behindWindow`,
  state `.active`, material from `GlassConfig.materialValues[clamped index]`), a tint overlay
  (`NSView` whose layer background = `NSColor(hex: tintHex)` with alpha `backgroundOpacity`),
  and a subtle 1 px inner border/highlight for the "liquid glass" edge (white at 6–10 % alpha).
- **Blur radius**: call the private CoreGraphics Services symbol at runtime, never link it:

```swift
private typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
private typealias CGSSetBlurFn = @convention(c) (Int32, Int32, Int32) -> Int32
// dlsym(RTLD_DEFAULT, "CGSMainConnectionID") / "CGSSetWindowBackgroundBlurRadius"
```

  Apply `Int32(config.blurRadius)` to `window.windowNumber` on every `apply` and whenever the
  view attaches to a window (`NSView.viewDidMoveToWindow`). If either symbol is missing
  (`dlsym` nil) or the call returns non-zero, degrade silently to the visual-effect material
  (no crash, no log spam).
- **Saturation**: `wantsLayer = true`, `layerUsesCoreImageFilters = true`, and a
  `CIFilter(name: "CIColorControls")` with `kCIInputSaturationKey = config.saturation` in
  `layer?.filters`. If the filter cannot be created, skip silently.
- **Corner radius**: the window is borderless-looking (`titlebarAppearsTransparent`,
  `titleVisibility = .hidden`, `fullSizeContentView`), `isOpaque = false`,
  `backgroundColor = .clear`, content view layer radius = `cornerRadius` with `masksToBounds`.
  Keep the traffic lights visible and inside a custom title strip (see WindowController).
- All `apply` calls must work before the view has a window (store settings, apply on attach).
- Must not fight the terminal: `GlassBackgroundView` is a sibling *behind* the terminal view and
  `hitTest` returns nil (so clicks fall through to the terminal).
- `RoundedClipView` is the container that clips both glass and terminal to the radius and adds
  `innerPadding` around the terminal.

---

## 6. `WindowController.swift` — owner G

```swift
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    init(configStore: ConfigStore)
    var terminalView: TerminalView { get }
    func showWindowAndStart()
    func applyConfig()
    func newWindow()                     // opens another independent window+shell
    func toggleFullScreenAction(_ sender: Any?)
    func windowDidResize(_ notification: Notification)
}
```

Requirements:
- Window: `NSWindow(contentRect:styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)`,
  `title = "GlassTerm"`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`,
  `isMovableByWindowBackground = true`, `minSize` 420×260, `isReleasedWhenClosed = false`,
  `collectionBehavior` includes `.fullScreenPrimary`, `appearance` follows system.
- Layering inside `contentView`: `GlassBackgroundView` (pinned, full bounds) →
  `RoundedClipView` (pinned, full bounds, radius) containing `TerminalView` inset by
  `config.innerPadding` on all four sides. Terminal gets first responder on show.
- Traffic lights: with `.fullSizeContentView` and a hidden title, AppKit still places the
  standard buttons — keep them at their standard position (do not hide). Add ~4 pt top inset
  to the terminal content so text never sits under the buttons.
- Default size: 100 cols × 30 rows using `terminalView.contentSize(forCols:rows:)`, clamped to
  the visible screen frame; cascade new windows by 24 pt; remember size/position in
  `NSUserDefaults` keys `GlassTerm.windowFrame`.
- Observes `.glassConfigDidChange` → `applyConfig()` → `terminalView.apply(config)` +
  chrome `apply(config)` + resize window content if the padding/corner radius changed the
  terminal's ideal size only when the user has not manually resized (keep it simple: never
  resize the window from a settings change; just relayout).
- `windowWillClose` → terminate the shell, save window frame, and if it was the last window
  post nothing (AppDelegate quits).
- Title: window title follows the shell's OSC title via `terminalView.onTitleChange`
  (fallback "GlassTerm").

---

## 7. `SettingsWindow.swift` — owner H

```swift
final class SettingsWindowController: NSWindowController {
    static let shared: SettingsWindowController
    func show()
}
```

Requirements:
- A real `NSWindow` (titled, closable, 560×620 min, not resizable below that, centered on first
  show, `title = "GlassTerm Settings"`, `isReleasedWhenClosed = false`), built with
  `NSStackView` rows: label (right-aligned, fixed 170 pt) + control (+ value label).
- Sections with headers: **Glass** / **Typography** / **Cursor** / **Window** / **Shell**.
- Controls, all bound to `ConfigStore.shared.set { ... }` so the main window updates live:
  - Background opacity — NSSlider 0…1, value label "55 %".
  - Blur radius — NSSlider 0…120 pt, label "42 pt".
  - Saturation — NSSlider 0…3, label "1.35×".
  - Tint colour — NSColorWell (sRGB, alpha ignored), writes `tintHex`.
  - Text colour — NSColorWell, writes `textHex`.
  - Vibrancy material — NSPopUpButton over `GlassConfig.materialNames`.
  - Font family — NSPopUpButton over `NSFontManager.shared.availableFontFamilies` filtered to
    monospaced families first (Menlo, SF Mono, Monaco, Courier New, …) then the rest; writes
    `fontFamily`.
  - Font size — NSSlider 9…48 + NSStepper 9…48 (synced), label "13 pt".
  - Line spacing — NSSlider 0.8…2.2, label "1.15×".
  - Cursor style — NSPopUpButton Block/Beam/Underline; cursor blink — NSSwitch.
  - Corner radius — NSSlider 0…40; inner padding — NSSlider 0…48.
  - Shell — NSTextField path + "Choose…" button (NSOpenPanel, `canChooseFiles`, hidden files
    allowed, suggests `/bin`) writing a `shellPath` key **only if** a `shellPath` field exists;
    if you do not add it to GlassConfig, omit this row entirely and do not invent the field.
  - Footer: "Reset to Defaults" button → `ConfigStore.shared.resetToDefaults()`.
- Live preview is inherent (same config singleton) — every control action must be continuous
  (`isContinuous = true` for sliders, `.colorWell` for colour, no OK button, no Apply button).
- Window closing must not quit the app; `show()` must bring the same instance forward and
  `NSApp.activate(ignoringOtherApps: true)`.
- No Auto Layout ambiguity: use explicit constraints/stack view, verify with
  `NSLayoutConstraint` logs absent (can't see logs headlessly — just be rigorous).

---

## 8. `main.swift` + `AppDelegate.swift` — owner A

```swift
// main.swift
import AppKit
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [TerminalWindowController] = []
    func applicationDidFinishLaunching(_ notification: Notification)
    func applicationWillTerminate(_ notification: Notification)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool
    @objc func newWindow(_ sender: Any?)
    @objc func openSettings(_ sender: Any?)
    @objc func copyAction(_ sender: Any?)
    @objc func pasteAction(_ sender: Any?)
    @objc func selectAllAction(_ sender: Any?)
    @objc func clearAction(_ sender: Any?)
    @objc func biggerFont(_ sender: Any?)
    @objc func smallerFont(_ sender: Any?)
    @objc func actualSize(_ sender: Any?)
    @objc func toggleFullScreen(_ sender: Any?)
}
```

- Build the menu bar in code (`NSMenu`/`NSMenuItem`), no nib:
  - **GlassTerm**: About GlassTerm (orderFrontStandardAboutPanel, custom credits text is fine),
    Settings… (⌘,), Separator, Services, Hide (⌘H), Hide Others (⌥⌘H), Show All, Separator,
    Quit GlassTerm (⌘Q).
  - **Shell**: New Window (⌘N), New Tab? no tabs — omit; Clear Scrollback (⌘K),
    Close Window (⌘W), Separator, Bigger (⌘+), Smaller (⌘-), Actual Size (⌘0).
  - **Edit**: Undo/Redo (first responder), Cut, Copy (⌘C), Paste (⌘V), Select All (⌘A).
    Copy/paste must route to the focused `TerminalView` (use `NSApp.sendAction` to first
    responder; the terminal implements these selectors, so plain target=nil works).
  - **View**: Toggle Full Screen (⌃⌘F), Enter/Exit Full Screen via standard selector.
  - **Window**: Minimize (⌘M), Zoom, Bring All to Front; `NSApp.windowsMenu`.
  - **Help**: "GlassTerm Help" → opens a small `NSAlert` with the keyboard cheat-sheet.
- ⌘, must open `SettingsWindowController.shared.show()` from both the menu and the app's
  standard `showSettingsWindow:` selector path is not required; wire the menu item directly.
- On launch: create one window, save/reload config (`ConfigStore.shared.reload()`), start a
  shell, activate app, and register `applicationWillTerminate` → `ConfigStore.shared.save()`.
- `newWindow` creates an independent `TerminalWindowController` and keeps it in `windows`;
  remove controllers on close (implement via a closure/delegate callback or by pruning
  `windows` whose `window == nil`).
- About panel: `NSApp.orderFrontStandardAboutPanel(options:)` with application name + version.

## 9. `build.sh` + `Resources/` — owner I

Deliverables:
- `build.sh` at project root, executable, `set -euo pipefail`.
  - Cleans `build/`, compiles all `Sources/*.swift` with
    `swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -framework Cocoa -o build/GlassTerm`.
  - Honors `ARCHS` env (`arm64`, `x86_64`, `universal` via `lipo`) but defaults to host arch.
  - Assembles `GlassTerm.app/Contents/{MacOS,Resources}`, copies the binary, `Info.plist`,
    `AppIcon.icns` if present, `chmod +x` the binary, `plutil -lint` the plist,
    ad-hoc `codesign --force --sign - --timestamp=none GlassTerm.app` (ignore signing failure
    with a warning, never abort).
  - Prints a clear `✅ Built …/GlassTerm.app` line and the launch command.
  - Must be re-runnable (idempotent) and work from any cwd (`cd "$(dirname "$0")"`).
- `Resources/Info.plist`: `CFBundleExecutable=GlassTerm`, `CFBundleIdentifier=com.glassterm.app`,
  `CFBundleName=GlassTerm`, `CFBundleDisplayName=GlassTerm`, `CFBundlePackageType=APPL`,
  `CFBundleShortVersionString=1.0.0`, `CFBundleVersion=1`, `LSMinimumSystemVersion=13.0`,
  `NSHighResolutionCapable=true`, `NSPrincipalClass=NSApplication`,
  `NSSupportsAutomaticGraphicsSwitching=true`, `LSApplicationCategoryType=public.app-category.developer-tools`,
  `NSHumanReadableCopyright`, `CFBundleIconFile=AppIcon`.
- Icon: generate `Resources/AppIcon.icns` from a 1024×1024 PNG drawn by a tiny Swift/CoreGraphics
  script (`tools/make-icon.swift`) — rounded-square glass gradient + `>_` glyph — then
  `iconutil -c icns`. If `iconutil` or drawing fails, skip the icon and keep the build green.

## Definition of done (integration gate)

`./build.sh` exits 0, `GlassTerm.app` exists, `plutil -lint` passes, `codesign -v` passes,
and `GlassTerm.app/Contents/MacOS/GlassTerm` launches (headless check via `./build.sh --verify`
may run the binary with `GT_SMOKE=1` which should print `SMOKE_OK` and exit).
