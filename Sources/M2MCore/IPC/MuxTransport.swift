import Foundation

/// 在单条字节流上复用四条逻辑通道。
///
/// 线格式：[1 字节通道号][4 字节大端长度][payload]
///
/// 这样中继无需理解协议内容即可转发；端点侧再按通道分派，
/// 从而保留 `docs/03-protocol.md` 定义的通道语义与优先级。
public final class MuxTransport: Transport {
    public static let headerSize = 5

    private let connection: IPCConnection
    private var channels: [Channel: MuxChannel] = [:]
    private var buffer = Data()
    private let lock = NSLock()

    public private(set) var state: TransportState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((TransportState) -> Void)?
    public private(set) var framesSent = 0
    public private(set) var framesReceived = 0
    public private(set) var malformedFrames = 0

    public init(connection: IPCConnection) {
        self.connection = connection
        for c in Channel.allCases {
            channels[c] = MuxChannel(transport: self, channel: c)
        }
        connection.onReceive = { [weak self] data in self?.ingest(data) }
        connection.onClose = { [weak self] in
            self?.state = .disconnected("对端已关闭连接")
        }
    }

    public func channel(_ channel: Channel) -> TransportChannel { channels[channel]! }

    public func start() { state = .connected }
    public func stop() { state = .disconnected(nil); connection.close() }

    fileprivate func write(_ payload: Data, channel: Channel) {
        var framed = Data(capacity: payload.count + MuxTransport.headerSize)
        framed.append(channel.rawValue)
        let n = UInt32(payload.count)
        framed.append(UInt8((n >> 24) & 0xFF))
        framed.append(UInt8((n >> 16) & 0xFF))
        framed.append(UInt8((n >> 8) & 0xFF))
        framed.append(UInt8(n & 0xFF))
        framed.append(payload)
        connection.send(framed)
        framesSent += 1
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var ready: [(Channel, Data)] = []
        while buffer.count >= MuxTransport.headerSize {
            let bytes = [UInt8](buffer.prefix(5))
            guard let channel = Channel(rawValue: bytes[0]) else {
                malformedFrames += 1
                buffer.removeAll()
                break
            }
            let len = (Int(bytes[1]) << 24) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 8) | Int(bytes[4])
            guard len >= 0, len <= IPCFraming.maxPayload else {
                malformedFrames += 1
                buffer.removeAll()
                break
            }
            guard buffer.count >= MuxTransport.headerSize + len else { break }
            let start = buffer.startIndex + MuxTransport.headerSize
            ready.append((channel, Data(buffer[start..<(start + len)])))
            buffer.removeFirst(MuxTransport.headerSize + len)
        }
        lock.unlock()
        for (channel, payload) in ready {
            framesReceived += 1
            channels[channel]?.deliver(payload)
        }
    }
}

private final class MuxChannel: TransportChannel {
    let channel: Channel
    private weak var transport: MuxTransport?
    var onReceive: ((Data) -> Void)?

    init(transport: MuxTransport, channel: Channel) {
        self.transport = transport
        self.channel = channel
    }

    func send(_ data: Data) { transport?.write(data, channel: channel) }
    func deliver(_ data: Data) { onReceive?(data) }
}
