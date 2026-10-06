import Foundation
import Darwin

/// Product identity and the places it keeps state. Nothing here is shared with MacKit.
enum Env {
    static let bundleID = "cyou.tianli.menusearch"
    static let productName = "MenuSearch"
    static let installedBundlePath = "/Applications/MenuSearch.app"

    /// Set only by tests. Every file the product writes then lives under this directory, and commands that read or
    /// act on real applications, global shortcuts, login items or the installed app refuse to run.
    static let isolatedRoot: URL? = {
        guard let path = ProcessInfo.processInfo.environment["MENUSEARCH_SUPPORT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }()
    static var isolated: Bool { isolatedRoot != nil }

    static let supportDirectory: URL = isolatedRoot ?? FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID, isDirectory: true)
    static var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var tuningOverrideURL: URL { supportDirectory.appendingPathComponent("tuning.json") }
    static var lockPath: String { supportDirectory.appendingPathComponent("instance.lock").path }
    static var lastShowURL: URL { supportDirectory.appendingPathComponent("last-show.json") }
    /// Left by an upgrade for the start that follows it: the helper reopens the application, and that start
    /// must not bring up a window.
    static var quietRelaunchURL: URL { supportDirectory.appendingPathComponent("relaunch-quietly") }

    /// A Unix socket path is limited to 103 bytes. The support directory is used when it fits; otherwise the
    /// per-user temporary directory with a name derived from the support directory, so both sides agree.
    static let socketPath: String = {
        let preferred = supportDirectory.appendingPathComponent("control.sock").path
        if preferred.utf8.count < 100 { return preferred }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let temp = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in supportDirectory.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return (temp as NSString).appendingPathComponent("menusearch-" + String(hash, radix: 16) + ".sock")
    }()

    /// The real executable, also when started through the ~/.local/bin/menusearch link.
    static let executableURL: URL = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        _NSGetExecutablePath(&buffer, &size)
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }()
    static let bundleURL: URL? = {
        let macOS = executableURL.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }()
    static let info: [String: Any] = bundleURL
        .flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) as? [String: Any] } ?? [:]
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "0" }
    static var build: String { info["CFBundleVersion"] as? String ?? "0" }
    static var resourcesURL: URL? { bundleURL?.appendingPathComponent("Contents/Resources", isDirectory: true) }

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

struct ProductError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Values that follow macOS rather than this product's code: which top-level menus are the system's, and how long a
/// slow application may hold a read. Shipped as Resources/tuning.json; a file of the same shape in the support
/// directory overrides single keys without a new build. Bad or missing values fall back to the built-in ones.
struct Tuning: Equatable {
    var skipTopLevelTitles: [String] = ["Apple", "苹果", ""]
    var scanDeadlineSeconds: Double = 5
    var messagingTimeoutSeconds: Double = 0.3
    var maxItems: Int = 10_000
    var maxDepth: Int = 64

    static let shared = load(bundled: Env.resourcesURL?.appendingPathComponent("tuning.json"), override: Env.tuningOverrideURL)

    static func load(bundled: URL?, override: URL?) -> Tuning {
        var tuning = Tuning()
        for url in [bundled, override].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url), data.count <= 65_536,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            tuning.merge(object)
        }
        return tuning
    }

    mutating func merge(_ object: [String: Any]) {
        if let titles = object["skip_top_level_titles"] as? [String], titles.count <= 64 { skipTopLevelTitles = titles }
        if let value = (object["scan_deadline_seconds"] as? NSNumber)?.doubleValue { scanDeadlineSeconds = min(30, max(0.5, value)) }
        if let value = (object["messaging_timeout_seconds"] as? NSNumber)?.doubleValue { messagingTimeoutSeconds = min(5, max(0.05, value)) }
        if let value = (object["max_items"] as? NSNumber)?.intValue { maxItems = min(100_000, max(100, value)) }
        if let value = (object["max_depth"] as? NSNumber)?.intValue { maxDepth = min(256, max(4, value)) }
    }
}
