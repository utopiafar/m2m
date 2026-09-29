import XCTest
@testable import M2MCore

// MARK: - 协议与编解码

final class ProtocolCodecTests: XCTestCase {

    func testEnvelopeRoundTrip() throws {
        let env = Envelope(type: .textCommit, epoch: 7, seq: 42, msgID: 99, payload: Data([1, 2, 3]))
        let decoded = try Envelope.decode(env.encode())
        XCTAssertEqual(decoded.type, .textCommit)
        XCTAssertEqual(decoded.epoch, 7)
        XCTAssertEqual(decoded.seq, 42)
        XCTAssertEqual(decoded.msgID, 99)
        XCTAssertEqual(decoded.payload, Data([1, 2, 3]))
    }

    func testBinaryReaderRejectsTruncatedData() {
        var w = BinaryWriter()
        w.writeString("hello")
        let data = w.data
        var reader = BinaryReader(Data(data.prefix(3)))
        XCTAssertThrowsError(try reader.readString())
    }

    func testVarintRoundTripForExtremeValues() throws {
        for value: UInt64 in [0, 1, 127, 128, 16383, 16384, UInt64.max / 2, UInt64.max] {
            var w = BinaryWriter(); w.writeUInt(value)
            var r = BinaryReader(w.data)
            XCTAssertEqual(try r.readUInt(), value)
        }
    }

    func testZigZagIntRoundTrip() throws {
        for value: Int64 in [0, 1, -1, 63, -64, 1_000_000, -1_000_000, Int64.max / 2, Int64.min / 2] {
            var w = BinaryWriter(); w.writeInt(value)
            var r = BinaryReader(w.data)
            XCTAssertEqual(try r.readInt(), value)
        }
    }

    func testWindowInfoRoundTrip() throws {
        let info = WindowInfo(windowUID: "w1", appPID: 1234, appLaunchID: "launch-a",
                              bundleID: "com.example.app", title: "主窗口",
                              role: .main, parentUID: nil, modal: false,
                              contentRect: Rect(10, 20, 640, 480), contentScale: 2.0,
                              constraints: SizeConstraints(minSize: Size(320, 200),
                                                           maxSize: Size(1600, 1200), resizable: .both),
                              minimized: false, focusable: true, zOrder: 3)
        let decoded = try WindowInfo.decode(info.encoded())
        XCTAssertEqual(decoded, info)
        XCTAssertEqual(decoded.captureSize, Size(1280, 960))
    }

    func testTextContextRoundTripPreservesCaretValidity() throws {
        let ctx = TextContext(epoch: 3, editVersion: 12, windowUID: "w", nodeID: "n",
                              role: .contentEditable, editable: true, acceptsUnicodeEvents: false,
                              caret: CaretInfo(valid: false, rectInWindow: .zero, lineHeight: 0),
                              selection: SelectionInfo(valid: true, location: 5, length: 3),
                              remoteMarkedPresent: true, remoteMarkedLength: 2,
                              contextBefore: "前文", contextAfter: "后文", contextTruncated: true)
        let decoded = try TextContext.decode(ctx.encoded())
        XCTAssertEqual(decoded.editVersion, 12)
        XCTAssertFalse(decoded.caret.valid, "插入点有效性必须无损传递")
        XCTAssertEqual(decoded.selection.location, 5)
        XCTAssertEqual(decoded.selection.length, 3)
        XCTAssertTrue(decoded.remoteMarkedPresent)
        XCTAssertEqual(decoded.contextBefore, "前文")
    }

    func testTextCommitRoundTripWithNilOptionalFields() throws {
        let commit = TextCommit(epoch: 1, windowUID: "w", nodeID: "n", editVersion: 4,
                                commitSeq: 9, text: "你好", fromLocalMarked: true,
                                replaceRange: nil, intent: .insertText)
        let decoded = try TextCommit.decode(commit.encoded())
        XCTAssertEqual(decoded.text, "你好")
        XCTAssertNil(decoded.replaceRange)
        XCTAssertEqual(decoded.commitSeq, 9)
    }

