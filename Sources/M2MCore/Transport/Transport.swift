import Foundation

/// 传输层抽象。真实实现走 WebRTC（T3）；单机验证走本文件内的模拟链路。
///
/// 之所以先做模拟链路：规格 T7 的正确性要求（输入不被文件阻塞、按键不丢、
/// 媒体可丢）必须在**可控且可确定复现**的条件下验证，而不是"在局域网上看起来还行"。
public protocol TransportChannel: AnyObject {
    var channel: Channel { get }
    /// 可靠有序通道不得丢弃；媒体通道允许丢弃过期数据。
    func send(_ data: Data)
    var onReceive: ((Data) -> Void)? { get set }
}

public enum TransportState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case degraded(String)
    case disconnected(String?)
}

public protocol Transport: AnyObject {
    var state: TransportState { get }
    var onStateChange: ((TransportState) -> Void)? { get set }
    func channel(_ channel: Channel) -> TransportChannel
    func start()
    func stop()
}

public extension Transport {
    func channel(_ c: Channel) -> TransportChannel { fatalError("unimplemented") }
}

// MARK: - 链路条件

/// 弱网与带宽条件。取值集合对齐 docs/06-test-plan.md §4 的弱网矩阵。
public struct LinkConditions: Equatable, Sendable {
    /// 单程基础延迟
    public var oneWayLatency: TimeInterval
    /// 抖动幅度（均匀分布 ±jitter）
    public var jitter: TimeInterval
    /// 丢包率 [0,1]
    public var lossRate: Double
    /// 乱序率 [0,1]：命中的包额外延迟一段随机时间
    public var reorderRate: Double
    /// 带宽上限（字节/秒）。nil 表示不限。
    public var capacityBytesPerSecond: Double?
    /// 是否完全断开（模拟网络中断）
    public var isDown: Bool

    public init(oneWayLatency: TimeInterval = 0.005, jitter: TimeInterval = 0,
                lossRate: Double = 0, reorderRate: Double = 0,
                capacityBytesPerSecond: Double? = nil, isDown: Bool = false) {
        self.oneWayLatency = oneWayLatency; self.jitter = jitter
        self.lossRate = lossRate; self.reorderRate = reorderRate
        self.capacityBytesPerSecond = capacityBytesPerSecond; self.isDown = isDown
    }

    public static let lan = LinkConditions()

    public static func rtt(_ ms: Double) -> LinkConditions {
        LinkConditions(oneWayLatency: ms / 2000)
    }

    public static func loss(_ rate: Double) -> LinkConditions {
        LinkConditions(oneWayLatency: 0.04, lossRate: rate)
    }

    public static func bandwidth(mbps: Double) -> LinkConditions {
        LinkConditions(oneWayLatency: 0.04, capacityBytesPerSecond: mbps * 1_000_000 / 8)
    }

    /// 常用预设，对应测试计划里的命名条件。
    public static let rtt80 = LinkConditions.rtt(80)
    public static let rtt160 = LinkConditions.rtt(160)
    public static let rtt250 = LinkConditions.rtt(250)
    public static let bw20Mbps = LinkConditions.bandwidth(mbps: 20)
    public static let bw8Mbps = LinkConditions.bandwidth(mbps: 8)
    public static let bw3Mbps = LinkConditions.bandwidth(mbps: 3)

    /// 验收最恶劣组合（规格 §4 验收规则）。
    public static let worstCase = LinkConditions(
        oneWayLatency: 0.08, jitter: 0.01, lossRate: 0.01,
        reorderRate: 0.005, capacityBytesPerSecond: 3 * 1_000_000 / 8
    )

    public var description: String {
        var parts: [String] = []
        parts.append("RTT \(Int(oneWayLatency * 2000))ms")
        if jitter > 0 { parts.append("抖动 ±\(Int(jitter * 1000))ms") }
        if lossRate > 0 { parts.append("丢包 \(String(format: "%.1f", lossRate * 100))%") }
        if reorderRate > 0 { parts.append("乱序 \(String(format: "%.1f", reorderRate * 100))%") }
        if let cap = capacityBytesPerSecond {
            parts.append("带宽 \(String(format: "%.1f", cap * 8 / 1_000_000))Mbps")
        } else {
            parts.append("带宽不限")
        }
        if isDown { parts.append("链路中断") }
        return parts.joined(separator: " / ")
    }
}

// MARK: - 模拟链路

