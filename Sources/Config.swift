import AppKit

// MARK: - GlassConfig

/// The single source of truth for every user-tunable appearance value.
///
/// Decoding is deliberately lenient: every key is read with `decodeIfPresent`
/// (and any type mismatch is swallowed) so a partial, older, or hand-edited
/// JSON file yields defaults for the missing keys instead of throwing.
struct GlassConfig: Codable, Equatable {

    // MARK: Fields

    var blurRadius: Double          // 0...120, default 42
    var backgroundOpacity: Double   // 0...1,   default 0.55 (glass tint alpha)
    var tintHex: String             // default "#1B1B2F"
    var textHex: String             // default "#F2F2F7"
    var saturation: Double          // 0...3,   default 1.35
    var materialIndex: Int          // 0...5 index into GlassConfig.materialNames
    var fontFamily: String          // default "Menlo"
    var fontSize: Double            // 9...48,  default 13
    var lineSpacing: Double         // 0.8...2.2 line-height multiplier, default 1.15
    var cursorStyleIndex: Int       // 0 block, 1 beam, 2 underline
    var cursorBlink: Bool           // default true
    var cornerRadius: Double        // 0...40,  default 14
    var innerPadding: Double        // 0...48,  default 12

    // MARK: Defaults / ranges (private: implementation detail, not part of the contract)

    private static let defaultBlurRadius: Double = 42
    private static let defaultBackgroundOpacity: Double = 0.55
    private static let defaultTintHex = "#1B1B2F"
    private static let defaultTextHex = "#F2F2F7"
    private static let defaultSaturation: Double = 1.35
    private static let defaultMaterialIndex = 0
    private static let defaultFontFamily = "Menlo"
    private static let defaultFontSize: Double = 13
    private static let defaultLineSpacing: Double = 1.15
    private static let defaultCursorStyleIndex = 0
    private static let defaultCursorBlink = true
    private static let defaultCornerRadius: Double = 14
    private static let defaultInnerPadding: Double = 12

    static let materialNames: [String] = [
        "Under Window", "HUD Window", "Sidebar", "Menu", "Popover", "Full Screen",
    ]

    static let materialValues: [NSVisualEffectView.Material] = [
        .underWindowBackground, .hudWindow, .sidebar, .menu, .popover, .fullScreenUI,
    ]

    static let cursorStyleNames: [String] = ["Block", "Beam", "Underline"]

    // MARK: Init

    /// Memberwise initialiser with defaults on every parameter, so that
    /// `GlassConfig()` is a fully valid value.
    init(blurRadius: Double = defaultBlurRadius,
         backgroundOpacity: Double = defaultBackgroundOpacity,
         tintHex: String = defaultTintHex,
         textHex: String = defaultTextHex,
         saturation: Double = defaultSaturation,
         materialIndex: Int = defaultMaterialIndex,
         fontFamily: String = defaultFontFamily,
         fontSize: Double = defaultFontSize,
         lineSpacing: Double = defaultLineSpacing,
         cursorStyleIndex: Int = defaultCursorStyleIndex,
         cursorBlink: Bool = defaultCursorBlink,
         cornerRadius: Double = defaultCornerRadius,
         innerPadding: Double = defaultInnerPadding) {
        self.blurRadius = blurRadius
        self.backgroundOpacity = backgroundOpacity
        self.tintHex = tintHex
        self.textHex = textHex
        self.saturation = saturation
        self.materialIndex = materialIndex
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.cursorStyleIndex = cursorStyleIndex
        self.cursorBlink = cursorBlink
        self.cornerRadius = cornerRadius
        self.innerPadding = innerPadding
    }

    // MARK: Codable (resilient decoding, synthesized encoding)

