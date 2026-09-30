import XCTest
import CryptoKit
@testable import M2MCore

/// 内存管道，用于在不涉及真实 IO 的情况下验证加密与握手语义。
final class InMemoryPipe: BytePipe {
    weak var peer: InMemoryPipe?
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isClosed = false
    /// 记录末端字节流，用于断言"线上确实是密文"
    private(set) var wireBytes: [Data] = []

    func send(_ data: Data) {
        guard !isClosed else { return }
        wireBytes.append(data)
        peer?.deliver(data)
    }

    private func deliver(_ data: Data) {
        guard !isClosed else { return }
        onReceive?(data)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
    }
}

/// 对应 docs/06-test-plan.md 的 T-SEC-01…06。
final class SecurePipeTests: XCTestCase {

    private func makePair(initiatorCode: String = "ABC123", responderCode: String? = nil)
    -> (SecurePipe, SecurePipe, InMemoryPipe, InMemoryPipe) {
        let a = InMemoryPipe()
        let b = InMemoryPipe()
        a.peer = b
        b.peer = a
        let initiator = SecurePipe(inner: a, role: .initiator, pairingCode: PairingCode(initiatorCode))
        let responder = SecurePipe(inner: b, role: .responder,
                                   pairingCode: PairingCode(responderCode ?? initiatorCode))
        responder.responderDeviceID = "host-device"
        return (initiator, responder, a, b)
    }

    func testCorrectCodeCompletesHandshakeOnBothSides() {
        let (initiator, responder, _, _) = makePair()
        initiator.begin(deviceID: "viewer-device")
        XCTAssertTrue(initiator.isReady)
        XCTAssertTrue(responder.isReady)
        XCTAssertEqual(initiator.handshakeState, .complete)
        XCTAssertEqual(responder.handshakeState, .complete)
        XCTAssertEqual(initiator.peerDeviceID, "host-device")
        XCTAssertEqual(responder.peerDeviceID, "viewer-device")
    }

    func testPayloadFlowsAfterHandshake() {
        let (initiator, responder, _, _) = makePair()
        initiator.begin(deviceID: "v")
        var received: Data?
        responder.onReceive = { received = $0 }
        initiator.send(Data("中文负载 payload".utf8))
        XCTAssertEqual(received, Data("中文负载 payload".utf8))
        XCTAssertEqual(initiator.sealedFrames, 1)
        XCTAssertEqual(responder.openedFrames, 1)
    }

    func testSealedFrameIsCiphertextNotPlaintext() {
        let (initiator, responder, a, _) = makePair()
        initiator.begin(deviceID: "v")
        _ = responder
        let marker = "SECRET-MARKER-明文标记"
        initiator.send(Data(marker.utf8))
        let sealedFrames = a.wireBytes.filter { SecurePipe.handshakePayload($0) == nil }
        XCTAssertEqual(sealedFrames.count, 1)
        XCTAssertFalse(String(decoding: sealedFrames[0], as: UTF8.self).contains(marker),
                       "密文帧里出现了明文标记")
        // ChaChaPoly 的 combined 至少要比明文多出 16 字节认证标签
        XCTAssertGreaterThan(sealedFrames[0].count, marker.utf8.count + 15)
    }

    func testWrongCodeIsRejectedAtHandshake() {
        // T-SEC-02 的核心：配对码不一致必须被拒绝，而不是悄悄建立连接
        let (initiator, responder, _, _) = makePair(initiatorCode: "AAAAAA", responderCode: "BBBBBB")
        var failure: PairingError?
        initiator.onHandshakeFailure = { failure = $0 }
        initiator.begin(deviceID: "v")
        XCTAssertFalse(initiator.isReady)
        XCTAssertEqual(failure, .codeMismatch)
    }

    func testWrongCodeMeansNoDataEverFlows() {
        let (initiator, responder, _, _) = makePair(initiatorCode: "AAAAAA", responderCode: "BBBBBB")
        var responderReceived: [Data] = []
        responder.onReceive = { responderReceived.append($0) }
        initiator.begin(deviceID: "v")
        initiator.send(Data("不该到达".utf8))
        XCTAssertTrue(responderReceived.isEmpty, "配对失败后仍传出了数据")
    }

    func testTooManyAttemptsIsRefusedAcrossConnections() {
        // T-SEC-02：错误尝试必须限速。关键在于**跨连接**累计：
        // 每次失败都会断开，若计数在连接内部，重连一次就归零，等于没有限速。
        let tracker = PairingAttemptTracker(maxAttempts: 3, lockoutDuration: 60)
        let code = PairingCode("BBBBBB")
        var failures: [PairingError] = []

        // 模拟攻击者连续建立 5 次连接，每次尝试一个错误的配对码
        for round in 0..<5 {
            let serverSide = InMemoryPipe()
            let clientSide = InMemoryPipe()
            serverSide.peer = clientSide
            clientSide.peer = serverSide
            let responder = SecurePipe(inner: serverSide, role: .responder, pairingCode: code)
            responder.responderDeviceID = "host"
            responder.attemptTracker = tracker
            responder.onHandshakeFailure = { failures.append($0) }

            let attacker = SecurePipe(inner: clientSide, role: .initiator,
                                      pairingCode: PairingCode("WRONG\(round)"))
            attacker.begin(deviceID: "attacker")
        }

        XCTAssertTrue(failures.contains(.tooManyAttempts(limit: 3)),
                      "5 次错误尝试后必须触发跨连接限速，实际失败序列：\(failures)")
    }

