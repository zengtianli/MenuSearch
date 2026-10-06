import AppKit
import ApplicationServices

/// This product's groups in the shared settings window. Every control goes through Coordinator, the same methods
/// the command line uses, and reflects whatever those methods left in effect.
final class ProductSettings: NSObject {
    private unowned let coordinator: Coordinator
    let modePopup = NSPopUpButton()
    let recorder = HotkeyRecorder()
    let clearButton = NSButton(title: "清除", target: nil, action: nil)
    let hotkeyDetail = AppLifecycleUI.detailLabel()
    let modeDetail = AppLifecycleUI.detailLabel()
    let accessDetail = AppLifecycleUI.detailLabel()
    let accessButton = NSButton(title: "打开系统设置…", target: nil, action: nil)
    let commandDetail = AppLifecycleUI.detailLabel()
    let copyButton = NSButton(title: "拷贝命令", target: nil, action: nil)
    let loginSwitch = NSSwitch()
    let loginDetail = AppLifecycleUI.detailLabel()
    let quitButton = NSButton(title: "退出", target: nil, action: nil)
    let quitDetail = AppLifecycleUI.detailLabel()
    private enum Row { case mode, hotkey, login }
    /// The result of the latest change made here, shown on the row it belongs to until the next change.
    private var feedback: (text: String, failed: Bool, row: Row)?
    static let command = "menusearch show"

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        super.init()
        for mode in Mode.allCases {
            modePopup.addItem(withTitle: mode.title)
            modePopup.lastItem?.representedObject = mode.rawValue
        }
        modePopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        for control in [modePopup, clearButton, accessButton, copyButton, loginSwitch, quitButton] as [NSControl] {
            control.target = self; control.action = #selector(changed(_:))
        }
        recorder.onBegin = { [weak self] in self?.coordinator.registrar.unregister() }
        recorder.onEnd = { [weak self] combo in self?.recorded(combo) }
    }

    func groups() -> [NSView] {
        refresh()
        let keys = NSStackView(views: [recorder, clearButton]); keys.spacing = 8
        let purpose = AppLifecycleUI.detailLabel("在任意 App 里按下快捷键，列出它菜单栏和各级子菜单里的全部命令；输入即过滤，↑↓ 选择，回车执行，Esc 关闭。菜单内容只在本机读取，不保存、不上传。")
        return [
            AppLifecycleUI.group(nil, rows: [AppLifecycleUI.row("搜索当前 App 的菜单命令", detail: purpose)]),
            AppLifecycleUI.group("权限", rows: [AppLifecycleUI.row("辅助功能", detail: accessDetail, accessory: accessButton)]),
            AppLifecycleUI.group("呼出方式", rows: [
                AppLifecycleUI.row("用什么呼出面板", detail: modeDetail, accessory: modePopup),
                AppLifecycleUI.row("快捷键", detail: hotkeyDetail, accessory: keys),
                AppLifecycleUI.row("外部呼出命令", detail: commandDetail, accessory: copyButton)]),
            AppLifecycleUI.group("运行", rows: [
                AppLifecycleUI.row("登录时启动", detail: loginDetail, accessory: loginSwitch),
                AppLifecycleUI.row("退出 MenuSearch", detail: quitDetail, accessory: quitButton)])
        ]
    }

    func refresh() {
        let settings = coordinator.settings
        let builtin = settings.mode == .builtin
        let trusted = AXIsProcessTrusted()
        accessDetail.textColor = trusted ? .secondaryLabelColor : .systemOrange
        accessDetail.stringValue = trusted ? "已允许。MenuSearch 用它读取当前 App 的菜单并执行你选中的命令。"
            : "尚未允许。读取和执行菜单命令需要它；请在「隐私与安全性 › 辅助功能」里打开 MenuSearch，这里不会代你授权。"
        accessButton.title = trusted ? "查看系统设置…" : "打开系统设置…"
        modePopup.selectItem(at: Mode.allCases.firstIndex(of: settings.mode) ?? 0)
        modeDetail.stringValue = builtin ? "MenuSearch 保持运行并自己注册下面的快捷键，在程序坞、⌘Tab 和菜单栏里都能看到它。关掉这个窗口后仍可呼出，直到你退出它。"
            : "由 skhd、Karabiner 或其他启动器运行右下方的命令。MenuSearch 不注册快捷键，面板关闭后进程即结束。"
        if !recorder.isRecording { recorder.combo = settings.hotkey }
        clearButton.isEnabled = settings.hotkey != nil
        hotkeyDetail.textColor = .secondaryLabelColor
        if let error = coordinator.hotkeyError {
            hotkeyDetail.stringValue = error; hotkeyDetail.textColor = .systemOrange
        } else if let combo = settings.hotkey {
            hotkeyDetail.stringValue = builtin ? "\(combo.display) 已注册。在任意 App 里按它即可搜索该 App 的菜单。" + (coordinator.hotkeyWarning.map { " " + $0 } ?? "")
                : "\(combo.display) 已保存，切回「内置快捷键」后生效。"
            if builtin, coordinator.hotkeyWarning != nil { hotkeyDetail.textColor = .systemOrange }
        } else {
            hotkeyDetail.stringValue = builtin ? "尚未设置。点右侧按钮后按下组合键（至少带 ⌘、⌃ 或 ⌥），Esc 取消。" : "外部呼出方式下不需要。"
        }
        commandDetail.stringValue = builtin ? "\(Self.command)：其他工具也可以运行它来呼出，同一个面板。"
            : "\(Self.command)：把它绑到你的键位工具上。MenuSearch 不会改动那些工具的配置。"
        loginSwitch.state = coordinator.login.enabled ? .on : .off
        loginSwitch.isEnabled = builtin
        loginDetail.stringValue = builtin ? "开机登录后自动启动，不显示窗口。" : "外部呼出方式下不常驻，不需要登录时启动。"
        quitDetail.stringValue = coordinator.staysResident ? "也可以从程序坞、菜单栏图标或 ⌘Q 退出。退出后快捷键不再响应，直到再次打开 MenuSearch。"
            : "现在没有设置可用的快捷键，MenuSearch 不会留在后台；关掉这个窗口它就结束。"
        if let problem = coordinator.store.loadError {
            modeDetail.stringValue = problem; modeDetail.textColor = .systemOrange
        } else { modeDetail.textColor = .secondaryLabelColor }
        loginDetail.textColor = .secondaryLabelColor
        if let feedback {
            let label = [Row.mode: modeDetail, .hotkey: hotkeyDetail, .login: loginDetail][feedback.row] ?? hotkeyDetail
            label.stringValue = feedback.text
            label.textColor = feedback.failed ? .systemOrange : .secondaryLabelColor
        }
    }

    private func report(_ result: Result<String?, ProductError>, on row: Row) {
        switch result {
        case .success(let notice): feedback = notice.map { ($0, false, row) }
        case .failure(let error): feedback = (error.message, true, row)
        }
        refresh()
    }

    private func recorded(_ combo: Combo?) {
        guard let combo else {
            // Cancelled: put back whatever was registered before recording started.
            feedback = nil
            coordinator.reloadFromDisk()
            return
        }
        // The previous combination was released for recording; register it again so a refusal can fall back to it.
        if coordinator.settings.mode == .builtin, let previous = coordinator.settings.hotkey { _ = coordinator.registrar.register(previous) }
        report(coordinator.setHotkey(combo), on: .hotkey)
    }

    /// For the offscreen self-test: the same path a recorded combination takes.
    func recordForTest(_ combo: Combo) { recorded(combo) }

    @objc private func changed(_ sender: NSControl) {
        switch sender {
        case modePopup:
            guard let raw = modePopup.selectedItem?.representedObject as? String, let mode = Mode(rawValue: raw) else { return }
            report(coordinator.setMode(mode), on: .mode)
        case clearButton: report(coordinator.setHotkey(nil), on: .hotkey)
        case loginSwitch: report(coordinator.setLogin(loginSwitch.state == .on), on: .login)
        case accessButton:
            // Makes the system list this application, then opens the pane where the user decides.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case copyButton:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.command, forType: .string)
            feedback = nil
            commandDetail.stringValue = "已拷贝：\(Self.command)"
        case quitButton: coordinator.terminate()
        default: break
        }
    }
}
