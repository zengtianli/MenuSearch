#if APP_STORE
import AppKit
import ApplicationServices

/// Offscreen checks only for a renamed, sandboxed test copy. No permissions, hotkeys or login items are changed.
enum StoreSelfTest {
    private final class Registrar: HotkeyRegistering {
        var combo: Combo?
        func register(_ combo: Combo) -> Bool { self.combo = combo; return true }
        func unregister() { combo = nil }
    }
    private struct Login: LoginItem {
        var status: String { "test-unavailable" }
        var enabled: Bool { false }
        func set(_ on: Bool) throws { throw ProductError("离屏验证不更改登录项。") }
    }

    static func run() -> Never {
        let home = NSHomeDirectory()
        guard Bundle.main.bundleIdentifier == "test.tianli.menusearch.store",
              home.contains("/Containers/test.tianli.menusearch.store/Data") else {
            fputs("--store-self-test 只接受改名后的沙盒测试副本。\n", stderr); exit(2)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let probe = Env.supportDirectory.appendingPathComponent("store-self-test", isDirectory: true)
        setenv("APP_LIFECYCLE_SUPPORT_DIR", probe.appendingPathComponent("lifecycle").path, 1)
        var checks: [String: Bool] = [:]
        var error = ""
        do {
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            checks["container_support"] = Env.supportDirectory.path.hasPrefix(home + "/")
            let settings = SettingsStore(url: probe.appendingPathComponent("settings.json"))
            let combo = Combo(canonical: "ctrl+alt+m")!
            try settings.save(Settings(mode: .builtin, hotkey: combo))
            checks["settings_roundtrip"] = settings.load() == Settings(mode: .builtin, hotkey: combo)
            let file = AppConfigurationFile(url: settings.url, keys: ["mode", "hotkey"]) { try Settings.validate(field: $0) }
            let configuration = AppConfiguration(productID: Env.bundleID, files: [file])
            let exported = probe.appendingPathComponent("export.json")
            try StoreSettingsUI.export(configuration, to: exported)
            try settings.save(Settings(mode: .builtin, hotkey: nil))
            try StoreSettingsUI.load(configuration, from: exported)
            checks["configuration_export_import"] = settings.load().hotkey == combo
            let backups = probe.appendingPathComponent("lifecycle/" + Env.bundleID + "/Backups")
            checks["import_backup"] = !(try FileManager.default.contentsOfDirectory(atPath: backups.path)).isEmpty
            let foreign = try JSONSerialization.data(withJSONObject: ["version": 1, "product": "another.product", "values": [:]])
            checks["foreign_import_rejected"] = (try? configuration.importData(foreign)) == nil
            try settings.save(Settings(mode: .external, hotkey: combo))
            checks["download_external_mode_migrates"] = settings.load().mode == .builtin && settings.load().hotkey == combo

            let coordinator = Coordinator(store: settings, testing: true)
            coordinator.registrar = Registrar(); coordinator.login = Login()
            coordinator.systemConflict = { _ in nil }; coordinator.terminate = {}
            coordinator.start()
            checks["hotkey_transaction"] = coordinator.registrar.combo == combo && coordinator.staysResident
            checks["external_mode_rejected"] = {
                if case .failure = coordinator.setMode(.external) { return true }; return false
            }()
            coordinator.installSettingsWindow()
            let labels = try StoreSettingsUI.shared.offscreenSnapshot(to: probe.appendingPathComponent("settings.png"))
            checks["settings_rendered"] = try Data(contentsOf: probe.appendingPathComponent("settings.png")).count > 10_000
            checks["settings_no_update_or_cli_controls"] = !labels.contains { $0.contains("检查更新") || $0.contains("升级到新版") || $0.contains("外部呼出") || $0.contains("拷贝命令") }
            checks["settings_transfer_visible"] = labels.contains("导出配置…") && labels.contains("导入配置…")
            checks["permission_guidance"] = labels.contains("辅助功能") && coordinator.productSettings?.accessButton.title.contains("系统设置") == true
            let command = MenuCommand(id: "fixture", title: "Export as PDF…", path: ["File", "Export as PDF…"], shortcut: "", enabled: true, checked: false)
            checks["core_menu_filter"] = MenuSearchIndex([command]).filter("exp pdf").first?.id == "fixture"
            let panel = PanelController(testing: true)
            // Invokes the production presentation directly, without changing TCC or scanning another app.
            panel.presentAccessibilityGuidance()
            checks["missing_permission_is_not_empty_list"] = panel.message.stringValue.contains("辅助功能") && !panel.accessibilityButton.isHidden
            panel.close()
            checks["bundled_tuning_read"] = Env.resourcesURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tuning.json").path) } ?? false
        } catch let caught { error = caught.localizedDescription }
        checks["offscreen_no_dock"] = NSApp.activationPolicy() == .prohibited && !NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible }
        let passed = error.isEmpty && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let result: [String: Any] = ["ok": passed, "home": home, "support": Env.supportDirectory.path,
            "probe": probe.path, "sandbox_container": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "",
            "pid": Int(getpid()), "checks": checks, "failed": checks.filter { !$0.value }.keys.sorted(), "error": error,
            "external_actions": 0, "accessibility": AXIsProcessTrusted(),
            "limitations": ["真实辅助功能授权、菜单读取与执行、快捷键送达、SMAppService 登录注册、系统文件面板授权、iCloud 跨设备同步未测。"]]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: probe.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
        }
        exit(passed ? 0 : 1)
    }
}
#endif
