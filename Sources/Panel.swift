// The search panel. Reading, filtering and the execution guards moved out of MacKit
// (macos/Sources/MenuSearchPanel.swift, MIT). Unlike the prototype, closing the panel ends only the panel: whether
// the process goes on is the application's decision (see Coordinator).
import AppKit
import ApplicationServices

private final class CommandPanel: NSPanel {
    weak var controller: PanelController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { controller?.close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            switch event.charactersIgnoringModifiers {
            case "r": controller?.refresh(); return true
            case ",": controller?.openSettings(); return true
            case "w": controller?.close(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class CommandTable: NSTableView {
    var execute: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { execute?() }
        else { super.keyDown(with: event) }
    }
}

/// A shortcut drawn as key caps: each modifier on its own cap, then the key.
final class KeycapsView: NSView {
    var shortcut = "" {
        didSet { tokens = Self.tokens(shortcut); invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    private var tokens: [String] = []
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let cap: CGFloat = 20, gap: CGFloat = 3

    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first), rest.count > 1 { result.append(String(first)); rest = rest.dropFirst() }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }
    private func width(_ token: String) -> CGFloat {
        max(Self.cap, ceil((token as NSString).size(withAttributes: [.font: Self.font]).width) + 10)
    }
    override var intrinsicContentSize: NSSize {
        tokens.isEmpty ? NSSize(width: 0, height: Self.cap)
            : NSSize(width: tokens.map(width).reduce(0, +) + CGFloat(tokens.count - 1) * Self.gap, height: Self.cap)
    }
    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
        for token in tokens {
            let rect = NSRect(x: x, y: (bounds.height - Self.cap) / 2, width: width(token), height: Self.cap)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.06).setFill(); path.fill()
            NSColor.labelColor.withAlphaComponent(0.16).setStroke(); path.lineWidth = 1; path.stroke()
            let size = (token as NSString).size(withAttributes: attributes)
            (token as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            x += rect.width + Self.gap
        }
    }
}

/// The selected row is a rounded grey bar, the same whether or not the panel's application is active.
private final class CommandRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

private final class CommandCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("command")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let keys = KeycapsView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(600), for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)
        path.font = .systemFont(ofSize: 13); path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.font = .systemFont(ofSize: 12); note.textColor = .tertiaryLabelColor
        note.setContentCompressionResistancePriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        keys.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, title, path, spacer, note, keys])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        row.setCustomSpacing(12, after: icon)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row); textField = title; imageView = icon
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ command: MenuCommand, icon image: NSImage?) {
        icon.image = image
        icon.alphaValue = command.enabled ? 1 : 0.45
        title.stringValue = (command.checked ? "✓ " : "") + command.title
        title.textColor = command.enabled ? .labelColor : .tertiaryLabelColor
        path.stringValue = command.location
        path.textColor = command.enabled ? .secondaryLabelColor : .tertiaryLabelColor
        note.stringValue = command.enabled ? "" : "不可用"
        note.isHidden = command.enabled
        keys.shortcut = command.shortcut
        keys.isHidden = command.shortcut.isEmpty
        toolTip = command.fullPath
    }
}

/// A label with its key cap in the bottom bar; clicking it does the same as the key.
private final class FooterAction: NSView {
    private let handler: () -> Void
    init(_ title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabelColor
        let keys = KeycapsView(); keys.shortcut = key
        let stack = NSStackView(views: [label, keys])
        stack.spacing = 6; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { handler() }
}

/// A borderless, nonactivating key panel: the target application keeps its menu bar and stays in front. Every
/// presentation reads the menu afresh; nothing is cached between presentations and no menu content is written to disk.
final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    struct Ready {
        let elapsedMS: Double
        let scanMS: Double
        let count: Int
        let complete: Bool
    }
    static let size = NSSize(width: 750, height: 474)
    static let cornerRadius: CGFloat = 16

    var onClosed: (() -> Void)?
    var onReady: ((Ready) -> Void)?
    var onOpenSettings: (() -> Void)?

