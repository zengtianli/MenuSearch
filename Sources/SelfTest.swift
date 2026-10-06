import AppKit

/// `MenuSearch --self-test --output DIR [--pid N]`: the production panel, settings window, shortcut and mode logic,
/// control socket and stores, run offscreen in an isolated support directory. Nothing is shown, no key is
/// registered with the system, no login item is touched and no other application's menu is executed.
/// With --pid the panel is additionally rendered from that application's real menu (a read).
enum SelfTest {
    private final class FakeRegistrar: HotkeyRegistering {
        private(set) var combo: Combo?
        var refused: Set<String> = []
        func register(_ combo: Combo) -> Bool {
            self.combo = nil
            guard !refused.contains(combo.canonical) else { return false }
            self.combo = combo
            return true
        }
        func unregister() { combo = nil }
    }
    private final class FakeLogin: LoginItem {
        var on = false
        var status: String { on ? "enabled" : "disabled" }
        var enabled: Bool { on }
        func set(_ value: Bool) throws { on = value }
    }
    private final class Counter { var value = 0 }

    private static func succeeded(_ result: Result<String?, ProductError>) -> Bool { if case .success = result { return true }; return false }

    /// The compositor supplies the blurred backdrop on screen; offscreen the window background stands in for it.
    private static func render(_ controller: PanelController, to url: URL, appearance name: NSAppearance.Name) throws -> Bool {
        guard let appearance = NSAppearance(named: name), let view = controller.panel.contentView else { return false }
        controller.panel.appearance = appearance
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            bitmap.size = view.bounds.size
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSBezierPath(roundedRect: view.bounds, xRadius: PanelController.cornerRadius, yRadius: PanelController.cornerRadius).addClip()
            NSColor.windowBackgroundColor.setFill(); view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
        try png?.write(to: url)
        return (png?.count ?? 0) > 10_000
    }

