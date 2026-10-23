//
//  GlassChrome.swift
//  GlassTerm
//
//  Owner F — the translucent "liquid glass" chrome.
//
//  Layers (bottom → top), all created once in `init` so that slider-driven
//  `apply(_:)` calls never churn the view hierarchy:
//
//      NSVisualEffectView  (.behindWindow vibrancy, material from config)
//      tint overlay        (config tint colour at config opacity)
//      top sheen           (white 10 % → clear gradient, the "liquid" highlight)
//      hairline border     (white @ 8 %, 1 px, follows the corner radius)
//
//  Window blur radius is driven through the private CoreGraphics Services
//  symbols, resolved at runtime with `dlsym` — nothing is linked, nothing is
//  polled, and a machine without those symbols simply keeps the material's
//  built-in blur.
//
//  `RoundedClipView` is the clipping container the window controller wraps
//  around the glass/terminal stack.
//

import AppKit
import CoreImage
import Darwin

// MARK: - Runtime-resolved CoreGraphics Services blur

// Signatures of the private symbols. Never link these; they live in
// CoreGraphics' SkyLight/CGS private surface and are resolved lazily.
typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
typealias CGSSetBlurFn = @convention(c) (Int32, Int32, Int32) -> Int32

/// Bridges to the private window-server blur API.
///
/// Resolution happens exactly once (lazy static). Every failure mode degrades
/// to the `NSVisualEffectView` material: missing symbols, a null connection,
/// or a non-zero status. Only the first failure is logged — never per frame.
enum GlassBlurBridge {

    /// `RTLD_DEFAULT` on Darwin is `(void *)-2`.
    private static let rtldDefault: UnsafeMutableRawPointer? =
        UnsafeMutableRawPointer(bitPattern: -2)

    private static let mainConnectionID: CGSMainConnectionIDFn? = {
        guard let handle = rtldDefault,
              let symbol = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: CGSMainConnectionIDFn.self)
    }()

    private static let setWindowBackgroundBlurRadius: CGSSetBlurFn? = {
        guard let handle = rtldDefault,
              let symbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return unsafeBitCast(symbol, to: CGSSetBlurFn.self)
    }()

    /// Diagnostics only: which of the two private symbols resolved on this
    /// machine. Used by smoke tests; never consulted by the render path.
    static var symbolAvailability: (mainConnectionID: Bool, blurRadius: Bool) {
        return (mainConnectionID != nil, setWindowBackgroundBlurRadius != nil)
    }

    private static var didLogFailure = false

    private static func logFailureOnce(_ reason: String) {
        guard !didLogFailure else { return }
        didLogFailure = true
        NSLog("GlassTerm: window blur unavailable, using material blur (%@)", reason)
    }

    /// Sets the background blur radius (in points) for a window number.
    ///
    /// - Returns: `true` when the window server accepted the value.
    @discardableResult
    static func setBlurRadius(_ radius: Double, forWindowNumber windowNumber: Int) -> Bool {
        // Windows that are not on screen (or not yet ordered in) have no
        // number; there is nothing sensible to do and nothing to report.
        guard windowNumber > 0 else { return false }

        guard let connect = mainConnectionID else {
            logFailureOnce("CGSMainConnectionID not found")
            return false
        }
        guard let setBlur = setWindowBackgroundBlurRadius else {
            logFailureOnce("CGSSetWindowBackgroundBlurRadius not found")
            return false
        }
        guard let connection = Int32(exactly: connect()) , connection != 0 else {
            logFailureOnce("CGSMainConnectionID returned no connection")
            return false
        }

        let pixels = Int32(min(max(radius.rounded(), 0), 1000))
        let status = setBlur(connection, Int32(truncatingIfNeeded: windowNumber), pixels)
        guard status == 0 else {
            logFailureOnce("CGSSetWindowBackgroundBlurRadius returned \(status)")
            return false
        }
        return true
    }
}

// MARK: - GlassBackgroundView

/// The vibrancy + tint + sheen stack that sits behind the terminal.
///
/// The whole view is click-through (`hitTest` returns `nil`) and never opaque,
/// so the terminal — a sibling further up the hierarchy — keeps every mouse
/// event and the desktop shows through the vibrancy.
final class GlassBackgroundView: NSView {

    // MARK: Surface

    /// Index of the vibrancy material that was last applied. Read-only; the
    /// smoke tests use it to prove config tracking.
    private(set) var materialIndex: Int = 0

    // MARK: Chrome views (built once, never rebuilt)

    private let visualEffectView = NSVisualEffectView()
    private let tintView = NSView()
    private let sheenView = GlassSheenView()
    private let borderView = NSView()

    // MARK: State

