import AppKit
import ApplicationServices

/// A shortcut source that registers nothing: used where no live process may hold a system-wide key
/// (an isolated support directory), so the same validation and storage code still runs.
final class NullRegistrar: HotkeyRegistering {
    private(set) var combo: Combo?
    func register(_ combo: Combo) -> Bool { self.combo = combo; return true }
    func unregister() { combo = nil }
}

struct UnavailableLoginItem: LoginItem {
    var status: String { "unavailable" }
    var enabled: Bool { false }
    func set(_ on: Bool) throws { throw ProductError("隔离环境不能更改登录项。") }
}

/// The `menusearch` command: the same executable as the application, sharing its settings store and, through the
/// control socket, its live instance. Reading commands never start or change anything.
enum CLI {
    struct Usage: Error { let message: String }

    static var usage: String { """
        MenuSearch \(Env.version) · 菜单搜索 — 搜索并执行当前 App 的菜单命令

        用法：menusearch <命令> [选项]

          status [--json]                  版本、呼出方式、快捷键、权限和后台实例状态（只读）
          show                             对当前 App 呼出面板；面板已显示时关闭
          scan [--pid PID] [--query 词] [--json]
                                           读取菜单命令（只读）；缺省为当前 App，--query 用面板同一套匹配过滤
          execute --pid PID --path-json '["View","Show Path Bar"]' [--json]
                                           执行完整路径唯一匹配的命令；目标 App 须在前台
          settings                         打开设置窗口
          config get [--json]              查看配置
          config set mode builtin|external 内置快捷键 / 外部呼出
          config set hotkey <组合键|none>   例：alt+m、cmd+shift+space
          config set login on|off          登录时启动（仅内置快捷键方式）
          config set icloud on|off         用 iCloud 记住配置（同设置窗口里的开关）
          config export [文件]             导出配置；缺省写到标准输出
          config import <文件>             导入配置，原配置自动备份
          config path                      配置文件位置
          update [--install] [--json]      查询 GitHub 上的最新正式版（只在运行这条命令时联网）；--install 下载、验证后升级，配置保留
          quit                             退出后台实例
          help | --help                    显示本说明
          version | --version              显示版本

        退出码：0 成功；1 未完成（没有权限、菜单不完整、目标不在前台、实例无响应等）；2 用法错误。
        读命令（不改任何东西）：status、scan、config get、config path、config export、update（不带 --install）、version、help。
        写命令：show、execute、settings、config set、config import、update --install、quit。
        加 --json 时，标准输出只有一个 JSON 对象：成功 {"ok": true, …}，失败 {"ok": false, "error": "原因"}。
        仅在窗口中：在系统设置里授权辅助功能、用按键录制快捷键（命令行直接写组合键）、把外部呼出命令拷到剪贴板。
        scan 和 execute 在命令行进程内读取菜单，用的是调用它的终端或工具的辅助功能权限；
        show 交给 MenuSearch.app 自己读取，用的是 App 的权限。
        """ }

    static func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    private static func fail(_ message: String, json: Bool) -> Int32 {
        if json { printJSON(["ok": false, "error": message]) } else { fputs(message + "\n", stderr) }
        return 1
    }

    private static func option(_ name: String, in arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard arguments.count > index + 1 else { throw Usage(message: "\(name) 需要一个值。") }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
        return value
    }

    private static func none(_ arguments: [String]) throws {
        if let extra = arguments.first { throw Usage(message: "多余的参数「\(extra)」。") }
    }

    private static let isolationRefusal = "隔离环境（MENUSEARCH_SUPPORT_DIR）不能读取或操作本机的 App、快捷键和后台实例。"

