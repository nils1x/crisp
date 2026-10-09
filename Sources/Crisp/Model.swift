import AppKit
import Carbon
import CoreGraphics
import Foundation

struct Shortcut: Codable, Equatable, Hashable {
    // CGEventFlags bits for Shift, Control, Option and Command.
    var modifiers: UInt64
    var key: Int

    static let hyper: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue
    static let option: UInt64 = CGEventFlags.maskAlternate.rawValue
    static let control: UInt64 = CGEventFlags.maskControl.rawValue

    var isValid: Bool {
        modifiers != 0 && modifiers & ~Self.hyper == 0
            && (0...127).contains(key) && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key)
    }

    static func recorded(keyCode: Int, flags: CGEventFlags) -> Shortcut? {
        let shortcut = Shortcut(modifiers: flags.rawValue & hyper, key: keyCode)
        return shortcut.isValid ? shortcut : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modifiers == rhs.modifiers && lhs.key == rhs.key
    }

    var label: String {
        if modifiers == Self.hyper { return "Hyper + \(KeyChoice.name(for: key))" }
        var text = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { text += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { text += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { text += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { text += "⌘" }
        return text + KeyChoice.name(for: key)
    }

    // Ignore hardware-independent flags (numeric pad, Fn, Caps Lock, etc.).
    func matches(keyCode: Int, flags: CGEventFlags) -> Bool {
        let relevant = Self.hyper
        return key == keyCode && modifiers == flags.rawValue & relevant
    }
}

struct KeyChoice: Identifiable {
    let name: String
    let code: Int
    var id: Int { code }

    private static let translatedNames = NSCache<NSString, NSString>()

    static func name(for code: Int) -> String {
        if let special = special.first(where: { $0.code == code }) { return special.name }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let cacheKey = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { "\(Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String):\(code)" as NSString }
        if let cacheKey, let cached = translatedNames.object(forKey: cacheKey) { return cached as String }

        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return cache("Key \(code)", for: cacheKey)
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return cache("Key \(code)", for: cacheKey) }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var output = [UniChar](repeating: 0, count: 4)
        let result = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &dead, output.count, &length, &output)
        let name = result == noErr && length > 0
            ? String(utf16CodeUnits: output, count: length).uppercased() : "Key \(code)"
        return cache(name, for: cacheKey)
    }

    private static func cache(_ name: String, for key: NSString?) -> String {
        if let key { translatedNames.setObject(name as NSString, forKey: key) }
        return name
    }

    private static let special = [KeyChoice(name: "←", code: 123), KeyChoice(name: "→", code: 124),
                                  KeyChoice(name: "↓", code: 125), KeyChoice(name: "↑", code: 126),
                                  KeyChoice(name: "Return", code: 36), KeyChoice(name: "Delete", code: 51),
                                  KeyChoice(name: "Forward Delete", code: 117),
                                  KeyChoice(name: "Tab", code: 48), KeyChoice(name: "Space", code: 49),
                                  KeyChoice(name: "Escape", code: 53), KeyChoice(name: "F18", code: 79),
                                  KeyChoice(name: "F19", code: 80), KeyChoice(name: "F20", code: 90)]
}

enum HyperSource: String, Codable, CaseIterable, Identifiable {
    case off, capsLock, f18, f19, f20
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .capsLock: "Caps Lock"
        case .f18: "F18"
        case .f19: "F19"
        case .f20: "F20"
        }
    }
    var keyCode: Int? {
        switch self {
        case .off: nil
        case .capsLock, .f18: 79
        case .f19: 80
        case .f20: 90
        }
    }

    func suppressesRawCapsLock(keyCode: Int, isActive: Bool) -> Bool {
        self == .capsLock && isActive && keyCode == 57
    }
}

struct AppBinding: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bundleID: String
    var shortcut: Shortcut
    var enabled = true
}

enum AppFocusPlan: Equatable {
    case launch
    case activate
    case restoreMinimizedWindow
    case reopenWindow

    static func make(isRunning: Bool, minimizedWindows: [Bool]?) -> Self {
        guard isRunning else { return .launch }
        guard let minimizedWindows, !minimizedWindows.isEmpty else { return .reopenWindow }
        return minimizedWindows.allSatisfy { $0 } ? .restoreMinimizedWindow : .activate
    }
}