    func testMediaFrameWireRoundTrip() throws {
        let payload = Data((0..<256).map { UInt8($0 % 251) })
        let wire = MediaFrameWire(codec: .rawBGRA, isKeyframe: true, layoutVersion: 5,
                                  frameIndex: 3, width: 320, height: 200,
                                  pixelChecksum: 0xDEADBEEF, streamID: "s1", payload: payload)
        let decoded = try MediaFrameWire.decode(wire.encoded())
        XCTAssertEqual(decoded.streamID, "s1")
        XCTAssertEqual(decoded.layoutVersion, 5)
        XCTAssertEqual(decoded.pixelChecksum, 0xDEADBEEF)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.asEncodedFrame.size, Size(320, 200))
    }

    func testCapabilitiesIntersection() {
        let a = Capabilities(media: MediaCapabilities(codecs: [.rawBGRA, .h264, .hevc], maxFPS: 60, hardwareEncode: false),
                             text: TextCapabilities(axAvailable: true, focusTracking: true, selectionRead: true,
                                                    caretRect: false, compositionSupport: true),
                             adapters: ["generic", "claude"], apps: [])
        let b = Capabilities(media: MediaCapabilities(codecs: [.h264, .rawBGRA], maxFPS: 30, hardwareEncode: true),
                             text: TextCapabilities(axAvailable: true, focusTracking: false, selectionRead: true,
                                                    caretRect: true, compositionSupport: false),
                             adapters: ["generic"], apps: [])
        let i = a.intersected(with: b)
        XCTAssertEqual(Set(i.media.codecs), Set([CodecKind.rawBGRA, .h264]))
        XCTAssertEqual(i.media.maxFPS, 30)
        XCTAssertFalse(i.media.hardwareEncode)
        XCTAssertFalse(i.text.caretRect, "交集下 caretRect 必须为 false（A 不支持）")
        XCTAssertFalse(i.text.compositionSupport)
        XCTAssertFalse(i.text.focusTracking)
        XCTAssertEqual(i.adapters, ["generic"])
    }
}

// MARK: - 消息总线不变量

final class MessageBusTests: XCTestCase {

    private func makeBusPair() -> (MessageBus, MessageBus, SimulatedNetwork) {
        let net = SimulatedNetwork()
        let a = MessageBus(epoch: 1)
        let b = MessageBus(epoch: 1)
        a.attach(net.endpointA)
        b.attach(net.endpointB)
        return (a, b, net)
    }

    func testDuplicateMessageIsDroppedAndHandlerCalledOnce() {
        let (a, b, net) = makeBusPair()
        var received = 0
        b.on([.sessionState]) { _ in received += 1 }
        let env = Envelope(type: .sessionState, epoch: 1, seq: 1, msgID: 555,
                           payload: SessionStateMsg(phase: .active).encoded())
        net.endpointA.channel(.control).send(env.encode())
        net.drain()
        XCTAssertEqual(received, 1)
        // 同 msgID 再发一次（模拟重传）
        net.endpointA.channel(.control).send(env.encode())
        net.drain()
        XCTAssertEqual(received, 1, "重复 msgID 必须被幂等丢弃")
        XCTAssertEqual(b.diagnostics.droppedAsDuplicate, 1)
        _ = a
    }

    func testMessageFromOldEpochIsDropped() {
        let (_, b, net) = makeBusPair()
        var received = 0
        b.on([.sessionState]) { _ in received += 1 }
        let env = Envelope(type: .sessionState, epoch: 99, seq: 1, msgID: 1,
                           payload: SessionStateMsg(phase: .active).encoded())
        net.endpointA.channel(.control).send(env.encode())
        net.drain()
        XCTAssertEqual(received, 0, "过期 epoch 的消息不得被处理")
        XCTAssertEqual(b.diagnostics.droppedByEpoch, 1)
    }

