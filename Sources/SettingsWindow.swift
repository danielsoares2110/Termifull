import AppKit

// MARK: - Flipped document view for the settings scroll area

/// A plain flipped container so the stack view starts at the top of the scroll view.
private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - SettingsWindowController

/// Owner H. A native AppKit Settings window whose controls are bound directly to
/// `ConfigStore.shared` so every edit previews live in the terminal window.
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    // MARK: Controls

    private let opacitySlider = NSSlider(value: 0.55, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let blurSlider = NSSlider(value: 42, minValue: 0, maxValue: 120, target: nil, action: nil)
    private let saturationSlider = NSSlider(value: 1.35, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let tintWell = NSColorWell(frame: .zero)
    private let textWell = NSColorWell(frame: .zero)
    private let materialPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontSizeSlider = NSSlider(value: 13, minValue: 9, maxValue: 48, target: nil, action: nil)
    private let fontSizeStepper = NSStepper(frame: .zero)
    private let lineSpacingSlider = NSSlider(value: 1.15, minValue: 0.8, maxValue: 2.2, target: nil, action: nil)
    private let cursorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cursorBlinkSwitch = NSSwitch(frame: .zero)
    private let cornerRadiusSlider = NSSlider(value: 14, minValue: 0, maxValue: 40, target: nil, action: nil)
    private let innerPaddingSlider = NSSlider(value: 12, minValue: 0, maxValue: 48, target: nil, action: nil)

    private let opacityValue = SettingsWindowController.makeValueLabel()
    private let blurValue = SettingsWindowController.makeValueLabel()
    private let saturationValue = SettingsWindowController.makeValueLabel()
    private let fontSizeValue = SettingsWindowController.makeValueLabel()
    private let lineSpacingValue = SettingsWindowController.makeValueLabel()
    private let cornerRadiusValue = SettingsWindowController.makeValueLabel()
    private let innerPaddingValue = SettingsWindowController.makeValueLabel()

    // MARK: State

    private var fontFamilies: [String] = []
    private var isSyncing = false
    private var isApplyingLocalChange = false
    private var hasCentered = false
    private var configObserver: NSObjectProtocol?

    // MARK: Layout constants

    private enum Metrics {
        static let contentWidth: CGFloat = 560
        static let contentHeight: CGFloat = 640
        static let inset: CGFloat = 20
        static let labelWidth: CGFloat = 170
        static let valueWidth: CGFloat = 64
        static let controlMinWidth: CGFloat = 240
        static let rowSpacing: CGFloat = 8
        static let sectionSpacing: CGFloat = 10
        static let footerHeight: CGFloat = 32
        static let separatorWidth: CGFloat = 500
    }

    // MARK: Init

    private init() {
        let rect = NSRect(x: 0, y: 0,
                          width: Metrics.contentWidth,
                          height: Metrics.contentHeight)
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        super.init(window: window)
        configureWindow(window)
        buildInterface()
        observeConfigChanges()
        refreshFromConfig()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let configObserver = configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    // MARK: Public API

    /// Brings the one settings window forward (never creates a second one).
    func show() {
        refreshFromConfig()

        if !hasCentered {
            window?.center()
            hasCentered = true
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(opacitySlider)
    }

    /// Re-reads every control from the shared store. Safe to call at any time.
    func refreshFromConfig() {
        let config = ConfigStore.shared.config
        isSyncing = true
        defer { isSyncing = false }

        opacitySlider.doubleValue = Self.clamp(config.backgroundOpacity, 0, 1)
        blurSlider.doubleValue = Self.clamp(config.blurRadius, 0, 120)
        saturationSlider.doubleValue = Self.clamp(config.saturation, 0, 3)
        lineSpacingSlider.doubleValue = Self.clamp(config.lineSpacing, 0.8, 2.2)
        cornerRadiusSlider.doubleValue = Self.clamp(config.cornerRadius, 0, 40)
        innerPaddingSlider.doubleValue = Self.clamp(config.innerPadding, 0, 48)

        let size = Self.clamp(config.fontSize, 9, 48)
        fontSizeSlider.doubleValue = size
        fontSizeStepper.doubleValue = size

        tintWell.color = NSColor(hex: config.tintHex) ?? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.18, alpha: 1)
        textWell.color = NSColor(hex: config.textHex) ?? NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)

        if GlassConfig.materialNames.isEmpty {
            materialPopup.selectItem(at: -1)
        } else {
            let index = min(max(config.materialIndex, 0), GlassConfig.materialNames.count - 1)
            materialPopup.selectItem(at: index)
        }

        if fontFamilies.isEmpty {
            fontFamilies = Self.orderedFontFamilies(current: config.fontFamily)
            fontPopup.removeAllItems()
            fontPopup.addItems(withTitles: fontFamilies)
        }
        if let fontIndex = fontFamilies.firstIndex(of: config.fontFamily) {
            fontPopup.selectItem(at: fontIndex)
        } else if !fontFamilies.isEmpty {
            fontPopup.selectItem(at: 0)
        }

        let cursorNames = GlassConfig.cursorStyleNames
        if cursorNames.isEmpty {
            cursorPopup.selectItem(at: -1)
        } else {
            let index = min(max(config.cursorStyleIndex, 0), cursorNames.count - 1)
            cursorPopup.selectItem(at: index)
        }

        cursorBlinkSwitch.state = config.cursorBlink ? .on : .off
        updateValueLabels()
        window?.recalculateKeyViewLoop()
    }

    // MARK: Window / interface construction

    private func configureWindow(_ window: NSWindow) {
        window.title = "GlassTerm Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Metrics.contentWidth, height: 620)
        window.tabbingMode = .disallowed
        window.initialFirstResponder = opacitySlider
    }

    private func buildInterface() {
        guard let window = window else { return }

        let content = NSView(frame: NSRect(x: 0, y: 0,
                                           width: Metrics.contentWidth,
                                           height: Metrics.contentHeight))
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        // Scroll view + flipped document view so short windows still scroll.
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let documentView = SettingsFlippedView(frame: .zero)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.sectionSpacing
        stack.distribution = .fill
        documentView.addSubview(stack)

        // Footer with the reset button (stays outside the scroll area).
        let resetButton = NSButton(title: "Reset to Defaults",
                                   target: self,
                                   action: #selector(resetToDefaults(_:)))
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        resetButton.keyEquivalent = ""

        content.addSubview(scrollView)
        content.addSubview(resetButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.inset),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.inset),
            scrollView.bottomAnchor.constraint(equalTo: resetButton.topAnchor, constant: -8),

            resetButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.inset),
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            resetButton.heightAnchor.constraint(equalToConstant: Metrics.footerHeight),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        // Controls
        configureSlider(opacitySlider, action: #selector(opacityChanged(_:)))
        configureSlider(blurSlider, action: #selector(blurChanged(_:)))
        configureSlider(saturationSlider, action: #selector(saturationChanged(_:)))
        configureSlider(fontSizeSlider, action: #selector(fontSizeSliderChanged(_:)))
        configureSlider(lineSpacingSlider, action: #selector(lineSpacingChanged(_:)))
        configureSlider(cornerRadiusSlider, action: #selector(cornerRadiusChanged(_:)))
        configureSlider(innerPaddingSlider, action: #selector(innerPaddingChanged(_:)))

        fontSizeStepper.minValue = 9
        fontSizeStepper.maxValue = 48
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.autorepeat = true
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepperChanged(_:))

        materialPopup.addItems(withTitles: GlassConfig.materialNames)
        materialPopup.target = self
        materialPopup.action = #selector(materialChanged(_:))

        fontFamilies = Self.orderedFontFamilies(current: ConfigStore.shared.config.fontFamily)
        fontPopup.removeAllItems()
        fontPopup.addItems(withTitles: fontFamilies)
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))

        cursorPopup.addItems(withTitles: GlassConfig.cursorStyleNames)
        cursorPopup.target = self
        cursorPopup.action = #selector(cursorStyleChanged(_:))

        cursorBlinkSwitch.target = self
        cursorBlinkSwitch.action = #selector(cursorBlinkChanged(_:))

        configureColorWell(tintWell, action: #selector(tintColorChanged(_:)))
        configureColorWell(textWell, action: #selector(textColorChanged(_:)))

        // Glass
        addSection(to: stack, title: "Glass", isFirst: true, rows: [
            makeRow(title: "Background opacity", control: opacitySlider, value: opacityValue),
            makeRow(title: "Blur radius", control: blurSlider, value: blurValue),
            makeRow(title: "Saturation", control: saturationSlider, value: saturationValue),
            makeRow(title: "Tint colour", control: tintWell, value: nil),
            makeRow(title: "Text colour", control: textWell, value: nil),
            makeRow(title: "Vibrancy material", control: materialPopup, value: nil)
        ])

        // Typography
        addSection(to: stack, title: "Typography", isFirst: false, rows: [
            makeRow(title: "Font family", control: fontPopup, value: nil),
            makeRow(title: "Font size", control: makeFontSizeRow(), value: fontSizeValue),
            makeRow(title: "Line spacing", control: lineSpacingSlider, value: lineSpacingValue)
        ])

        // Cursor
        addSection(to: stack, title: "Cursor", isFirst: false, rows: [
            makeRow(title: "Cursor style", control: cursorPopup, value: nil),
            makeRow(title: "Cursor blink", control: cursorBlinkSwitch, value: nil)
        ])

        // Window
        addSection(to: stack, title: "Window", isFirst: false, rows: [
            makeRow(title: "Corner radius", control: cornerRadiusSlider, value: cornerRadiusValue),
            makeRow(title: "Inner padding", control: innerPaddingSlider, value: innerPaddingValue)
        ])

        window.recalculateKeyViewLoop()
    }

    /// Font size gets a slider + stepper side by side inside the control column.
    private func makeFontSizeRow() -> NSView {
        let holder = NSStackView(views: [fontSizeSlider, fontSizeStepper])
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.orientation = .horizontal
        holder.alignment = .centerY
        holder.spacing = 6
        holder.setHuggingPriority(.defaultLow, for: .horizontal)
        return holder
    }

    private func configureSlider(_ slider: NSSlider, action: Selector) {
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureColorWell(_ well: NSColorWell, action: Selector) {
        well.translatesAutoresizingMaskIntoConstraints = false
        well.target = self
        well.action = action
        well.isContinuous = true
        if #available(macOS 14.0, *) {
            well.supportsAlpha = false
        }
        if #available(macOS 13.0, *) {
            well.colorWellStyle = .minimal
        }
    }

    private func addSection(to stack: NSStackView, title: String, isFirst: Bool, rows: [NSView]) {
        if !isFirst {
            stack.addArrangedSubview(makeSeparator())
            stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        }

        let header = NSTextField(labelWithString: title)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.font = NSFont.boldSystemFont(ofSize: 12)
        header.textColor = .labelColor
        stack.addArrangedSubview(header)

        for row in rows {
            stack.addArrangedSubview(row)
        }
        stack.setCustomSpacing(14, after: rows.last ?? header)
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: Metrics.separatorWidth).isActive = true
        return separator
    }

    private func makeRow(title: String,
                         control: NSView,
                         value: NSTextField?) -> NSStackView {
        let label = SettingsWindowController.makeTitleLabel(title)
        let valueLabel = value ?? SettingsWindowController.makeValueLabel()

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.controlMinWidth).isActive = true

        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.rowSpacing
        row.distribution = .fill

        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        row.addArrangedSubview(valueLabel)

        label.widthAnchor.constraint(equalToConstant: Metrics.labelWidth).isActive = true
        valueLabel.widthAnchor.constraint(equalToConstant: Metrics.valueWidth).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return row
    }

    private static func makeTitleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: Observation

    private func observeConfigChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .glassConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Our own edits are already reflected locally; re-reading them mid-drag
            // would fight the control that is being dragged.
            guard !self.isApplyingLocalChange else { return }
            self.refreshFromConfig()
        }
    }

    // MARK: Actions (live, every one writes through ConfigStore.set)

    @objc private func opacityChanged(_ sender: NSSlider) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue, 0, 1)
        store { $0.backgroundOpacity = value }
        updateValueLabels()
    }

    @objc private func blurChanged(_ sender: NSSlider) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue, 0, 120)
        store { $0.blurRadius = value }
        updateValueLabels()
    }

    @objc private func saturationChanged(_ sender: NSSlider) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue, 0, 3)
        store { $0.saturation = value }
        updateValueLabels()
    }

    @objc private func tintColorChanged(_ sender: NSColorWell) {
        guard !isSyncing else { return }
        let color = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let hex = color.hexString
        store { $0.tintHex = hex }
    }

    @objc private func textColorChanged(_ sender: NSColorWell) {
        guard !isSyncing else { return }
        let color = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let hex = color.hexString
        store { $0.textHex = hex }
    }

    @objc private func materialChanged(_ sender: NSPopUpButton) {
        guard !isSyncing else { return }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < GlassConfig.materialNames.count else { return }
        store { $0.materialIndex = index }
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        guard !isSyncing else { return }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < fontFamilies.count else { return }
        let family = fontFamilies[index]
        store { $0.fontFamily = family }
    }

    @objc private func fontSizeSliderChanged(_ sender: NSSlider) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue.rounded(), 9, 48)
        sender.doubleValue = value
        store { $0.fontSize = value }
        isSyncing = true
        fontSizeStepper.doubleValue = value
        isSyncing = false
        updateValueLabels()
    }

    @objc private func fontSizeStepperChanged(_ sender: NSStepper) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue.rounded(), 9, 48)
        sender.doubleValue = value
        store { $0.fontSize = value }
        isSyncing = true
        fontSizeSlider.doubleValue = value
        isSyncing = false
        updateValueLabels()
    }

    @objc private func lineSpacingChanged(_ sender: NSSlider) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue, 0.8, 2.2)
        store { $0.lineSpacing = value }
        updateValueLabels()
    }

    @objc private func cursorStyleChanged(_ sender: NSPopUpButton) {
        guard !isSyncing else { return }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < GlassConfig.cursorStyleNames.count else { return }
        store { $0.cursorStyleIndex = index }
    }

    @objc private func cursorBlinkChanged(_ sender: NSSwitch) {
        guard !isSyncing else { return }
        let enabled = sender.state == .on
        store { $0.cursorBlink = enabled }
    }

    @objc private func cornerRadiusChanged(_ sender: NSSlider) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue, 0, 40)
        store { $0.cornerRadius = value }
        updateValueLabels()
    }

    @objc private func innerPaddingChanged(_ sender: NSSlider) {
        guard !isSyncing else { return }
        let value = Self.clamp(sender.doubleValue, 0, 48)
        store { $0.innerPadding = value }
        updateValueLabels()
    }

    @objc private func resetToDefaults(_ sender: NSButton) {
        ConfigStore.shared.resetToDefaults()
        refreshFromConfig()
    }

    // MARK: Helpers

    /// All mutations go through the store; the store clamps, saves and notifies.
    private func store(_ mutate: @escaping (inout GlassConfig) -> Void) {
        isApplyingLocalChange = true
        ConfigStore.shared.set(mutate)
        isApplyingLocalChange = false
    }

    private func updateValueLabels() {
        let config = ConfigStore.shared.config
        opacityValue.stringValue = String(format: "%.0f %%", Self.clamp(config.backgroundOpacity, 0, 1) * 100)
        blurValue.stringValue = String(format: "%.0f pt", Self.clamp(config.blurRadius, 0, 120))
        saturationValue.stringValue = String(format: "%.2f×", Self.clamp(config.saturation, 0, 3))
        fontSizeValue.stringValue = String(format: "%.0f pt", Self.clamp(config.fontSize, 9, 48))
        lineSpacingValue.stringValue = String(format: "%.2f×", Self.clamp(config.lineSpacing, 0.8, 2.2))
        cornerRadiusValue.stringValue = String(format: "%.0f pt", Self.clamp(config.cornerRadius, 0, 40))
        innerPaddingValue.stringValue = String(format: "%.0f pt", Self.clamp(config.innerPadding, 0, 48))
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        return min(max(value, lower), upper)
    }

    /// Monospaced families first (in the listed order), then everything else A–Z.
    private static func orderedFontFamilies(current: String) -> [String] {
        let available = NSFontManager.shared.availableFontFamilies
        let preferred = ["Menlo", "SF Mono", "SFMono-Regular", "Monaco", "Courier New",
                         "Andale Mono", "PT Mono", "JetBrains Mono", "Fira Code", "Hack"]
        var seen = Set<String>()
        var ordered: [String] = []

        for family in preferred where available.contains(family) {
            if seen.insert(family).inserted {
                ordered.append(family)
            }
        }

        let rest = available
            .filter { !seen.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        ordered.append(contentsOf: rest)

        // Never let a stored family vanish from the popup.
        if !ordered.contains(current) {
            ordered.insert(current, at: 0)
        }
        return ordered
    }
}