/// 单机模拟链路：两个端点 + 一条可配置条件的共享链路。
///
/// 两条建模规则，决定了模拟是否可信：
///
/// 1. **按优先级服务**（control > input > state > media > file）。
///    这正是 T7 要求的"输入不得被文件上传阻塞"，可在测试中直接断言。
/// 2. **区分可靠通道与媒体通道**：可靠有序通道（control/input/state/file）在丢包时
///    **重传**，媒体通道则直接丢弃该帧。如果对所有通道一律丢包，模拟会假装
///    "控制消息会丢"，与真实可靠传输不符，规范中的"可靠有序"承诺也就无法被验证。
public final class SimulatedLink {
    public struct Packet {
        public let data: Data
        public let channel: Channel
        public let enqueuedAt: TimeInterval
        public let deliverAt: TimeInterval
        public let sequence: UInt64
        public let direction: Direction
        /// 已重传次数（仅可靠通道使用）。
        public var attempts: Int = 0
    }
    public enum Direction: Sendable, Hashable { case toB, toA }

    /// 可靠通道的重传延迟（模拟 RTO）。
    public var retransmitDelay: TimeInterval = 0.2
    /// 单包最大重传次数，避免不可达时无限重试。
    public var maxRetransmits: Int = 5
    /// 媒体等待队列上限。超出时丢弃**最旧的媒体帧**（优先显示新画面，
    /// 不为每帧都展示而积压历史画面）。可靠通道不受此限制。
    public var maxQueuedMediaPackets: Int = 8

    /// 链路条件，运行时可随时切换（模拟"各种情况"）。
    public var conditionsAtoB: LinkConditions
    public var conditionsBtoA: LinkConditions

    /// 等待开始传输的包（尚未占用链路）。
    private struct Waiting {
        let data: Data
        let channel: Channel
        let enqueuedAt: TimeInterval
        let direction: Direction
        let sequence: UInt64
        let attempts: Int
    }

    private var waiting: [Waiting] = []
    /// 已开始传输、等待送达的包。
    private var inflight: [Packet] = []
    /// 每条方向链路的"重新空闲时刻"。
    private var linkFreeAt: [Direction: TimeInterval] = [.toA: 0, .toB: 0]

    private var clock: TimeInterval = 0
    private let lock = NSLock()

    private var seq: UInt64 = 0
    private var rng: SeededRandom

    /// 已投递包的统计，供测试与报告使用。
    public private(set) var stats = LinkStats()

    public init(seed: UInt64 = 0xC0FFEE, conditions: LinkConditions = .lan) {
        self.rng = SeededRandom(seed: seed)
        self.conditionsAtoB = conditions
        self.conditionsBtoA = conditions
    }