    let panel: NSPanel
    let search = NSTextField()
    let table = CommandTable()
    /// Bottom-left line: what is being searched, or what went wrong.
    let state = NSTextField(labelWithString: "")
    /// Section header above the list: the target application and how many commands are shown.
    let header = NSTextField(labelWithString: "")
    let timing = NSTextField(labelWithString: "")
    /// Shown in place of the list when there is nothing to list.
    let message = NSTextField(wrappingLabelWithString: "")
    let accessibilityButton = NSButton(title: "打开辅助功能设置…", target: nil, action: nil)
    private let targetIcon = NSImageView()
    private let queue = DispatchQueue(label: "cyou.tianli.menusearch.menu-reader", qos: .userInitiated)
    private(set) var reader: MenuReader?
    private(set) var snapshot: MenuSnapshot?
    private var index = MenuSearchIndex([])
    private(set) var shown: [MenuCommand] = []
    private var rowIcon: NSImage?
    private var targetName = ""
    private var busy = false
    private var executing = false
    private var generation = 0
    private var requestedAt: Date?
    /// A presentation is open (visible, or briefly hidden while its command runs).
    private(set) var active = false
    private let testing: Bool
    var testExecuted: [String] = []
    var testClosed = 0

    init(testing: Bool = false) {
        self.testing = testing
        let panel = CommandPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        super.init()
        panel.controller = self
        panel.title = Env.productName
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        root.maskImage = Self.mask(radius: Self.cornerRadius)
        panel.contentView = root

        targetIcon.imageScaling = .scaleProportionallyUpOrDown
        search.isBordered = false; search.drawsBackground = false; search.focusRingType = .none
        search.font = .systemFont(ofSize: 19)
        search.placeholderString = "搜索菜单命令…"
        search.lineBreakMode = .byTruncatingTail
        search.cell?.usesSingleLineMode = true
        search.cell?.isScrollable = true
        search.delegate = self
        header.font = .systemFont(ofSize: 11.5, weight: .semibold); header.textColor = .secondaryLabelColor
        timing.font = .systemFont(ofSize: 11.5); timing.textColor = .tertiaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: CommandCell.identifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 40
        table.style = .plain; table.backgroundColor = .clear
        table.intercellSpacing = .zero; table.gridStyleMask = []
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.target = self; table.doubleAction = #selector(executeSelection)
        table.execute = { [weak self] in self?.executeSelection() }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table

        message.font = .systemFont(ofSize: 13); message.textColor = .secondaryLabelColor
        message.alignment = .center; message.maximumNumberOfLines = 4
        accessibilityButton.target = self; accessibilityButton.action = #selector(openAccessibility)
        accessibilityButton.bezelStyle = .rounded
        let empty = NSStackView(views: [message, accessibilityButton])
        empty.orientation = .vertical; empty.alignment = .centerX; empty.spacing = 12

        let productIcon = NSImageView(image: NSApp.applicationIconImage)
        productIcon.imageScaling = .scaleProportionallyUpOrDown
        state.font = .systemFont(ofSize: 12, weight: .medium); state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [
            FooterAction("执行", key: "↩") { [weak self] in self?.executeSelection() },
            FooterAction("刷新", key: "⌘R") { [weak self] in self?.refresh() },
            FooterAction("设置", key: "⌘,") { [weak self] in self?.openSettings() }
        ])
        actions.spacing = 16; actions.alignment = .centerY
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        let topLine = NSBox(), bottomLine = NSBox()
        topLine.boxType = .separator; bottomLine.boxType = .separator
        for view in [targetIcon, search, topLine, header, timing, scroll, empty, bottomLine, productIcon, state, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            targetIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            targetIcon.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 29),
            targetIcon.widthAnchor.constraint(equalToConstant: 24), targetIcon.heightAnchor.constraint(equalToConstant: 24),
            search.leadingAnchor.constraint(equalTo: targetIcon.trailingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            search.centerYAnchor.constraint(equalTo: targetIcon.centerYAnchor),
            topLine.topAnchor.constraint(equalTo: root.topAnchor, constant: 58),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor), topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 9),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            timing.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            timing.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            timing.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            bottomLine.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -42),
            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor), bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            productIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            productIcon.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -21),
            productIcon.widthAnchor.constraint(equalToConstant: 18), productIcon.heightAnchor.constraint(equalToConstant: 18),
            state.leadingAnchor.constraint(equalTo: productIcon.trailingAnchor, constant: 8),
            state.centerYAnchor.constraint(equalTo: productIcon.centerYAnchor),
            state.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -16),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            actions.centerYAnchor.constraint(equalTo: productIcon.centerYAnchor)
        ])
        showEmpty(nil)
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// The caller has already captured `target`, before anything here can change which application is in front.
    func present(target: NSRunningApplication, requestedAt: Date = Date()) {
        begin(name: target.localizedName ?? "当前 App", icon: target.icon)
        reader = MenuReader(target: target)
        self.requestedAt = requestedAt
        show()
        refresh()
    }

    /// Offscreen checks: the production views filled from a given snapshot, without reading any application.
    func presentFixture(_ snapshot: MenuSnapshot, icon: NSImage? = NSImage(named: NSImage.applicationIconName)) {
        begin(name: snapshot.app, icon: icon)
        apply(snapshot)
    }

    /// Opens the panel only to say why nothing can be searched.
    func present(message text: String) {
        begin(name: "", icon: NSApp.applicationIconImage)
        showEmpty(text)
        state.stringValue = "没有可搜索的 App"
        show()
    }

    private func begin(name: String, icon: NSImage?) {
        active = true; generation += 1
        busy = false; executing = false
        reader = nil; snapshot = nil; index = MenuSearchIndex([]); shown = []
        targetName = name; rowIcon = icon
        targetIcon.image = icon
        search.stringValue = ""
        search.placeholderString = name.isEmpty ? "搜索菜单命令…" : "搜索 \(name) 的菜单命令…"
        header.stringValue = name; timing.stringValue = ""
        state.stringValue = ""; state.textColor = .secondaryLabelColor
        panel.title = name.isEmpty ? Env.productName : "\(Env.productName) · \(name)"
        showEmpty(nil)
        table.reloadData()
    }

    private func showEmpty(_ text: String?, accessibility: Bool = false) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        accessibilityButton.isHidden = !accessibility
    }

    private func show() {
        guard !testing else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + frame.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        panel.invalidateShadow()
    }

    @objc private func openAccessibility() {
        guard !testing else { return }
        // Makes the system list this application, then opens the pane where the user decides.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        close()
    }

    func openSettings() {
        close()
        onOpenSettings?()
    }

    func refresh() {
        guard active, !busy, let reader else { return }
        busy = true
        state.stringValue = "正在读取菜单…"; state.textColor = .secondaryLabelColor
        generation += 1
        let version = generation
        queue.async { [weak self] in
            let result = Result { try reader.scan() }
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == version else { return }
                self.busy = false
                switch result {
                case .success(let snapshot): self.apply(snapshot)
                case .failure(let error):
                    self.snapshot = nil; self.index = MenuSearchIndex([]); self.shown = []
                    self.table.reloadData(); self.timing.stringValue = ""
                    self.header.stringValue = self.targetName
                    self.state.stringValue = "读取失败，可按 ⌘R 重试"; self.state.textColor = .systemOrange
                    self.showEmpty(error.localizedDescription, accessibility: !AXIsProcessTrusted())
                    self.requestedAt = nil
                }
            }
        }
    }

    func apply(_ snapshot: MenuSnapshot) {
        self.snapshot = snapshot
        index = MenuSearchIndex(snapshot.items)
        targetName = snapshot.app
        search.placeholderString = "搜索 \(snapshot.app) 的菜单命令…"
        panel.title = "\(Env.productName) · \(snapshot.app)"
        filter()
        if let requestedAt {
            self.requestedAt = nil
            if !testing { panel.displayIfNeeded() }
            onReady?(Ready(elapsedMS: Date().timeIntervalSince(requestedAt) * 1000, scanMS: snapshot.durationMS,
                           count: snapshot.items.count, complete: snapshot.complete))
        }
    }

    func filter() {
        let oldID = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].id : nil
        shown = index.filter(search.stringValue)
        table.reloadData()
        let row = oldID.flatMap { id in shown.firstIndex { $0.id == id } } ?? (shown.isEmpty ? nil : 0)
        if let row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        else { table.deselectAll(nil) }
        guard let snapshot else { return }
        let total = snapshot.items.count
        header.stringValue = shown.count == total ? "\(snapshot.app)（\(total) 条）" : "\(snapshot.app)（\(shown.count) / \(total) 条）"
        timing.stringValue = "\(Int(snapshot.durationMS.rounded())) ms"
        if snapshot.complete {
            state.stringValue = "仅搜索 \(snapshot.app) 的菜单"; state.textColor = .secondaryLabelColor
        } else {
            state.stringValue = "结果不完整：" + snapshot.warnings.joined(separator: " "); state.textColor = .systemOrange
        }
        showEmpty(shown.isEmpty ? (total == 0 ? "\(snapshot.app) 没有可读取的菜单命令。" : "没有匹配的菜单命令") : nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CommandRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: CommandCell.identifier, owner: nil) as? CommandCell ?? CommandCell(frame: .zero)
        cell.show(shown[row], icon: rowIcon)
        return cell
    }

    func controlTextDidChange(_ notification: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // An input method that is still composing owns Return, the arrows and Esc.
        if textView.hasMarkedText() { return false }
        // Preserve standard text editing (including modifier-arrow movements).
        if NSApp.currentEvent?.modifierFlags.intersection([.command, .option, .control]).isEmpty == false { return false }
        switch NSStringFromSelector(selector) {
        case "moveDown:": move(1); return true
        case "moveUp:": move(-1); return true
        case "insertNewline:": executeSelection(); return true
        case "cancelOperation:": close(); return true
        default: return false
        }
    }
    private func move(_ step: Int) {
        guard !shown.isEmpty else { return }
        let row = min(shown.count - 1, max(0, table.selectedRow + step))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc func executeSelection() {
        guard active, !busy, shown.indices.contains(table.selectedRow) else { return }
        let command = shown[table.selectedRow]
        guard command.enabled else { state.stringValue = "这个命令当前不可用"; state.textColor = .systemOrange; return }
        if testing { testExecuted.append(command.id); return }
        guard let reader, let current = NSWorkspace.shared.frontmostApplication,
              current.processIdentifier == reader.target.processIdentifier else {
            state.stringValue = "当前 App 已变化，请关闭面板后重新呼出。"; state.textColor = .systemOrange; return
        }
        busy = true; executing = true
        let version = generation
        // Return the key focus before pressing, without activating or switching the target app.
        panel.orderOut(nil)
        queue.async { [weak self] in
            let result = Result { try reader.perform(command) }
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == version else { return }
                switch result {
                case .success: self.close()
                case .failure(let error):
                    self.busy = false; self.executing = false
                    self.show()
                    self.state.stringValue = error.localizedDescription; self.state.textColor = .systemOrange
                }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) { if !executing { close() } }
    func windowWillClose(_ notification: Notification) { close() }

    /// Ends this presentation and drops everything read for it. The process is not touched here.
    func close() {
        guard active else { return }
        active = false; generation += 1
        busy = false; executing = false; requestedAt = nil
        if testing { testClosed += 1 } else { panel.orderOut(nil) }
        reader = nil; snapshot = nil; index = MenuSearchIndex([]); shown = []
        rowIcon = nil; targetIcon.image = nil
        search.stringValue = ""
        table.reloadData()
        onClosed?()
    }
}