    static func run(_ arguments: [String]) -> Int32 {
        var rest = arguments
        let json = rest.contains("--json")
        rest.removeAll { $0 == "--json" }
        guard let command = rest.first else { print(usage); return 0 }
        rest.removeFirst()
        do {
            switch command {
            case "help", "--help", "-h":
                print(usage); return 0
            case "version", "--version":
                if json { printJSON(["ok": true, "version": Env.version, "build": Env.build]) } else { print("\(Env.version) (\(Env.build))") }
                return 0
            case "status":
                try none(rest)
                let state = status()
                if json { printJSON(state) } else { print(statusText(state)) }
                return 0
            case "show":
                try none(rest)
                return show(json: json)
            case "scan":
                let pid = try option("--pid", in: &rest).map { try number($0, "--pid") }
                let query = try option("--query", in: &rest)
                try none(rest)
                return scan(pid: pid, query: query, json: json)
            case "execute":
                guard let pid = try option("--pid", in: &rest).map({ try number($0, "--pid") }) else { throw Usage(message: "execute 需要 --pid。") }
                guard let raw = try option("--path-json", in: &rest) else { throw Usage(message: "execute 需要 --path-json。") }
                try none(rest)
                guard let data = raw.data(using: .utf8), let path = try? JSONDecoder().decode([String].self, from: data),
                      !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else { throw Usage(message: "--path-json 需要非空的菜单名称 JSON 数组。") }
                return execute(pid: pid, path: path, json: json)
            case "settings":
                try none(rest)
                guard !Env.isolated else { return fail(isolationRefusal, json: json) }
                guard let reply = sendStartingApp(["cmd": "settings"]) else { return fail("MenuSearch 没有响应。", json: json) }
                if json { printJSON(reply) }
                return reply["ok"] as? Bool == true ? 0 : 1
            case "config":
                return try config(rest, json: json)
            case "update":
                let install = rest.contains("--install")
                rest.removeAll { $0 == "--install" }
                try none(rest)
                return update(install: install, json: json)
            case "quit":
                try none(rest)
                guard !Env.isolated else { return fail(isolationRefusal, json: json) }
                let reply = Control.request(["cmd": "quit"]) ?? ["ok": true, "action": "not_running"]
                if json { printJSON(reply) } else { print(reply["action"] as? String == "not_running" ? "没有后台实例在运行。" : "已请求退出。") }
                return 0
            default:
                throw Usage(message: "未知命令「\(command)」。")
            }
        } catch let error as Usage {
            if json { printJSON(["ok": false, "error": error.message, "usage": true]) }
            fputs(error.message + " 运行 menusearch --help 查看用法。\n", stderr)
            return 2
        } catch {
            return fail(error.localizedDescription, json: json)
        }
    }

    private static func number(_ text: String, _ name: String) throws -> Int32 {
        guard let value = Int32(text), value > 0 else { throw Usage(message: "\(name) 需要正整数。") }
        return value
    }

    // MARK: status

    /// Reads the settings file and asks a running instance, if there is one. Starts and writes nothing.
    static func status() -> [String: Any] {
        let store = SettingsStore()
        let settings = store.load()
        var state: [String: Any] = [
            "ok": true, "version": Env.version, "build": Env.build, "bundle_id": Env.bundleID,
            "bundle_path": Env.bundleURL?.path ?? NSNull(), "installed": Env.bundleURL?.path == Env.installedBundlePath,
            "mode": settings.mode.rawValue,
            "hotkey": settings.hotkey.map { ["display": $0.display, "key": $0.canonical] as [String: Any] } ?? NSNull(),
            "settings_path": store.url.path, "settings_error": store.loadError ?? NSNull(), "isolated": Env.isolated,
            // Whether the process that ran this command may use Accessibility; the application's own answer is in "resident".
            "caller_accessibility": AXIsProcessTrusted()]
        let live = Env.isolated ? nil : Control.request(["cmd": "status"], timeout: 2)
        state["resident"] = live ?? ["running": false]
        if let last = live?["last_show"], !(last is NSNull) { state["last_show"] = last }
        else if let data = try? Data(contentsOf: Env.lastShowURL), let last = try? JSONSerialization.jsonObject(with: data) { state["last_show"] = last }
        else { state["last_show"] = NSNull() }
        return state
    }