enum ScreenSize: String, Codable, CaseIterable, Identifiable {
    case macBook, wide, ultrawide, superUltrawide, vertical

    var id: String { rawValue }
    var label: String {
        switch self {
        case .macBook: "MacBook (16:10)"
        case .wide: "Wide (16:9)"
        case .ultrawide: "Ultrawide (21:9)"
        case .superUltrawide: "Super ultrawide (32:9)"
        case .vertical: "Vertical"
        }
    }

    static func classify(_ frame: CGRect) -> ScreenSize {
        guard frame.height > 0 else { return .macBook }
        let ratio = frame.width / frame.height
        if ratio < 1 { return .vertical }
        if ratio < 1.7 { return .macBook }
        if ratio < 2.05 { return .wide }
        if ratio < 2.85 { return .ultrawide }
        return .superUltrawide
    }
}

struct Layout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    // Coordinates in the usable screen: x/y from its top-left, 0…1.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var shortcut: Shortcut
    var enabled = true
    var availableScreens = Set(ScreenSize.allCases)

    // Older saved layouts have no screen filter. Keep them working on all displays.
    enum CodingKeys: String, CodingKey {
        case id, name, x, y, width, height, shortcut, enabled, availableScreens
    }

    init(id: UUID = UUID(), name: String, x: Double, y: Double, width: Double,
         height: Double, shortcut: Shortcut, enabled: Bool = true,
         availableScreens: Set<ScreenSize> = Set(ScreenSize.allCases)) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.shortcut = shortcut
        self.enabled = enabled
        self.availableScreens = availableScreens
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        width = try values.decode(Double.self, forKey: .width)
        height = try values.decode(Double.self, forKey: .height)
        shortcut = try values.decode(Shortcut.self, forKey: .shortcut)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        availableScreens = try values.decodeIfPresent(Set<ScreenSize>.self, forKey: .availableScreens)
            ?? Set(ScreenSize.allCases)
    }

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000001 && y + height <= 1.000001
            && !availableScreens.isEmpty
    }

    func frame(in visibleFrame: CGRect) -> CGRect? {
        guard isValid, visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
        return CGRect(x: visibleFrame.minX + x * visibleFrame.width,
                      y: visibleFrame.maxY - (y + height) * visibleFrame.height,
                      width: width * visibleFrame.width,
                      height: height * visibleFrame.height)
    }
}

enum LayoutDimension: String, Hashable {
    case x, y, width, height
}

struct LayoutDimensions: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ layout: Layout) {
        x = layout.x
        y = layout.y
        width = layout.width
        height = layout.height
    }

    subscript(_ dimension: LayoutDimension) -> Double {
        get {
            switch dimension {
            case .x: x
            case .y: y
            case .width: width
            case .height: height
            }
        }
        set {
            switch dimension {
            case .x: x = newValue
            case .y: y = newValue
            case .width: width = newValue
            case .height: height = newValue
            }
        }
    }

    func applying(to layout: Layout) -> Layout {
        var updated = layout
        updated.x = x
        updated.y = y
        updated.width = width
        updated.height = height
        return updated
    }

    static func parseValue(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Layout values are ratios, so accept either decimal convention without
        // interpreting punctuation as a thousands separator.
        var normalized = ""
        var decimalSeparatorSeen = false
        for character in trimmed {
            if character == "," || character == "." {
                guard !decimalSeparatorSeen else { return nil }
                decimalSeparatorSeen = true
                normalized.append(".")
            } else if character.isNumber || character == "-" || character == "+" {
                normalized.append(character)
            } else {
                return nil
            }
        }
        guard let value = Double(normalized), value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
}

struct CrispConfig: Codable {
    var apps: [AppBinding]
    var layouts: [Layout]
    var hyperSource: HyperSource
    var instantSpaces: Bool
    var windowManagementEnabled: Bool
    var menuBarIcon: MenuBarIcon

    enum CodingKeys: String, CodingKey {
        case apps, layouts, hyperSource, instantSpaces, windowManagementEnabled, menuBarIcon
    }