    public var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return clock }

    public func enqueue(_ data: Data, channel: Channel, direction: Direction, attempts: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        let conditions = conditions(direction)
        // 链路中断：一律丢弃，不做缓冲。这样"重连后不得重放"才是被真正验证的行为，
        // 而不是依赖传输层偷偷缓冲。
        guard !conditions.isDown else {
            stats.droppedByLinkDown += 1
            return
        }
        if conditions.lossRate > 0, rng.nextDouble() < conditions.lossRate {
            if channel.isReliableOrdered {
                // 可靠通道：重传，不是丢弃
                stats.retransmissions += 1
                guard attempts < maxRetransmits else {
                    stats.droppedAfterMaxRetransmits += 1
                    return
                }
                seq += 1
                waiting.append(Waiting(data: data, channel: channel,
                                       enqueuedAt: clock + retransmitDelay,
                                       direction: direction, sequence: seq, attempts: attempts + 1))
                return
            }
            // 媒体通道：直接丢弃该帧（实时性优先，等下一帧而不是等重传）
            stats.droppedByLoss += 1
            return
        }
        seq += 1
        waiting.append(Waiting(data: data, channel: channel, enqueuedAt: clock,
                               direction: direction, sequence: seq, attempts: attempts))
        // 媒体背压：丢最旧，不丢新
        if channel == .media {
            let mediaIndices = waiting.indices.filter { waiting[$0].channel == .media }
            if mediaIndices.count > maxQueuedMediaPackets {
                let excess = mediaIndices.count - maxQueuedMediaPackets
                for idx in mediaIndices.prefix(excess).reversed() {
                    waiting.remove(at: idx)
                    stats.droppedByBackpressure += 1
                }
            }
        }
    }

    private func conditions(_ d: Direction) -> LinkConditions {
        d == .toB ? conditionsAtoB : conditionsBtoA
    }

    /// 按优先级把"已到达链路入口"的等待包排入传输。
    ///
    /// 这是 T7 的实现点：同一时刻链路空闲时，优先服务高优先级通道，
    /// 因此一个小的输入包不会被已经排队的文件分块挤到后面。
    private func schedule(upTo limit: TimeInterval) {
        for direction in [Direction.toA, .toB] {
            while true {
                let free = linkFreeAt[direction] ?? 0
                // 只考虑在链路空闲前已到达入口的包
                let eligible = waiting.indices.filter {
                    waiting[$0].direction == direction && waiting[$0].enqueuedAt <= max(free, clock)
                }
                guard !eligible.isEmpty else { break }
                let chosen = eligible.min { a, b in
                    let pa = waiting[a].channel.priority, pb = waiting[b].channel.priority
                    if pa != pb { return pa < pb }
                    return waiting[a].sequence < waiting[b].sequence
                }!
                let w = waiting.remove(at: chosen)
                let c = conditions(direction)
                let service = serializationDelay(bytes: w.data.count, conditions: c)
                let jitter: TimeInterval = c.jitter > 0 ? (rng.nextDouble() * 2 - 1) * c.jitter : 0
                var extra: TimeInterval = 0
                // 乱序只对可丢弃的实时通道建模；可靠有序传输不会乱序送达
                if w.channel.isDroppable, c.reorderRate > 0, rng.nextDouble() < c.reorderRate {
                    extra = rng.nextDouble() * 0.05
                    stats.reordered += 1
                }
                let start = max(free, w.enqueuedAt)
                let deliver = start + service + c.oneWayLatency + jitter + extra
                linkFreeAt[direction] = start + service
                inflight.append(Packet(data: w.data, channel: w.channel, enqueuedAt: w.enqueuedAt,
                                       deliverAt: max(deliver, clock), sequence: w.sequence,
                                       direction: direction, attempts: w.attempts))
                // 排定过程中可能已超过 limit，但排定本身不耗时间，继续直到无可用包
                if linkFreeAt[direction]! > limit && waiting.allSatisfy({ $0.direction != direction || $0.enqueuedAt > linkFreeAt[direction]! }) {
                    break
                }
            }
        }
    }

    private func serializationDelay(bytes: Int, conditions: LinkConditions) -> TimeInterval {
        guard let cap = conditions.capacityBytesPerSecond, cap > 0 else { return 0 }
        return Double(bytes) / cap
    }

    /// 推进时钟并返回此期间应投递的包，按到达时间 + 优先级排序。
    public func advance(to time: TimeInterval) -> [Packet] {
        lock.lock()
        clock = max(clock, time)
        schedule(upTo: clock)
        var due: [Packet] = []
        var remaining: [Packet] = []
        for p in inflight {
            if p.deliverAt <= clock { due.append(p) } else { remaining.append(p) }
        }
        inflight = remaining
        lock.unlock()

        due.sort { lhs, rhs in
            if lhs.deliverAt != rhs.deliverAt { return lhs.deliverAt < rhs.deliverAt }
            if lhs.channel.priority != rhs.channel.priority { return lhs.channel.priority < rhs.channel.priority }
            return lhs.sequence < rhs.sequence
        }
        for p in due {
            stats.delivered += 1
            stats.byChannel[p.channel, default: 0] += 1
            stats.bytesByChannel[p.channel, default: 0] += p.data.count
        }
        return due
    }

    public func advance(by delta: TimeInterval) -> [Packet] {
        advance(to: clock + delta)
    }

    /// 反复推进到"所有在途与等待的包都已投递"。
    public func drain(maxSteps: Int = 4000) -> [Packet] {
        var all: [Packet] = []
        var steps = 0
        while steps < maxSteps {
            steps += 1
            let pending = pendingCount
            guard pending > 0 else { break }
            let next = nextEventTime()
            let target = next > clock ? next : clock + 0.001
            let batch = advance(to: target)
            all.append(contentsOf: batch)
            if batch.isEmpty && pendingCount > 0 && next <= clock {
                // 防御：避免零进度死循环
                _ = advance(by: 0.001)
            }
        }
        return all
    }

    /// 下一个事件时刻（用于把时钟直接跳到该点，而不是小步模拟）。
    public func nextEventTime() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        var candidates: [TimeInterval] = []
        for p in inflight { candidates.append(p.deliverAt) }
        for dir in [Direction.toA, .toB] {
            let free = linkFreeAt[dir] ?? 0
            for w in waiting where w.direction == dir {
                candidates.append(max(free, w.enqueuedAt))
            }
        }
        return candidates.min() ?? clock
    }

    /// 连接断开：清空所有在途与等待数据。
    public func tearDown() {
        lock.lock(); defer { lock.unlock() }
        let lost = waiting.count + inflight.count
        stats.droppedByLinkDown += lost
        waiting.removeAll()
        inflight.removeAll()
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiting.count + inflight.count
    }

    public var waitingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiting.count
    }

    public var inflightCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inflight.count
    }
}