    private static func statusText(_ state: [String: Any]) -> String {
        let resident = state["resident"] as? [String: Any] ?? [:]
        let running = resident["running"] as? Bool == true
        let mode = Mode(rawValue: state["mode"] as? String ?? "")?.title ?? "?"
        let hotkey = (state["hotkey"] as? [String: Any])?["display"] as? String
        var lines = ["MenuSearch \(state["version"] ?? "?") (\(state["build"] ?? "?"))  \(state["bundle_path"] as? String ?? "未在 .app 内")"]
        var key = hotkey ?? "未设置"
        if running, hotkey != nil { key += resident["hotkey_registered"] as? Bool == true ? "（已注册）" : "（未注册）" }
        lines.append("呼出方式：\(mode)    快捷键：\(key)")
        if let error = resident["hotkey_error"] as? String { lines.append("快捷键问题：\(error)") }
        if let warning = resident["hotkey_warning"] as? String { lines.append("快捷键提示：\(warning)") }
        if running {
            lines.append("后台实例：运行中（pid \(resident["pid"] ?? "?")），面板\(resident["panel_visible"] as? Bool == true ? "已显示" : "未显示")")
            let presence = resident["presence"] as? [String: Any] ?? [:]
            let icon = presence["menu_bar_icon"] as? Bool != true ? "不显示"
                : presence["menu_bar_icon_on_screen"] as? Bool == true ? "显示" : "已添加，但菜单栏现在放不下它（被刘海或其他图标挤掉）"
            lines.append("程序坞与 ⌘Tab：\(presence["dock"] as? Bool == true ? "显示" : "不显示")    菜单栏图标：\(icon)")
            lines.append("辅助功能（MenuSearch.app）：\(resident["accessibility"] as? Bool == true ? "已允许" : "未允许")")
            lines.append("登录时启动：\(resident["login_item"] as? String ?? "?")    iCloud 记住配置：\(resident["icloud_sync"] as? Bool == true ? "开" : "关")")
        } else {
            lines.append("后台实例：未运行（App 的辅助功能权限要等它运行时才能回读）")
        }
        lines.append("辅助功能（本次调用进程）：\(state["caller_accessibility"] as? Bool == true ? "已允许" : "未允许")")
        if let problem = state["settings_error"] as? String { lines.append("配置：\(problem)") }
        if let last = state["last_show"] as? [String: Any] {
            lines.append("最近一次呼出：\(last["at"] ?? "?")，\(last["source"] ?? "?")，\(last["count"] ?? "?") 条，\(last["elapsed_ms"] ?? "?") ms（读取 \(last["scan_ms"] ?? "?") ms）")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: talking to the application

    /// Sends to the listening instance; when none listens, starts the application in the background (no window, no
    /// activation) and sends as soon as it listens.
    static func sendStartingApp(_ request: [String: Any], wait: TimeInterval = 6) -> [String: Any]? {
        if let reply = Control.request(request) { return reply }
        guard let bundle = Env.bundleURL else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = ["--app-background"]
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration, completionHandler: nil)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            usleep(10_000)
            if let reply = Control.request(request) { return reply }
        }
        return nil
    }

    private static func show(json: Bool) -> Int32 {
        let requested = Date()
        guard !Env.isolated else { return fail(isolationRefusal, json: json) }
        // Captured here, in the caller's moment: nothing the application does afterwards can change the answer.
        let target = NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication
        var request: [String: Any] = ["cmd": "show", "t0": requested.timeIntervalSince1970]
        if let target { request["pid"] = Int(target.processIdentifier) }
        guard let reply = sendStartingApp(request) else {
            return fail(Env.bundleURL == nil ? "这个可执行文件不在 MenuSearch.app 内，无法启动 App。" : "MenuSearch 没有响应。", json: json)
        }
        if json { printJSON(reply) }
        else if reply["ok"] as? Bool != true { fputs((reply["error"] as? String ?? "未能呼出。") + "\n", stderr) }
        return reply["ok"] as? Bool == true ? 0 : 1
    }

    // MARK: scan / execute

    private static func describe(_ error: Error) -> String {
        if case MenuSearchError.accessibility = error {
            return "运行这条命令的进程没有辅助功能权限。命令行读取用的是调用它的终端或工具的权限，不是 MenuSearch.app 的；"
                + "请在「系统设置 › 隐私与安全性 › 辅助功能」里允许该终端，或改用 menusearch show 由 App 读取。"
        }
        return error.localizedDescription
    }

