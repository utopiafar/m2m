import Foundation

/// 本地中继：模拟"第三方中转服务器"的角色，但完全不承载业务内容。
///
/// 设计要点（对齐 docs/02-architecture.md 与 T3）：
/// - 只做连接协调与转发，不运行目标应用、不做视频转码、不解析业务语义
/// - 可在线调整链路条件（延迟 / 抖动 / 丢包 / 带宽），用于"兼容各种带宽"的验证
/// - 单机部署时通过私有 UDS 提供，不监听任何网络端口
public final class RelayServer {
    public private(set) var conditions: LinkConditions
    private let listener: IPCListener
    private var hostConnection: IPCConnection?
    private var viewerConnection: IPCConnection?
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var scheduler: SimulatedNetwork

    public private(set) var forwardedHostToViewer = 0
    public private(set) var forwardedViewerToHost = 0
    public private(set) var bytesHostToViewer = 0
    public private(set) var bytesViewerToHost = 0
    /// 供报告使用的链路统计
    public var linkStats: LinkStats { scheduler.link.stats }

    /// 外部控制文件（可选）：用于在不建立额外连接的前提下调整链路条件。
    public var controlFile: ControlFile?

    public init(socketPath: String, conditions: LinkConditions = .lan, seed: UInt64 = 0xC0FFEE,
                controlFilePath: String? = nil) {
        self.conditions = conditions
        self.listener = IPCListener(path: socketPath, label: "m2m.relay")
        self.scheduler = SimulatedNetwork(conditions: conditions, seed: seed)
        if let controlFilePath {
            self.controlFile = ControlFile(url: URL(fileURLWithPath: controlFilePath))
        }
    }

    public func start() throws {
        listener.maxConnections = 2
        listener.onAccept = { [weak self] conn in
            self?.accept(conn)
        }
        try listener.start()
        startPump()
        startControlPolling()
    }

    /// 轮询控制文件，应用新的链路条件（模拟"网络状况变化"）。
    private func startControlPolling() {
        guard controlFile != nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "m2m.relay.control"))
        t.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in
            guard let self, let control = self.controlFile?.readIfChanged(RelayControl.self) else { return }
            if let conditions = control.conditions {
                self.update(conditions: conditions.apply(to: self.conditions))
            }
            if let down = control.down { self.setDown(down) }
        }
        controlTimer = t
        t.resume()
    }

    private var controlTimer: DispatchSourceTimer?

    private func accept(_ conn: IPCConnection) {
        lock.lock()
        let role: String
        if hostConnection == nil {
            hostConnection = conn
            role = "host"
        } else if viewerConnection == nil {
            viewerConnection = conn
            role = "viewer"
        } else {
            lock.unlock()
            conn.close()
            return
        }
        lock.unlock()

        if role == "host" {
            // Host 发来的数据 → 目标为 Viewer 方向（toB）
            conn.onReceive = { [weak self] data in
                guard let self else { return }
                self.scheduler.link.enqueue(data, channel: .media, direction: .toB)
                self.forwardedHostToViewer += 1
                self.bytesHostToViewer += data.count
            }
        } else {
            conn.onReceive = { [weak self] data in
                guard let self else { return }
                self.scheduler.link.enqueue(data, channel: .media, direction: .toA)
                self.forwardedViewerToHost += 1
                self.bytesViewerToHost += data.count
            }
        }
        conn.onClose = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if role == "host" { self.hostConnection = nil } else { self.viewerConnection = nil }
            self.lock.unlock()
        }
    }

    /// 定时把链路中到期的数据投递给对端。
    ///
    /// 中继不解析内容，因此这里统一用 `.media` 通道入队——真实的优先级调度发生在
    /// 端点的发送侧（`SimulatedEndpoint`），中继只负责"按当前网络条件转发"。
    private func startPump() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "m2m.relay.pump"))
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let packets = self.scheduler.link.advance(by: 0.002)
            guard !packets.isEmpty else { return }
            self.lock.lock()
            let host = self.hostConnection
            let viewer = self.viewerConnection
            self.lock.unlock()
            for p in packets {
                if p.direction == .toB { viewer?.send(p.data) }
                else { host?.send(p.data) }
            }
        }
        timer = t
        t.resume()
    }

    public func update(conditions newValue: LinkConditions) {
        lock.lock()
        conditions = newValue
        lock.unlock()
        scheduler.setConditions(newValue)
    }

    public func setDown(_ down: Bool) {
        scheduler.setDown(down)
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        controlTimer?.cancel()
        controlTimer = nil
        listener.stop()
        // 先在锁内把引用摘掉，再在锁外关闭连接。
        // connection.close() 会回调 onClose，而 onClose 需要同一把锁；
        // 如果持锁调用就会自锁死。
        lock.lock()
        let host = hostConnection
        let viewer = viewerConnection
        hostConnection = nil
        viewerConnection = nil
        lock.unlock()
        host?.close()
        viewer?.close()
    }

    /// 已接入的端点数（0/1/2）。编排器据此判断"两端都就位"，而不是只看状态文件存在。
    public var connectedEndpointCount: Int {
        lock.lock(); defer { lock.unlock() }
        return (hostConnection != nil ? 1 : 0) + (viewerConnection != nil ? 1 : 0)
    }

    public var statusDescription: String {
        let h = hostConnection != nil ? "已接入" : "未接入"
        let v = viewerConnection != nil ? "已接入" : "未接入"
        return "Host \(h) / Viewer \(v) / 条件 \(conditions.description)"
    }
}