    func testEpochAdvanceInvalidatesPreviousEpoch() {
        let (_, b, net) = makeBusPair()
        var received = 0
        b.on([.sessionState]) { _ in received += 1 }
        b.setEpoch(2)
        let old = Envelope(type: .sessionState, epoch: 1, seq: 1, msgID: 1,
                           payload: SessionStateMsg(phase: .active).encoded())
        net.endpointA.channel(.control).send(old.encode())
        net.drain()
        XCTAssertEqual(received, 0)
        let fresh = Envelope(type: .sessionState, epoch: 2, seq: 1, msgID: 2,
                             payload: SessionStateMsg(phase: .active).encoded())
        net.endpointA.channel(.control).send(fresh.encode())
        net.drain()
        XCTAssertEqual(received, 1)
    }

    func testGapDetectionRecordsMissingMessages() {
        let (_, b, net) = makeBusPair()
        b.on([.sessionState]) { _ in }
        for seq: UInt64 in [1, 2, 5] {
            let env = Envelope(type: .sessionState, epoch: 1, seq: seq, msgID: seq,
                               payload: SessionStateMsg(phase: .active).encoded())
            net.endpointA.channel(.control).send(env.encode())
            net.drain()
        }
        XCTAssertEqual(b.diagnostics.gapsDetected, 2, "seq 3、4 缺失应被记录")
    }

    func testChannelPriorityOrdering() {
        XCTAssertLessThan(Channel.control.priority, Channel.input.priority)
        XCTAssertLessThan(Channel.input.priority, Channel.state.priority)
        XCTAssertLessThan(Channel.state.priority, Channel.media.priority)
        XCTAssertLessThan(Channel.media.priority, Channel.file.priority)
    }

    func testMessageTypeChannelAssignment() {
        XCTAssertEqual(MessageType.keyEvent.channel, .input)
        XCTAssertEqual(MessageType.textCommit.channel, .input)
        XCTAssertEqual(MessageType.revokeControl.channel, .control)
        XCTAssertEqual(MessageType.windowDelta.channel, .state)
        XCTAssertEqual(MessageType.fileChunk.channel, .file)
    }

    func testDroppableChannelsOnlyMedia() {
        XCTAssertTrue(Channel.media.isDroppable)
        for c in [Channel.control, .input, .state, .file] {
            XCTAssertFalse(c.isDroppable, "\(c) 不得被丢弃")
        }
    }
}

// MARK: - 链路模拟器

final class SimulatedLinkTests: XCTestCase {

    func testLatencyAppliedToDelivery() {
        let net = SimulatedNetwork(conditions: LinkConditions.rtt(160))
        var received = 0
        net.endpointA.channel(.control).onReceive = { _ in received += 1 }
        net.endpointB.channel(.control).send(Data([1]))
        // RTT 160ms → 单程 80ms
        net.advance(by: 0.05)
        XCTAssertEqual(received, 0, "延迟未到不应投递")
        net.advance(by: 0.05)
        XCTAssertEqual(received, 1)
    }

    /// 媒体通道丢包直接丢帧（实时性优先）。
    func testLossDropsPackets() {
        let net = SimulatedNetwork(conditions: LinkConditions(oneWayLatency: 0.001, lossRate: 0.5), seed: 12345)
        var received = 0
        net.endpointA.channel(.media).onReceive = { _ in received += 1 }
        for i in 0..<200 { net.endpointB.channel(.media).send(Data([UInt8(i % 256)])) }
        net.drain()
        XCTAssertGreaterThan(net.link.stats.droppedByLoss, 0)
        XCTAssertLessThan(received, 200)
    }

    func testLinkDownDropsEverything() {
        let net = SimulatedNetwork(conditions: .lan)
        net.setDown(true)
        var received = 0
        net.endpointA.channel(.input).onReceive = { _ in received += 1 }
        net.endpointB.channel(.input).send(Data([1, 2, 3]))
        net.drain()
        XCTAssertEqual(received, 0)
        XCTAssertEqual(net.link.stats.droppedByLinkDown, 1)
    }

