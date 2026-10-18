#if !APP_STORE
import AppKit

/// Inspects actual product views. Shared settings strings are reported separately for their owner.
enum LocalizationSelfTest {
    private static func text(_ view: NSView) -> [String] {
        var own: [String] = []
        if let field = view as? NSTextField {
            own.append(field.stringValue)
            if let placeholder = field.placeholderString { own.append(placeholder) }
        }
        if let popup = view as? NSPopUpButton { own += popup.itemTitles }
        else if let button = view as? NSButton { own.append(button.title) }
        if let tooltip = view.toolTip { own.append(tooltip) }
        if let label = view.accessibilityLabel() { own.append(label) }
        return own + view.subviews.flatMap(text)
    }

    private static func chinese(_ value: String) -> Bool {
        value.range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    static func check(panel: PanelController, coordinator: Coordinator, out: URL) throws {
        guard NSApp.activationPolicy() == .prohibited, let product = coordinator.productSettings else {
            throw ProductError("Localization checks require offscreen product views.")
        }
        let english = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
        var strings = text(panel.panel.contentView!)
        let menu = NSMenu()
        MenuBarMenu.fill(menu, hotkey: nil, target: nil)
        strings += menu.items.map(\.title)
        let groups = product.groups()
        strings += groups.flatMap(text)
        _ = coordinator.setMode(.external)
        product.refresh()
        strings += groups.flatMap(text)
        _ = coordinator.setMode(.builtin)
        product.refresh()
        product.recordForTest(Combo(canonical: "alt+m")!)
        // No user menus are involved: test empty, denied permission, and disabled-command states.
        panel.search.stringValue = "no-such-command"
        panel.filter()
        strings += text(panel.panel.contentView!)
        guard try SelfTest.render(panel, to: out.appendingPathComponent("panel-empty.png"), appearance: .aqua) else {
            throw ProductError("Could not render the empty state.")
        }
        panel.presentAccessibilityGuidance()
        strings += text(panel.panel.contentView!)
        guard try SelfTest.render(panel, to: out.appendingPathComponent("panel-permission.png"), appearance: .aqua) else {
            throw ProductError("Could not render permission guidance.")
        }
        let raw = ProductError(localized: "\(Env.productName) 已被其他 App 占用，未能注册；原快捷键保持不变。")
        strings += [raw.localizedMessage, MenuSearchError.accessibility.localizedMessage]
        let file = Env.supportDirectory.appendingPathComponent("invalid-settings.json")
        try Data("{}".utf8).write(to: file)
        try Data("{\"mode\":false}".utf8).write(to: file)
        let damaged = SettingsStore(url: file)
        _ = damaged.load()
        strings += [damaged.localizedLoadError ?? ""]
        let registry = Env.supportDirectory.appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try Data("[{\"component\":\"OtherApp\",\"key\":\"alt+m\"}]".utf8).write(to: registry.appendingPathComponent("other.json"))
        if let conflict = KeyConflicts.registered(Combo(canonical: "alt+m")!, in: registry) {
            strings.append(conflict.localizedMessage)
            guard conflict.message.contains("未说明") else { throw ProductError("CLI fallback text changed.") }
        }
        let remaining = strings.filter(chinese)
        let shared = NSApp.windows.filter { $0 !== panel.panel }.flatMap { $0.contentView.map(text) ?? [] }.filter(chinese)
        let report: [String: Any] = [
            "ok": !english || remaining.isEmpty,
            "language": Bundle.main.preferredLocalizations.first ?? "",
            "product_text_count": strings.count,
            "remaining_product_chinese": remaining,
            "shared_layer_chinese": Array(Set(shared)).sorted(),
            "cli_error_preserved": raw.message == "MenuSearch 已被其他 App 占用，未能注册；原快捷键保持不变。",
            "offscreen": NSApp.windows.allSatisfy { !$0.isVisible } && NSApp.activationPolicy() == .prohibited,
            "scope": "Production product views, fixed English demo menus; shared-layer strings reported separately."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("l10n.json"))
        if english && !remaining.isEmpty { throw ProductError("Chinese text remains in English product views: \(remaining)") }
    }
}
#endif
