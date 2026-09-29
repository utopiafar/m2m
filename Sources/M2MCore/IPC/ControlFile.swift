import Foundation

/// 进程外控制入口。
///
/// 用途：让编排器（m2mctl）在不额外建立连接的前提下调整中继的链路条件、
/// 或驱动目标应用（demo）打开窗口/设置文本。
///
/// 隔离：控制文件位于该进程自己的私有运行子目录内，权限 0600，
/// 由进程轮询读取；不引入任何网络监听面，也不与业务数据通道混用。
public final class ControlFile {
    public let url: URL
    private var lastModified: Date?
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    /// 读取当前内容（仅当文件发生变化时返回非 nil，避免重复执行）。
    public func readIfChanged<T: Decodable>(_ type: T.Type) -> T? {
        lock.lock(); defer { lock.unlock() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attrs?[.modificationDate] as? Date else { return nil }
        if let last = lastModified, modified <= last { return nil }
        lastModified = modified
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func write<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
}

/// 中继控制指令。
public struct RelayControl: Codable, Sendable {
    public struct Conditions: Codable, Sendable {
        public var oneWayLatencyMs: Double?
        public var jitterMs: Double?
        public var lossRate: Double?
        public var bandwidthMbps: Double?
        public var down: Bool?

        public init(oneWayLatencyMs: Double? = nil, jitterMs: Double? = nil,
                    lossRate: Double? = nil, bandwidthMbps: Double? = nil, down: Bool? = nil) {
            self.oneWayLatencyMs = oneWayLatencyMs; self.jitterMs = jitterMs
            self.lossRate = lossRate; self.bandwidthMbps = bandwidthMbps; self.down = down
        }

        public func apply(to base: LinkConditions) -> LinkConditions {
            var c = base
            if let v = oneWayLatencyMs { c.oneWayLatency = v / 1000 }
            if let v = jitterMs { c.jitter = v / 1000 }
            if let v = lossRate { c.lossRate = v }
            if let v = bandwidthMbps {
                c.capacityBytesPerSecond = v <= 0 ? nil : v * 1_000_000 / 8
            }
            if let v = down { c.isDown = v }
            return c
        }
    }

    public var conditions: Conditions?
    public var down: Bool?

    public init(conditions: Conditions? = nil, down: Bool? = nil) {
        self.conditions = conditions; self.down = down
    }
}

/// demo 控制指令（批量）。
public struct DemoControl: Codable, Sendable {
    public var requests: [DemoRequest]
    public init(requests: [DemoRequest]) { self.requests = requests }
}
