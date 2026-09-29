import Foundation

/// Unix 域套接字封装。单机多进程隔离的传输基础。
///
/// 为什么用 UDS 而不是 TCP：
/// - 不占用端口，不经过网络栈，不会被同机其他用户/进程从网络上访问
/// - 套接字文件放在私有运行目录内并设为 0600，天然形成进程间隔离边界
/// - 单机上仍走完整的字节流与背压语义，足以验证协议与恢复行为
public enum IPCError: Error, LocalizedError {
    case socketCreateFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case closed
    case framingError

    public var errorDescription: String? {
        switch self {
        case .socketCreateFailed(let s): return "创建套接字失败：\(s)"
        case .bindFailed(let s): return "绑定失败：\(s)"
        case .listenFailed(let s): return "监听失败：\(s)"
        case .connectFailed(let s): return "连接失败：\(s)"
        case .closed: return "连接已关闭"
        case .framingError: return "帧格式错误"
        }
    }
}

/// 长度前缀帧：[4 字节大端长度][payload]
public enum IPCFraming {
    public static let headerSize = 4
    public static let maxPayload = 32 * 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + headerSize)
        let n = UInt32(payload.count)
        out.append(UInt8((n >> 24) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8(n & 0xFF))
        out.append(payload)
        return out
    }
}

/// 一个已建立的 UDS 连接。线程安全的发送 + 后台接收循环。
public final class IPCConnection {
    public typealias Handler = (Data) -> Void

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    public var onReceive: Handler?
    public var onClose: (() -> Void)?
    public private(set) var bytesSent = 0
    public private(set) var bytesReceived = 0
    private var readBuffer = Data()
    private let readQueue: DispatchQueue

    public init(fd: Int32, label: String = "m2m.ipc") {
        self.fd = fd
        self.readQueue = DispatchQueue(label: label)
        // 关闭 SIGPIPE，写失败时返回 EPIPE 而不是杀进程
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        startReading()
    }

    private func startReading() {
        readQueue.async { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = recv(self.fd, &buf, buf.count, 0)
                if n > 0 {
                    self.lock.lock()
                    self.bytesReceived += n
                    self.readBuffer.append(contentsOf: buf[0..<n])
                    let frames = self.drainFrames()
                    self.lock.unlock()
                    for f in frames { self.onReceive?(f) }
                } else if n == 0 {
                    self.handleClose()
                    return
                } else {
                    if errno == EINTR { continue }
                    self.handleClose()
                    return
                }
            }
        }
    }

    /// 必须在持锁状态下调用。
    private func drainFrames() -> [Data] {
        var out: [Data] = []
        while readBuffer.count >= IPCFraming.headerSize {
            let b = [UInt8](readBuffer.prefix(4))
            let len = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            guard len >= 0, len <= IPCFraming.maxPayload else {
                readBuffer.removeAll()
                break
            }
            guard readBuffer.count >= IPCFraming.headerSize + len else { break }
            let start = readBuffer.startIndex + IPCFraming.headerSize
            let payload = Data(readBuffer[start..<(start + len)])
            readBuffer.removeFirst(IPCFraming.headerSize + len)
            out.append(payload)
        }
        return out
    }

    private func handleClose() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { onClose?() }
    }

    public func send(_ payload: Data) {
        let framed = IPCFraming.frame(payload)
        lock.lock()
        guard !closed else { lock.unlock(); return }
        bytesSent += framed.count
        lock.unlock()
        var offset = 0
        framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < framed.count {
                let n = Darwin.send(fd, base.advanced(by: offset), framed.count - offset, 0)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        if !wasClosed { onClose?() }
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

/// UDS 监听器。套接字文件权限固定为 0600，保证只有同一用户可连接。
public final class IPCListener {
    public typealias AcceptHandler = (IPCConnection) -> Void

    private let path: String
    private var fd: Int32 = -1
    private var running = false
    private let acceptQueue: DispatchQueue
    public var onAccept: AcceptHandler?
    /// 最多接受多少连接后停止（用于"只允许两端接入"的中继）。
    public var maxConnections: Int = Int.max
    public private(set) var acceptedCount = 0

    public init(path: String, label: String = "m2m.ipc.listener") {
        self.path = path
        self.acceptQueue = DispatchQueue(label: label)
    }

    public func start() throws {
        try? FileManager.default.removeItem(atPath: path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketCreateFailed(String(cString: strerror(errno))) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPath else { throw IPCError.bindFailed("路径过长") }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxPath) { cptr in
                _ = strncpy(cptr, path, maxPath - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            let e = String(cString: strerror(errno))
            Darwin.close(fd)
            throw IPCError.bindFailed(e)
        }
        // 只允许当前用户访问
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw IPCError.listenFailed(String(cString: strerror(errno)))
        }
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while running {
            if fd < 0 { break }
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            if acceptedCount >= maxConnections {
                Darwin.close(clientFD)
                continue
            }
            acceptedCount += 1
            onAccept?(IPCConnection(fd: clientFD, label: "m2m.ipc.conn"))
        }
    }

    public func stop() {
        running = false
        if fd >= 0 {
            // 必须先 shutdown 再 close：仅 close 不保证能唤醒阻塞中的 accept，
            // 会让接收线程永久挂住（关闭时表现为进程无法退出）。
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// UDS 客户端连接。
public enum IPCClient {
    public static func connect(to path: String) throws -> IPCConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketCreateFailed(String(cString: strerror(errno))) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPath else {
            Darwin.close(fd)
            throw IPCError.connectFailed("路径过长")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxPath) { cptr in
                _ = strncpy(cptr, path, maxPath - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else {
            let e = String(cString: strerror(errno))
            Darwin.close(fd)
            throw IPCError.connectFailed("\(e)（路径 \(path)）")
        }
        return IPCConnection(fd: fd, label: "m2m.ipc.client")
    }

    /// 带重试的连接（用于启动顺序不确定的多进程场景）。
    public static func connectWithRetry(to path: String, timeout: TimeInterval = 10) throws -> IPCConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = IPCError.connectFailed("未尝试")
        while Date() < deadline {
            do { return try connect(to: path) }
            catch { lastError = error; usleep(50_000) }
        }
        throw lastError
    }
}