/// 链路统计，供测试断言与报告使用。
public struct LinkStats: Sendable, Equatable {
    public var delivered: Int = 0
    public var droppedByLoss: Int = 0
    public var droppedByLinkDown: Int = 0
    public var droppedAfterMaxRetransmits: Int = 0
    /// 因发送队列背压被丢弃的过期媒体帧。
    public var droppedByBackpressure: Int = 0
    public var retransmissions: Int = 0
    public var reordered: Int = 0
    public var byChannel: [Channel: Int] = [:]
    public var bytesByChannel: [Channel: Int] = [:]

    public var totalBytes: Int { bytesByChannel.values.reduce(0, +) }

    public var description: String {
        "投递 \(delivered) / 丢包(媒体) \(droppedByLoss) / 背压丢弃 \(droppedByBackpressure) / 重传 \(retransmissions) / 中断丢弃 \(droppedByLinkDown) / 乱序 \(reordered)"
    }
}

/// 确定性随机数（测试可复现）。
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    public mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

// MARK: - 基于模拟链路的 Transport

/// 一个端点。`send` 写入链路；`advance` 时把属于本端的包交给 `onReceive`。
public final class SimulatedEndpoint: Transport {
    public let side: LinkDirection
    private let link: SimulatedLink
    private var channels: [Channel: EndpointChannel] = [:]
    private let lock = NSLock()

    public var state: TransportState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((TransportState) -> Void)?

    public init(link: SimulatedLink, side: LinkDirection) {
        self.link = link
        self.side = side
        for c in Channel.allCases {
            channels[c] = EndpointChannel(link: link, channel: c, side: side)
        }
    }

    public func channel(_ channel: Channel) -> TransportChannel {
        channels[channel]!
    }

    public func start() { state = .connected }
    public func stop() { state = .disconnected(nil) }

    /// 由测试或运行时驱动：投递到本端的包。
    public func deliver(_ packets: [SimulatedLink.Packet]) {
        let mine = side == .a ? SimulatedLink.Direction.toA : SimulatedLink.Direction.toB
        for p in packets where p.direction == mine {
            channels[p.channel]?.receive(p.data)
        }
    }

    public var physicalSendBytes: Int { 0 }
}

public enum LinkDirection: Sendable { case a, b }

final class EndpointChannel: TransportChannel {
    let channel: Channel
    private let link: SimulatedLink
    private let side: LinkDirection
    var onReceive: ((Data) -> Void)?

    init(link: SimulatedLink, channel: Channel, side: LinkDirection) {
        self.link = link; self.channel = channel; self.side = side
    }

    func send(_ data: Data) {
        let direction: SimulatedLink.Direction = (side == .a) ? .toB : .toA
        link.enqueue(data, channel: channel, direction: direction)
    }

    fileprivate func receive(_ data: Data) { onReceive?(data) }
}

/// 把两个端点接成一对，并提供推进时钟的入口。
public final class SimulatedNetwork {
    public let link: SimulatedLink
    public let endpointA: SimulatedEndpoint
    public let endpointB: SimulatedEndpoint

    public init(conditions: LinkConditions = .lan, seed: UInt64 = 0xC0FFEE) {
        link = SimulatedLink(seed: seed, conditions: conditions)
        endpointA = SimulatedEndpoint(link: link, side: .a)
        endpointB = SimulatedEndpoint(link: link, side: .b)
    }

    /// 推进时钟并把到期包投递给两端。
    @discardableResult
    public func advance(by delta: TimeInterval) -> Int {
        let packets = link.advance(by: delta)
        endpointA.deliver(packets)
        endpointB.deliver(packets)
        return packets.count
    }

    @discardableResult
    public func advance(to time: TimeInterval) -> Int {
        let packets = link.advance(to: time)
        endpointA.deliver(packets)
        endpointB.deliver(packets)
        return packets.count
    }

    /// 反复推进直到链路静默（用于把在途消息全部送达）。
    @discardableResult
    public func drain() -> Int {
        let packets = link.drain()
        endpointA.deliver(packets)
        endpointB.deliver(packets)
        return packets.count
    }

    public var currentTime: TimeInterval { link.now }

    public func setConditions(_ c: LinkConditions) {
        link.conditionsAtoB = c
        link.conditionsBtoA = c
    }

    public func setDown(_ down: Bool) {
        link.conditionsAtoB.isDown = down
        link.conditionsBtoA.isDown = down
        // 链路中断 = 连接断开：在途与排队中的数据一并丢失。
        // 这样"重连后不得重放"才是被验证的行为，而不是被传输层的隐式缓冲掩盖。
        if down { link.tearDown() }
    }
}
