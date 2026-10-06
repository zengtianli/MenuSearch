// Logic tests, compiled with the non-UI sources and run by build.sh before the application is built.
// The offscreen self-test in the built application (--self-test) covers the panel, settings window and lifecycle.
import Foundation
import Darwin

var failures: [String] = []
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() { failures.append(name) }
}

// Matching and ranking.
let commands = [
    MenuCommand(id: "0", title: "Export as PDF…", path: ["File", "Export as PDF…"], shortcut: "", enabled: true, checked: false),
    MenuCommand(id: "1", title: "Export Bookmarks…", path: ["File", "Export Bookmarks…"], shortcut: "", enabled: true, checked: false),
    MenuCommand(id: "2", title: "Show Path Bar", path: ["View", "Show Path Bar"], shortcut: "⌥⌘P", enabled: true, checked: false),
    MenuCommand(id: "3", title: "Date Modified", path: ["View", "Sort By", "Date Modified"], shortcut: "", enabled: true, checked: false),
    MenuCommand(id: "4", title: "Date Modified", path: ["View", "Group By", "Date Modified"], shortcut: "", enabled: false, checked: false),
    MenuCommand(id: "5", title: "未读", path: ["显示", "未读"], shortcut: "", enabled: true, checked: true),
    MenuCommand(id: "6", title: "ＦＵＬＬ Width", path: ["Format", "ＦＵＬＬ Width"], shortcut: "", enabled: true, checked: false)
]
let index = MenuSearchIndex(commands)
expect(index.filter("").map(\.id) == commands.map(\.id), "empty query keeps menu order")
expect(index.filter("  ").count == commands.count, "blank query lists everything")
expect(index.filter("exp pdf").map(\.id) == ["0"], "tokens narrow to one command")
expect(index.filter("export").map(\.id) == ["0", "1"], "equal scores keep menu order")
expect(index.filter("path bar").first?.id == "2", "words in a title")
expect(index.filter("spb").first?.id == "2", "discontinuous characters")
expect(Set(index.filter("date modified").map(\.fullPath)).count == 2, "same title, different paths")
expect(index.filter("group date").map(\.id) == ["4"], "path tokens select among duplicates")
expect(index.filter("未读").map(\.id) == ["5"] && index.filter("显示").map(\.id) == ["5"], "Chinese title and path")
expect(index.filter("full width").map(\.id) == ["6"] && index.filter("EXPORT AS").first?.id == "0", "width and case folding")
expect(index.filter("zzz").isEmpty, "no match")
expect(commands[3].location == "View › Sort By" && commands[3].fullPath == "View › Sort By › Date Modified", "path strings")

// Key equivalents as the menu bar shows them.
expect(MenuReader.shortcutText(character: "E", virtualKey: -1, modifiers: 1) == "⇧⌘E", "shift command letter")
expect(MenuReader.shortcutText(character: "\u{08}", virtualKey: -1, modifiers: 1) == "⇧⌘⌫" && MenuReader.shortcutText(character: "\u{7f}", virtualKey: -1, modifiers: 0) == "⌘⌦", "delete keys declared as control characters")
expect(MenuReader.shortcutText(character: "\r", virtualKey: -1, modifiers: 8) == "↩" && MenuReader.shortcutText(character: " ", virtualKey: -1, modifiers: 6) == "⌃⌥⌘Space", "return and space")
expect(MenuReader.shortcutText(character: "", virtualKey: 126, modifiers: 2) == "⌥⌘↑" && MenuReader.shortcutText(character: "\u{f703}", virtualKey: -1, modifiers: 0) == "⌘→", "arrows by key code and by function character")
expect(MenuReader.shortcutText(character: "", virtualKey: -1, modifiers: 0) == "" && MenuReader.shortcutText(character: "", virtualKey: 999, modifiers: 0) == "", "no key equivalent")

// Shortcut combinations.
let optionM = Combo(canonical: "alt+m")
expect(optionM?.keyCode == 46 && optionM?.modifiers == ["alt"] && optionM?.display == "⌥M", "alt+m")
expect(Combo(canonical: "⌃⌥⇧⌘K")?.canonical == "cmd+ctrl+alt+shift+k", "symbols parse to registry order")
expect(Combo(canonical: "shift+cmd+space") == Combo(canonical: "cmd+shift+space"), "modifier order does not matter")
expect(Combo(canonical: "m") == nil && Combo(canonical: "shift+m") == nil && Combo(canonical: "") == nil, "a plain key is not a shortcut")
expect(Combo(canonical: "f5") != nil && Combo(keyCode: 9999, modifiers: ["cmd"]) == nil && Combo(keyCode: 46, modifiers: ["meta"]) == nil, "function keys and unknown input")
expect(Combo(json: ["key_code": 46, "modifiers": ["alt"]]) == optionM && Combo(json: ["key_code": "46"]) == nil && Combo(json: nil) == nil, "stored form")
expect(Combo(canonical: "cmd+shift+,")?.keyName == "comma" && Combo(canonical: "cmd+comma")?.display == "⌘,", "punctuation by symbol and by name")