    private var pendingConfig: GlassConfig?
    private var lastBlurRadius: Double?
    private var appliedSaturation: Double?
    private var appliedTintHex: String?
    private var appliedTintOpacity: Double?
    private var appliedCornerRadius: CGFloat = .nan

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpChrome()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpChrome()
    }

    /// Never opaque: the vibrancy and the desktop behind it must show through.
    override var isOpaque: Bool { false }

    private func setUpChrome() {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        autoresizesSubviews = true
        configureRootLayer()

        // Bottom: window-background vibrancy.
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.isEmphasized = true
        if let material = Self.material(at: 0) {
            visualEffectView.material = material
        }
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.frame = bounds
        addSubview(visualEffectView)

        // Middle: colour wash at config opacity.
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.clear.cgColor
        tintView.autoresizingMask = [.width, .height]
        tintView.frame = bounds
        addSubview(tintView)

        // Top: one-pixel glass edge plus a soft top sheen.
        borderView.wantsLayer = true
        borderView.layer?.borderWidth = 1
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        borderView.layer?.cornerCurve = .continuous
        borderView.layer?.cornerRadius = 0
        borderView.autoresizingMask = [.width, .height]
        borderView.frame = bounds

        sheenView.wantsLayer = true
        sheenView.autoresizingMask = [.width, .height]
        sheenView.frame = bounds
        addSubview(sheenView)

        // Border above the sheen so the hairline stays crisp.
        addSubview(borderView)
    }

    // MARK: NSView

    /// Fully click-through: the terminal below/above keeps all mouse input.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        attach(toWindow: window)
    }

    // MARK: Config

    /// Applies `config` idempotently. Safe before the view is in a window and
    /// safe at slider-drag rates: no subviews are added or removed here.
    func apply(_ config: GlassConfig) {
        pendingConfig = config
        lastBlurRadius = config.blurRadius

        applyMaterial(config.materialIndex)
        applyTint(hex: config.tintHex, opacity: config.backgroundOpacity)
        applyCornerRadius(CGFloat(config.cornerRadius))
        applySaturation(config.saturation)
        applyBlurRadiusIfPossible()
    }

    /// Called when the view moves to (or between) windows, and by the window
    /// controller when it installs the chrome.
    func attach(toWindow window: NSWindow?) {
        guard let window = window, let radius = lastBlurRadius else { return }
        GlassBlurBridge.setBlurRadius(radius, forWindowNumber: window.windowNumber)
    }

    // MARK: Internals

    private static func clampedMaterialIndex(_ raw: Int) -> Int {
        let count = GlassConfig.materialValues.count
        guard count > 0 else { return 0 }
        return min(max(raw, 0), count - 1)
    }

    private static func material(at index: Int) -> NSVisualEffectView.Material? {
        let materials = GlassConfig.materialValues
        guard !materials.isEmpty else { return nil }
        return materials[clampedMaterialIndex(index)]
    }

    private func configureRootLayer() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor
        root.isOpaque = false
        root.masksToBounds = true
        root.cornerCurve = .continuous
        if !appliedCornerRadius.isNaN {
            root.cornerRadius = appliedCornerRadius
        }
    }

    private func applyMaterial(_ rawIndex: Int) {
        let index = Self.clampedMaterialIndex(rawIndex)
        materialIndex = index
        guard let material = Self.material(at: index) else { return }
        if visualEffectView.material != material {
            visualEffectView.material = material
        }
    }

    private func applyTint(hex: String, opacity: Double) {
        guard appliedTintHex != hex || appliedTintOpacity != opacity else { return }
        appliedTintHex = hex
        appliedTintOpacity = opacity

        let alpha = CGFloat(min(max(opacity, 0), 1))
        let base = NSColor(hex: hex) ?? NSColor.clear
        tintView.layer?.backgroundColor = base.withAlphaComponent(alpha).cgColor
    }

    private func applyCornerRadius(_ radius: CGFloat) {
        let clamped = max(0, radius)
        guard appliedCornerRadius != clamped else { return }
        appliedCornerRadius = clamped
        configureRootLayer()
        borderView.layer?.cornerRadius = clamped
    }

    private func applySaturation(_ saturation: Double) {
        let value = max(0, saturation)
        // Idempotent: never stack CIColorControls on the layer, and never
        // rebuild the filter for an unchanged value (slider drag at 60 Hz).
        guard appliedSaturation != value else { return }
        guard let layer = self.layer else { return }
        guard let filter = CIFilter(name: "CIColorControls") else { return }

        filter.setValue(value, forKey: kCIInputSaturationKey)
        layer.filters = [filter]
        appliedSaturation = value
    }

    private func applyBlurRadiusIfPossible() {
        guard let window = self.window, let radius = lastBlurRadius else { return }
        GlassBlurBridge.setBlurRadius(radius, forWindowNumber: window.windowNumber)
    }
}

// MARK: - Sheen

/// Backing layer is a vertical gradient: white at the top edge fading out.
/// Owns no state — the layer follows the view's bounds automatically.
private final class GlassSheenView: NSView {

    override var isOpaque: Bool { false }

    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        gradient.locations = [0.0, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.55)
        return gradient
    }
}

// MARK: - RoundedClipView

/// Clips its subtree (glass + terminal) to `config.cornerRadius`.
/// Draws nothing itself; it exists only for the layer mask.
final class RoundedClipView: NSView {

    var cornerRadius: CGFloat {
        didSet { updateLayerChrome() }
    }

    init(frame frameRect: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = max(0, cornerRadius)
        super.init(frame: frameRect)
        setUpChrome()
    }

    required init?(coder: NSCoder) {
        self.cornerRadius = 0
        super.init(coder: coder)
        setUpChrome()
    }

    /// Transparent by definition — only the layer mask does any work.
    override var isOpaque: Bool { false }

    private func setUpChrome() {
        wantsLayer = true
        autoresizesSubviews = true
        updateLayerChrome()
    }

    private func updateLayerChrome() {
        guard let layer = self.layer else { return }
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = max(0, cornerRadius)
        layer.backgroundColor = nil
        layer.isOpaque = false
    }

    /// Nothing is painted here; the rounded mask is the entire job.
    override func draw(_ dirtyRect: NSRect) {}

    func apply(_ config: GlassConfig) {
        let radius = max(0, CGFloat(config.cornerRadius))
        if cornerRadius != radius {
            cornerRadius = radius
        } else {
            // Re-assert the mask in case the backing layer was recreated.
            updateLayerChrome()
        }
    }
}
