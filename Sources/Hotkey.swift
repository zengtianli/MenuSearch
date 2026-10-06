import AppKit
import Carbon.HIToolbox

/// What the mode and shortcut logic needs from the system, so the same logic runs against a stand-in in tests.
protocol HotkeyRegistering: AnyObject {
    var combo: Combo? { get }
    /// false when the system refuses the combination, usually because another application owns it.
    func register(_ combo: Combo) -> Bool
    func unregister()
}

/// System-wide shortcut through Carbon's RegisterEventHotKey: one specific combination is registered with the
/// window server. No event tap, no key logging, no Accessibility permission, and nothing runs while idle.
final class GlobalHotkey: HotkeyRegistering {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var combo: Combo?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ combo: Combo) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4D4E_5553), id: 1) // 'MNUS'
        guard RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr else {
            reference = nil
            return false
        }
        self.combo = combo
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        combo = nil
    }
}

enum KeyConflicts {
    /// A shortcut macOS itself has enabled (Spotlight, Mission Control, screenshots…). Registering the same
    /// combination can succeed and still never arrive, so it is refused with the reason.
    static func system(_ combo: Combo) -> String? {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let items = list?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for item in items {
            guard (item["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  let code = (item["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let modifiers = (item["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { continue }
            if code == combo.keyCode && modifiers & 0x1B00 == combo.carbonModifiers {
                return "\(combo.display) 已是 macOS 的系统快捷键（系统设置 › 键盘 › 键盘快捷键）。请换一个组合，或先在那里关闭它。"
            }
        }
        return nil
    }

    /// Other applications' declarations in the optional cross-application registry (~/.config/mackit/keys.d).
    /// The registry is a convention between this user's apps; it is read when present and never required.
    static var registryDirectory: URL? {
        guard !Env.isolated else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mackit/keys.d", isDirectory: true)
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
    }
    static let registryFile = "menusearch.json"

    static func registered(_ combo: Combo, in directory: URL? = registryDirectory) -> String? {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" && file.lastPathComponent != registryFile {
            guard let data = try? Data(contentsOf: file), data.count <= 1_048_576,
                  let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            for row in rows where (row["mode"] as? String ?? "global") == "global" {
                guard let key = row["key"] as? String, Combo(canonical: key) == combo else { continue }
                let owner = row["component"] as? String ?? file.deletingPathExtension().lastPathComponent
                return "键位登记里 \(owner) 也声明了 \(combo.display)（\(row["description"] as? String ?? "未说明")）。两边会同时响应，建议换一个。"
            }
        }
        return nil
    }

    /// A binding in skhd's own configuration, if skhd is used on this Mac. Read only: nothing there is ever changed.
    /// skhd intercepts keys with an event tap, which normally runs before a registered shortcut is delivered, so the
    /// same combination in both is expected not to arrive here. (Expected from how the two work; not measured.)
    static func skhd(_ combo: Combo, files: [URL]? = nil) -> String? {
        guard files != nil || !Env.isolated else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names: [String: UInt32] = ["backspace": 51, "delete": 117]
        let modifierNames: [String: [String]] = ["cmd": ["cmd"], "ctrl": ["ctrl"], "alt": ["alt"], "shift": ["shift"],
                                                 "hyper": ["cmd", "ctrl", "alt", "shift"], "meh": ["ctrl", "alt", "shift"]]
        for url in files ?? [home.appendingPathComponent(".config/skhd/skhdrc"), home.appendingPathComponent(".skhdrc")] {
            guard let data = try? Data(contentsOf: url), data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("::"), let colon = trimmed.firstIndex(of: ":") else { continue }
                // "alt - m", "ctrl + shift - 0x29", optionally after "mode <".
                let binding = String(trimmed[..<colon].split(separator: "<").last ?? "")
                guard let dash = binding.range(of: " - ", options: .backwards) else { continue }
                var modifiers: [String] = []
                var known = true
                for name in binding[..<dash.lowerBound].split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                    // Left/right-only and fn bindings are a different key as far as a system shortcut is concerned.
                    guard let mapped = modifierNames[name] else { known = false; break }
                    modifiers += mapped
                }
                let key = binding[dash.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
                let code = key.hasPrefix("0x") ? UInt32(key.dropFirst(2), radix: 16) : (names[key] ?? Combo.keyCodes[key])
                guard known, let code, Combo(keyCode: code, modifiers: modifiers) == combo else { continue }
                let command = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let shown = command.count > 60 ? String(command.prefix(60)) + "…" : command
                return "skhd 也绑定了 \(combo.display)（\(shown)）。两边会抢同一个键，通常是 skhd 先拿走、这里收不到。可以改用「外部呼出」并让 skhd 运行 menusearch show，或换一个组合。"
            }
        }
        return nil
    }

    /// First run on a Mac that has the registry: make this product's keys known without waiting for a change.
    static func declareIfMissing(_ settings: Settings) {
        guard let directory = registryDirectory, !FileManager.default.fileExists(atPath: directory.appendingPathComponent(registryFile).path) else { return }
        declare(settings, in: directory)
    }

    /// Declares this product's keys for the registry: the panel keys always, the system-wide one while it is in use.
    static func declare(_ settings: Settings, in directory: URL? = registryDirectory) {
        guard let directory else { return }
        var rows: [[String: Any]] = []
        if settings.mode == .builtin, let combo = settings.hotkey {
            rows.append(["component": "menusearch", "mode": "global", "key": combo.canonical, "description": "搜索当前 App 的菜单命令", "source": Env.settingsURL.path])
        }
        for (key, description) in [("up", "上一条命令"), ("down", "下一条命令"), ("return", "执行选中的命令"), ("escape", "关闭面板")] {
            rows.append(["component": "menusearch", "mode": "app:MenuSearch", "key": key, "description": description, "source": Env.settingsURL.path])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else { return }
        let target = directory.appendingPathComponent(registryFile)
        // A link placed by someone else is left alone.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil { return }
        try? data.write(to: target, options: .atomic)
    }
}

/// Records a shortcut: click, then press the combination. Esc cancels and keeps the current one.
final class HotkeyRecorder: NSButton {
    var combo: Combo? { didSet { refresh() } }
    var onBegin: (() -> Void)?
    /// nil when recording was cancelled.
    var onEnd: ((Combo?) -> Void)?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    var isRecording: Bool { monitor != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() { title = isRecording ? "请按快捷键…" : (combo?.display ?? "录制快捷键") }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        onBegin?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(nil); return nil }
            guard let combo = Self.combo(from: event) else { NSSound.beep(); return nil }
            self.stop(combo)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.stop(nil)
        }
        refresh()
    }

    static func combo(from event: NSEvent) -> Combo? {
        let flags = event.modifierFlags
        var modifiers: [String] = []
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.control) { modifiers.append("ctrl") }
        if flags.contains(.option) { modifiers.append("alt") }
        if flags.contains(.shift) { modifiers.append("shift") }
        return Combo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    private func stop(_ result: Combo?) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        refresh()
        onEnd?(result)
    }
}
