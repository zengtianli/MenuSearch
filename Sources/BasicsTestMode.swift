#if !APP_STORE
import Foundation

/// A disposable, re-identified application may exercise the real lifecycle against private fixtures.
/// The installed identity can never enable this transport, even when a caller sets all test variables.
enum BasicsTestMode {
    static let channel = "basics-test"
    static var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        guard Env.isolated, let identity = Bundle.main.bundleIdentifier,
              identity.hasPrefix("test.tianli.menusearch.basics."),
              let path = env["MENUSEARCH_BASICS_ROOT"], !path.isEmpty,
              let local = env["APP_LIFECYCLE_SUPPORT_DIR"], let cloud = env["APP_LIFECYCLE_CLOUD_DIR"],
              let fixedHome = env["CFFIXED_USER_HOME"] else { return false }
        let rootURL = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let root = rootURL.path
        guard rootURL.lastPathComponent.hasPrefix("product-basics-"),
              rootURL.deletingLastPathComponent().lastPathComponent == "acceptance",
              rootURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "perf" else { return false }
        func inside(_ path: String) -> Bool {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/")
        }
        return inside(Env.supportDirectory.path) && inside(local) && inside(cloud) && inside(fixedHome)
            && URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
                == URL(fileURLWithPath: fixedHome).standardizedFileURL.path
    }

    static var updateSource: AppUpdateSource {
        enabled ? .privateCloud(channel: channel) : UpdateChannel.current.updateSource
    }

    static func allowsUpdate(_ arguments: [String]) -> Bool {
        guard enabled, arguments.first == "update", arguments.count > 1 else { return false }
        switch arguments[1] {
        case "check", "options": return true
        case "install": return arguments.contains("--dry-run") && !arguments.contains("--yes")
        default: return false
        }
    }
}
#endif
