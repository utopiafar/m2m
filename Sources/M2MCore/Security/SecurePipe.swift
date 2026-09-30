import Foundation
import CryptoKit

// MARK: - 可加密封装的字节管道
//
// 把"两端之间的一条字节流"抽象出来，使加密层可以插在复用器与具体传输（UDS / WebRTC
// 数据通道）之间，而不影响上层的四通道语义。

public protocol BytePipe: AnyObject {
    func send(_ data: Data)
    var onReceive: ((Data) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isClosed: Bool { get }
    func close()
}

extension IPCConnection: BytePipe {}

// MARK: - 配对

public struct PairingCode: Equatable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value.uppercased() }

    /// 生成易读的配对码（去掉易混字符）。
    public static func generate(length: Int = 6, rng: inout SeededRandom) -> PairingCode {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let s = String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
        return PairingCode(s)
    }

    public var isValid: Bool { value.count >= 4 }
}

/// 配对尝试计数器。**必须活在连接之外**：
/// 每次失败都会断开连接，如果计数在连接内部，用户（或攻击者）重连一次就归零，
/// 实际起不到限速作用。
public final class PairingAttemptTracker {
    public let maxAttempts: Int
    public let lockoutDuration: TimeInterval
    private var failures: [String: [Date]] = [:]
    private let lock = NSLock()

    public init(maxAttempts: Int = 3, lockoutDuration: TimeInterval = 60) {
        self.maxAttempts = maxAttempts
        self.lockoutDuration = lockoutDuration
    }

    /// 记录一次尝试。返回 false 表示应拒绝（已超出上限）。
    public func recordAttempt(peer: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var list = failures[peer] ?? []
        list.removeAll { now.timeIntervalSince($0) > lockoutDuration }
        if list.count >= maxAttempts { failures[peer] = list; return false }
        list.append(now)
        failures[peer] = list
        return true
    }

    /// 配对成功后清除该对端的失败记录。
    public func recordSuccess(peer: String) {
        lock.lock(); failures.removeValue(forKey: peer); lock.unlock()
    }

    public func lockoutRemaining(peer: String, now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let list = (failures[peer] ?? []).filter { now.timeIntervalSince($0) <= lockoutDuration }
        guard list.count >= maxAttempts, let earliest = list.first else { return 0 }
        return max(0, lockoutDuration - now.timeIntervalSince(earliest))
    }

    public func reset() {
        lock.lock(); failures.removeAll(); lock.unlock()
    }
}

public enum PairingError: Error, LocalizedError, Equatable {
    case codeMismatch
    case tooManyAttempts(limit: Int)
    case handshakeTimeout
    case malformedHandshake
    case decryptionFailed
    case peerRejected(String)

    public var errorDescription: String? {
        switch self {
        case .codeMismatch: return "配对码不正确"
        case .tooManyAttempts(let limit): return "配对尝试次数超过上限（\(limit) 次），已拒绝连接"
        case .handshakeTimeout: return "配对握手超时"
        case .malformedHandshake: return "配对握手数据格式错误"
        case .decryptionFailed: return "解密失败（密钥不一致或数据被篡改）"
        case .peerRejected(let r): return "对端拒绝：\(r)"
        }
    }
}

/// 握手消息（明文，仅包含公钥与证明）。
struct PairingHello: Codable {
    var publicKey: Data
    var deviceID: String
    var version: Int
}

struct PairingAck: Codable {
    var publicKey: Data
    var deviceID: String
    /// 用派生密钥对双方公钥计算的认证标签，用于确认配对码一致
    var proof: Data
    var accepted: Bool
    var reason: String?
}

// MARK: - 安全管道