// Settings store.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("menusearch-tests-\(getpid())", isDirectory: true)
try? FileManager.default.removeItem(at: scratch)
let store = SettingsStore(url: scratch.appendingPathComponent("nested/settings.json"))
expect(store.load() == Settings() && store.loadError == nil && !FileManager.default.fileExists(atPath: scratch.path), "reading creates nothing")
do {
    try store.save(Settings(mode: .external, hotkey: optionM))
    expect(store.load() == Settings(mode: .external, hotkey: optionM), "round trip")
    try store.save(Settings(mode: .builtin, hotkey: nil))
    expect(store.load() == Settings(), "cleared shortcut is removed")
    try Data("[1,2]".utf8).write(to: store.url)
    expect(store.load() == Settings() && store.loadError != nil, "wrong shape falls back")
    try Data("{\"mode\":\"builtin\",\"hotkey\":{\"key_code\":46,\"modifiers\":[\"shift\"]}}".utf8).write(to: store.url)
    expect(store.load() == Settings() && store.loadError != nil, "unusable stored shortcut falls back")
} catch { failures.append("settings store: \(error.localizedDescription)") }
expect((try? Settings.validate(field: "external")) != nil && (try? Settings.validate(field: "sometimes")) == nil
    && (try? Settings.validate(field: ["key_code": 46, "modifiers": ["alt"]] as [String: Any])) != nil
    && (try? Settings.validate(field: ["key_code": 46] as [String: Any])) == nil, "imported fields are validated")

// Tuning data.
var tuning = Tuning()
tuning.merge(["scan_deadline_seconds": 0.01, "messaging_timeout_seconds": 99, "max_depth": 1, "max_items": 5, "skip_top_level_titles": "Apple"])
expect(tuning.scanDeadlineSeconds == 0.5 && tuning.messagingTimeoutSeconds == 5 && tuning.maxDepth == 4 && tuning.maxItems == 100
    && tuning.skipTopLevelTitles == Tuning().skipTopLevelTitles, "out-of-range values are clamped, wrong types ignored")

// Control socket: one request, one reply, and silence when nobody listens.
let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("menusearch-tests-\(getpid()).sock")
let lockPath = scratch.appendingPathComponent("nested/instance.lock").path
expect(Control.request(["cmd": "ping"], socketPath: socketPath, timeout: 1) == nil, "no listener")
expect(!Control.primaryHoldsLock(lockPath: lockPath), "no lock holder")
expect(Control.address(String(repeating: "x", count: 200)) == nil, "over-long socket path refused")
let server = ControlServer(lockPath: lockPath, socketPath: socketPath)
expect(server.acquire(), "lock acquired")
expect(!ControlServer(lockPath: lockPath, socketPath: socketPath).acquire(), "second instance refused")
server.handler = { request in ["ok": true, "echo": request["cmd"] as? String ?? "", "中文": "可以"] }
do {
    try server.listen()
    var reply: [String: Any]?
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { reply = Control.request(["cmd": "ping"], socketPath: socketPath, timeout: 3); finished.signal() }
    let deadline = Date().addingTimeInterval(5)
    while finished.wait(timeout: .now()) == .timedOut && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    expect(reply?["echo"] as? String == "ping" && reply?["中文"] as? String == "可以", "request and reply")
    var mode = stat()
    expect(stat(socketPath, &mode) == 0 && mode.st_mode & 0o077 == 0, "socket is private to the user")
} catch { failures.append("control socket: \(error.localizedDescription)") }
server.stop()
expect(Control.request(["cmd": "ping"], socketPath: socketPath, timeout: 1) == nil && !Control.primaryHoldsLock(lockPath: lockPath), "stopped")

try? FileManager.default.removeItem(at: scratch)
if failures.isEmpty { print("Logic tests passed.") } else {
    for failure in failures { fputs("FAILED: \(failure)\n", stderr) }
    exit(1)
}