    init(apps: [AppBinding], layouts: [Layout], hyperSource: HyperSource,
         instantSpaces: Bool, windowManagementEnabled: Bool = true,
         menuBarIcon: MenuBarIcon = .supra) {
        self.apps = apps
        self.layouts = layouts
        self.hyperSource = hyperSource
        self.instantSpaces = instantSpaces
        self.windowManagementEnabled = windowManagementEnabled
        self.menuBarIcon = menuBarIcon
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(apps: try values.decode([AppBinding].self, forKey: .apps),
                  layouts: try values.decode([Layout].self, forKey: .layouts),
                  hyperSource: try values.decode(HyperSource.self, forKey: .hyperSource),
                  instantSpaces: try values.decode(Bool.self, forKey: .instantSpaces),
                  windowManagementEnabled: try values.decodeIfPresent(Bool.self, forKey: .windowManagementEnabled) ?? true,
                  menuBarIcon: try values.decodeIfPresent(MenuBarIcon.self, forKey: .menuBarIcon) ?? .supra)
    }

    static let initial: CrispConfig = {
        let apps = [("Ghostty", "com.mitchellh.ghostty", 5),
                    ("Reminders", "com.apple.reminders", 15),
                    ("Mail", "com.apple.mail", 46),
                    ("Finder", "com.apple.finder", 3),
                    ("Obsidian", "md.obsidian", 31),
                    ("Zed", "dev.zed.Zed", 16),
                    ("Search", "com.officecommun.search", 1)]
            .map { AppBinding(name: $0.0, bundleID: $0.1,
                              shortcut: Shortcut(modifiers: Shortcut.option, key: $0.2)) }
        let specs: [(String, Double, Double, Double, Double, Int)] = [
            ("Left Half", 0, 0, 0.5, 1, 123),
            ("Right Half", 0.5, 0, 0.5, 1, 124),
            ("Right Third", 2.0 / 3, 0, 1.0 / 3, 1, 124),
            ("Top Half", 0, 0, 1, 0.5, 126),
            ("Bottom Half", 0, 0.5, 1, 0.5, 125),
            ("Full", 0, 0, 1, 1, 36),
            ("Centered", 0.1, 0.05, 0.8, 0.9, 51),
            ("Centered Tight", 0.2, 0.1, 0.6, 0.8, 17),
            ("Top Left", 0, 0, 0.5, 0.5, 18),
            ("Top Right", 0.5, 0, 0.5, 0.5, 19),
            ("Bottom Left", 0, 0.5, 0.5, 0.5, 20),
            ("Bottom Right", 0.5, 0.5, 0.5, 0.5, 21),
            ("Left Fourth", 0, 0, 0.25, 1, 23),
            ("Middle Half", 0.25, 0, 0.5, 1, 22),
            ("Right Fourth", 0.75, 0, 0.25, 1, 26),
            ("Left Two Thirds", 0, 0, 2.0 / 3, 1, 28),
            ("Right Two Thirds", 1.0 / 3, 0, 2.0 / 3, 1, 25)
        ]
        let layouts = specs.map { Layout(name: $0.0, x: $0.1, y: $0.2,
                                        width: $0.3, height: $0.4,
                                        shortcut: Shortcut(modifiers: Shortcut.hyper, key: $0.5)) }
        return CrispConfig(apps: apps, layouts: layouts, hyperSource: .off, instantSpaces: false,
                           windowManagementEnabled: true, menuBarIcon: .supra)
    }()

    // Upgrade only untouched defaults. Never replace a customized shortcut.
    func upgradingLayouts() -> CrispConfig {
        var copy = self
        if !copy.layouts.contains(where: { $0.name == "Right Third" }),
           let index = copy.layouts.firstIndex(where: { $0.name == "Right Half" }) {
            let half = copy.layouts[index]
            copy.layouts.insert(Layout(name: "Right Third", x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1,
                                       shortcut: half.shortcut, enabled: half.enabled,
                                       availableScreens: half.availableScreens), at: index + 1)
        }
        let old = Shortcut(modifiers: Shortcut.hyper, key: 8)
        let replacement = Shortcut(modifiers: Shortcut.hyper, key: 51)
        if let center = copy.layouts.firstIndex(where: { $0.name == "Centered" && $0.shortcut == old }),
           !copy.apps.contains(where: { $0.enabled && $0.shortcut == replacement }),
           !copy.layouts.enumerated().contains(where: { $0.offset != center && $0.element.enabled && $0.element.shortcut == replacement }) {
            copy.layouts[center].shortcut = replacement
        }
        return copy
    }

