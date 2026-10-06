import AppKit

/// How the panel is summoned. The two are mutually exclusive: only one source of the shortcut exists at a time.
enum Mode: String, CaseIterable {
    /// MenuSearch stays in the background and registers the recorded shortcut itself.
    case builtin
    /// skhd, Karabiner or another launcher runs `menusearch show`; MenuSearch registers nothing and does not stay.
    case external
    var title: String { self == .builtin ? "内置快捷键" : "外部呼出" }
}

/// One key with modifiers, stored by physical key code so it survives keyboard layout changes.
struct Combo: Equatable {
    static let modifierOrder = ["cmd", "ctrl", "alt", "shift"]
    static let keyNames: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e",
        15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "equal", 25: "9", 26: "7",
        27: "minus", 28: "8", 29: "0", 30: "rightbracket", 31: "o", 32: "u", 33: "leftbracket", 34: "i", 35: "p", 36: "return",
        37: "l", 38: "j", 39: "quote", 40: "k", 41: "semicolon", 42: "backslash", 43: "comma", 44: "slash", 45: "n", 46: "m",
        47: "period", 48: "tab", 49: "space", 50: "grave", 51: "delete", 53: "escape", 96: "f5", 97: "f6", 98: "f7", 99: "f3",
        100: "f8", 101: "f9", 103: "f11", 109: "f10", 111: "f12", 115: "home", 116: "pageup", 117: "forwarddelete", 118: "f4",
        119: "end", 120: "f2", 121: "pagedown", 122: "f1", 123: "left", 124: "right", 125: "down", 126: "up"]
    static let keyCodes: [String: UInt32] = Dictionary(uniqueKeysWithValues: keyNames.map { ($1, $0) })
    private static let symbols: [String: String] = [
        "equal": "=", "minus": "-", "rightbracket": "]", "leftbracket": "[", "return": "↩", "quote": "'", "semicolon": ";",
        "backslash": "\\", "comma": ",", "slash": "/", "period": ".", "tab": "⇥", "space": "Space", "grave": "`", "delete": "⌫",
        "escape": "⎋", "home": "Home", "pageup": "Page Up", "forwarddelete": "⌦", "end": "End", "pagedown": "Page Down",
        "left": "←", "right": "→", "down": "↓", "up": "↑"]
    private static let aliases: [String: String] = [
        "cmd": "cmd", "command": "cmd", "⌘": "cmd", "ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl",
        "alt": "alt", "opt": "alt", "option": "alt", "⌥": "alt", "shift": "shift", "⇧": "shift"]

    let keyCode: UInt32
    /// A subset of `modifierOrder`, in that order.
    let modifiers: [String]

    /// nil when the key is unknown or the combination could not be a system-wide shortcut: it needs ⌘, ⌃ or ⌥,
    /// except for the function keys.
    init?(keyCode: UInt32, modifiers: [String]) {
        guard let name = Self.keyNames[keyCode] else { return nil }
        let set = Set(modifiers)
        guard set.isSubset(of: Self.modifierOrder) else { return nil }
        let functionKey = name.count >= 2 && name.hasPrefix("f") && Int(name.dropFirst()) != nil
        guard functionKey || !set.isDisjoint(with: ["cmd", "ctrl", "alt"]) else { return nil }
        self.keyCode = keyCode
        self.modifiers = Self.modifierOrder.filter(set.contains)
    }

    /// "alt+m", "cmd+shift+space", "⌥M", "⌃⌥F5".
    init?(canonical text: String) {
        var source = text.trimmingCharacters(in: .whitespaces).lowercased()
        for symbol in ["⌘", "⌃", "⌥", "⇧"] { source = source.replacingOccurrences(of: symbol, with: symbol + "+") }
        let parts = source.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last, let code = Self.keyCodes[last] ?? Self.symbols.first(where: { $0.value.lowercased() == last })
            .flatMap({ Self.keyCodes[$0.key] }) else { return nil }
        var modifiers: [String] = []
        for part in parts.dropLast() {
            guard let modifier = Self.aliases[part] else { return nil }
            modifiers.append(modifier)
        }
        self.init(keyCode: code, modifiers: modifiers)
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let code = (object["key_code"] as? NSNumber)?.uint32Value,
              let modifiers = object["modifiers"] as? [String] else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    var json: [String: Any] { ["key_code": Int(keyCode), "modifiers": modifiers] }
    var keyName: String { Self.keyNames[keyCode] ?? "?" }
    /// The form the cross-application key registry compares: cmd, ctrl, alt, shift, then the key.
    var canonical: String { (modifiers + [keyName]).joined(separator: "+") }
    var display: String {
        let marks = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
        return ["ctrl", "alt", "shift", "cmd"].filter(modifiers.contains).compactMap { marks[$0] }.joined()
            + (Self.symbols[keyName] ?? keyName.uppercased())
    }
    /// Carbon modifier mask (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096).
    /// The combination as a menu item shows it, or nil for keys a menu cannot display.
    var menuEquivalent: (String, NSEvent.ModifierFlags)? {
        let special: [String: Int] = ["return": 0x0d, "tab": 0x09, "space": 0x20, "delete": 0x08, "escape": 0x1b, "forwarddelete": NSDeleteFunctionKey,
                                      "home": NSHomeFunctionKey, "end": NSEndFunctionKey, "pageup": NSPageUpFunctionKey, "pagedown": NSPageDownFunctionKey,
                                      "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey, "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey]
        let name = keyName
        let key: String
        if name.count == 1 { key = name }
        else if let symbol = Self.symbols[name], symbol.count == 1, symbol.unicodeScalars.allSatisfy(\.isASCII) { key = symbol }
        else if let code = special[name], let scalar = Unicode.Scalar(code) { key = String(Character(scalar)) }
        else if name.hasPrefix("f"), let number = Int(name.dropFirst()), let scalar = Unicode.Scalar(NSF1FunctionKey + number - 1) { key = String(Character(scalar)) }
        else { return nil }
        let flags: [String: NSEvent.ModifierFlags] = ["cmd": .command, "ctrl": .control, "alt": .option, "shift": .shift]
        return (key, modifiers.reduce(into: NSEvent.ModifierFlags()) { $0.formUnion(flags[$1] ?? []) })
    }

    var carbonModifiers: UInt32 {
        let masks: [String: UInt32] = ["cmd": 256, "shift": 512, "alt": 2048, "ctrl": 4096]
        return modifiers.reduce(0) { $0 | (masks[$1] ?? 0) }
    }
}