    static func run(arguments: [String]) -> Never {
        guard Env.isolated, let lifecycle = ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"], !lifecycle.isEmpty else {
            fputs("--self-test 只在隔离目录里运行：把 MENUSEARCH_SUPPORT_DIR 和 APP_LIFECYCLE_SUPPORT_DIR 设为临时目录。\n", stderr); exit(2)
        }
        guard let index = arguments.firstIndex(of: "--output"), arguments.count > index + 1 else {
            fputs("--self-test 需要 --output DIR\n", stderr); exit(2)
        }
        let out = URL(fileURLWithPath: arguments[index + 1])
        let realPID = arguments.firstIndex(of: "--pid").flatMap { arguments.count > $0 + 1 ? Int32(arguments[$0 + 1]) : nil }
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks: [String: Bool] = [:]
        var metrics: [String: Any] = [:]
        var notes: [String] = []
        var failure = ""
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Env.ensureSupportDirectory()
            try panelChecks(&checks, &metrics, &notes, out: out, realPID: realPID)
            try logicChecks(&checks, out: out)
        } catch { failure = error.localizedDescription }
        checks["never_on_screen"] = !NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible }
        let passed = failure.isEmpty && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let result: [String: Any] = [
            "ok": passed, "environment": "offscreen-production-views", "external_actions": 0, "version": Env.version, "build": Env.build,
            "checks": checks, "failed": checks.filter { !$0.value }.keys.sorted(), "metrics": metrics, "notes": notes, "error": failure,
            "limitations": ["真实热键送达、对其他 App 菜单的实际执行、输入法真实组词、窗口上屏后的观感不在这里验证，需要在真实桌面上确认。"]]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("self-test.json"))
            print(String(decoding: data, as: UTF8.self))
        }
        exit(passed ? 0 : 1)
    }

    /// `MenuSearch --site-shots --output DIR`: the product page's screenshots, rendered offscreen from the production
    /// panel and settings window in an isolated support directory. The menu shown is fixed demo data.
    static func siteShots(arguments: [String]) -> Never {
        guard Env.isolated, let lifecycle = ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"], !lifecycle.isEmpty,
              let index = arguments.firstIndex(of: "--output"), arguments.count > index + 1 else {
            fputs("--site-shots 需要 --output DIR，并且只在隔离目录里运行（MENUSEARCH_SUPPORT_DIR 与 APP_LIFECYCLE_SUPPORT_DIR）。\n", stderr); exit(2)
        }
        let out = URL(fileURLWithPath: arguments[index + 1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        func item(_ id: Int, _ title: String, _ path: [String], _ shortcut: String = "", enabled: Bool = true, checked: Bool = false) -> MenuCommand {
            MenuCommand(id: String(id), title: title, path: path + [title], shortcut: shortcut, enabled: enabled, checked: checked)
        }
        let demo = [
            item(0, "New Window", ["File"], "⌘N"), item(1, "New Private Window", ["File"], "⇧⌘N"),
            item(2, "Export as PDF…", ["File"]), item(3, "Use Selection for Find", ["Edit", "Find"], "⌘E", enabled: false),
            item(4, "Show Tab Overview", ["View"], "⇧⌘\\"), item(5, "Show Status Bar", ["View"], "⌘/", checked: true),
            item(6, "Show JavaScript Console", ["Develop"], "⌥⌘C"), item(7, "Reopen Last Closed Tab", ["History"], "⇧⌘T"),
            item(8, "Add Bookmark…", ["Bookmarks"], "⌘D"), item(9, "Show Previous Tab", ["Window"], "⌃⇧⇥"),
            item(10, "Show Next Tab", ["Window"], "⌃⇥"), item(11, "Duplicate Tab", ["Window"]),
            item(12, "Pin Tab", ["Window"]), item(13, "Move Tab to New Window", ["Window"]),
            item(14, "Merge All Windows", ["Window"]), item(15, "Safari Help", ["Help"])]
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari").map { NSWorkspace.shared.icon(forFile: $0.path) }
        var written: [String: Bool] = [:]
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Env.ensureSupportDirectory()
            let list = PanelController(testing: true)
            list.presentFixture(snapshot(demo), icon: icon)
            written["panel.png"] = try render(list, to: out.appendingPathComponent("panel.png"), appearance: .aqua)
            let search = PanelController(testing: true)
            search.presentFixture(snapshot(demo), icon: icon)
            search.search.stringValue = "tab"; search.filter()
            written["panel-search-dark.png"] = try render(search, to: out.appendingPathComponent("panel-search-dark.png"), appearance: .darkAqua)
            let coordinator = Coordinator(store: SettingsStore(), testing: true)
            coordinator.registrar = FakeRegistrar(); coordinator.login = FakeLogin()
            coordinator.systemConflict = { _ in nil }; coordinator.registryConflict = { _ in nil }
            coordinator.declare = { _ in }; coordinator.terminate = {}
            coordinator.start()
            _ = coordinator.setHotkey(Combo(canonical: "alt+m"))
            coordinator.installSettingsWindow()
            let settings = try AppLifecycleUI.shared.offscreenSnapshot(to: out.appendingPathComponent("settings.png"), appearance: .aqua)
            written["settings.png"] = !settings.isEmpty && settings.values.allSatisfy { $0 }
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        let ok = written.count == 3 && written.values.allSatisfy { $0 } && NSApp.windows.allSatisfy { !$0.isVisible }
        CLI.printJSON(["ok": ok, "files": written, "version": Env.version, "build": Env.build, "data": "fixed demo menu"])
        exit(ok ? 0 : 1)
    }

    private static let fixture: [MenuCommand] = [
        MenuCommand(id: "0", title: "Export as PDF…", path: ["File", "Export as PDF…"], shortcut: "⇧⌘E", enabled: true, checked: false),
        MenuCommand(id: "1", title: "JavaScript Console", path: ["View", "Developer", "JavaScript Console"], shortcut: "⌥⌘J", enabled: true, checked: false),
        MenuCommand(id: "2", title: "Use Selection for Find", path: ["Edit", "Find", "Use Selection for Find"], shortcut: "⌘E", enabled: false, checked: false),
        MenuCommand(id: "3", title: "写笔记", path: ["文件", "写笔记"], shortcut: "⌘N", enabled: true, checked: false),
        MenuCommand(id: "4", title: "Date Modified", path: ["View", "Group Stacks By", "Date Modified"], shortcut: "", enabled: true, checked: true),
        MenuCommand(id: "5", title: "Date Modified", path: ["View", "Sort Stacks By", "Date Modified"], shortcut: "", enabled: true, checked: false),
        MenuCommand(id: "6", title: "Date Modified", path: ["View", "Clean Up By", "Date Modified"], shortcut: "", enabled: true, checked: false)
    ]
    private static func snapshot(_ items: [MenuCommand], complete: Bool = true, warnings: [String] = []) -> MenuSnapshot {
        MenuSnapshot(ok: true, pid: 0, app: "Safari", bundleID: "fixture", durationMS: 168, complete: complete, warnings: warnings, items: items)
    }

    private static func panelChecks(_ checks: inout [String: Bool], _ metrics: inout [String: Any], _ notes: inout [String],
                                    out: URL, realPID: Int32?) throws {
        let items = fixture
        let ui = PanelController(testing: true)
        ui.presentFixture(snapshot(items))
        func type(_ text: String) {
            ui.search.stringValue = text
            ui.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
        func key(_ selector: String, _ editor: NSTextView) -> Bool { ui.control(ui.search, textView: editor, doCommandBy: NSSelectorFromString(selector)) }
        checks["empty_lists_all"] = ui.shown.count == items.count
        checks["header_names_target"] = ui.header.stringValue.contains("Safari") && ui.header.stringValue.contains("7")
            && ui.state.stringValue.contains("Safari") && ui.panel.title.contains("Safari")
        checks["distinct_duplicate_paths"] = Set(MenuSearchIndex(items).filter("date modified").map(\.fullPath)).count == 3
        checks["fuzzy_multi_token"] = MenuSearchIndex(items).filter("exp pdf").first?.id == "0"
        checks["path_search"] = MenuSearchIndex(items).filter("view developer").first?.id == "1"
        checks["chinese"] = MenuSearchIndex(items).filter("写笔记").first?.id == "3"
        type("use selection"); ui.executeSelection()
        checks["disabled_not_executed"] = ui.testExecuted.isEmpty && ui.shown.first?.id == "2"
        type("exp pdf")
        let editor = NSTextView()
        _ = key("insertNewline:", editor)
        checks["enter_dispatch"] = ui.testExecuted == ["0"]
        type("")
        _ = key("moveDown:", editor)
        checks["down_browses"] = ui.table.selectedRow == 1
        _ = key("moveUp:", editor)
        checks["up_browses"] = ui.table.selectedRow == 0
        checks["editing_preserved"] = !key("deleteWordBackward:", editor) && !key("moveToBeginningOfLine:", editor)
        editor.setMarkedText("写", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        checks["ime_return_preserved"] = !key("insertNewline:", editor) && ui.testExecuted == ["0"]
        checks["ime_escape_preserved"] = !key("cancelOperation:", editor) && ui.active
        editor.unmarkText()
        type("zzzz no such command")
        checks["no_match_is_stated"] = ui.shown.isEmpty && !ui.message.isHidden && ui.table.selectedRow == -1
        ui.executeSelection()
        checks["nothing_selected_not_executed"] = ui.testExecuted == ["0"]
        ui.presentFixture(snapshot([items[0]], complete: false, warnings: ["部分菜单暂未响应，请刷新后重试。"]))
        checks["incomplete_is_stated"] = ui.state.stringValue.contains("不完整")
        let updated = MenuCommand(id: "0", title: "Hide Status Bar", path: ["View", "Hide Status Bar"], shortcut: "⌘/", enabled: true, checked: false)
        ui.presentFixture(snapshot([updated]))
        checks["fresh_dynamic_titles"] = ui.shown.first?.title == "Hide Status Bar" && !ui.shown.contains { $0.title.contains("Export") }
        checks["keycaps_split_modifiers"] = KeycapsView.tokens("⇧⌘,") == ["⇧", "⌘", ","] && KeycapsView.tokens("⌃⌥Space") == ["⌃", "⌥", "Space"]
            && KeycapsView.tokens("F5") == ["F5"] && KeycapsView.tokens("⌘") == ["⌘"]
        _ = key("cancelOperation:", editor)
        checks["esc_closes_panel_only"] = !ui.active && ui.testClosed == 1 && ui.shown.isEmpty

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let preview = PanelController(testing: true)
            preview.presentFixture(snapshot(items))
            checks["render_\(name)"] = try render(preview, to: out.appendingPathComponent("panel-\(name).png"), appearance: appearance)
            preview.search.stringValue = "date"; preview.filter()
            checks["render_filtered_\(name)"] = try render(preview, to: out.appendingPathComponent("panel-filtered-\(name).png"), appearance: appearance)
        }
        if let realPID {
            do {
                let target = try MenuReader.target(pid: realPID)
                let real = try MenuReader(target: target).scan()
                let name = real.app.replacingOccurrences(of: " ", with: "-")
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let preview = PanelController(testing: true)
                    preview.presentFixture(real, icon: target.icon)
                    checks["render_native_\(suffix)"] = try render(preview, to: out.appendingPathComponent("native-\(name)-\(suffix).png"), appearance: appearance)
                }
                metrics["native_scan"] = ["app": real.app, "count": real.items.count, "scan_ms": (real.durationMS * 10).rounded() / 10, "complete": real.complete]
            } catch { notes.append("未渲染真实菜单（--pid \(realPID)）：\(error.localizedDescription)") }
        }

        // Typing into a 1000-command list: the production filter, table reload and layout.
        var big: [MenuCommand] = []
        let words = ["Export", "Import", "Show", "Hide", "Toggle", "写笔记", "未读"]
        for i in 0..<1000 {
            let title = "\(words[i % words.count]) Command \(i)"
            big.append(MenuCommand(id: String(i), title: title, path: ["Menu \(i % 12)", "Group \(i % 31)", title],
                                   shortcut: i % 5 == 0 ? "⇧⌘K" : "", enabled: i % 9 != 0, checked: i % 13 == 0))
        }
        let load = PanelController(testing: true)
        load.presentFixture(snapshot(big))
        var samples: [Double] = []
        let queries = ["e", "ex", "exp", "exp 1", "show 12", "写", "写笔记", "menu 3 hide", "tgl", "cmd 99", "未读", "import group 7", "", "h", "hid"]
        for _ in 0..<8 {
            for query in queries {
                let start = DispatchTime.now().uptimeNanoseconds
                load.search.stringValue = query
                load.filter()
                load.panel.contentView?.layoutSubtreeIfNeeded()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        metrics["filter"] = ["items": big.count, "samples": samples.count, "p50_ms": (samples[samples.count / 2] * 100).rounded() / 100,
                             "p95_ms": (p95 * 100).rounded() / 100, "max_ms": ((samples.last ?? 0) * 100).rounded() / 100,
                             "method": "offscreen production filter + table reload + layout"]
        checks["filter_1000_within_budget"] = p95 <= 50
        load.close()
    }

    private static func logicChecks(_ checks: inout [String: Bool], out: URL) throws {
        let files = FileManager.default
        let items = fixture
        let altM = Combo(canonical: "alt+m")!
        checks["combo_forms_agree"] = Combo(canonical: "⌥M") == altM && Combo(canonical: "Option+M") == altM && altM.display == "⌥M"
            && altM.canonical == "alt+m" && altM.keyCode == 46 && altM.carbonModifiers == 2048
        checks["combo_needs_modifier"] = Combo(canonical: "m") == nil && Combo(canonical: "shift+m") == nil
            && Combo(canonical: "f5") != nil && Combo(canonical: "cmd+nonsense") == nil && Combo(canonical: "hyper+m") == nil
        checks["combo_round_trip"] = Combo(json: altM.json) == altM && Combo(canonical: "cmd+shift+space")?.display == "⇧⌘Space"
            && Combo(canonical: "ctrl+alt+f5")?.canonical == "ctrl+alt+f5"

        // Mode and shortcut transactions against a stand-in for the system registration.
        let directory = Env.supportDirectory.appendingPathComponent("lifecycle", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        let coordinator = Coordinator(store: store, testing: true)
        let registrar = FakeRegistrar(), login = FakeLogin(), quits = Counter()
        coordinator.registrar = registrar; coordinator.login = login
        coordinator.systemConflict = { $0.canonical == "ctrl+up" ? "\($0.display) 已是 macOS 的系统快捷键。" : nil }
        coordinator.registryConflict = { _ in nil }; coordinator.declare = { _ in }
        coordinator.terminate = { quits.value += 1 }
        // What the product asked to show: (Dock and ⌘Tab, menu bar icon).
        var presented: [[Bool]] = []
        coordinator.present = { presented.append([$0, $1]) }
        coordinator.start()
        func stored() -> Settings { SettingsStore(url: store.url).load() }

        checks["first_run_has_no_hotkey"] = coordinator.settings == Settings() && registrar.combo == nil && !coordinator.staysResident
        checks["one_shot_process_stays_out_of_dock"] = presented.last == [false, false]
        checks["hotkey_set_registers"] = succeeded(coordinator.setHotkey(altM)) && registrar.combo == altM && coordinator.staysResident && stored().hotkey == altM
        checks["resident_shows_in_dock_and_menu_bar"] = presented.last == [true, true]
        coordinator.panel.presentFixture(snapshot(items)); coordinator.panel.close()
        checks["builtin_close_keeps_listening"] = quits.value == 0 && registrar.combo == altM && coordinator.panel.testClosed == 1
        coordinator.panel.presentFixture(snapshot(items))
        checks["panel_reusable_after_close"] = coordinator.panel.shown.count == items.count && coordinator.panelActive
        coordinator.panel.close()
        checks["close_releases_menu_data"] = coordinator.panel.shown.isEmpty && coordinator.panel.snapshot == nil
            && coordinator.panel.reader == nil && coordinator.panel.search.stringValue.isEmpty
        registrar.refused = ["cmd+space"]
        checks["refused_hotkey_keeps_previous"] = !succeeded(coordinator.setHotkey(Combo(canonical: "cmd+space")!))
            && registrar.combo == altM && coordinator.settings.hotkey == altM && stored().hotkey == altM
        checks["system_hotkey_refused"] = !succeeded(coordinator.setHotkey(Combo(canonical: "ctrl+up")!)) && registrar.combo == altM && stored().hotkey == altM
        checks["refused_hotkey_keeps_presence"] = presented.last == [true, true]
        // Chosen in the ⌘Tab switcher with nothing on screen: the settings window comes up; closing it changes nothing else.
        quits.value = 0
        coordinator.activated()
        checks["switcher_opens_settings"] = coordinator.settingsVisible && presented.last == [true, true]
        coordinator.settingsClosed()
        checks["resident_survives_settings_close"] = !coordinator.settingsVisible && quits.value == 0 && registrar.combo == altM && presented.last == [true, true]
        coordinator.panel.presentFixture(snapshot(items))
        coordinator.activated()
        checks["activation_leaves_open_panel_alone"] = !coordinator.settingsVisible && coordinator.panelActive
        coordinator.panel.close()
        let own = coordinator.show(pid: getpid(), source: "test")
        checks["own_window_is_not_a_target"] = own["action"] as? String == "message_shown" && coordinator.panelActive && coordinator.panel.reader == nil
        checks["second_call_closes"] = coordinator.show(pid: getpid(), source: "test")["action"] as? String == "closed" && !coordinator.panelActive
        checks["exited_target_rejected"] = (try? coordinator.resolveTarget(pid: 2_000_000_000)) == nil

        login.on = true
        checks["external_stops_shortcut_source"] = succeeded(coordinator.setMode(.external)) && registrar.combo == nil
            && coordinator.settings.mode == .external && stored().mode == .external && stored().hotkey == altM
        checks["external_turns_login_off"] = !login.on
        checks["external_leaves_dock_and_menu_bar"] = presented.last == [false, false]
        checks["login_needs_builtin"] = !succeeded(coordinator.setLogin(true)) && !login.on
        quits.value = 0
        coordinator.panel.presentFixture(snapshot(items)); coordinator.panel.close()
        checks["external_exits_after_panel"] = quits.value == 1
        quits.value = 0
        coordinator.openSettings()
        coordinator.panel.presentFixture(snapshot(items)); coordinator.panel.close()
        checks["settings_window_keeps_process"] = quits.value == 0
        checks["settings_window_shows_in_dock_only"] = presented.last == [true, false]
        coordinator.settingsClosed()
        checks["external_exits_after_settings"] = quits.value == 1 && presented.last == [false, false]
        registrar.refused = ["alt+m"]
        checks["failed_builtin_switch_rolls_back"] = !succeeded(coordinator.setMode(.builtin)) && coordinator.settings.mode == .external
            && stored().mode == .external && registrar.combo == nil
        registrar.refused = []
        checks["builtin_switch_registers"] = succeeded(coordinator.setMode(.builtin)) && registrar.combo == altM && stored().mode == .builtin
        checks["login_on_in_builtin"] = succeeded(coordinator.setLogin(true)) && login.on
        checks["builtin_switch_returns_to_dock"] = presented.last == [true, true]
        checks["hotkey_clear"] = succeeded(coordinator.setHotkey(nil)) && registrar.combo == nil && stored().hotkey == nil && !coordinator.staysResident
        checks["hotkey_clear_leaves_dock"] = presented.last == [false, false]

        // The menu under the menu bar icon, and the shortcut as a menu shows it.
        let barMenu = NSMenu()
        MenuBarMenu.fill(barMenu, hotkey: altM, target: nil)
        checks["menu_bar_menu_has_search_settings_quit"] = barMenu.items.map(\.title) == ["搜索当前 App 的菜单", "", "设置…", "", "退出 MenuSearch"]
            && barMenu.items.allSatisfy { $0.isSeparatorItem || $0.action != nil }
            && barMenu.items[0].keyEquivalent == "m" && barMenu.items[0].keyEquivalentModifierMask == .option
        let spaceKey = Combo(canonical: "cmd+shift+space")!.menuEquivalent, functionKey = Combo(canonical: "ctrl+f5")!.menuEquivalent
        checks["shortcut_as_menu_equivalent"] = spaceKey?.0 == " " && spaceKey?.1 == [.command, .shift]
            && functionKey?.0.unicodeScalars.first?.value == UInt32(NSF5FunctionKey) && functionKey?.1 == .control
            && Combo(canonical: "alt+comma")!.menuEquivalent?.0 == ","
        checks["menu_bar_symbol_exists"] = NSImage(systemSymbolName: MenuBarMenu.symbol, accessibilityDescription: nil) != nil
        // The bundle itself declares a background application, so one-shot runs and these tests never enter the Dock;
        // only the instance that stays is promoted.
        checks["bundle_starts_in_background"] = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true

        // The upgrade and the iCloud switch act on the installed application; an isolated run refuses both.
        checks["isolated_run_cannot_upgrade_or_flip_icloud"] = coordinator.handle(["cmd": "update"])["ok"] as? Bool == false
            && coordinator.handle(["cmd": "config", "key": "icloud", "value": "on"])["ok"] as? Bool == false
            && !FileManager.default.fileExists(atPath: Env.quietRelaunchURL.path)

        // A change that cannot be saved is not left half applied.
        let blocked = Env.supportDirectory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let unsaved = Coordinator(store: SettingsStore(url: blocked.appendingPathComponent("settings.json")), testing: true)
        let unsavedRegistrar = FakeRegistrar()
        unsaved.registrar = unsavedRegistrar; unsaved.login = FakeLogin()
        unsaved.systemConflict = { _ in nil }; unsaved.registryConflict = { _ in nil }; unsaved.declare = { _ in }; unsaved.terminate = {}
        unsaved.start()
        checks["unsaved_change_not_applied"] = !succeeded(unsaved.setHotkey(altM)) && unsavedRegistrar.combo == nil && unsaved.settings.hotkey == nil
            && !succeeded(unsaved.setMode(.external)) && unsaved.settings.mode == .builtin

        // Damaged settings: defaults are used and the damaged file is kept.
        let damagedDirectory = Env.supportDirectory.appendingPathComponent("damaged", isDirectory: true)
        try files.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        let damaged = SettingsStore(url: damagedDirectory.appendingPathComponent("settings.json"))
        try Data("{ not json".utf8).write(to: damaged.url)
        checks["damaged_settings_fall_back"] = damaged.load() == Settings() && damaged.loadError != nil
        try damaged.save(Settings(mode: .external, hotkey: altM))
        checks["damaged_settings_are_kept"] = try files.contentsOfDirectory(atPath: damagedDirectory.path).contains { $0.hasPrefix("settings.corrupt-") }
            && damaged.load() == Settings(mode: .external, hotkey: altM) && damaged.loadError == nil
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: damaged.url)) as? [String: Any] ?? [:]
        object["future_field"] = "kept"
        try JSONSerialization.data(withJSONObject: object).write(to: damaged.url)
        try damaged.save(Settings(mode: .builtin, hotkey: nil))
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: damaged.url)) as? [String: Any] ?? [:]
        checks["unknown_fields_survive"] = rewritten["future_field"] as? String == "kept" && rewritten["hotkey"] == nil && rewritten["mode"] as? String == "builtin"
        try Data("{\"mode\":\"sometimes\"}".utf8).write(to: damaged.url)
        checks["invalid_mode_falls_back"] = damaged.load() == Settings() && damaged.loadError != nil

        // Values that follow macOS: an override file changes single keys, nonsense is clamped or ignored.
        let override = Env.supportDirectory.appendingPathComponent("tuning-test.json")
        try Data("{\"skip_top_level_titles\":[\"Apple\",\"蘋果\"],\"scan_deadline_seconds\":999,\"max_items\":\"many\"}".utf8).write(to: override)
        let tuned = Tuning.load(bundled: nil, override: override)
        checks["tuning_override_applies"] = tuned.skipTopLevelTitles == ["Apple", "蘋果"] && tuned.scanDeadlineSeconds == 30 && tuned.maxItems == 10_000
        try Data("garbage".utf8).write(to: override)
        checks["tuning_bad_file_falls_back"] = Tuning.load(bundled: nil, override: override) == Tuning()
        if let bundled = Env.resourcesURL?.appendingPathComponent("tuning.json"), files.fileExists(atPath: bundled.path) {
            checks["tuning_shipped_file_read"] = Tuning.load(bundled: bundled, override: nil) == Tuning()
        }

        // The optional cross-application key registry.
        let registry = Env.supportDirectory.appendingPathComponent("keys.d", isDirectory: true)
        try files.createDirectory(at: registry, withIntermediateDirectories: true)
        let row: [[String: Any]] = [["component": "otherapp", "mode": "global", "key": "⌥M", "description": "别的功能"]]
        try JSONSerialization.data(withJSONObject: row).write(to: registry.appendingPathComponent("otherapp.json"))
        try JSONSerialization.data(withJSONObject: row).write(to: registry.appendingPathComponent(KeyConflicts.registryFile))
        checks["registry_conflict_reported"] = KeyConflicts.registered(altM, in: registry)?.contains("otherapp") == true
            && KeyConflicts.registered(Combo(canonical: "alt+k")!, in: registry) == nil
        func declared() -> [[String: Any]] {
            ((try? JSONSerialization.jsonObject(with: Data(contentsOf: registry.appendingPathComponent(KeyConflicts.registryFile)))) as? [[String: Any]]) ?? []
        }
        KeyConflicts.declare(Settings(mode: .builtin, hotkey: altM), in: registry)
        let whileBuiltin = declared().contains { $0["mode"] as? String == "global" && $0["key"] as? String == "alt+m" }
        KeyConflicts.declare(Settings(mode: .external, hotkey: altM), in: registry)
        checks["registry_declares_only_active_key"] = whileBuiltin && !declared().contains { $0["mode"] as? String == "global" } && !declared().isEmpty

        let skhdrc = Env.supportDirectory.appendingPathComponent("skhdrc")
        try Data("# comment\nctrl + shift - 0x29 : echo right\nlalt - k : echo left-only\nalt - m : \"/Applications/Other.app/Contents/MacOS/Other\" --menu\nhyper - f12 : echo hyper\n".utf8).write(to: skhdrc)
        checks["skhd_binding_reported"] = KeyConflicts.skhd(altM, files: [skhdrc])?.contains("Other.app") == true
            && KeyConflicts.skhd(Combo(canonical: "ctrl+shift+semicolon")!, files: [skhdrc]) != nil
            && KeyConflicts.skhd(Combo(canonical: "cmd+ctrl+alt+shift+f12")!, files: [skhdrc]) != nil
            && KeyConflicts.skhd(Combo(canonical: "alt+k")!, files: [skhdrc]) == nil
            && KeyConflicts.skhd(altM, files: [Env.supportDirectory.appendingPathComponent("no-such-file")]) == nil

        // Single instance and the control socket.
        let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("menusearch-selftest-\(getpid()).sock")
        let lockPath = Env.supportDirectory.appendingPathComponent("selftest.lock").path
        let server = ControlServer(lockPath: lockPath, socketPath: socketPath)
        checks["instance_lock_acquired"] = server.acquire()
        checks["second_instance_refused"] = !ControlServer(lockPath: lockPath, socketPath: socketPath).acquire() && Control.primaryHoldsLock(lockPath: lockPath)
        server.handler = { coordinator.handle($0) }
        try server.listen()
        func ask(_ request: [String: Any]) -> [String: Any]? {
            var reply: [String: Any]?
            var done = false
            DispatchQueue.global().async {
                let answer = Control.request(request, socketPath: socketPath, timeout: 3)
                DispatchQueue.main.async { reply = answer; done = true }
            }
            let deadline = Date().addingTimeInterval(6)
            while !done && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return reply
        }
        let live = ask(["cmd": "status"])
        checks["socket_status"] = live?["running"] as? Bool == true && live?["mode"] as? String == "builtin" && live?["hotkey_registered"] as? Bool == false
        checks["socket_config_applies"] = ask(["cmd": "config", "key": "hotkey", "value": "alt+k"])?["ok"] as? Bool == true
            && registrar.combo?.canonical == "alt+k" && stored().hotkey?.canonical == "alt+k"
        registrar.refused = ["cmd+space"]
        checks["socket_refusal_reported"] = ask(["cmd": "config", "key": "hotkey", "value": "cmd+space"])?["ok"] as? Bool == false && registrar.combo?.canonical == "alt+k"
        checks["socket_bad_requests_rejected"] = ask(["cmd": "config", "key": "mode", "value": "sometimes"])?["ok"] as? Bool == false
            && ask(["cmd": "config", "key": "hotkey", "value": "m"])?["ok"] as? Bool == false && ask(["cmd": "nonsense"])?["ok"] as? Bool == false
            && coordinator.settings.mode == .builtin
        checks["socket_show_rejects_own_window"] = ask(["cmd": "show", "pid": Int(getpid())])?["action"] as? String == "message_shown" && coordinator.panelActive
        coordinator.panel.close()
        server.stop()
        checks["socket_closed_is_silent"] = Control.request(["cmd": "status"], socketPath: socketPath, timeout: 1) == nil
            && !files.fileExists(atPath: socketPath) && !Control.primaryHoldsLock(lockPath: lockPath)

        // The settings window: the shared shell with this product's groups, built by the code the user's click runs.
        coordinator.installSettingsWindow()
        let light = try AppLifecycleUI.shared.offscreenSnapshot(to: out.appendingPathComponent("settings-light.png"), appearance: .aqua)
        let dark = try AppLifecycleUI.shared.offscreenSnapshot(to: out.appendingPathComponent("settings-dark.png"), appearance: .darkAqua)
        checks["settings_render_light"] = !light.isEmpty && light.values.allSatisfy { $0 }
        checks["settings_render_dark"] = !dark.isEmpty && dark.values.allSatisfy { $0 }
        if let product = coordinator.productSettings {
            checks["settings_reflect_state"] = product.modePopup.titleOfSelectedItem == Mode.builtin.title && product.recorder.title == "⌥K"
                && product.loginSwitch.isEnabled && product.clearButton.isEnabled
            product.recordForTest(Combo(canonical: "cmd+space")!)
            checks["settings_refusal_keeps_previous"] = product.hotkeyDetail.stringValue.contains("占用") && product.recorder.title == "⌥K"
                && registrar.combo?.canonical == "alt+k"
            product.recordForTest(altM)
            checks["settings_record_applies"] = product.recorder.title == "⌥M" && registrar.combo == altM && stored().hotkey == altM
            _ = try AppLifecycleUI.shared.offscreenSnapshot(to: out.appendingPathComponent("settings-recorded-light.png"), appearance: .aqua)
        } else { checks["settings_reflect_state"] = false }

        // Configuration export and import, through the same object the window and `menusearch config` use.
        let transfer = CLI.configuration(store: store)
        let exported = try transfer.exportData()
        _ = coordinator.setHotkey(Combo(canonical: "alt+k")!)
        _ = coordinator.setMode(.external)
        try transfer.importData(exported)
        coordinator.reloadFromDisk()
        checks["config_export_import_restores"] = coordinator.settings == Settings(mode: .builtin, hotkey: altM) && registrar.combo == altM
        let invalid = try JSONSerialization.data(withJSONObject: ["version": 1, "product": Env.bundleID, "values": ["file.0.mode": "sometimes"]])
        let foreign = try JSONSerialization.data(withJSONObject: ["version": 1, "product": "cyou.tianli.mackit", "values": ["file.0.mode": "external"]])
        checks["config_import_rejects_invalid"] = (try? transfer.importData(invalid)) == nil && (try? transfer.importData(foreign)) == nil
            && stored() == Settings(mode: .builtin, hotkey: altM)
        let text = String(decoding: exported, as: UTF8.self)
        checks["config_export_has_only_preferences"] = text.contains("file.0.mode") && text.contains("file.0.hotkey")
            && !text.contains(NSHomeDirectory()) && !text.contains("pid") && !text.contains("last_show")
    }
}