    /// T7 的核心断言：在带宽受限链路上，输入必须优先于文件分块被服务。
    func testInputIsServedBeforeFileChunksUnderBandwidthLimit() {
        let net = SimulatedNetwork(conditions: LinkConditions.bandwidth(mbps: 1), seed: 7)
        var order: [Channel] = []
        // 从 B 发送（方向 toA），因此必须在 A 上监听
        net.endpointA.channel(.input).onReceive = { _ in order.append(.input) }
        net.endpointA.channel(.file).onReceive = { _ in order.append(.file) }

        // 先塞满文件分块（大块），再发输入
        for i in 0..<10 {
            net.endpointB.channel(.file).send(Data(repeating: UInt8(i), count: 4000))
        }
        net.endpointB.channel(.input).send(Data(repeating: 9, count: 8))
        net.drain()

        XCTAssertTrue(order.contains(.input))
        let firstInputIndex = order.firstIndex(of: .input)!
        let fileChunksBeforeInput = order[0..<firstInputIndex].filter { $0 == .file }.count
        // 已经被序列化进管道的首批分块不可避免，但输入不应排在全部文件之后
        XCTAssertLessThan(fileChunksBeforeInput, 10,
                          "输入被排在所有文件分块之后，说明优先级调度未生效")
    }

    func testSameDeliverTimeOrdersByPriority() {
        let net = SimulatedNetwork(conditions: LinkConditions(oneWayLatency: 0.05), seed: 3)
        var order: [Channel] = []
        net.endpointA.channel(.file).onReceive = { _ in order.append(.file) }
        net.endpointA.channel(.media).onReceive = { _ in order.append(.media) }
        net.endpointA.channel(.input).onReceive = { _ in order.append(.input) }
        // 同时入队
        net.endpointB.channel(.file).send(Data([3]))
        net.endpointB.channel(.media).send(Data([2]))
        net.endpointB.channel(.input).send(Data([1]))
        net.drain()
        XCTAssertEqual(order, [.input, .media, .file], "同一到达时刻必须按优先级排序")
    }

    func testDeterministicWithSameSeed() {
        func run() -> Int {
            let net = SimulatedNetwork(conditions: LinkConditions(oneWayLatency: 0.01, lossRate: 0.3), seed: 42)
            var n = 0
            net.endpointA.channel(.media).onReceive = { _ in n += 1 }
            for i in 0..<100 { net.endpointB.channel(.media).send(Data([UInt8(i)])) }
            net.drain()
            return n
        }
        XCTAssertEqual(run(), run(), "相同种子必须得到相同结果，保证测试可复现")
    }
}

// MARK: - 通道分配的排序安全性

final class ChannelAssignmentTests: XCTestCase {

    /// 同一逻辑事务的消息必须落在同一通道上，否则会被优先级调度拆散顺序。
    func testFileTransactionMessagesShareOneChannel() {
        let fileMessages: [MessageType] = [.fileOffer, .fileChunk, .fileComplete, .fileAbort, .fileProgress]
        let channels = Set(fileMessages.map(\.channel))
        XCTAssertEqual(channels.count, 1,
                       "文件事务消息被拆到多个通道：\(fileMessages.map { "\($0)->\($0.channel)" })")
    }

    func testTextTransactionMessagesShareOneChannel() {
        // 提交与其结果必须同通道，否则结果可能先于请求被处理
        XCTAssertEqual(MessageType.textCommit.channel, MessageType.textCommitResult.channel)
    }

    func testWindowTransactionMessagesShareOneChannel() {
        XCTAssertEqual(MessageType.windowResizeRequest.channel, MessageType.windowResizeResult.channel)
    }

    func testStreamControlMessagesShareOneChannel() {
        XCTAssertEqual(MessageType.streamInfo.channel, MessageType.streamAdjustRequest.channel)
    }
}