    private enum CodingKeys: String, CodingKey {
        case blurRadius, backgroundOpacity, tintHex, textHex, saturation, materialIndex
        case fontFamily, fontSize, lineSpacing, cursorStyleIndex, cursorBlink
        case cornerRadius, innerPadding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            blurRadius: Self.lenient(c, .blurRadius, Self.defaultBlurRadius),
            backgroundOpacity: Self.lenient(c, .backgroundOpacity, Self.defaultBackgroundOpacity),
            tintHex: Self.lenient(c, .tintHex, Self.defaultTintHex),
            textHex: Self.lenient(c, .textHex, Self.defaultTextHex),
            saturation: Self.lenient(c, .saturation, Self.defaultSaturation),
            materialIndex: Self.lenient(c, .materialIndex, Self.defaultMaterialIndex),
            fontFamily: Self.lenient(c, .fontFamily, Self.defaultFontFamily),
            fontSize: Self.lenient(c, .fontSize, Self.defaultFontSize),
            lineSpacing: Self.lenient(c, .lineSpacing, Self.defaultLineSpacing),
            cursorStyleIndex: Self.lenient(c, .cursorStyleIndex, Self.defaultCursorStyleIndex),
            cursorBlink: Self.lenient(c, .cursorBlink, Self.defaultCursorBlink),
            cornerRadius: Self.lenient(c, .cornerRadius, Self.defaultCornerRadius),
            innerPadding: Self.lenient(c, .innerPadding, Self.defaultInnerPadding)
        )
    }

    /// Reads `key`, falling back to `fallback` when it is absent, null, of the
    /// wrong type, or otherwise undecodable. Never throws.
    private static func lenient<T: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>,
                                              _ key: CodingKeys,
                                              _ fallback: T) -> T {
        if let value = try? container.decodeIfPresent(T.self, forKey: key) {
            return value
        }
        return fallback
    }

    // MARK: Clamping

    /// Returns a copy with every numeric field clamped into its documented range
    /// and every colour normalised to `#RRGGBB` (invalid colours revert to defaults).
    func clamped() -> GlassConfig {
        var out = self
        out.blurRadius = GlassConfig.clamp(blurRadius, 0, 120, Self.defaultBlurRadius)
        out.backgroundOpacity = GlassConfig.clamp(backgroundOpacity, 0, 1, Self.defaultBackgroundOpacity)
        out.saturation = GlassConfig.clamp(saturation, 0, 3, Self.defaultSaturation)
        out.materialIndex = GlassConfig.clampIndex(materialIndex, count: GlassConfig.materialNames.count,
                                                   fallback: Self.defaultMaterialIndex)
        out.fontSize = GlassConfig.clamp(fontSize, 9, 48, Self.defaultFontSize)
        out.lineSpacing = GlassConfig.clamp(lineSpacing, 0.8, 2.2, Self.defaultLineSpacing)
        out.cursorStyleIndex = GlassConfig.clampIndex(cursorStyleIndex,
                                                      count: GlassConfig.cursorStyleNames.count,
                                                      fallback: Self.defaultCursorStyleIndex)
        out.cornerRadius = GlassConfig.clamp(cornerRadius, 0, 40, Self.defaultCornerRadius)
        out.innerPadding = GlassConfig.clamp(innerPadding, 0, 48, Self.defaultInnerPadding)

        let family = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        out.fontFamily = family.isEmpty ? Self.defaultFontFamily : family

        out.tintHex = GlassConfig.normalisedHex(tintHex) ?? Self.defaultTintHex
        out.textHex = GlassConfig.normalisedHex(textHex) ?? Self.defaultTextHex
        return out
    }

    /// NaN / infinity are not clampable, so they fall back to the default.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double,
                              _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }

    private static func clampIndex(_ value: Int, count: Int, fallback: Int) -> Int {
        guard count > 0 else { return 0 }
        return Swift.min(Swift.max(value, 0), count - 1)
    }

    private static func normalisedHex(_ raw: String) -> String? {
        guard let color = NSColor(hex: raw) else { return nil }
        return color.hexString
    }
}

// MARK: - Notification

extension Notification.Name {
    static let glassConfigDidChange = Notification.Name("GlassTermConfigDidChange")
}

// MARK: - ConfigStore

/// Loads, clamps, persists and broadcasts `GlassConfig`.
/// Safe to touch before `NSApplication` is running: nothing here references `NSApp`.
final class ConfigStore {