    func testSuccessfulPairingClearsFailureHistory() {
        let tracker = PairingAttemptTracker(maxAttempts: 3, lockoutDuration: 60)
        XCTAssertTrue(tracker.recordAttempt(peer: "device-a"), "第 1 次应放行")
        XCTAssertTrue(tracker.recordAttempt(peer: "device-a"), "第 2 次应放行")
        XCTAssertEqual(tracker.lockoutRemaining(peer: "device-a"), 0, "未达上限时不应处于锁定态")
        XCTAssertTrue(tracker.recordAttempt(peer: "device-a"), "第 3 次应放行")
        XCTAssertGreaterThan(tracker.lockoutRemaining(peer: "device-a"), 0, "达到上限后应进入锁定")
        XCTAssertFalse(tracker.recordAttempt(peer: "device-a"), "达上限后必须拒绝")

        tracker.recordSuccess(peer: "device-a")
        XCTAssertEqual(tracker.lockoutRemaining(peer: "device-a"), 0, "配对成功后应清除失败记录")
        XCTAssertTrue(tracker.recordAttempt(peer: "device-a"), "清除后应可再次尝试")
    }

    func testUnpairedPipeDropsApplicationDataInsteadOfSendingPlaintext() {
        // 未完成握手时，业务数据必须被丢弃，绝不能明文外发
        let a = InMemoryPipe()
        let b = InMemoryPipe()
        a.peer = b; b.peer = a
        let pipe = SecurePipe(inner: a, role: .initiator, pairingCode: PairingCode("ABC123"))
        pipe.send(Data("未配对就不该出现在线上".utf8))
        XCTAssertTrue(a.wireBytes.isEmpty, "未完成握手时写入了数据")
        XCTAssertFalse(pipe.isReady)
    }

    func testTamperedCiphertextIsRejected() {
        // T-SEC-03：篡改必须被检测
        let (initiator, responder, a, _) = makePair()
        initiator.begin(deviceID: "v")
        var received: [Data] = []
        responder.onReceive = { received.append($0) }
        initiator.send(Data("原始内容".utf8))
        XCTAssertEqual(received.count, 1)

        // 取最后一条密文并翻转一个字节，重发
        guard var tampered = a.wireBytes.last else { return XCTFail("没有密文") }
        tampered[tampered.count - 1] ^= 0x01
        responder.onReceive = { received.append($0) }
        b_peerDeliver(a, tampered)
        XCTAssertEqual(received.count, 1, "被篡改的帧不得被投递")
        XCTAssertGreaterThan(responder.rejectedFrames, 0)
    }

    func testReplayedCiphertextIsRejectedByNonceCounter() {
        // 重放：同一密文再次送达必须失败（计数器 nonce 不允许复用）
        let (initiator, responder, a, _) = makePair()
        initiator.begin(deviceID: "v")
        var received: [Data] = []
        responder.onReceive = { received.append($0) }
        initiator.send(Data("第一条".utf8))
        guard let frame = a.wireBytes.last else { return XCTFail("没有密文") }
        let before = received.count
        // 直接重放同一帧
        b_peerDeliver(a, frame)
        XCTAssertEqual(received.count, before, "重放的帧不得被投递")
        XCTAssertGreaterThan(responder.rejectedFrames, 0)
    }

    func testDifferentSessionsDeriveDifferentKeys() {
        // 每次握手使用新的临时密钥，同一配对码两次会话的密钥必须不同
        let (i1, r1, a1, _) = makePair()
        i1.begin(deviceID: "v")
        i1.send(Data("A".utf8))
        let (i2, r2, a2, _) = makePair()
        i2.begin(deviceID: "v")
        i2.send(Data("A".utf8))
        _ = (r1, r2)
        let s1 = a1.wireBytes.filter { SecurePipe.handshakePayload($0) == nil }
        let s2 = a2.wireBytes.filter { SecurePipe.handshakePayload($0) == nil }
        XCTAssertNotEqual(s1, s2, "两次会话的密文相同，说明密钥没有随机化")
    }

    func testPairingCodeGenerationIsReadableAndNonTrivial() {
        var rng = SeededRandom(seed: 42)
        let code = PairingCode.generate(length: 6, rng: &rng)
        XCTAssertEqual(code.value.count, 6)
        XCTAssertTrue(code.isValid)
        // 排除易混字符
        XCTAssertFalse(code.value.contains("0"))
        XCTAssertFalse(code.value.contains("O"))
        XCTAssertFalse(code.value.contains("1"))
        XCTAssertFalse(code.value.contains("I"))
        var rng2 = SeededRandom(seed: 42)
        XCTAssertEqual(PairingCode.generate(length: 6, rng: &rng2).value, code.value,
                       "相同种子必须产生相同配对码，保证测试可复现")
    }

    func testShortCodeIsInvalid() {
        XCTAssertFalse(PairingCode("ab").isValid)
    }

    func testConstantTimeEqualsIsCorrect() {
        XCTAssertTrue(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(constantTimeEquals(Data([1, 2]), Data([1, 2, 3])), "长度不同必须不等")
        XCTAssertTrue(constantTimeEquals(Data(), Data()))
    }
}

/// 触发对端投递的辅助（复用 InMemoryPipe 的 peer 链）。
private func b_peerDeliver(_ pipe: InMemoryPipe, _ data: Data) {
    pipe.peer?.test_deliver(data)
}

extension InMemoryPipe {
    func test_deliver(_ data: Data) {
        onReceive?(data)
    }
}