    private static func scan(pid: Int32?, query: String?, json: Bool) -> Int32 {
        guard !Env.isolated else { return fail(isolationRefusal, json: json) }
        do {
            let read = try MenuReader(target: MenuReader.target(pid: pid)).scan()
            // The panel's own index and ranking, so a script sees the order the panel would show.
            let snapshot = query.map {
                MenuSnapshot(ok: read.ok, pid: read.pid, app: read.app, bundleID: read.bundleID, durationMS: read.durationMS,
                             complete: read.complete, warnings: read.warnings, items: MenuSearchIndex(read.items).filter($0))
            } ?? read
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.keyEncodingStrategy = .convertToSnakeCase
                print(String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "{}")
            } else {
                for item in snapshot.items {
                    print(item.fullPath + (item.shortcut.isEmpty ? "" : "  [\(item.shortcut)]") + (item.checked ? "  ✓" : "") + (item.enabled ? "" : "  （不可用）"))
                }
                print("\(snapshot.app)：\(snapshot.items.count) 条，\(Int(snapshot.durationMS.rounded())) ms" + (snapshot.complete ? "" : "，不完整：" + snapshot.warnings.joined(separator: " ")))
            }
            return snapshot.complete ? 0 : 1
        } catch { return fail(describe(error), json: json) }
    }

    private static func execute(pid: Int32, path: [String], json: Bool) -> Int32 {
        guard !Env.isolated else { return fail(isolationRefusal, json: json) }
        do {
            let reader = MenuReader(target: try MenuReader.target(pid: pid))
            let snapshot = try reader.scan()
            guard snapshot.complete else { throw ProductError("菜单读取不完整，未执行：" + snapshot.warnings.joined(separator: " ")) }
            let matches = snapshot.items.filter { $0.path == path }
            guard matches.count == 1 else { throw ProductError(matches.isEmpty ? "没有这条完整路径的命令，请重新读取菜单。" : "完整路径匹配到 \(matches.count) 条命令，未执行。") }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { throw ProductError("目标 App 不在前台，未执行命令。") }
            try reader.perform(matches[0])
            if json { printJSON(["ok": true, "executed": matches[0].fullPath, "pid": Int(snapshot.pid)]) } else { print("已执行：\(matches[0].fullPath)") }
            return 0
        } catch { return fail(describe(error), json: json) }
    }

    // MARK: config

    static func configuration(store: SettingsStore = SettingsStore()) -> AppConfiguration {
        let file = AppConfigurationFile(url: store.url, keys: ["mode", "hotkey"]) { try Settings.validate(field: $0) }
        return AppConfiguration(productID: Env.bundleID, files: [file])
    }

    /// The settings window's "使用 iCloud 记住配置" switch, read from the application's own preferences.
    private static var icloudSync: Bool {
        !Env.isolated && UserDefaults(suiteName: Env.bundleID)?.bool(forKey: "appLifecycle.configuration.enabled") == true
    }

    /// Asks GitHub for the latest published release; this is the only command that uses the network. With `install`
    /// the application itself downloads and verifies the package and swaps it in, as its settings window does.
    private static func update(install: Bool, json: Bool) -> Int32 {
        guard !Env.isolated else { return fail(isolationRefusal, json: json) }
        guard let bundle = Env.bundleURL else { return fail("这个命令要从安装好的 MenuSearch.app 里运行。", json: json) }
        var outcome: Result<AppRelease, Error>?
        AppUpdateChecker.check(source: UpdateChannel.current.updateSource, bundleID: Env.bundleID,
                               version: Env.version, build: Env.build) { result in DispatchQueue.main.async { outcome = result } }
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        guard let outcome else { return fail("读取发行记录超时。", json: json) }
        let release: AppRelease
        switch outcome {
        case .failure(let error): return fail("检查未完成：" + error.localizedDescription, json: json)
        case .success(let found): release = found
        }
        // A GitHub release is named by its version tag; the feed carries no build number ("0").
        let publishedBuild: String? = release.build == "0" ? nil : release.build
        let newer = release.isNewer(than: Env.version, build: Env.build)
        let installable = newer && AppUpgradeInstaller.supportsReplacement(release: release, currentBundle: bundle)
        var result: [String: Any] = ["ok": true, "channel": UpdateChannel.current.name, "newer": newer, "can_install": installable,
                                     "current": ["version": Env.version, "build": Env.build],
                                     "latest": ["version": release.version, "build": publishedBuild.map { $0 as Any } ?? NSNull()]]
        func report(_ text: String) -> Int32 { if json { printJSON(result) } else { print(text) }; return 0 }
        let current = "\(Env.version) (\(Env.build))", latest = publishedBuild.map { "\(release.version) (\($0))" } ?? release.version
        guard newer else {
            result["action"] = "none"
            return report("当前 \(current) 已是最新版（\(UpdateChannel.current.name) 上的正式版是 \(latest)）。")
        }
        guard install else { return report("有新版 \(latest)，当前 \(current)。运行 menusearch update --install 升级，配置会保留。") }
        guard installable else { return fail("这个发行包不能直接替换当前安装（\(latest)）。", json: json) }
        guard let reply = sendStartingApp(["cmd": "update"]), reply["ok"] as? Bool == true else {
            return fail("MenuSearch 没有响应，未升级。", json: json)
        }
        // The application verifies the package, hands over to the replacement helper and quits. The upgrade is done
        // when the bundle on disk reports the new version.
        let until = Date().addingTimeInterval(120)
        while Date() < until {
            usleep(500_000)
            let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            if info?["CFBundleShortVersionString"] as? String == release.version, let installed = info?["CFBundleVersion"] as? String,
               publishedBuild == nil || publishedBuild == installed {
                result["action"] = "upgraded"
                result["installed"] = ["version": release.version, "build": installed]
                return report("已从 \(current) 升级到 \(release.version) (\(installed))，配置保留。")
            }
            if let problem = Control.request(["cmd": "status"], timeout: 1)?["upgrade_error"] as? String {
                return fail("升级未完成，当前版本已保留：" + problem, json: json)
            }
        }
        return fail("升级在 2 分钟内没有完成；请运行 menusearch status 查看当前版本。", json: json)
    }

    private static func config(_ arguments: [String], json: Bool) throws -> Int32 {
        var rest = arguments
        guard let verb = rest.first else { throw Usage(message: "config 需要子命令：get、set、export、import、path。") }
        rest.removeFirst()
        let store = SettingsStore()
        switch verb {
        case "path":
            try none(rest)
            if json { printJSON(["ok": true, "path": store.url.path]) } else { print(store.url.path) }
            return 0
        case "get":
            try none(rest)
            let settings = store.load()
            if json {
                printJSON(["ok": true, "mode": settings.mode.rawValue,
                           "hotkey": settings.hotkey.map { ["display": $0.display, "key": $0.canonical] as [String: Any] } ?? NSNull(),
                           "icloud": icloudSync, "settings_error": store.loadError ?? NSNull()])
            } else {
                print("mode = \(settings.mode.rawValue)\nhotkey = \(settings.hotkey?.canonical ?? "none")\nicloud = \(icloudSync ? "on" : "off")")
                if let problem = store.loadError { fputs(problem + "\n", stderr) }
            }
            return 0
        case "set":
            guard rest.count == 2 else { throw Usage(message: "用法：config set <mode|hotkey|login|icloud> <值>。") }
            guard ["mode", "hotkey", "login", "icloud"].contains(rest[0]) else { throw Usage(message: "未知的配置项「\(rest[0])」。可用：mode、hotkey、login、icloud。") }
            let request: [String: Any] = ["cmd": "config", "key": rest[0], "value": rest[1]]
            let reply: [String: Any]
            if Env.isolated {
                // No live process may hold a system-wide key here: validate and store through the same code.
                let coordinator = Coordinator(store: store, testing: true)
                coordinator.registrar = NullRegistrar()
                coordinator.systemConflict = { _ in nil }; coordinator.registryConflict = { _ in nil }
                coordinator.declare = { _ in }; coordinator.terminate = {}
                coordinator.login = UnavailableLoginItem()
                coordinator.start()
                var result = coordinator.handle(request)
                result["state"] = nil
                result["applied"] = "stored_only"
                reply = result
            } else {
                guard let live = sendStartingApp(request) else { return fail("MenuSearch 没有响应，配置未更改。", json: json) }
                reply = live
            }
            let ok = reply["ok"] as? Bool == true
            if json { printJSON(reply) }
            else if ok { print("已设置 \(rest[0]) = \(rest[1])" + ((reply["notice"] as? String).map { "\n" + $0 } ?? "")) }
            else { fputs((reply["error"] as? String ?? "未能设置。") + "\n", stderr) }
            return ok ? 0 : 1
        case "export":
            guard rest.count <= 1 else { throw Usage(message: "用法：config export [文件]。") }
            let data = try configuration(store: store).exportData()
            if let path = rest.first, path != "-" {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                if json { printJSON(["ok": true, "path": path]) } else { print("已导出到 \(path)") }
            } else { print(String(data: data, encoding: .utf8) ?? "") }
            return 0
        case "import":
            guard rest.count == 1 else { throw Usage(message: "用法：config import <文件>。") }
            let data = try Data(contentsOf: URL(fileURLWithPath: rest[0]))
            try configuration(store: store).importData(data)
            // A running instance re-reads the file and re-registers its shortcut.
            let live = Env.isolated ? nil : Control.request(["cmd": "reload"])
            if json { printJSON(["ok": true, "reloaded_running_instance": live != nil]) } else { print("已导入；原配置已备份。") }
            return 0
        default:
            throw Usage(message: "未知的 config 子命令「\(verb)」。")
        }
    }
}
