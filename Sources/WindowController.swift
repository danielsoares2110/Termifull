import AppKit

/// Owns exactly one GlassTerm window: the glass chrome, the clipped terminal, live config
/// application, frame persistence and multi-window spawning.
///
/// Layering (bottom to top):
///
///     contentView (plain NSView, wantsLayer, layer corner radius + masksToBounds)
///       ├─ GlassBackgroundView  — pinned to the content view bounds (vibrancy + tint)
///       └─ RoundedClipView      — pinned to the content view bounds (clips the terminal)
///            └─ TerminalView    — inset by innerPadding (+4 pt at the top for the traffic lights)
///
/// The content view's own layer performs the window-level rounding, so the glass can be a
/// sibling of the clip view and everything stays inside the rounded rect. A transparent,
/// non-opaque window is required or the four corners render black.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {

    private enum Metrics {
        static let defaultColumns = 100
        static let defaultRows = 30
        static let minimumWindowSize = NSSize(width: 420, height: 260)
        /// Extra top inset so the first line of text never sits under the traffic lights.
        static let trafficLightInset: CGFloat = 4
        /// Down-right offset (AppKit's y axis grows upward) for cascaded windows.
        static let cascadeOffset: CGFloat = 24
        /// The default window never exceeds the visible frame minus this margin.
        static let screenMargin: CGFloat = 80
        /// The terminal is never squeezed below this many points on either axis.
        static let minimumTerminalExtent: CGFloat = 100
        static let frameDefaultsKey = "GlassTerm.windowFrame"
    }

    private let configStore: ConfigStore
    private var appliedConfig: GlassConfig

    private var glassView: GlassBackgroundView?
    private var clipView: RoundedClipView?
    private var terminal: TerminalView!

    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?

    private var configObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    private var hasStartedShell = false
    private var didPlaceWindow = false
    private var isClosingWindow = false

    /// Independent windows opened through `newWindow()`; pruned when they close.
    private var childControllers: [TerminalWindowController] = []

    // MARK: - Surface

    /// The window's terminal; valid for the lifetime of this controller.
    var terminalView: TerminalView { terminal }

    // MARK: - Construction

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.appliedConfig = configStore.config
        super.init(window: nil)
        // We place windows ourselves (center on first launch, cascade for new windows).
        shouldCascadeWindows = false
        buildWindow()
        observeConfigChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("GlassTerm windows are built in code; init(coder:) is not supported")
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminal?.onTitleChange = nil
        terminal?.onBell = nil
        window?.delegate = nil
    }

    private func observeConfigChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .glassConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyConfig()
        }

        // Closed windows save their frame on `windowWillClose`; this catches Cmd-Q with
        // windows still open so the next launch restores the last position.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveWindowFrame()
        }
    }

    // MARK: - Window assembly

    private func buildWindow() {
        let config = appliedConfig

        // The terminal needs a font to measure itself, so build it before the window exists.
        let terminal = TerminalView(frame: .zero, config: config)
        let contentSize = Self.defaultContentSize(for: terminal)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "GlassTerm"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = Metrics.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .none

        self.window = window
        window.delegate = self

        // Plain root view: its layer is what rounds and masks the whole window.
        let contentRoot = NSView(frame: NSRect(origin: .zero, size: contentSize))
        contentRoot.wantsLayer = true
        contentRoot.autoresizingMask = [.width, .height]
        applyCornerRadius(to: contentRoot, radius: config.cornerRadius)
        window.contentView = contentRoot

        // 1. Glass, behind everything, full bounds.
        let glass = GlassBackgroundView(frame: contentRoot.bounds)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.apply(config)
        contentRoot.addSubview(glass)

        // 2. Clip container.
        let clip = RoundedClipView(frame: contentRoot.bounds, cornerRadius: CGFloat(config.cornerRadius))
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.apply(config)
        contentRoot.addSubview(clip)

        // 3. Terminal, inset by innerPadding (+ traffic-light inset at the top).
        terminal.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(terminal)

        let leading = terminal.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: CGFloat(config.innerPadding))
        let trailing = terminal.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -CGFloat(config.innerPadding))
        let top = terminal.topAnchor.constraint(equalTo: clip.topAnchor, constant: CGFloat(config.innerPadding) + Metrics.trafficLightInset)
        let bottom = terminal.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -CGFloat(config.innerPadding))

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            glass.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            glass.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),

            clip.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            clip.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            clip.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),

            leading, trailing, top, bottom,
        ])

        leadingConstraint = leading
        trailingConstraint = trailing
        topConstraint = top
        bottomConstraint = bottom

        self.glassView = glass
        self.clipView = clip
        self.terminal = terminal

        terminal.onTitleChange = { [weak self] title in
            self?.updateWindowTitle(from: title)
        }

        // With `.fullSizeContentView` the content view spans the entire frame, so driving the
        // frame directly gives the terminal exactly the measured content size (30 rows).
        window.setFrame(NSRect(origin: window.frame.origin, size: contentSize), display: false)

        updateTerminalInsets(for: config)
        contentRoot.layoutSubtreeIfNeeded()
    }

    // MARK: - Showing

    func showWindowAndStart() {
        guard let window else { return }
        applyInitialPlacementIfNeeded()

        glassView?.attach(toWindow: window)

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        if let terminal {
            window.makeFirstResponder(terminal)
        }

        if !hasStartedShell, let terminal {
            hasStartedShell = true
            terminal.start(shell: nil, workingDirectory: NSHomeDirectory())
        }

        terminal?.focusTerminal()
        terminal?.updatePTYSize()
    }

    private func applyInitialPlacementIfNeeded() {
        guard !didPlaceWindow, let window else { return }
        didPlaceWindow = true

        if restoreWindowFrame(into: window) {
            return
        }
        window.setFrame(Self.centeredFrame(for: window.frame), display: false)
    }

    // MARK: - Live configuration

    func applyConfig() {
        guard !isClosingWindow else { return }
        let config = configStore.config
        appliedConfig = config

        terminal?.apply(config)
        glassView?.apply(config)
        clipView?.apply(config)

        if let contentView = window?.contentView {
            applyCornerRadius(to: contentView, radius: config.cornerRadius)
        }

        updateTerminalInsets(for: config)
        window?.invalidateShadow()
        window?.contentView?.layoutSubtreeIfNeeded()
        // Never resize the window here: a settings change may only relayout the terminal.
        terminal?.updatePTYSize()
    }

    private func applyCornerRadius(to view: NSView, radius: Double) {
        guard let layer = view.layer else { return }
        let clamped = CGFloat(min(max(radius, 0), 40))
        layer.cornerRadius = clamped
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        view.needsLayout = true
    }

    /// Recomputes the four terminal insets, clamped so the terminal keeps a usable size even
    /// with `innerPadding == 48` inside a 420×260 window.
    private func updateTerminalInsets(for config: GlassConfig) {
        guard let host = clipView else { return }
        let bounds = host.bounds
        let padding = CGFloat(config.innerPadding)

        let widthLimit = max(0, (bounds.width - Metrics.minimumTerminalExtent) / 2)
        let heightLimit = max(0, (bounds.height - Metrics.minimumTerminalExtent - Metrics.trafficLightInset) / 2)
        let horizontal = min(max(padding, 0), widthLimit)
        let vertical = min(max(padding, 0), heightLimit)
        let top = min(max(padding + Metrics.trafficLightInset, Metrics.trafficLightInset),
                      heightLimit + Metrics.trafficLightInset)

        setConstant(leadingConstraint, horizontal)
        setConstant(trailingConstraint, -horizontal)
        setConstant(topConstraint, top)
        setConstant(bottomConstraint, -vertical)
    }

    private func setConstant(_ constraint: NSLayoutConstraint?, _ value: CGFloat) {
        guard let constraint, abs(constraint.constant - value) > 0.01 else { return }
        constraint.constant = value
    }

    // MARK: - Multi-window

    @discardableResult
    func newWindow() -> TerminalWindowController {
        pruneChildControllers()

        let child = TerminalWindowController(configStore: configStore)
        childControllers.append(child)
        child.showWindowAndStart()
        cascade(child)
        child.window?.makeKeyAndOrderFront(nil)
        return child
    }

    private func cascade(_ child: TerminalWindowController) {
        guard let window, let childWindow = child.window, childWindow !== window else { return }
        var frame = childWindow.frame
        frame.origin.x = window.frame.origin.x + Metrics.cascadeOffset
        frame.origin.y = window.frame.origin.y - Metrics.cascadeOffset
        childWindow.setFrame(Self.clampedToVisibleScreen(frame), display: true)
    }

    /// Closed child controllers are invisible to the user but still retained by this array;
    /// dropping them here releases their windows, views and PTYs.
    private func pruneChildControllers() {
        childControllers.removeAll { controller in
            controller.window == nil || controller.isClosingWindow
        }
    }

    // MARK: - Full screen

    func toggleFullScreenAction(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        // Rounded corners look wrong against a full-screen backdrop.
        if let contentView = window?.contentView, let layer = contentView.layer {
            layer.cornerRadius = 0
        }
        clipView?.cornerRadius = 0
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if let contentView = window?.contentView {
            applyCornerRadius(to: contentView, radius: appliedConfig.cornerRadius)
        }
        clipView?.apply(appliedConfig)
        updateTerminalInsets(for: appliedConfig)
    }

    // MARK: - Resize

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window, !isClosingWindow else { return }
        // No config store / settings access here: pure layout math on the applied config.
        updateTerminalInsets(for: appliedConfig)
        terminal?.updatePTYSize()
    }

    // MARK: - Close

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        guard !isClosingWindow else { return }
        isClosingWindow = true

        saveWindowFrame()

        // Stop callbacks before the view hierarchy goes away.
        terminal?.onTitleChange = nil
        terminal?.onBell = nil

        // Detaching the terminal tells it to terminate its PTY (`viewWillMove(toWindow:)`);
        // `deinit` would do the same, but closing should not wait for this controller to die.
        clipView?.removeFromSuperview()
        clipView = nil
        glassView = nil

        window?.delegate = nil

        // Let AppKit finish the close before dropping the window reference; AppDelegate prunes
        // controllers whose `window` became nil.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isClosingWindow else { return }
            self.window = nil
        }
    }

    // MARK: - Frame persistence

    private func saveWindowFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Metrics.frameDefaultsKey)
    }

    @discardableResult
    private func restoreWindowFrame(into window: NSWindow) -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: Metrics.frameDefaultsKey) else { return false }
        var frame = NSRectFromString(raw)
        guard frame.width >= 200, frame.height >= 150 else { return false }
        guard Self.frameIntersectsVisibleScreen(frame) else { return false }
        frame = Self.clampedToVisibleScreen(frame)
        window.setFrame(frame, display: false)
        return true
    }

    // MARK: - Title

    private func updateWindowTitle(from rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let window else { return }
        if title.isEmpty {
            window.title = "GlassTerm"
        } else if title.hasPrefix("GlassTerm") {
            window.title = title
        } else {
            // Cosmetic only: the titlebar itself is hidden.
            window.title = "GlassTerm — \(title)"
        }
    }

    // MARK: - Geometry helpers

    private static func defaultContentSize(for terminal: TerminalView) -> NSSize {
        let measured = terminal.contentSize(forCols: Metrics.defaultColumns, rows: Metrics.defaultRows)
        var size = NSSize(width: measured.width, height: measured.height + Metrics.trafficLightInset)

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            size.width = min(size.width, max(Metrics.minimumWindowSize.width, visible.width - Metrics.screenMargin))
            size.height = min(size.height, max(Metrics.minimumWindowSize.height, visible.height - Metrics.screenMargin))
        }

        size.width = max(size.width, Metrics.minimumWindowSize.width)
        size.height = max(size.height, Metrics.minimumWindowSize.height)
        return size
    }

    private static func centeredFrame(for frame: NSRect) -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return frame }
        let visible = screen.visibleFrame
        var centered = frame
        centered.origin.x = visible.midX - frame.width / 2
        centered.origin.y = visible.midY - frame.height / 2
        return clampedToVisibleScreen(centered)
    }

    private static func clampedToVisibleScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return frame }
        let visible = screen.visibleFrame
        var clamped = frame
        clamped.origin.x = min(max(clamped.origin.x, visible.minX), max(visible.minX, visible.maxX - clamped.width))
        clamped.origin.y = min(max(clamped.origin.y, visible.minY), max(visible.minY, visible.maxY - clamped.height))
        return clamped
    }

    private static func frameIntersectsVisibleScreen(_ frame: NSRect) -> Bool {
        for screen in NSScreen.screens {
            let intersection = screen.visibleFrame.intersection(frame)
            if !intersection.isNull, intersection.width > 80, intersection.height > 80 {
                return true
            }
        }
        return false
    }
}
