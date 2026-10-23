import AppKit

/// A flipped, layer-backed custom view that draws a `Terminal` grid with AppKit text drawing,
/// owns the shell `PtyProcess`, and translates keyboard / mouse / scroll input into PTY bytes.
///
/// The view is intentionally transparent: `.defaultColor` cell backgrounds are not painted so the
/// glass chrome behind the view shows through.
final class TerminalView: NSView {

    // MARK: - Public surface

    private(set) var config: GlassConfig
    var onTitleChange: ((String) -> Void)?
    var onBell: (() -> Void)?

    // MARK: - Core

    private let terminal: Terminal
    private var pty: PtyProcess?
    private var ownsSession = false
    private var sessionToken = 0

    // MARK: - Font metrics

    private struct FontMetrics {
        var base: NSFont
        var bold: NSFont
        var italic: NSFont
        var boldItalic: NSFont
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var lineHeight: CGFloat
    }

    private var metrics: FontMetrics

    /// Current monospace cell metrics (padding-free).
    var cellSize: CGSize {
        CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
    }

    // MARK: - Colours

    /// One Dark-ish 16 colour ANSI palette.
    private static let ansi16: [NSColor] = [
        NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1), // 0 black
        NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1), // 1 red
        NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1), // 2 green
        NSColor(srgbRed: 0.898, green: 0.753, blue: 0.482, alpha: 1), // 3 yellow
        NSColor(srgbRed: 0.380, green: 0.686, blue: 0.937, alpha: 1), // 4 blue
        NSColor(srgbRed: 0.776, green: 0.471, blue: 0.867, alpha: 1), // 5 magenta
        NSColor(srgbRed: 0.337, green: 0.714, blue: 0.761, alpha: 1), // 6 cyan
        NSColor(srgbRed: 0.671, green: 0.698, blue: 0.749, alpha: 1), // 7 white
        NSColor(srgbRed: 0.361, green: 0.388, blue: 0.439, alpha: 1), // 8 bright black
        NSColor(srgbRed: 1.000, green: 0.482, blue: 0.525, alpha: 1), // 9 bright red
        NSColor(srgbRed: 0.663, green: 0.878, blue: 0.545, alpha: 1), // 10 bright green
        NSColor(srgbRed: 0.937, green: 0.816, blue: 0.541, alpha: 1), // 11 bright yellow
        NSColor(srgbRed: 0.498, green: 0.769, blue: 1.000, alpha: 1), // 12 bright blue
        NSColor(srgbRed: 0.878, green: 0.651, blue: 0.941, alpha: 1), // 13 bright magenta
        NSColor(srgbRed: 0.498, green: 0.839, blue: 0.878, alpha: 1), // 14 bright cyan
        NSColor(srgbRed: 0.980, green: 0.980, blue: 0.980, alpha: 1), // 15 bright white
    ]

    private var palette: [NSColor] = []
    private var defaultFG: NSColor = .white
    private var reverseInk: NSColor = .black

    // MARK: - Viewport

    /// Lines scrolled up from the live bottom (0 = live). Fractional values give sub-line scrolling.
    private var scrollOffset: CGFloat = 0
    private var scrollbackCache: [[Cell]] = []
    private var scrollbackCacheKey: Int = -1

    // MARK: - Selection

    private struct GridPoint: Equatable {
        var row: Int
        var col: Int
    }

    private var selAnchor: GridPoint?
    private var selHead: GridPoint?
    private var draggingAnchor: GridPoint?
    private var isDragging = false
    private var suppressClearOnMouseUp = false

    // MARK: - Cursor

    private var blinkOn = true
    private var blinkTimer: Timer?

    // MARK: - Layout

    private var inRelayout = false

    // MARK: - Draw scratch

    private struct CellDrawInfo {
        var fg: NSColor
        var bg: NSColor
        var bgKey: Int
        var hidden: Bool
    }

    private var rowBuffer: [CellDrawInfo] = []

    // MARK: - Init

    init(frame frameRect: NSRect, config: GlassConfig) {
        let cfg = config.clamped()
        let m = TerminalView.makeMetrics(for: cfg)
        self.config = cfg
        self.metrics = m
        self.defaultFG = NSColor(hex: cfg.textHex) ?? NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
        self.reverseInk = NSColor(hex: cfg.tintHex) ?? .black
        self.palette = TerminalView.makePalette()

        let pad = TerminalView.clampPadding(cfg.innerPadding)
        let cols = max(20, Int(floor(max(0, frameRect.width - pad * 2) / m.cellWidth)))
        let rows = max(5, Int(floor(max(0, frameRect.height - pad * 2) / m.cellHeight)))
        self.terminal = Terminal(cols: min(cols, 600), rows: min(rows, 300))

        super.init(frame: frameRect)

        self.autoresizingMask = [.width, .height]
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.isOpaque = false
        self.layer?.masksToBounds = true

        wireTerminalCallbacks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalView does not support NSCoding")
    }

    deinit {
        blinkTimer?.invalidate()
        pty?.terminate()
    }

    private func wireTerminalCallbacks() {
        terminal.onResponse = { [weak self] response in
            guard let self else { return }
            self.pty?.write(Data(response.utf8))
        }
        terminal.onBell = { [weak self] in
            guard let self else { return }
            NSSound.beep()
            self.onBell?()
        }
        terminal.onTitleChange = { [weak self] title in
            guard let self else { return }
            self.onTitleChange?(title)
        }
    }

    // MARK: - View behaviour

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if config.cursorBlink { startCursorBlink() }
            relayout()
            needsDisplay = true
        } else {
            stopCursorBlink()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopCursorBlink()
            if ownsSession {
                pty?.terminate()
                ownsSession = false
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            blinkOn = true
            if config.cursorBlink { startCursorBlink() }
            needsDisplay = true
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        stopCursorBlink()
        blinkOn = true
        needsDisplay = true
        return ok
    }

    // MARK: - Configuration

    func apply(_ newConfig: GlassConfig) {
        let cfg = newConfig.clamped()
        config = cfg
        metrics = TerminalView.makeMetrics(for: cfg)
        if let fg = NSColor(hex: cfg.textHex) { defaultFG = fg }
        if let ink = NSColor(hex: cfg.tintHex) { reverseInk = ink }
        palette = TerminalView.makePalette()

        if cfg.cursorBlink {
            blinkOn = true
            startCursorBlink()
        } else {
            stopCursorBlink()
        }

        let pad = TerminalView.clampPadding(cfg.innerPadding)
        _ = pad
        relayout()
        needsDisplay = true
    }

    /// Total view size needed to show `cols` × `rows` cells including the inner padding.
    func contentSize(forCols cols: Int, rows: Int) -> NSSize {
        let c = CGFloat(max(1, cols))
        let r = CGFloat(max(1, rows))
        let pad = padding
        return NSSize(width: ceil(c * metrics.cellWidth + pad * 2),
                      height: ceil(r * metrics.cellHeight + pad * 2))
    }

    // MARK: - Font size shortcuts

    func increaseFontSize() { setFontSize(config.fontSize + 1) }
    func decreaseFontSize() { setFontSize(config.fontSize - 1) }
    func resetFontSize() { setFontSize(13) }

    private func setFontSize(_ size: Double) {
        var cfg = config
        let clamped = max(9, min(48, size))
        guard abs(cfg.fontSize - clamped) > 0.001 else { return }
        cfg.fontSize = clamped
        apply(cfg)
    }

    // MARK: - Session

    func start(shell: String? = nil, workingDirectory: String? = nil) {
        if let existing = pty, existing.isRunning { return }
        pty?.terminate()
        pty = nil
        ownsSession = false

        let shellPath: String
        if let shell, !shell.isEmpty {
            shellPath = shell
        } else {
            shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }
        let cwd: String
        if let workingDirectory, !workingDirectory.isEmpty {
            cwd = workingDirectory
        } else {
            cwd = NSHomeDirectory()
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "GlassTerm"
        environment["TERM_PROGRAM_VERSION"] = "1.0.0"
        if environment["LANG"]?.isEmpty != false {
            environment["LANG"] = "en_US.UTF-8"
        }

        let size = gridSize(for: bounds.size)

        sessionToken += 1
        let token = sessionToken
        let process = PtyProcess()

        process.onData = { [weak self] data in
            guard let self, self.sessionToken == token else { return }
            self.terminal.feed(data)
            self.handleIncomingOutput()
        }
        process.onExit = { [weak self] _ in
            guard let self, self.sessionToken == token else { return }
            self.pty = nil
            self.ownsSession = false
            self.needsDisplay = true
        }

        do {
            try process.start(shell: shellPath,
                              args: [],
                              environment: environment,
                              workingDirectory: cwd,
                              cols: size.cols,
                              rows: size.rows)
            pty = process
            ownsSession = true
        } catch {
            NSLog("GlassTerm: failed to start shell \(shellPath): \(error)")
            pty = nil
            ownsSession = false
        }
    }

    func focusTerminal() {
        window?.makeFirstResponder(self)
    }

    func updatePTYSize() {
        relayout()
    }

    // MARK: - Terminal actions

    func copySelection() {
        guard let text = selectedText(), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteFromPasteboard() {
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }
        var text = raw
            .replacingOccurrences(of: "\u{1b}[200~", with: "")
            .replacingOccurrences(of: "\u{1b}[201~", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var filtered = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                filtered.append(scalar)
            } else if scalar.value >= 0x20 && scalar.value != 0x7f {
                filtered.append(scalar)
            }
        }
        text = String(filtered)
        guard !text.isEmpty else { return }

        if terminal.bracketedPaste {
            send("\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            send(text)
        }
    }

    func selectAll() {
        let rows = max(1, terminal.rows)
        let cols = max(1, terminal.cols)
        selAnchor = GridPoint(row: 0, col: 0)
        selHead = GridPoint(row: rows - 1, col: cols - 1)
        needsDisplay = true
    }

    func clearScreen() {
        send("\u{1b}[2J\u{1b}[H\u{1b}[3J")
        scrollOffset = 0
        scrollbackCacheKey = -1
        selAnchor = nil
        selHead = nil
        needsDisplay = true
    }

    // MARK: - Geometry

    private var padding: CGFloat {
        TerminalView.clampPadding(config.innerPadding)
    }

    private static func clampPadding(_ raw: Double) -> CGFloat {
        let value = CGFloat(raw)
        guard value.isFinite else { return 0 }
        return max(0, min(2000, value))
    }

    private static func makeMetrics(for config: GlassConfig) -> FontMetrics {
        let rawSize = CGFloat(config.fontSize)
        let size: CGFloat = rawSize.isFinite ? max(4, min(160, rawSize)) : 13

        let named = NSFont(name: config.fontFamily, size: size)
        let base = named ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        let manager = NSFontManager.shared
        let bold = manager.convert(base, toHaveTrait: .boldFontMask)
        let italic = manager.convert(base, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)

        var advance: CGFloat = 0
        let glyph = base.glyph(withName: "M")
        if glyph != 0 {
            advance = base.advancement(forGlyph: glyph).width
        }
        if !advance.isFinite || advance < 0.5 {
            advance = ("M" as NSString).size(withAttributes: [.font: base]).width
        }
        if !advance.isFinite || advance <= 0 {
            advance = size * 0.6
        }
        let cellWidth = max(1, advance)

        let rawLine = base.ascender - base.descender + base.leading
        let lineHeight = (rawLine.isFinite && rawLine > 0) ? rawLine : size * 1.2
        let rawSpacing = CGFloat(config.lineSpacing)
        let spacing = rawSpacing.isFinite ? max(0.5, min(3.0, rawSpacing)) : 1.15
        let cellHeight = max(1, ceil(lineHeight) * spacing)

        return FontMetrics(base: base,
                           bold: bold,
                           italic: italic,
                           boldItalic: boldItalic,
                           cellWidth: cellWidth,
                           cellHeight: cellHeight,
                           lineHeight: lineHeight)
    }

    private func gridSize(for size: NSSize) -> (cols: Int, rows: Int) {
        let pad = padding
        let usableWidth = max(0, size.width - pad * 2)
        let usableHeight = max(0, size.height - pad * 2)
        let cellW = max(1, metrics.cellWidth)
        let cellH = max(1, metrics.cellHeight)
        let cols = max(20, Int(floor(usableWidth / cellW)))
        let rows = max(5, Int(floor(usableHeight / cellH)))
        return (min(cols, 600), min(rows, 300))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    /// Recompute the grid from the current bounds and push the new size to core + PTY.
    private func relayout() {
        guard !inRelayout else { return }
        inRelayout = true
        defer { inRelayout = false }

        let target = gridSize(for: bounds.size)
        pty?.resize(cols: target.cols, rows: target.rows)

        guard target.cols != terminal.cols || target.rows != terminal.rows else {
            clampScroll()
            return
        }

        let wasLive = scrollOffset <= 0.0001
        terminal.resize(cols: target.cols, rows: target.rows)
        scrollbackCacheKey = -1
        scrollOffset = wasLive ? 0 : min(scrollOffset, CGFloat(terminal.scrollbackCount))
        needsDisplay = true
    }

    // MARK: - Scrollback

    private func clampedScrollOffset() -> CGFloat {
        guard scrollOffset.isFinite else { return 0 }
        let maximum = CGFloat(max(0, terminal.scrollbackCount))
        return max(0, min(maximum, scrollOffset))
    }

    private func clampScroll() {
        scrollOffset = clampedScrollOffset()
    }

    private func scrollbackLinesSnapshot() -> [[Cell]] {
        let count = terminal.scrollbackCount
        if scrollbackCacheKey == count { return scrollbackCache }
        let snapshot = count > 0 ? terminal.scrollbackLines(limit: count) : []
        scrollbackCache = snapshot
        scrollbackCacheKey = count
        return snapshot
    }

    private func handleIncomingOutput() {
        if scrollOffset <= 0.0001 {
            scrollOffset = 0
        } else {
            scrollOffset = min(scrollOffset, CGFloat(terminal.scrollbackCount))
        }
        if scrollbackCacheKey != terminal.scrollbackCount {
            scrollbackCacheKey = -1
        }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let maximum = CGFloat(max(0, terminal.scrollbackCount))
        guard maximum > 0 else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta.isFinite else { return }

        let lines: CGFloat
        if event.hasPreciseScrollingDeltas {
            lines = delta / max(1, metrics.cellHeight)
        } else {
            lines = delta * 3
        }

        scrollOffset = max(0, min(maximum, scrollOffset + lines))
        needsDisplay = true
    }

    // MARK: - Drawing

    private func color(for term: TermColor) -> NSColor {
        switch term {
        case .defaultColor:
            return defaultFG
        case .indexed(let index):
            return paletteColor(Int(index))
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255,
                           green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255,
                           alpha: 1)
        }
    }

    private func paletteColor(_ index: Int) -> NSColor {
        let i = max(0, min(255, index))
        return i < palette.count ? palette[i] : defaultFG
    }

    private static func colorKey(_ color: TermColor) -> Int {
        switch color {
        case .defaultColor:
            return 0
        case .indexed(let i):
            return 1 + Int(i)
        case .rgb(let r, let g, let b):
            return 257 + (Int(r) << 16 | Int(g) << 8 | Int(b))
        }
    }

    private static func makePalette() -> [NSColor] {
        var colors = [NSColor]()
        colors.reserveCapacity(256)
        colors.append(contentsOf: ansi16)

        let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    colors.append(NSColor(srgbRed: levels[r] / 255,
                                          green: levels[g] / 255,
                                          blue: levels[b] / 255,
                                          alpha: 1))
                }
            }
        }
        for i in 0..<24 {
            let v = CGFloat(8 + i * 10) / 255
            colors.append(NSColor(srgbRed: v, green: v, blue: v, alpha: 1))
        }
        while colors.count < 256 {
            colors.append(ansi16[0])
        }
        return colors
    }

    private func font(for attrs: CellAttrs) -> NSFont {
        let bold = attrs.contains(.bold)
        let italic = attrs.contains(.italic)
        if bold && italic { return metrics.boldItalic }
        if bold { return metrics.bold }
        if italic { return metrics.italic }
        return metrics.base
    }

    private func cellDrawInfo(_ cell: Cell) -> CellDrawInfo {
        let reversed = cell.attrs.contains(.reverse)
        let fgTerm = reversed ? cell.bg : cell.fg
        let bgTerm = reversed ? cell.fg : cell.bg

        var fg: NSColor
        if fgTerm == .defaultColor {
            // In reverse video the "default foreground" is the terminal background; on glass that is
            // transparent, so use the tint colour as ink instead of drawing invisible text.
            fg = reversed ? reverseInk : defaultFG
        } else {
            fg = color(for: fgTerm)
        }

        var bg: NSColor = .clear
        var bgKey = 0
        if bgTerm != .defaultColor {
            bg = color(for: bgTerm)
            bgKey = TerminalView.colorKey(bgTerm)
        } else if reversed {
            // SGR 7 on fully default cells inverts to a filled block of the text colour.
            bg = defaultFG
            bgKey = -1
        }

        if cell.attrs.contains(.dim) {
            fg = fg.withAlphaComponent(fg.alphaComponent * 0.55)
        }
        var hidden = false
        if cell.attrs.contains(.hidden) {
            fg = fg.withAlphaComponent(0)
            hidden = true
        }

        return CellDrawInfo(fg: fg, bg: bg, bgKey: bgKey, hidden: hidden)
    }

    private func drawCellBackgrounds(_ infos: [CellDrawInfo], count: Int,
                                     originX: CGFloat, y: CGFloat,
                                     cellW: CGFloat, cellH: CGFloat) {
        var runStart = -1
        var runKey = 0
        var runColor: NSColor = .clear

        func flush(upTo end: Int) {
            guard runStart >= 0, end > runStart, runColor.alphaComponent > 0.001 else { return }
            runColor.setFill()
            NSRect(x: originX + CGFloat(runStart) * cellW,
                   y: y,
                   width: CGFloat(end - runStart) * cellW,
                   height: cellH).fill()
        }

        for c in 0..<count {
            let info = infos[c]
            if info.bgKey != runKey {
                flush(upTo: c)
                runKey = info.bgKey
                runStart = info.bgKey == 0 ? -1 : c
                runColor = info.bg
            }
        }
        flush(upTo: count)
    }

    private func drawRow(_ cells: [Cell], cols: Int, originX: CGFloat,
                         y: CGFloat, cellW: CGFloat, cellH: CGFloat) {
        let count = min(cells.count, cols)
        guard count > 0 else { return }

        rowBuffer.removeAll(keepingCapacity: true)
        rowBuffer.reserveCapacity(count)
        for i in 0..<count {
            rowBuffer.append(cellDrawInfo(cells[i]))
        }

        drawCellBackgrounds(rowBuffer, count: count, originX: originX, y: y, cellW: cellW, cellH: cellH)

        let textTop = y + max(0, (cellH - metrics.lineHeight) * 0.5)
        for i in 0..<count {
            let cell = cells[i]
            if cell.width == 0 { continue }          // wide-glyph tail: nothing to draw
            let info = rowBuffer[i]
            if info.hidden { continue }
            let text = cell.text
            if text.isEmpty { continue }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font(for: cell.attrs),
                .foregroundColor: info.fg,
            ]
            if cell.attrs.contains(.underline) {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if cell.attrs.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            let x = originX + CGFloat(i) * cellW
            (text as NSString).draw(at: NSPoint(x: x, y: textTop), withAttributes: attrs)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let grid = terminal.grid()
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let cellW = metrics.cellWidth
        let cellH = metrics.cellHeight
        let pad = padding
        let scrollbackCount = terminal.scrollbackCount
        let scrollback = scrollbackLinesSnapshot()

        let offset = clampedScrollOffset()
        let wholeOffset = Int(floor(offset))
        let fraction = offset - CGFloat(wholeOffset)
        let topAbsolute = scrollbackCount - wholeOffset

        let maxV = rows + wholeOffset
        let firstV = max(0, Int(floor((dirtyRect.minY - pad) / cellH + fraction)))
        let lastV = min(maxV, Int(ceil((dirtyRect.maxY - pad) / cellH + fraction)))
        if firstV <= lastV {
            for v in firstV...lastV {
                let absolute = topAbsolute + v
                guard absolute >= 0, absolute < scrollbackCount + rows else { continue }
                let y = pad + CGFloat(v) * cellH - fraction * cellH
                guard y + cellH > 0, y < bounds.height else { continue }

                let cells: [Cell]?
                if absolute < scrollbackCount {
                    cells = absolute < scrollback.count ? scrollback[absolute] : nil
                } else {
                    let gridRow = absolute - scrollbackCount
                    cells = (gridRow >= 0 && gridRow < grid.count) ? grid[gridRow] : nil
                }
                if let cells {
                    drawRow(cells, cols: cols, originX: pad, y: y, cellW: cellW, cellH: cellH)
                }
            }
        }

        drawSelectionOverlay(rows: rows, cols: cols, scrollbackCount: scrollbackCount,
                             topAbsolute: topAbsolute, fraction: fraction,
                             pad: pad, cellW: cellW, cellH: cellH)
        drawCursor(grid: grid, rows: rows, cols: cols, pad: pad, cellW: cellW, cellH: cellH)
    }

    private func drawSelectionOverlay(rows: Int, cols: Int, scrollbackCount: Int,
                                      topAbsolute: Int, fraction: CGFloat,
                                      pad: CGFloat, cellW: CGFloat, cellH: CGFloat) {
        guard let (start, end) = orderedSelection() else { return }
        let color = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
        color.setFill()

        let firstRow = max(0, start.row)
        let lastRow = min(rows - 1, end.row)
        guard firstRow <= lastRow else { return }

        for row in firstRow...lastRow {
            let y = pad + CGFloat(scrollbackCount + row - topAbsolute) * cellH - fraction * cellH
            guard y + cellH > 0, y < bounds.height else { continue }
            let from = row == start.row ? max(0, start.col) : 0
            let to = row == end.row ? min(cols - 1, end.col) : cols - 1
            guard to >= from else { continue }
            NSRect(x: pad + CGFloat(from) * cellW,
                   y: y,
                   width: CGFloat(to - from + 1) * cellW,
                   height: cellH).fill()
        }
    }

    // MARK: - Cursor

    private func cursorShape() -> Int {
        if let hint = terminal.cursorShapeHint {
            switch hint {
            case 0, 1, 2: return 0   // block
            case 3, 4: return 2      // underline
            case 5, 6: return 1      // beam
            default: break
            }
        }
        return max(0, min(2, config.cursorStyleIndex))
    }

    private var shouldDrawCursor: Bool {
        guard window != nil else { return false }
        guard window?.firstResponder === self else { return false }
        guard terminal.cursorVisible else { return false }
        if scrollOffset > 0.5 { return false }
        if config.cursorBlink && !blinkOn { return false }
        return true
    }

    private func drawCursor(grid: [[Cell]], rows: Int, cols: Int,
                            pad: CGFloat, cellW: CGFloat, cellH: CGFloat) {
        guard shouldDrawCursor else { return }
        let row = terminal.cursorRow
        let col = terminal.cursorCol
        guard row >= 0, row < rows, col >= 0, col < cols else { return }

        let x = pad + CGFloat(col) * cellW
        let y = pad + CGFloat(row) * cellH
        let shape = cursorShape()
        let color = defaultFG.withAlphaComponent(0.9)
        color.setFill()

        switch shape {
        case 1: // beam
            let width = max(1, min(3, cellW * 0.18))
            NSRect(x: x, y: y, width: width, height: cellH).fill()
        case 2: // underline
            let height = max(1.5, min(3, cellH * 0.12))
            NSRect(x: x, y: y + cellH - height, width: cellW, height: height).fill()
        default: // block
            NSRect(x: x, y: y, width: cellW, height: cellH).fill()
            if row < grid.count, col < grid[row].count {
                let cell = grid[row][col]
                if cell.width != 0, !cell.text.isEmpty, !cell.attrs.contains(.hidden) {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font(for: cell.attrs),
                        .foregroundColor: reverseInk,
                    ]
                    let textTop = y + max(0, (cellH - metrics.lineHeight) * 0.5)
                    (cell.text as NSString).draw(at: NSPoint(x: x, y: textTop), withAttributes: attrs)
                }
            }
        }
    }

    private func cursorRectForRedraw() -> NSRect? {
        guard window != nil, window?.firstResponder === self else { return nil }
        guard terminal.cursorVisible, scrollOffset <= 0.5 else { return nil }
        let rect = NSRect(x: padding + CGFloat(terminal.cursorCol) * metrics.cellWidth,
                          y: padding + CGFloat(terminal.cursorRow) * metrics.cellHeight,
                          width: metrics.cellWidth,
                          height: metrics.cellHeight)
        return rect.insetBy(dx: -2, dy: -2)
    }

    private func startCursorBlink() {
        guard config.cursorBlink, blinkTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.window != nil, self.window?.firstResponder === self else { return }
            self.blinkOn.toggle()
            if let rect = self.cursorRectForRedraw() {
                self.setNeedsDisplay(rect)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopCursorBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
    }

    // MARK: - Selection

    private func orderedSelection() -> (start: GridPoint, end: GridPoint)? {
        guard let anchor = selAnchor, let head = selHead else { return nil }
        let cols = max(1, terminal.cols)
        let anchorIndex = anchor.row * cols + anchor.col
        let headIndex = head.row * cols + head.col
        return anchorIndex <= headIndex ? (anchor, head) : (head, anchor)
    }

    private func selectedText() -> String? {
        guard let (start, end) = orderedSelection() else { return nil }
        let grid = terminal.grid()
        var lines: [String] = []

        let firstRow = max(0, start.row)
        let lastRow = min(max(0, grid.count - 1), end.row)
        guard firstRow <= lastRow else { return nil }

        for row in firstRow...lastRow {
            let cells = grid[row]
            guard !cells.isEmpty else {
                lines.append("")
                continue
            }
            let from = row == start.row ? max(0, start.col) : 0
            let to = row == end.row ? min(cells.count - 1, end.col) : cells.count - 1
            var line = ""
            if to >= from {
                for c in from...to {
                    guard c >= 0, c < cells.count else { continue }
                    let cell = cells[c]
                    if cell.width == 0 { continue }
                    var text = cell.text
                    if text == "\0" { text = " " }
                    if text.isEmpty { text = " " }
                    line += text
                }
            }
            while line.hasSuffix(" ") || line.hasSuffix("\t") {
                line.removeLast()
            }
            lines.append(line)
        }

        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private func extendSelection(keyCode: UInt16) -> Bool {
        let rows = max(1, terminal.rows)
        let cols = max(1, terminal.cols)

        var anchor = selAnchor
        var head = selHead

        if anchor == nil || head == nil {
            let cursorPoint = GridPoint(row: max(0, min(rows - 1, terminal.cursorRow)),
                                        col: max(0, min(cols - 1, terminal.cursorCol)))
            anchor = cursorPoint
            head = cursorPoint
        }

        guard let fixedAnchor = anchor, var movingHead = head else { return false }
        switch keyCode {
        case 123: movingHead.col = max(0, movingHead.col - 1)
        case 124: movingHead.col = min(cols - 1, movingHead.col + 1)
        case 125: movingHead.row = min(rows - 1, movingHead.row + 1)
        case 126: movingHead.row = max(0, movingHead.row - 1)
        case 115: movingHead.col = 0
        case 119: movingHead.col = cols - 1
        default: return false
        }

        selAnchor = fixedAnchor
        selHead = movingHead
        needsDisplay = true
        return true
    }

    private func gridPoint(from event: NSEvent) -> GridPoint? {
        let point = convert(event.locationInWindow, from: nil)
        let cellW = metrics.cellWidth
        let cellH = metrics.cellHeight
        guard cellW > 0, cellH > 0 else { return nil }
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let col = Int(floor((point.x - padding) / cellW))
        let row = Int(floor((point.y - padding) / cellH))
        return GridPoint(row: max(0, min(rows - 1, row)), col: max(0, min(cols - 1, col)))
    }

    private func selectWord(at point: GridPoint) {
        let grid = terminal.grid()
        guard point.row >= 0, point.row < grid.count else { return }
        let cells = grid[point.row]
        guard !cells.isEmpty else { return }
        let col = max(0, min(cells.count - 1, point.col))

        func isWord(_ cell: Cell) -> Bool {
            guard cell.width != 0, let scalar = cell.text.unicodeScalars.first else { return false }
            if CharacterSet.alphanumerics.contains(scalar) { return true }
            return scalar == "/" || scalar == "." || scalar == "_" || scalar == "-"
        }

        if !isWord(cells[col]) {
            selAnchor = GridPoint(row: point.row, col: col)
            selHead = GridPoint(row: point.row, col: col)
            needsDisplay = true
            return
        }

        var start = col
        while start > 0 && isWord(cells[start - 1]) { start -= 1 }
        var end = col
        while end + 1 < cells.count && isWord(cells[end + 1]) { end += 1 }

        selAnchor = GridPoint(row: point.row, col: start)
        selHead = GridPoint(row: point.row, col: end)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if scrollOffset > 0 {
            scrollOffset = 0
            needsDisplay = true
        }
        guard let point = gridPoint(from: event) else { return }

        isDragging = false
        suppressClearOnMouseUp = false
        draggingAnchor = point

        if event.clickCount == 2 {
            selectWord(at: point)
            suppressClearOnMouseUp = true
            return
        }

        selAnchor = point
        selHead = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = draggingAnchor else { return }
        guard let point = gridPoint(from: event) else { return }
        isDragging = true
        selAnchor = anchor
        selHead = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging && !suppressClearOnMouseUp {
            selAnchor = nil
            selHead = nil
            needsDisplay = true
        }
        isDragging = false
        suppressClearOnMouseUp = false
        draggingAnchor = nil
    }

    // MARK: - Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // Only claim shortcuts while this terminal is the active responder; other controls
        // (settings fields, etc.) keep their standard editing behaviour.
        guard window?.firstResponder === self else { return false }
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }

        switch characters {
        case "c":
            copySelection()
            return true
        case "v":
            pasteFromPasteboard()
            return true
        case "a":
            selectAll()
            return true
        case "k":
            clearScreen()
            return true
        case "=", "+":
            increaseFontSize()
            return true
        case "-", "_":
            decreaseFontSize()
            return true
        case "0":
            resetFontSize()
            return true
        default:
            // Not ours: let the menu bar (⌘N, ⌘W, ⌘Q, …) handle it.
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            // Cmd combinations belong to the menu; never leak them into the shell.
            if !performKeyEquivalent(with: event) {
                super.keyDown(with: event)
            }
            return
        }
        if handleKey(event, flags: flags) { return }
        super.keyDown(with: event)
    }

    private func handleKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        let shift = flags.contains(.shift)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let keyCode = event.keyCode

        // Shift + navigation extends the selection instead of reaching the shell.
        if shift, keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126
            || keyCode == 115 || keyCode == 119 {
            if extendSelection(keyCode: keyCode) { return true }
        }

        switch keyCode {
        case 36, 76: // Return, keypad Enter
            send(option ? "\u{1b}\r" : "\r")
            return true
        case 51: // Backspace
            send(control ? "\u{08}" : "\u{7f}")
            return true
        case 48: // Tab
            send(shift ? "\u{1b}[Z" : "\t")
            return true
        case 53: // Escape
            send("\u{1b}")
            return true
        case 123, 124, 125, 126: // arrows
            send(arrowSequence(keyCode: keyCode, flags: flags))
            return true
        case 115: // Home
            send(homeEndSequence(home: true, flags: flags))
            return true
        case 119: // End
            send(homeEndSequence(home: false, flags: flags))
            return true
        case 116: // Page Up
            send(editingSequence(code: 5, flags: flags))
            return true
        case 121: // Page Down
            send(editingSequence(code: 6, flags: flags))
            return true
        case 117: // Forward Delete
            send(editingSequence(code: 3, flags: flags))
            return true
        case 114: // Insert / Help
            send(editingSequence(code: 2, flags: flags))
            return true
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111:
            if let sequence = TerminalView.functionKeys[keyCode] {
                send(sequence)
                return true
            }
        default:
            break
        }

        if control {
            if let scalars = event.charactersIgnoringModifiers?.unicodeScalars, let first = scalars.first {
                let value = first.value
                if value >= 97 && value <= 122 { // a...z
                    send(String(UnicodeScalar(UInt8(value - 96))))
                    return true
                }
                switch first {
                case "[": send("\u{1b}"); return true
                case "]": send("\u{1d}"); return true
                case "\\": send("\u{1c}"); return true
                case "^": send("\u{1e}"); return true
                case "_": send("\u{1f}"); return true
                case " ": send("\0"); return true
                default: break
                }
            }
        }

        if option {
            if let base = event.charactersIgnoringModifiers, !base.isEmpty, isPrintable(base) {
                send("\u{1b}" + base)   // meta = ESC prefix
                return true
            }
        }

        if let characters = event.characters, !characters.isEmpty, isPrintable(characters) {
            send(characters)
            return true
        }

        return false
    }

    private func isPrintable(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { continue }
            if scalar.value >= 0xf700 && scalar.value <= 0xf8ff { continue } // function-key glyphs
            return true
        }
        return false
    }

    private static let functionKeys: [UInt16: String] = [
        122: "\u{1b}OP",      // F1
        120: "\u{1b}OQ",      // F2
        99: "\u{1b}OR",       // F3
        118: "\u{1b}OS",      // F4
        96: "\u{1b}[15~",     // F5
        97: "\u{1b}[17~",     // F6
        98: "\u{1b}[18~",     // F7
        100: "\u{1b}[19~",    // F8
        101: "\u{1b}[20~",    // F9
        109: "\u{1b}[21~",    // F10
        103: "\u{1b}[23~",    // F11
        111: "\u{1b}[24~",    // F12
    ]

    private func arrowSequence(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String {
        let suffix: String
        switch keyCode {
        case 123: suffix = "D"
        case 124: suffix = "C"
        case 125: suffix = "B"
        default: suffix = "A"
        }

        let option = flags.contains(.option)
        let control = flags.contains(.control)
        if !option && !control && terminal.applicationCursorKeys {
            return "\u{1b}O" + suffix
        }
        if option || control {
            var modifier = 1
            if option { modifier += 2 }
            if control { modifier += 4 }
            return "\u{1b}[1;\(modifier)" + suffix
        }
        return "\u{1b}[" + suffix
    }

    private func homeEndSequence(home: Bool, flags: NSEvent.ModifierFlags) -> String {
        let letter = home ? "H" : "F"
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        if !option && !control && terminal.applicationCursorKeys {
            return "\u{1b}O" + letter
        }
        if option || control {
            var modifier = 1
            if option { modifier += 2 }
            if control { modifier += 4 }
            return "\u{1b}[1;\(modifier)" + letter
        }
        return "\u{1b}[" + letter
    }

    private func editingSequence(code: Int, flags: NSEvent.ModifierFlags) -> String {
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        if option || control {
            var modifier = 1
            if option { modifier += 2 }
            if control { modifier += 4 }
            return "\u{1b}[\(code);\(modifier)~"
        }
        return "\u{1b}[\(code)~"
    }

    private func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        pty?.write(data)
    }

    // MARK: - Menu actions

    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    @objc func paste(_ sender: Any?) {
        pasteFromPasteboard()
    }

    @objc func selectAll(_ sender: Any?) {
        selectAll()
    }
}

// MARK: - Menu validation

extension TerminalView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(TerminalView.copy(_:)):
            return selectedText() != nil
        case #selector(TerminalView.paste(_:)):
            return NSPasteboard.general.string(forType: .string)?.isEmpty == false
        case #selector(TerminalView.selectAll(_:)):
            return true
        default:
            return true
        }
    }
}
