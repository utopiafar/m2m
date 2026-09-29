import Foundation

/// 承载协议的不变量：
/// - 按 `msgID` 去重（幂等，规格 §0）
/// - 按 `epoch` 过滤过期消息
/// - 按通道 `seq` 检测丢失与乱序
/// - 可靠有序通道保证投递顺序；媒体通道允许丢最新
public final class MessageBus {
    public typealias Handler = (Envelope) -> Void

    public private(set) var epoch: UInt64
    private var handlers: [MessageType: [Handler]] = [:]
    private var seenMessageIDs = Set<UInt64>()
    private var seenMessageIDOrder: [UInt64] = []
    private var expectedSeq: [Channel: UInt64] = [:]
    private var outboundMsgID: UInt64 = 0
    private var outboundSeq: [Channel: UInt64] = [:]
    private var channels: [Channel: TransportChannel] = [:]
    private let dedupWindow = 4096

    /// 消息投递队列。
    ///
    /// 必须设置：传输层的读取发生在后台队列上，如果业务处理器直接在读取队列里执行，
    /// 一旦处理器需要向**同一条连接**发起同步请求（例如 Host 询问目标应用的窗口状态），
    /// 就会因为读取队列被占住而互相等待。把处理器统一投递到会话队列即可避免死锁。
    public var deliveryQueue: DispatchQueue?

    /// 诊断计数，供测试与报告断言。
    public private(set) var diagnostics = BusDiagnostics()

    public init(epoch: UInt64) {
        self.epoch = epoch
    }

    public func attach(_ transport: Transport) {
        for c in Channel.allCases {
            let ch = transport.channel(c)
            ch.onReceive = { [weak self] data in
                self?.handleInbound(data, channel: c)
            }
            channels[c] = ch
        }
    }

    public func on(_ types: [MessageType], _ handler: @escaping Handler) {
        for t in types { handlers[t, default: []].append(handler) }
    }

    /// 广播时的默认 epoch 由 bus 持有；会话重连时可推进。
    public func setEpoch(_ newEpoch: UInt64) {
        epoch = newEpoch
        expectedSeq.removeAll()
        seenMessageIDs.removeAll()
        seenMessageIDOrder.removeAll()
    }

    @discardableResult
    public func send<T: BinaryCodable>(_ message: T, type: MessageType, epoch: UInt64? = nil) -> UInt64 {
        let e = epoch ?? self.epoch
        let channel = type.channel
        outboundMsgID += 1
        outboundSeq[channel, default: 0] += 1
        let envelope = Envelope(type: type, epoch: e, seq: outboundSeq[channel]!,
                                msgID: outboundMsgID, payload: message.encoded())
        channels[channel]?.send(envelope.encode())
        diagnostics.sent[type, default: 0] += 1
        return outboundMsgID
    }

    /// 直接发送裸字节（媒体帧走这条路径，不经过消息编解码）。
    public func sendRaw(_ data: Data, channel: Channel) {
        channels[channel]?.send(data)
    }

    private func handleInbound(_ data: Data, channel: Channel) {
        // 媒体通道是裸帧，交给监听者自行解析
        guard channel != .media else {
            handlerForRawChannel(channel)?(data)
            return
        }
        guard let envelope = try? Envelope.decode(data) else {
            diagnostics.decodeFailures += 1
            return
        }
        guard envelope.epoch == epoch else {
            diagnostics.droppedByEpoch += 1
            return
        }
        guard !seenMessageIDs.contains(envelope.msgID) else {
            diagnostics.droppedAsDuplicate += 1
            return
        }
        seenMessageIDs.insert(envelope.msgID)
        seenMessageIDOrder.append(envelope.msgID)
        if seenMessageIDOrder.count > dedupWindow {
            let evicted = seenMessageIDOrder.removeFirst()
            seenMessageIDs.remove(evicted)
        }

        // 序号连续性检查（仅诊断，不影响投递；可靠通道由传输层保证有序）
        if let expected = expectedSeq[channel] {
            if envelope.seq > expected {
                diagnostics.gapsDetected += Int(envelope.seq - expected)
            } else if envelope.seq < expected {
                diagnostics.outOfOrder += 1
            }
        }
        expectedSeq[channel] = max(expectedSeq[channel] ?? 0, envelope.seq + 1)

        diagnostics.received[envelope.type, default: 0] += 1
        let targets = handlers[envelope.type] ?? []
        if let q = deliveryQueue {
            q.async { for h in targets { h(envelope) } }
        } else {
            for h in targets { h(envelope) }
        }
    }

    public typealias RawHandler = (Data) -> Void
    private var rawHandlers: [Channel: RawHandler] = [:]
    private func handlerForRawChannel(_ c: Channel) -> RawHandler? { rawHandlers[c] }

    public func onRaw(_ channel: Channel, _ handler: @escaping RawHandler) {
        rawHandlers[channel] = handler
    }

    public func decode<T: BinaryCodable>(_ envelope: Envelope, as type: T.Type) -> T? {
        try? T.decode(envelope.payload)
    }

    public func resetOutboundCounters() {
        outboundMsgID = 0
        outboundSeq.removeAll()
    }
}

public struct BusDiagnostics: Sendable, Equatable {
    public var sent: [MessageType: Int] = [:]
    public var received: [MessageType: Int] = [:]
    public var droppedAsDuplicate: Int = 0
    public var droppedByEpoch: Int = 0
    public var decodeFailures: Int = 0
    public var gapsDetected: Int = 0
    public var outOfOrder: Int = 0
}
