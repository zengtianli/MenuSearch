#if APP_STORE
// Standard settings entry for Mac App Store / TestFlight editions, which carry no shared lifecycle code (its updater,
// iCloud document sync and CLI are outside the sandbox build). Same rule as the download edition's AppLifecycleUI
// (本人 2026-10-18 / 2026-11-08): ⌘, opens 设置…/Settings…, whose first row is the interface language — Follow System,
// 简体中文 or English — stored as this app's own AppleLanguages override and applied when the app reopens.
//
// One shared copy, vendored byte-for-byte like every swift-shared file (chapter l10n vendor / chapter rollout); store
// editions add it to their store target and write no language or ⌘, code of their own (2026-11-08: Cadence and
// KeyScope each had a hand-written copy). Use:
//   · app menu:   appMenu.addItem(StoreSettingsEntry.menuItem(target: self, action: #selector(openSettings)))
//   · settings:   StoreSettingsEntry.window(appName: "Cadence", content: AnyView(…product rows…)).makeKeyAndOrderFront(nil)
//                 or put StoreLanguagePicker(appName:) first in the product's own SwiftUI settings form
//   · self-test:  StoreLanguage.domain = <isolated domain>, then set/current/resolved round trip
// Text here is in both languages (StoreText.pick), so a product's string catalog needs no entries for it.
import AppKit
import SwiftUI

enum StoreText {
    /// The interface language this process shows: APP_LIFECYCLE_LANGUAGE (self-tests pin it), else the bundle's
    /// preferred localization, else the system list. Same order as LifecycleText in the shared lifecycle layer.
    static var language: String {
        if let pinned = ProcessInfo.processInfo.environment["APP_LIFECYCLE_LANGUAGE"], !pinned.isEmpty { return resolve([pinned]) }
        let declared = Bundle.main.localizations.filter { $0 != "Base" }
        if !declared.isEmpty { return resolve(Bundle.main.preferredLocalizations.filter { $0 != "Base" }) }
        return resolve(Locale.preferredLanguages)
    }
    static func resolve(_ identifiers: [String]) -> String {
        (identifiers.first ?? "en").lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    }
    static func pick(_ english: String, _ chinese: String) -> String { language == "zh-Hans" ? chinese : english }
}

/// In-app language choice, stored as this app's own `AppleLanguages` override (the mechanism of System Settings →
/// Language & Region → Applications), applied at the next launch. "Follow System" removes the override.
enum StoreLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", en
    var id: String { rawValue }

    static let key = "AppleLanguages"
    /// The defaults domain holding the override; self-tests point it at an isolated domain.
    static var domain = Bundle.main.bundleIdentifier ?? "app"
    /// Language names written in their own language: an English interface still shows 简体中文. Checks for leftover
    /// Chinese in English screens exempt them (Chapter l10n LANGUAGE_ENDONYMS holds the same names).
    static let endonyms: Set<String> = ["简体中文", "English"]

    var title: String {
        switch self {
        case .system: return StoreText.pick("Follow System", "跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
    /// Only this app's own domain counts; the global list is the system language, not a choice.
    static var current: StoreLanguage {
        guard let code = (UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String])?.first?.lowercased()
        else { return .system }
        return code.hasPrefix("zh") ? .zhHans : (code.hasPrefix("en") ? .en : .system)
    }
    /// Saves the choice; returns true when the process must reopen to show it.
    @discardableResult static func set(_ choice: StoreLanguage) -> Bool {
        var values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        values[key] = choice == .system ? nil : [choice.rawValue]
        UserDefaults.standard.setPersistentDomain(values, forName: domain)
        return needsRelaunch
    }
    /// The interface language the saved choice resolves to at the next launch.
    static var resolved: String {
        switch current {
        case .system:
            let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
            let pick = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: system ?? Locale.preferredLanguages).first ?? "en"
            return StoreText.resolve([pick])
        case let choice: return choice.rawValue
        }
    }
    static var needsRelaunch: Bool { resolved != StoreText.language }
    /// Opens a fresh instance of this app, then quits this one.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async { if error == nil { NSApp.terminate(nil) } }
        }
    }
}

/// The language row: picker, then "takes effect after reopening" with a Reopen Now button when needed.
/// SwiftUI types are written in full so a product's own Binding/Text/View types cannot collide.
@available(macOS 13.0, *)
struct StoreLanguagePicker: SwiftUI.View {
    let appName: String
    @SwiftUI.State private var choice = StoreLanguage.current
    @SwiftUI.State private var relaunchNeeded = StoreLanguage.needsRelaunch
    var body: some SwiftUI.View {
        SwiftUI.VStack(alignment: .leading, spacing: 8) {
            SwiftUI.Picker(StoreText.pick("Language", "界面语言"), selection: SwiftUI.Binding(
                get: { choice }, set: { choice = $0; relaunchNeeded = StoreLanguage.set($0) })) {
                SwiftUI.ForEach(StoreLanguage.allCases) { SwiftUI.Text(verbatim: $0.title).tag($0) }
            }.accessibilityIdentifier("settings.language")
            if relaunchNeeded {
                SwiftUI.HStack {
                    SwiftUI.Text(verbatim: StoreText.pick("Takes effect after \(appName) reopens.", "重新打开 \(appName) 后生效。"))
                        .font(.caption).foregroundStyle(.secondary)
                    SwiftUI.Spacer()
                    SwiftUI.Button(StoreText.pick("Reopen Now", "立即重新打开")) { StoreLanguage.relaunch() }
                }
            }
        }
    }
}

enum StoreSettingsEntry {
    static var title: String { StoreText.pick("Settings…", "设置…") }
    /// 设置…/Settings… with ⌘, for the app menu.
    static func menuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ",")
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        return item
    }
    @MainActor private static var cached: NSWindow?
    /// The standard settings window: the language row first, then the product's own rows (`content`). With
    /// show: false it stays offscreen and hidden (self-tests render it).
    @available(macOS 13.0, *)
    @MainActor @discardableResult static func window(appName: String, content: SwiftUI.AnyView? = nil, show: Bool = true) -> NSWindow {
        let window = cached ?? {
            let made = NSWindow(contentRect: NSRect(x: show ? 0 : -20000, y: show ? 0 : -20000, width: 460, height: 240),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            made.title = StoreText.pick("\(appName) Settings", "\(appName) 设置")
            made.isReleasedWhenClosed = false
            made.contentView = NSHostingView(rootView: SwiftUI.VStack(alignment: .leading, spacing: 14) {
                StoreLanguagePicker(appName: appName)
                if let content { SwiftUI.Divider(); content }
            }.padding(20).frame(width: 460, alignment: .leading))
            return made
        }()
        cached = window
        if show { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        return window
    }
}
#endif
