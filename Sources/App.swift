import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

protocol LoginItem {
    var status: String { get }
    var enabled: Bool { get }
    func set(_ on: Bool) throws
}

struct SystemLoginItem: LoginItem {
    var status: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        // Before the first registration the system answers "not found" for the application itself.
        case .notRegistered, .notFound: return "disabled"
        case .requiresApproval: return "requires_approval"
        @unknown default: return "unknown"
        }
    }
    var enabled: Bool { SMAppService.mainApp.status == .enabled }
    func set(_ on: Bool) throws { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
}

/// The one place that decides how the panel is summoned and whether the process stays. The settings window, the
/// shortcut callback and every command-line request go through these methods, so a change and its rollback are
/// the same code whoever asks.
final class Coordinator: NSObject {
    let store: SettingsStore
    private(set) var settings = Settings()
    var registrar: HotkeyRegistering!
    /// Why the stored shortcut is not registered right now.
    private(set) var hotkeyError: String?
    /// The shortcut works, but something else declares the same combination.
    private(set) var hotkeyWarning: String?
    var systemConflict: (Combo) -> String? = KeyConflicts.system
    var registryConflict: (Combo) -> String? = { KeyConflicts.skhd($0) ?? KeyConflicts.registered($0) }
    var declare: (Settings) -> Void = { KeyConflicts.declare($0) }
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var login: LoginItem = SystemLoginItem()
    var onChange: (() -> Void)?
    /// Applies how the product shows itself: `application` puts it in the Dock and the ⌘Tab switcher, `menuBarIcon`
    /// adds the menu bar icon. The application delegate does it for real; the self-test records the requests.
    var present: (_ application: Bool, _ menuBarIcon: Bool) -> Void = { _, _ in }
    /// What is actually showing, read back for `status`.
    var presence: () -> [String: Any] = { [:] }
    private let testing: Bool
    private var loadedPanel: PanelController?
    /// Built on first use: command-line paths that never show anything never create a window.
    var panel: PanelController {
        if let loadedPanel { return loadedPanel }
        let panel = PanelController(testing: testing)
        panel.onClosed = { [weak self] in self?.scheduleIdleCheck(after: 0.2) }
        panel.onReady = { [weak self] in self?.record($0) }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        loadedPanel = panel
        return panel
    }
    var panelActive: Bool { loadedPanel?.active ?? false }
    private(set) var settingsVisible = false
    private weak var settingsWindow: NSWindow?
    /// The application the user was in when the settings window opened; it gets the keyboard back afterwards.
    private var applicationBeforeSettings: NSRunningApplication?
    /// The last other application that came to the front while this one was running.
    private var lastOtherApplication: NSRunningApplication?
    private var graceUntil = Date.distantPast
    private var showSource = "builtin"
    private(set) var lastShow: [String: Any]?
    /// Why the upgrade asked for from the command line did not happen; this build stays in place.
    private(set) var upgradeError: String?
    private var configuration: AppConfiguration?
    private(set) var productSettings: ProductSettings?

    init(store: SettingsStore = SettingsStore(), testing: Bool = false) {
        self.store = store
        self.testing = testing
        super.init()
    }

    // MARK: Lifecycle

    /// Loads the stored choice and starts its shortcut source, if any.
    func start() {
        settings = store.load()
        applyRegistration()
        updatePresence()
    }

    /// A process that stays for the shortcut is an ordinary application: visible in the Dock, the ⌘Tab switcher and
    /// the menu bar, with the usual ways to quit it. One that lives for a single panel never shows up there.
    private func updatePresence() { present(staysResident || settingsVisible, staysResident) }

    private func applyRegistration() {
        registrar.unregister()
        hotkeyError = nil; hotkeyWarning = nil
        guard settings.mode == .builtin, let combo = settings.hotkey else { return }
        if let reason = systemConflict(combo) { hotkeyError = reason }
        else if !registrar.register(combo) { hotkeyError = "\(combo.display) 已被其他 App 占用，未能注册。请换一个组合。" }
        else { hotkeyWarning = registryConflict(combo) }
    }

    /// The settings file changed underneath (configuration import or iCloud): apply it like a restart would.
    func reloadFromDisk() {
        settings = store.load()
        applyRegistration()
        if settings.mode == .external, login.enabled { try? login.set(false) }
        declare(settings)
        updatePresence()
        onChange?()
        scheduleIdleCheck(after: 0.3)
    }