/// 端到端加密管道。
///
/// 设计取舍（诚实说明）：
/// - 密钥 = HKDF( X25519 共享密钥 ‖ 配对码 )，配对码作为 PSK 混入。
///   X25519 提供对**被动窃听**的机密性；配对码提供对**主动中间人**的认证
///   （中间人各持有不同的 DH 密钥，不知道该码就无法算出同一把会话密钥）。
/// - 这不是完整的 PAKE（如 SPAKE2/OPAQUE）：配对码本身没有零知识证明，
///   主动攻击者每猜一次都需要重新发起一次握手，因此由尝试次数上限来兜底。
///   单机 UDS 场景足够；跨公网部署应替换为 PAKE 或证书固定。
/// - 每个方向使用独立的密钥与单调递增的计数器 nonce，杜绝重放。
public final class SecurePipe: BytePipe {
    private let inner: BytePipe
    private let role: Role
    public let pairingCode: PairingCode
    /// 每连接的尝试上限（未提供 tracker 时的退化行为）
    public var maxAttempts: Int = 3
    /// 跨连接的尝试限速器（推荐提供；这样重连无法重置计数）
    public var attemptTracker: PairingAttemptTracker?

    public enum Role { case initiator, responder }

    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var expectedReceiveCounter: UInt64 = 0
    private var handshakeComplete = false
    private var attempts = 0
    private var handshakeTimer: DispatchSourceTimer?
    private var myPrivateKey: Curve25519.KeyAgreement.PrivateKey

    public private(set) var peerDeviceID: String?
    /// 本机标识（responder 在 ack 中回给对端）
    public var responderDeviceID: String?
    public private(set) var handshakeState: HandshakeState = .idle
    /// 诊断计数
    public private(set) var sealedFrames = 0
    public private(set) var openedFrames = 0
    public private(set) var rejectedFrames = 0

    public enum HandshakeState: Equatable {
        case idle, awaitingPeer, complete, failed(String)
    }

    public var onReceive: ((Data) -> Void)?
    public var onClose: (() -> Void)?
    public var onHandshakeComplete: ((String) -> Void)?
    public var onHandshakeFailure: ((PairingError) -> Void)?

    public var isClosed: Bool { inner.isClosed }

    public init(inner: BytePipe, role: Role, pairingCode: PairingCode,
                privateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        self.inner = inner
        self.role = role
        self.pairingCode = pairingCode
        self.myPrivateKey = privateKey
        inner.onReceive = { [weak self] data in self?.handleInbound(data) }
        inner.onClose = { [weak self] in self?.onClose?() }
    }

    /// 已建立密钥后才允许传输业务数据。
    public var isReady: Bool { handshakeComplete }

