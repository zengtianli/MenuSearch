import Foundation
import Darwin

/// One protocol for the single instance and for every outside caller: a lock file names the primary process, and a
/// Unix socket beside it carries one JSON request and one JSON reply per connection. Only the same user may connect.
enum Control {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func configure(_ descriptor: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    static func readLine(_ descriptor: Int32, limit: Int = 262_144) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(chunk, count: count)
            if chunk[..<count].contains(0x0A) { break }
        }
        guard let end = data.firstIndex(of: 0x0A) else { return data.isEmpty ? nil : data }
        return data.prefix(upTo: end)
    }

    /// nil when no primary instance is listening.
    static func request(_ payload: [String: Any], socketPath: String = Env.socketPath, timeout: TimeInterval = 5) -> [String: Any]? {
        guard var address = address(socketPath) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        configure(descriptor, timeout: timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        data.append(0x0A)
        guard writeAll(descriptor, data), let line = readLine(descriptor) else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Whether some process holds the instance lock. A read-only probe: it creates nothing.
    static func primaryHoldsLock(lockPath: String = Env.lockPath) -> Bool {
        let descriptor = open(lockPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { flock(descriptor, LOCK_UN); return false }
        return true
    }
}

final class ControlServer {
    private let lockPath: String
    private let socketPath: String
    private var lockDescriptor: Int32 = -1
    private var listenDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "cyou.tianli.menusearch.control")
    /// Runs on the main queue.
    var handler: (([String: Any]) -> [String: Any])?

    init(lockPath: String = Env.lockPath, socketPath: String = Env.socketPath) {
        self.lockPath = lockPath; self.socketPath = socketPath
    }

    /// false when another process is already the primary instance.
    func acquire() -> Bool {
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        // A status probe holds a shared lock for an instant; a few short retries tell it apart from a real primary.
        for attempt in 0..<5 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { lockDescriptor = descriptor; return true }
            if attempt < 4 { usleep(10_000) }
        }
        close(descriptor)
        return false
    }

    func listen() throws {
        guard lockDescriptor >= 0 else { throw ProductError("没有取得实例锁。") }
        guard var address = Control.address(socketPath) else { throw ProductError("状态目录路径过长，无法建立本机控制通道。") }
        unlink(socketPath) // only the lock holder gets here, so a leftover file belongs to a dead instance
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProductError("无法建立本机控制通道。") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, S_IRUSR | S_IWUSR) == 0, Darwin.listen(descriptor, 8) == 0 else {
            close(descriptor); unlink(socketPath)
            throw ProductError("无法监听本机控制通道（\(String(cString: strerror(errno)))）。")
        }
        listenDescriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    private func accept() {
        let client = Darwin.accept(listenDescriptor, nil, nil)
        guard client >= 0 else { return }
        var user: uid_t = 0, group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == getuid() else { close(client); return }
        Control.configure(client, timeout: 2)
        guard let line = Control.readLine(client),
              let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { close(client); return }
        DispatchQueue.main.async { [weak self] in
            let reply = self?.handler?(request) ?? ["ok": false, "error": "MenuSearch 尚未就绪。"]
            var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
            data.append(0x0A)
            (self?.queue ?? .global()).async { _ = Control.writeAll(client, data); close(client) }
        }
    }

    func stop() {
        source?.cancel(); source = nil
        if listenDescriptor >= 0 { close(listenDescriptor); listenDescriptor = -1; unlink(socketPath) }
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor); lockDescriptor = -1 }
    }
}