    func shutdown() { registrar.unregister() }

    /// Builtin mode with a working shortcut is the only reason to stay without a window.
    var staysResident: Bool { settings.mode == .builtin && registrar.combo != nil }

    func grace(_ seconds: TimeInterval) {
        graceUntil = Date().addingTimeInterval(seconds)
        scheduleIdleCheck(after: seconds + 0.05)
    }

    func scheduleIdleCheck(after delay: TimeInterval) {
        if testing { idleCheck(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.idleCheck() }
    }

    private func idleCheck() {
        guard !staysResident, !panelActive, !settingsVisible, Date() >= graceUntil else { return }
        terminate()
    }

    // MARK: Showing the panel

    func resolveTarget(pid: pid_t?) throws -> NSRunningApplication {
        let found: NSRunningApplication?
        if let pid { found = NSRunningApplication(processIdentifier: pid) }
        else { found = NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication }
        guard let app = found, !app.isTerminated else {
            throw ProductError(pid == nil ? "没有找到当前 App。" : "目标 App 已退出。请回到要搜索的 App 再呼出。")
        }
        guard app.processIdentifier != getpid(), app.bundleIdentifier != Env.bundleID else {
            throw ProductError("现在在前面的是 MenuSearch 自己的窗口。请先切到要搜索的 App，再呼出。")
        }
        return app
    }

    /// The shortcut callback and `menusearch show` both land here. With no pid the target is captured as the first
    /// thing, before the panel can change anything on screen.
    @discardableResult
    func show(pid: pid_t?, requestedAt: Date = Date(), source: String) -> [String: Any] {
        if panelActive { panel.close(); return ["ok": true, "action": "closed"] }
        do {
            let target = try resolveTarget(pid: pid)
            showSource = source
            // Hidden with ⌘H: the panel must still appear, without bringing this application to the front.
            if !testing, NSApp.isHidden { NSApp.unhideWithoutActivation() }
            panel.present(target: target, requestedAt: requestedAt)
            return ["ok": true, "action": "shown", "target_pid": Int(target.processIdentifier),
                    "target": target.localizedName ?? "", "target_bundle_id": target.bundleIdentifier ?? ""]
        } catch {
            panel.present(message: error.localizedDescription)
            return ["ok": false, "action": "message_shown", "error": error.localizedDescription]
        }
    }

    /// Timing of the latest presentation, for `status`. Counts and durations only: no menu content is stored.
    private func record(_ ready: PanelController.Ready) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()), "source": showSource,
            "elapsed_ms": (ready.elapsedMS * 10).rounded() / 10, "scan_ms": (ready.scanMS * 10).rounded() / 10,
            "count": ready.count, "complete": ready.complete, "version": Env.version, "build": Env.build]
        lastShow = entry
        guard !testing else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
            try? Env.ensureSupportDirectory()
            try? data.write(to: Env.lastShowURL, options: .atomic)
        }
    }

    // MARK: Changing how it is summoned

    private func saved(_ next: Settings, notice: String?) -> Result<String?, ProductError> {
        settings = next
        hotkeyError = nil; hotkeyWarning = notice
        declare(settings)
        onChange?()
        return .success(notice)
    }

    /// nil clears the shortcut. A refused combination leaves the previous one registered and stored.
    func setHotkey(_ combo: Combo?) -> Result<String?, ProductError> {
        defer { updatePresence() }
        let previous = registrar.combo
        var notice: String?
        if let combo {
            if let reason = systemConflict(combo) { return .failure(ProductError(reason)) }
            guard registrar.register(combo) else {
                if let previous { _ = registrar.register(previous) }
                return .failure(ProductError("\(combo.display) 已被其他 App 占用，未能注册；原快捷键保持不变。"))
            }
            notice = registryConflict(combo)
            // In external mode the combination is only checked and stored for later.
            if settings.mode == .external { registrar.unregister() }
        } else { registrar.unregister() }
        var next = settings; next.hotkey = combo
        do { try store.save(next) } catch {
            registrar.unregister()
            if let previous { _ = registrar.register(previous) }
            return .failure(ProductError("设置未能保存（\(error.localizedDescription)）；原快捷键保持不变。"))
        }
        return saved(next, notice: notice)
    }

    /// Stops the old shortcut source, then starts the new one; if the new one cannot start, the old one comes back.
    func setMode(_ mode: Mode) -> Result<String?, ProductError> {
        guard mode != settings.mode else { return .success(nil) }
        defer { updatePresence() }
        var notice: String?
        switch mode {
        case .external:
            registrar.unregister()
        case .builtin:
            if let combo = settings.hotkey {
                if let reason = systemConflict(combo) { return .failure(ProductError(reason + " 呼出方式保持为外部呼出。")) }
                guard registrar.register(combo) else {
                    return .failure(ProductError("\(combo.display) 已被其他 App 占用，未能注册；呼出方式保持为外部呼出，请先换一个快捷键。"))
                }
                notice = registryConflict(combo)
            }
        }
        var next = settings; next.mode = mode
        do { try store.save(next) } catch {
            registrar.unregister()
            if settings.mode == .builtin, let combo = settings.hotkey { _ = registrar.register(combo) }
            return .failure(ProductError("设置未能保存（\(error.localizedDescription)）；呼出方式保持不变。"))
        }
        if mode == .external, login.enabled {
            try? login.set(false)
            notice = "已关闭登录时启动：外部呼出方式下 MenuSearch 不常驻。"
        }
        return saved(next, notice: notice)
    }

    func setLogin(_ on: Bool) -> Result<String?, ProductError> {
        if on {
            guard settings.mode == .builtin else { return .failure(ProductError("外部呼出方式下 MenuSearch 不常驻，不需要登录时启动。")) }
            guard testing || Env.bundleURL?.path == Env.installedBundlePath else {
                return .failure(ProductError("请先把 MenuSearch 安装到 /Applications，再开启登录时启动。"))
            }
        }
        do { try login.set(on) } catch { return .failure(ProductError("登录时启动未能更改：\(error.localizedDescription)")) }
        onChange?()
        return .success(nil)
    }

    // MARK: State for the window and the command line

    func status() -> [String: Any] {
        ["ok": true, "running": true, "pid": Int(getpid()), "executable": Env.executableURL.path,
         "version": Env.version, "build": Env.build, "mode": settings.mode.rawValue,
         "hotkey": settings.hotkey.map { ["display": $0.display, "key": $0.canonical] as [String: Any] } ?? NSNull(),
         "hotkey_registered": registrar.combo != nil, "hotkey_error": hotkeyError ?? NSNull(),
         "hotkey_warning": hotkeyWarning ?? NSNull(), "panel_visible": panelActive, "settings_visible": settingsVisible,
         "accessibility": AXIsProcessTrusted(), "login_item": login.status, "stays_resident": staysResident,
         "settings_error": store.loadError ?? NSNull(), "last_show": lastShow ?? NSNull(), "presence": presence(),
         "icloud_sync": configuration?.enabled ?? false, "upgrade_error": upgradeError ?? NSNull()]
    }

    private static func reply(_ result: Result<String?, ProductError>) -> [String: Any] {
        switch result {
        case .success(let notice): return ["ok": true, "notice": notice ?? NSNull()]
        case .failure(let error): return ["ok": false, "error": error.message]
        }
    }

    /// One request from the control socket. Runs on the main queue, after the application finished launching.
    func handle(_ request: [String: Any]) -> [String: Any] {
        defer { scheduleIdleCheck(after: 0.3) }
        switch request["cmd"] as? String {
        case "ping": return ["ok": true, "pid": Int(getpid())]
        case "status": return status()
        case "show":
            let pid = (request["pid"] as? NSNumber)?.int32Value
            let requested = (request["t0"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
            return show(pid: pid, requestedAt: requested, source: "external")
        case "settings":
            openSettings()
            return ["ok": true, "action": "settings"]
        case "config":
            var result: [String: Any]
            switch (request["key"] as? String, request["value"]) {
            case ("mode", let value as String):
                guard let mode = Mode(rawValue: value) else { return ["ok": false, "error": "呼出方式只能是 builtin 或 external。"] }
                result = Self.reply(setMode(mode))
            case ("hotkey", let value as String):
                if ["none", "off", ""].contains(value.lowercased()) { result = Self.reply(setHotkey(nil)) }
                else if let combo = Combo(canonical: value) { result = Self.reply(setHotkey(combo)) }
                else { return ["ok": false, "error": "无法识别的快捷键「\(value)」。写法如 alt+m、cmd+shift+space，至少带 ⌘、⌃ 或 ⌥。"] }
            case ("login", let value as String):
                guard ["on", "off"].contains(value) else { return ["ok": false, "error": "login 只能是 on 或 off。"] }
                result = Self.reply(setLogin(value == "on"))
            case ("icloud", let value as String):
                guard ["on", "off"].contains(value) else { return ["ok": false, "error": "icloud 只能是 on 或 off。"] }
                // The switch lives in the application's own preferences; an isolated run must not flip the real one.
                guard !testing, let configuration else { return ["ok": false, "error": "隔离环境不能更改 iCloud 配置同步。"] }
                configuration.setEnabled(value == "on")
                result = ["ok": true, "notice": NSNull()]
            default: return ["ok": false, "error": "未知的配置项。可用：mode、hotkey、login、icloud。"]
            }
            result["state"] = status()
            return result
        case "reload":
            reloadFromDisk()
            return status()
        case "update":
            guard !testing else { return ["ok": false, "error": "隔离环境不能升级。"] }
            startUpgrade()
            return ["ok": true, "action": "upgrade_started"]
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.terminate() }
            return ["ok": true, "action": "quit"]
        default: return ["ok": false, "error": "未知请求。"]
        }
    }

    /// What the settings window's "升级到新版…" does, without the confirmation sheet: download the published package,
    /// verify its checksum, signature and notarization, hand the swap to the shared helper and quit. A failure
    /// leaves this build in place.
    private func startUpgrade() {
        upgradeError = nil
        grace(180)
        guard let bundle = Env.bundleURL else { upgradeError = "没有在 .app 里运行。"; return }
        AppUpdateChecker.check(source: UpdateChannel.current.updateSource, bundleID: Env.bundleID,
                               version: Env.version, build: Env.build) { [weak self] checked in
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    let release = try checked.get()
                    guard release.isNewer(than: Env.version, build: Env.build) else { throw ProductError("没有比当前更新的正式版本。") }
                    guard AppUpgradeInstaller.supportsReplacement(release: release, currentBundle: bundle) else {
                        throw ProductError("这个发行包不能直接替换当前安装。")
                    }
                    AppUpgradeInstaller.prepare(release: release, currentBundle: bundle) { prepared in
                        DispatchQueue.main.async {
                            do {
                                let package = try prepared.get()
                                try Data().write(to: Env.quietRelaunchURL)
                                try AppUpgradeInstaller.launchReplacement(package, currentBundle: bundle, pid: getpid())
                                self.terminate()
                            } catch {
                                try? FileManager.default.removeItem(at: Env.quietRelaunchURL)
                                self.upgradeError = error.localizedDescription
                            }
                        }
                    }
                } catch { self.upgradeError = error.localizedDescription }
            }
        }
    }

    // MARK: Settings window

    /// Wires the shared settings/update window with this product's own groups and its transferable configuration.
    func installSettingsWindow() {
        let file = AppConfigurationFile(url: store.url, keys: ["mode", "hotkey"]) { try Settings.validate(field: $0) }
        let configuration = AppConfiguration(productID: Env.bundleID, files: [file])
        configuration.onChange = { [weak self] in self?.reloadFromDisk() }
        self.configuration = configuration
        let product = ProductSettings(coordinator: self)
        productSettings = product
        onChange = { [weak product] in product?.refresh() }
        AppLifecycleUI.shared.productGroups = { [weak product] in product?.groups() ?? [] }
        AppLifecycleUI.shared.willShow = { [weak product] in product?.refresh() }
        AppLifecycleUI.install(name: Env.productName, configuration: configuration, updateSource: UpdateChannel.current.updateSource)
    }

    func openSettings() {
        settingsVisible = true
        // While the window is open the product is an ordinary application with a Dock icon and a menu bar.
        updatePresence()
        guard !testing else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { applicationBeforeSettings = front }
        AppLifecycleUI.shared.show()
        if settingsWindow == nil, let window = NSApp.windows.first(where: { $0.title == "\(Env.productName) 设置" }) {
            settingsWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.settingsClosed()
            }
        }
    }

    func settingsClosed() {
        settingsVisible = false
        updatePresence()
        if !testing, NSApp.isActive {
            // With no window left this application must not keep the keyboard: the next press of the shortcut is
            // meant for the application the user came from.
            let previous = [applicationBeforeSettings, lastOtherApplication].compactMap { $0 }.first { !$0.isTerminated }
            previous?.activate()
        }
        applicationBeforeSettings = nil
        scheduleIdleCheck(after: 0.2)
    }

    func noteActivated(_ application: NSRunningApplication) {
        if application.processIdentifier != getpid() { lastOtherApplication = application }
    }

    /// Chosen in the ⌘Tab switcher or the Dock with nothing on screen: bring up the one window there is.
    func activated() {
        guard !settingsVisible, !panelActive else { return }
        openSettings()
    }
}

