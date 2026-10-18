#if APP_STORE
import AppKit
import UniformTypeIdentifiers

/// Product-owned store settings: the shared transfer engine, without the shared updater window.
final class StoreSettingsUI: NSObject {
    static let shared = StoreSettingsUI()
    private var product: ProductSettings?
    private var configuration: AppConfiguration?
    private var controller: NSWindowController?
    private let cloudToggle = NSSwitch()
    private let syncStatus = detailLabel()
    private var observer: NSObjectProtocol?

    static func install(product: ProductSettings, configuration: AppConfiguration) {
        let ui = shared
        ui.product = product; ui.configuration = configuration
        configuration.start()
        if let observer = ui.observer { NotificationCenter.default.removeObserver(observer) }
        ui.observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppConfigurationStatusChanged"), object: configuration, queue: .main) { [weak ui] _ in ui?.refresh() }
    }

    static func detailLabel(_ text: String = "") -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return field
    }

    static func row(_ title: String, detail: NSTextField? = nil, accessory: NSView? = nil) -> NSView {
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 13)
        let text = NSStackView(views: [name] + (detail.map { [$0] } ?? []))
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        text.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [text] + (accessory.map { [$0] } ?? []))
        row.alignment = .centerY; row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        detail?.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        accessory?.setContentHuggingPriority(.required, for: .horizontal)
        accessory?.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let controls = accessory as? NSStackView { controls.setHuggingPriority(.required, for: .horizontal) }
        return row
    }

    private final class Card: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor.labelColor.withAlphaComponent(0.04).setFill(); path.fill()
            NSColor.labelColor.withAlphaComponent(0.09).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    static func group(_ caption: String?, rows: [NSView]) -> NSView {
        let card = Card()
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        guard let caption else { return card }
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .secondaryLabelColor
        let outer = NSStackView(views: [label, card]); outer.orientation = .vertical; outer.alignment = .leading; outer.spacing = 6
        card.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        return outer
    }

    private func makeWindow() {
        guard controller == nil, let product else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.title = String(localized: "\(Env.productName) 设置"); window.isReleasedWhenClosed = false
        cloudToggle.target = self; cloudToggle.action = #selector(toggleCloud)
        let export = NSButton(title: String(localized: "导出配置…"), target: self, action: #selector(exportConfiguration))
        let load = NSButton(title: String(localized: "导入配置…"), target: self, action: #selector(importConfiguration))
        let transfers = NSStackView(views: [export, load]); transfers.spacing = 8
        let title = NSTextField(labelWithString: String(localized: "\(Env.productName) · 版本 \(Env.version) (\(Env.build))"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let groups = product.groups() + [Self.group(String(localized: "配置"), rows: [
            Self.row(String(localized: "使用 iCloud 记住配置"), detail: Self.detailLabel(String(localized: "使用系统 Apple 账户同步快捷键配置。辅助功能权限和登录项保留在本机。")), accessory: cloudToggle),
            Self.row(String(localized: "导入与导出"), detail: syncStatus, accessory: transfers)])]
        let stack = NSStackView(views: [title] + groups)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 520)
        ] + groups.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        content.layoutSubtreeIfNeeded(); window.setContentSize(content.fittingSize); window.center()
        controller = NSWindowController(window: window); refresh()
    }

    private func refresh() {
        product?.refresh()
        cloudToggle.state = configuration?.enabled == true ? .on : .off
        syncStatus.stringValue = configuration?.status ?? ""
    }

    func show() {
        makeWindow(); refresh()
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleCloud() { configuration?.setEnabled(cloudToggle.state == .on); refresh() }

    @objc private func exportConfiguration() {
        guard let configuration, let window = controller?.window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "MenuSearch-settings.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try Self.export(configuration, to: url); self?.syncStatus.stringValue = String(localized: "配置已导出。") }
            catch { self?.syncStatus.stringValue = String(localized: "导出未完成：\(error.localizedDescription)") }
        }
    }

    @objc private func importConfiguration() {
        guard let configuration, let window = controller?.window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try Self.load(configuration, from: url); self?.syncStatus.stringValue = String(localized: "已导入；原配置已备份。商店版使用内置快捷键。") }
            catch { self?.syncStatus.stringValue = String(localized: "导入未完成：\(error.localizedDescription)") }
        }
    }

    // No parent-directory creation: a save panel grants the selected file, not its containing folder.
    static func export(_ configuration: AppConfiguration, to url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try configuration.exportData().write(to: url, options: .atomic)
    }

    static func load(_ configuration: AppConfiguration, from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try configuration.importData(Data(contentsOf: url))
    }

    /// Constructs the actual store settings without ever ordering a window onto the desktop.
    func offscreenSnapshot(to url: URL) throws -> [String] {
        guard NSApp.activationPolicy() == .prohibited else { throw ProductError("离屏检查必须禁止窗口与 Dock。") }
        makeWindow(); refresh()
        guard let window = controller?.window, let view = window.contentView else { throw ProductError("设置窗口构造失败。") }
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded(); window.setContentSize(view.fittingSize); view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw ProductError("无法离屏渲染设置。") }
        bitmap.size = view.bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ProductError("无法建立离屏画布。") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); view.bounds.fill() }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ProductError("无法生成设置截图。") }
        try png.write(to: url)
        func text(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? (view as? NSButton).map { [$0.title] } ?? []
            return own + view.subviews.flatMap(text)
        }
        return text(view)
    }
}
#endif