struct Settings: Equatable {
    var mode: Mode = .builtin
    var hotkey: Combo?

    var json: [String: Any] {
        var object: [String: Any] = ["mode": mode.rawValue]
        if let hotkey { object["hotkey"] = hotkey.json }
        return object
    }

    /// Used for imported and synced values as well: one rule for what a stored field may contain.
    static func validate(field value: Any) throws {
        if value is NSNull { return }
        if let text = value as? String { guard Mode(rawValue: text) != nil else { throw ProductError("未知的呼出方式：\(text)") }; return }
        guard Combo(json: value) != nil else { throw ProductError("快捷键配置无效。") }
    }
}

/// settings.json in the support directory: the single store the window, the command line and configuration
/// transfer all read and write. Unknown fields survive a save.
final class SettingsStore {
    let url: URL
    /// Why the stored file could not be used; the defaults are in effect and the file is kept until the next save.
    private(set) var loadError: String?
    init(url: URL = Env.settingsURL) { self.url = url }

    func load() -> Settings {
        loadError = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        do {
            let object = try Self.object(url)
            var settings = Settings()
            if let raw = object["mode"] {
                guard let text = raw as? String, let mode = Mode(rawValue: text) else { throw ProductError("呼出方式无效") }
                settings.mode = mode
            }
            if let raw = object["hotkey"], !(raw is NSNull) {
                guard let combo = Combo(json: raw) else { throw ProductError("快捷键无效") }
                settings.hotkey = combo
            }
            return settings
        } catch {
            loadError = "配置文件无法读取（\(error.localizedDescription)），当前使用默认设置；保存新设置时原文件会另存备份。"
            return Settings()
        }
    }

    func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            if let existing = try? Self.object(url) { object = existing }
            else {
                // Keep what could not be parsed instead of overwriting it.
                let stamp = Int(Date().timeIntervalSince1970)
                try FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("settings.corrupt-\(stamp).json"))
            }
        }
        object["version"] = 1
        object["mode"] = settings.mode.rawValue
        object["hotkey"] = settings.hotkey?.json
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        loadError = nil
    }

    private static func object(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProductError("不是有效的设置文件")
        }
        return object
    }
}