    static let shared = ConfigStore()

    /// Guards `_config`. Never held across file I/O.
    private let lock = NSLock()
    private var _config: GlassConfig

    init(config: GlassConfig = GlassConfig()) {
        _config = config.clamped()
    }

    /// `~/.config/glassterm/config.json`
    var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("glassterm", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// Read-only outside this type; mutate through `set(_:)` so clamping and
    /// persistence always happen.
    var config: GlassConfig {
        lock.lock()
        defer { lock.unlock() }
        return _config
    }

    // MARK: Mutation

    /// copy → mutate → clamp → persist → notify (main queue, object: self)
    func set(_ mutate: (inout GlassConfig) -> Void) {
        lock.lock()
        var copy = _config
        lock.unlock()

        mutate(&copy)

        let clamped = copy.clamped()
        lock.lock()
        _config = clamped
        lock.unlock()

        save()
        postDidChange()
    }

    func resetToDefaults() {
        set { $0 = GlassConfig() }
    }

    // MARK: Persistence

    /// Atomic, pretty-printed, key-sorted write. Never throws to the caller.
    func save() {
        lock.lock()
        let snapshot = _config          // snapshot: a concurrent `set` cannot half-write
        lock.unlock()

        let fm = FileManager.default
        let url = fileURL
        let directory = url.deletingLastPathComponent()

        do {
            try fm.createDirectory(at: directory,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory only applies attributes when it creates; enforce anyway.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("GlassTerm: failed to save config to %@: %@",
                  url.path, String(describing: error))
        }
    }

    /// Reloads from disk; missing file, unreadable file, or corrupt JSON all fall
    /// back to defaults. The file on disk is never modified here.
    func reload() {
        let fm = FileManager.default
        let url = fileURL
        var loaded = GlassConfig()

        if fm.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                loaded = try JSONDecoder().decode(GlassConfig.self, from: data).clamped()
            } catch {
                NSLog("GlassTerm: failed to load config from %@, using defaults: %@",
                      url.path, String(describing: error))
                loaded = GlassConfig()
            }
        }

        lock.lock()
        _config = loaded
        lock.unlock()
    }

    // MARK: Notification

    private func postDidChange() {
        let post = {
            NotificationCenter.default.post(name: .glassConfigDidChange, object: self)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async { post() }
        }
    }
}

// MARK: - NSColor hex helpers

extension NSColor {

    /// Accepts `#RRGGBB`, `RRGGBB`, `#RRGGBBAA`, `RRGGBBAA` (case-insensitive,
    /// surrounding whitespace ignored). Interpreted as sRGB.
    convenience init?(hex: String) {
        guard let components = NSColor.rgbaComponents(fromHex: hex) else { return nil }
        self.init(srgbRed: components.r, green: components.g, blue: components.b, alpha: components.a)
    }

    /// `#RRGGBB`, uppercase, sRGB. Alpha is dropped; opaque colours round-trip exactly.
    var hexString: String {
        let srgb = usingColorSpace(.sRGB) ?? self
        let r = NSColor.byte(from: srgb.redComponent)
        let g = NSColor.byte(from: srgb.greenComponent)
        let b = NSColor.byte(from: srgb.blueComponent)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func byte(from component: CGFloat) -> Int {
        guard component.isFinite else { return 0 }
        let scaled = Int((component * 255).rounded())
        return Swift.min(Swift.max(scaled, 0), 255)
    }

    private static func rgbaComponents(fromHex raw: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8 else { return nil }   // 3-digit shorthand → nil
        guard let value = UInt64(text, radix: 16) else { return nil }

        if text.count == 6 {
            return (CGFloat((value >> 16) & 0xFF) / 255,
                    CGFloat((value >> 8) & 0xFF) / 255,
                    CGFloat(value & 0xFF) / 255,
                    1)
        }
        return (CGFloat((value >> 24) & 0xFF) / 255,
                CGFloat((value >> 16) & 0xFF) / 255,
                CGFloat((value >> 8) & 0xFF) / 255,
                CGFloat(value & 0xFF) / 255)
    }
}