/// Where new versions come from: this product's public GitHub Releases. Named once, here, in the literal form the
/// shared lifecycle expects; the settings window, the control socket and the command line all read it.
/// Nothing asks the network on its own: a release is looked up only when the user checks for updates.
struct UpdateChannel {
    let updateSource: AppUpdateSource
    static let current = UpdateChannel(updateSource: .github(repository: "zengtianli/MenuSearch"))
    var name: String {
        switch updateSource {
        case .github(let repository): return "GitHub " + repository
        case .privateCloud(let channel): return channel
        case .manifest(let url): return url.host ?? url.absoluteString
        case .appStore: return "App Store"
        }
    }
}

/// The menu under the menu bar icon: search the application in front, open the settings, quit.
enum MenuBarMenu {
    static let symbol = "filemenu.and.selection"

    static func fill(_ menu: NSMenu, hotkey: Combo?, target: AnyObject?) {
        menu.removeAllItems()
        let search = NSMenuItem(title: "搜索当前 App 的菜单", action: #selector(AppDelegate.searchFrontApplication(_:)), keyEquivalent: "")
        // Shown as a reminder of the shortcut; it only acts while this menu is open.
        if let (key, mask) = hotkey?.menuEquivalent { search.keyEquivalent = key; search.keyEquivalentModifierMask = mask }
        let settings = NSMenuItem(title: "设置…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        let quit = NSMenuItem(title: "退出 \(Env.productName)", action: #selector(AppDelegate.quit(_:)), keyEquivalent: "q")
        for item in [search, .separator(), settings, .separator(), quit] {
            if !item.isSeparatorItem { item.target = target }
            menu.addItem(item)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let coordinator = Coordinator()
    private let server: ControlServer
    private let background: Bool
    /// The hidden cold-start measurement: the same start in a throwaway directory, with nothing registered or shown.
    private let measuring: Bool
    private var hotkey: GlobalHotkey?
    private var accessibilityObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    /// A background or login start may be brought forward by the system; that is not the user asking for a window.
    private var quietUntil = Date.distantPast

    init(server: ControlServer, background: Bool, measuring: Bool = false) {
        self.server = server
        self.background = background
        self.measuring = measuring
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hotkey = GlobalHotkey { [weak self] in self?.coordinator.show(pid: nil, requestedAt: Date(), source: "builtin") }
        self.hotkey = hotkey
        coordinator.registrar = measuring ? NullRegistrar() : hotkey
        if measuring { coordinator.declare = { _ in }; coordinator.login = UnavailableLoginItem() }
        NSApp.mainMenu = buildMenu()
        // A measured copy stays a background process whatever its settings say.
        if !measuring {
            coordinator.present = { [weak self] application, menuBarIcon in self?.present(application: application, menuBarIcon: menuBarIcon) }
        }
        coordinator.presence = { [weak self] in
            // The system leaves an icon out when the menu bar has no room for it (a full bar next to the notch).
            let window = self?.statusItem?.button?.window
            return ["dock": NSApp.activationPolicy() == .regular, "menu_bar_icon": self?.statusItem?.isVisible ?? false,
                    "menu_bar_icon_on_screen": window.map { $0.screen != nil && $0.occlusionState.contains(.visible) } ?? false]
        }
        coordinator.start()
        if !measuring { KeyConflicts.declareIfMissing(coordinator.settings) }
        coordinator.installSettingsWindow()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.coordinator.noteActivated(application)
            }
        }
        // The system posts this when the Accessibility list changes; the window shows the new state without polling.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.coordinator.onChange?() }
        }
        server.handler = { [weak self] in self?.coordinator.handle($0) ?? ["ok": false, "error": "MenuSearch 正在退出。"] }
        do { try server.listen() } catch { NSLog("MenuSearch: %@", error.localizedDescription) }
        if measuring {
            // Ready to answer a summon: listening, and the panel the first press would build is built and laid out.
            coordinator.panel.panel.contentView?.layoutSubtreeIfNeeded()
            // The measuring tool ends this copy; if it does not, the copy ends itself.
            coordinator.grace(60)
            MainActor.assumeIsolated { LaneSignal.ready("panel") }
            return
        }
        // Reopened by the upgrade helper: the user asked for a new version, not for a window.
        let relaunched = (try? FileManager.default.removeItem(at: Env.quietRelaunchURL)) != nil
        let quiet = background || Self.launchedAsLoginItem || relaunched
        if quiet { quietUntil = Date().addingTimeInterval(2) }
        // After the launch sequence has settled, so its focus changes cannot dismiss or misdirect anything.
        DispatchQueue.main.async { [coordinator] in
            if quiet { coordinator.grace(3) } else { coordinator.openSettings() }
        }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.openSettings()
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date() >= quietUntil else { return }
        coordinator.activated()
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "设置…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func present(application: Bool, menuBarIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = application ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        if menuBarIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: MenuBarMenu.symbol, accessibilityDescription: Env.productName)
                ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: Env.productName)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "\(Env.productName) · 菜单搜索"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !menuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem?.menu { MenuBarMenu.fill(menu, hotkey: coordinator.settings.hotkey, target: self) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
        server.stop()
        if measuring, let root = Env.isolatedRoot?.deletingLastPathComponent(), root.lastPathComponent.hasPrefix("menusearch-measure-") {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }
    @objc func showSettings(_ sender: Any?) { coordinator.openSettings() }
    /// From the menu bar icon: clicking it does not change which application is in front.
    @objc func searchFrontApplication(_ sender: Any?) { coordinator.show(pid: nil, requestedAt: Date(), source: "menu_bar") }
    /// ⌘Q typed into the search panel belongs to nobody: it must not end the background listener by accident.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(quit(_:)) ? !coordinator.panelActive : true
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let application = NSMenu()
        application.addItem(withTitle: "关于 \(Env.productName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        application.addItem(.separator())
        application.addItem(withTitle: "隐藏 \(Env.productName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = application.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        let quit = NSMenuItem(title: "退出 \(Env.productName)", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        application.addItem(quit)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for menu in [application, edit, window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = window
        return main
    }
}

enum AppMain {
    /// The application process: started by Finder, at login, or by `menusearch` when no instance is listening.
    /// `measuring` is the hidden cold-start measurement of a copy: the same sequence in a directory of its own, so it
    /// neither meets the running instance nor reads the user's settings.
    static func run(arguments: [String], measuring: Bool = false) -> Never {
        signal(SIGPIPE, SIG_IGN)
        if measuring {
            let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("menusearch-measure-\(getpid())")
            setenv("MENUSEARCH_SUPPORT_DIR", root + "/support", 1)
            setenv("APP_LIFECYCLE_SUPPORT_DIR", root + "/lifecycle", 1)
            guard Env.isolated else { fputs("测量副本没有拿到独立目录。\n", stderr); exit(1) }
        } else if Env.isolated {
            fputs("隔离环境（MENUSEARCH_SUPPORT_DIR）不能启动常驻 App。\n", stderr); exit(1)
        }
        let background = measuring || arguments.contains("--app-background")
        do { try Env.ensureSupportDirectory() } catch {
            fputs("无法建立状态目录：\(error.localizedDescription)\n", stderr); exit(1)
        }
        let server = ControlServer()
        guard server.acquire() else {
            // Another instance already listens; a plain second open means "show the settings window".
            if measuring { exit(1) }
            if !background {
                for _ in 0..<100 {
                    if Control.request(["cmd": "settings"], timeout: 2) != nil { break }
                    usleep(20_000)
                }
            }
            exit(0)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate(server: server, background: background, measuring: measuring)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { NSApp.terminate(nil) }
        terminate.resume()
        withExtendedLifetime((delegate, terminate)) { application.run() }
        exit(0)
    }
}