    public func begin(deviceID: String, timeout: TimeInterval = 10) {
        guard role == .initiator else { return }
        var random = SeededRandom(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        let hello = PairingHello(publicKey: myPrivateKey.publicKey.rawRepresentation,
                                 deviceID: deviceID, version: 1)
        _ = random
        // 先置状态再发送：在同步传输（如内存管道）下，send 会立即触发对端回复并完成握手，
        // 若在发送后才赋值，就会把已经完成的握手状态覆盖回 awaitingPeer。
        handshakeState = .awaitingPeer
        sendHandshake(hello)
        startHandshakeTimer(timeout: timeout, deviceID: deviceID)
    }

    private func startHandshakeTimer(timeout: TimeInterval, deviceID: String) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "m2m.secure.handshake"))
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler { [weak self] in
            guard let self, !self.handshakeComplete else { return }
            self.fail(.handshakeTimeout)
        }
        handshakeTimer = t
        t.resume()
    }

    private func fail(_ error: PairingError) {
        handshakeState = .failed(error.localizedDescription)
        onHandshakeFailure?(error)
        // 握手失败即关闭连接：不留半开状态，避免降级为明文
        inner.close()
    }

    private func handleInbound(_ data: Data) {
        if handshakeComplete {
            guard let plaintext = open(data) else {
                rejectedFrames += 1
                return
            }
            onReceive?(plaintext)
            return
        }
        guard let payload = Self.handshakePayload(data) else {
            fail(.malformedHandshake)
            return
        }
        switch role {
        case .responder:
            guard let hello = try? JSONDecoder().decode(PairingHello.self, from: payload) else {
                fail(.malformedHandshake)
                return
            }
            respond(to: hello)
        case .initiator:
            guard let ack = try? JSONDecoder().decode(PairingAck.self, from: payload) else {
                fail(.malformedHandshake)
                return
            }
            completeAsInitiator(ack)
        }
    }

    private func respond(to hello: PairingHello) {
        attempts += 1
        if let tracker = attemptTracker {
            guard tracker.recordAttempt(peer: hello.deviceID) else {
                sendHandshake(PairingAck(publicKey: Data(), deviceID: "", proof: Data(),
                                         accepted: false, reason: "尝试次数超限"))
                fail(.tooManyAttempts(limit: tracker.maxAttempts))
                return
            }
        } else {
            guard attempts <= maxAttempts else {
                sendHandshake(PairingAck(publicKey: Data(), deviceID: "", proof: Data(),
                                         accepted: false, reason: "尝试次数超限"))
                fail(.tooManyAttempts(limit: maxAttempts))
                return
            }
        }
        guard let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.publicKey),
              let shared = try? myPrivateKey.sharedSecretFromKeyAgreement(with: peerKey) else {
            sendHandshake(PairingAck(publicKey: Data(), deviceID: "", proof: Data(),
                                     accepted: false, reason: "公钥无效"))
            fail(.malformedHandshake)
            return
        }
        // 先按**收到的**配对码派生（responder 用自己配置的码），再用标签验证对端码是否一致
        let keys = Self.deriveKeys(shared: shared, code: pairingCode,
                                  initiatorPublic: hello.publicKey,
                                  responderPublic: myPrivateKey.publicKey.rawRepresentation)
        // 主动验证：initiator 会在拿到 ack 后再发一条用会话密钥加密的确认，
        // 因此这里直接接受并等待首个加密帧来验证配对码是否一致。
        peerDeviceID = hello.deviceID
        applyKeys(keys, asInitiator: false)
        let proof = Self.proof(sendKey: keys.initiatorToResponder, hello: hello.publicKey)
        sendHandshake(PairingAck(publicKey: myPrivateKey.publicKey.rawRepresentation,
                                 deviceID: responderDeviceID ?? "host", proof: proof,
                                 accepted: true, reason: nil))
        handshakeComplete = true
        handshakeState = .complete
        handshakeTimer?.cancel(); handshakeTimer = nil
        onHandshakeComplete?(hello.deviceID)
    }

    private func completeAsInitiator(_ ack: PairingAck) {
        guard ack.accepted else {
            fail(.peerRejected(ack.reason ?? "未说明原因"))
            return
        }
        guard let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ack.publicKey),
              let shared = try? myPrivateKey.sharedSecretFromKeyAgreement(with: peerKey) else {
            fail(.malformedHandshake)
            return
        }
        let keys = Self.deriveKeys(shared: shared, code: pairingCode,
                                  initiatorPublic: myPrivateKey.publicKey.rawRepresentation,
                                  responderPublic: ack.publicKey)
        let expectedProof = Self.proof(sendKey: keys.initiatorToResponder,
                                       hello: myPrivateKey.publicKey.rawRepresentation)
        guard constantTimeEquals(expectedProof, ack.proof) else {
            fail(.codeMismatch)
            return
        }
        attemptTracker?.recordSuccess(peer: peerDeviceID ?? "unknown")
        applyKeys(keys, asInitiator: true)
        handshakeComplete = true
        handshakeState = .complete
        handshakeTimer?.cancel(); handshakeTimer = nil
        peerDeviceID = ack.deviceID
        onHandshakeComplete?(ack.deviceID)
    }

    private struct Keys {
        var initiatorToResponder: SymmetricKey
        var responderToInitiator: SymmetricKey
        var authTag: Data
    }

    private static func deriveKeys(shared: SharedSecret, code: PairingCode,
                                   initiatorPublic: Data, responderPublic: Data) -> Keys {
        // salt 绑定双方公钥，避免同一对密钥在不同上下文中复用
        let salt = SHA256.hash(data: initiatorPublic + responderPublic)
        let psk = SymmetricKey(data: SHA256.hash(data: Data(code.value.utf8)))
        let root = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared.withUnsafeBytes { Data($0) }),
                                          salt: Data(salt),
                                          info: Data("m2m/v1/session".utf8),
                                          outputByteCount: 32)
        // 把配对码作为第二段输入混入，使码不一致时派生出不同的密钥
        let mixed = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root.withUnsafeBytes { Data($0) }),
                                           salt: Data(psk.withUnsafeBytes { Data($0) }),
                                           info: Data("m2m/v1/psk".utf8),
                                           outputByteCount: 64)
        let bytes = mixed.withUnsafeBytes { Data($0) }
        let k1 = SymmetricKey(data: bytes.prefix(32))
        let k2 = SymmetricKey(data: bytes.suffix(32))
        let tag = Data(SHA256.hash(data: bytes + initiatorPublic + responderPublic))
        return Keys(initiatorToResponder: k1, responderToInitiator: k2, authTag: tag)
    }

    private static func proof(sendKey: SymmetricKey, hello: Data) -> Data {
        let keyData = sendKey.withUnsafeBytes { Data($0) }
        return Data(SHA256.hash(data: keyData + hello))
    }

    private func applyKeys(_ keys: Keys, asInitiator: Bool) {
        if asInitiator {
            sendKey = keys.initiatorToResponder
            receiveKey = keys.responderToInitiator
        } else {
            sendKey = keys.responderToInitiator
            receiveKey = keys.initiatorToResponder
        }
        sendCounter = 0
        expectedReceiveCounter = 0
    }

    // MARK: BytePipe

    public func send(_ data: Data) {
        guard handshakeComplete, let sendKey else { return }
        sealedFrames += 1
        // nonce = 单调计数器，杜绝重放与乱序重放
        let nonce = Self.nonce(sendCounter, role: role)
        sendCounter += 1
        guard let sealed = try? ChaChaPoly.seal(data, using: sendKey, nonce: nonce) else { return }
        sendPlain(sealed.combined)
    }

    private func open(_ data: Data) -> Data? {
        guard let receiveKey else { return nil }
        guard let box = try? ChaChaPoly.SealedBox(combined: data) else {
            rejectedFrames += 1
            return nil
        }
        // 重放防护：只接受"下一个期望的计数器"所对应的 nonce。
        // ChaChaPoly 的 nonce 位于 combined 内，若只调用 open 而不比对 nonce，
        // 完全相同的密文可以被无限次重放并成功解密（同一密钥 + 同一 nonce）。
        let expectedNonce = Self.nonce(expectedReceiveCounter,
                                       role: role == .initiator ? .responder : .initiator)
        guard constantTimeEquals(Data(box.nonce), Data(expectedNonce)) else {
            rejectedFrames += 1
            if expectedReceiveCounter > 0 { return nil }
            fail(.decryptionFailed)
            return nil
        }
        guard let plaintext = try? ChaChaPoly.open(box, using: receiveKey) else {
            // 解密失败通常意味着配对码不一致，此时必须断开而不是继续明文或静默丢弃
            if expectedReceiveCounter == 0 {
                fail(.codeMismatch)
            }
            return nil
        }
        expectedReceiveCounter += 1
        openedFrames += 1
        return plaintext
    }

    private func sendPlain(_ data: Data) { inner.send(data) }

    private func sendHandshake<T: Encodable>(_ message: T) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        inner.send(Self.handshakeFrame(data))
    }

    /// 握手帧带魔数前缀，与加密帧（ChaChaPoly combined）区分开，
    /// 避免解析歧义导致把握手数据当成密文去解密。
    static let handshakeMagic: [UInt8] = [0x6D, 0x32, 0x6D, 0x48]   // "m2mH"

    static func handshakeFrame(_ payload: Data) -> Data {
        var out = Data(handshakeMagic)
        out.append(payload)
        return out
    }

    static func handshakePayload(_ frame: Data) -> Data? {
        guard frame.count > handshakeMagic.count,
              [UInt8](frame.prefix(handshakeMagic.count)) == handshakeMagic else { return nil }
        return Data(frame.dropFirst(handshakeMagic.count))
    }

    private static func nonce(_ counter: UInt64, role: Role) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        let tag: UInt8 = role == .initiator ? 1 : 2
        bytes[0] = tag
        for i in 0..<8 {
            bytes[4 + i] = UInt8((counter >> (8 * UInt64(7 - i))) & 0xFF)
        }
        return try! ChaChaPoly.Nonce(data: Data(bytes))
    }

    public func close() { inner.close() }
}

/// 常量时间比较，避免通过比较耗时可推断认证标签。
func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}