    enum Action {
        case layout
        case app(AppBinding)
        case space(SpaceGesture.Direction)
    }

    func action(for shortcut: Shortcut) -> Action? {
        ShortcutResolver(self)[shortcut]
    }

    var validationError: String? {
        var usedApps: Set<Shortcut> = []
        for binding in apps where binding.enabled {
            guard !binding.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Choose an app before enabling its shortcut."
            }
            guard binding.shortcut.isValid, binding.shortcut.key != hyperSource.keyCode else {
                return "Record a key with at least one modifier, not the Hyper source key."
            }
            guard usedApps.insert(binding.shortcut).inserted else {
                return "Shortcut already used by another app."
            }
        }
        for layout in layouts where layout.enabled {
            guard layout.isValid else { return "Layout must fit the screen and allow at least one display size." }
            guard layout.shortcut.isValid, layout.shortcut.key != hyperSource.keyCode else {
                return "Record a key with at least one modifier, not the Hyper source key."
            }
        }
        return nil // Layouts may share any shortcut; dispatch prioritizes them over apps and Spaces.
    }
}

/// Shortcut lookup built once per config change. The key press path must not scan
/// the layout and app arrays: a dictionary keeps resolution O(1) with no allocation.
struct ShortcutResolver {
    private let actions: [Shortcut: CrispConfig.Action]
    /// Enabled, valid layouts per shortcut in list order, so cycling never rescans
    /// every layout. The display filter is applied per press because the focused
    /// window's screen is only known then.
    private let layouts: [Shortcut: [Layout]]

    init(_ config: CrispConfig) {
        var actions: [Shortcut: CrispConfig.Action] = [:]
        var layouts: [Shortcut: [Layout]] = [:]
        // Priority: layouts over apps over instant Spaces. Insert in reverse so the
        // first match wins; later writes must not overwrite an earlier one.
        if config.instantSpaces {
            actions[Shortcut(modifiers: Shortcut.control, key: 123)] = .space(.previous)
            actions[Shortcut(modifiers: Shortcut.control, key: 124)] = .space(.next)
        }
        // Reversed so the first enabled app in list order wins a shared shortcut.
        for app in config.apps.reversed() where app.enabled {
            actions[app.shortcut] = .app(app)
        }
        if config.windowManagementEnabled {
            for layout in config.layouts where layout.enabled {
                actions[layout.shortcut] = .layout
                if layout.isValid { layouts[layout.shortcut, default: []].append(layout) }
            }
        }
        self.actions = actions
        self.layouts = layouts
    }

    subscript(shortcut: Shortcut) -> CrispConfig.Action? {
        actions[shortcut]
    }

    func layouts(for shortcut: Shortcut, screen: ScreenSize) -> [Layout] {
        layouts[shortcut]?.filter { $0.availableScreens.contains(screen) } ?? []
    }
}

struct LayoutCycle {
    private var lastShortcut: Shortcut?
    private var lastLayoutID: UUID?
    /// `layouts` must already be filtered for the shortcut and display; see
    /// `ShortcutResolver.layouts(for:screen:)`.
    mutating func next(in eligible: [Layout], for shortcut: Shortcut, sameWindow: Bool) -> Layout? {
        guard !eligible.isEmpty else { return nil }
        guard sameWindow, lastShortcut == shortcut,
              let index = eligible.firstIndex(where: { $0.id == lastLayoutID }) else { return eligible[0] }
        return eligible[(index + 1) % eligible.count]
    }

    mutating func didApply(_ layout: Layout, for shortcut: Shortcut) {
        lastShortcut = shortcut
        lastLayoutID = layout.id
    }

    mutating func reset() {
        lastShortcut = nil
        lastLayoutID = nil
    }
}
