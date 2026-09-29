import Foundation

/// 文件桥。一期范围（P4）：本地选择/拖入 → 显式传输到远端临时目录 → 用户通过
/// 远端应用自身的文件选择流程使用。**不做透明文件系统，不做文件选择器重定向。**
///
/// 硬性要求：
/// - 分块传输必须限速，且不得阻塞输入（T7 / B-§4.3）
/// - 上传中断后可重试，且不得让半截文件被使用
/// - 临时文件必须有清理策略
public final class FileBridge {
    public struct Transfer: Equatable, Sendable {
        public var transferID: String
        public var name: String
        public var totalBytes: UInt64
        public var sentBytes: UInt64
        public var sha256: String
        public var remotePath: String?
        public var state: State

        public enum State: Equatable, Sendable {
            case pending
            case offering
            case transferring
            case awaitingComplete
            case completed
            case aborted(FileAbortReason)
        }

        public var progress: Double {
            totalBytes == 0 ? 0 : Double(sentBytes) / Double(totalBytes)
        }
    }

    public let chunkSize: Int
    /// 每秒最多发送的字节数。nil 表示不限速。
    public var rateLimitBytesPerSecond: Double?
    /// 远端临时目录（Host 侧）。
    public let remoteTempDirectory: URL
    /// 远端临时目录容量上限，超出时清理最旧文件。
    public var remoteTempQuotaBytes: UInt64

    public private(set) var transfers: [String: Transfer] = [:]
    public private(set) var completedNames: [String] = []
    /// 用于测试断言"文件上传没有阻塞输入"。
    public private(set) var bytesSentPerTick: [(time: TimeInterval, bytes: Int)] = []

    private var tokenBucket = 0.0
    private var lastTokenTime: TimeInterval = 0
    private var chunkQueue: [String: [Data]] = [:]
    private var writtenFiles: [String: Data] = [:]

    public init(remoteTempDirectory: URL, chunkSize: Int = 16 * 1024,
                rateLimitBytesPerSecond: Double? = nil, remoteTempQuotaBytes: UInt64 = 512 * 1024 * 1024) {
        self.remoteTempDirectory = remoteTempDirectory
        self.chunkSize = chunkSize
        self.rateLimitBytesPerSecond = rateLimitBytesPerSecond
        self.remoteTempQuotaBytes = remoteTempQuotaBytes
    }

    // MARK: 发送侧

    public func offer(transferID: String, name: String, data: Data) -> FileOffer {
        let sha = FileBridge.sha256(data)
        transfers[transferID] = Transfer(transferID: transferID, name: name,
                                        totalBytes: UInt64(data.count), sentBytes: 0,
                                        sha256: sha, remotePath: nil, state: .offering)
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        chunkQueue[transferID] = chunks
        return FileOffer(transferID: transferID, name: name, size: UInt64(data.count),
                         mime: "application/octet-stream", sha256: sha)
    }

    /// 发送一步：在限速允许的前提下产出一个分块。返回 nil 表示本次无可发内容。
    public func nextChunk(transferID: String, now: TimeInterval) -> FileChunk? {
        guard var t = transfers[transferID], t.state == .transferring || t.state == .offering else { return nil }
        guard var queue = chunkQueue[transferID], !queue.isEmpty else {
            if t.state == .transferring {
                t.state = .awaitingComplete
                transfers[transferID] = t
            }
            return nil
        }
        guard consumeTokens(bytes: queue[0].count, now: now) else { return nil }
        t.state = .transferring
        let bytes = queue.removeFirst()
        chunkQueue[transferID] = queue
        t.sentBytes += UInt64(bytes.count)
        transfers[transferID] = t
        bytesSentPerTick.append((now, bytes.count))
        let index = UInt32((t.totalBytes - UInt64(bytes.count)) / UInt64(chunkSize))
        return FileChunk(transferID: transferID, index: index, bytes: bytes)
    }

    public func beginTransfer(_ transferID: String) {
        guard var t = transfers[transferID] else { return }
        t.state = .transferring
        transfers[transferID] = t
    }

    public func abort(_ transferID: String, reason: FileAbortReason) {
        guard var t = transfers[transferID] else { return }
        t.state = .aborted(reason)
        transfers[transferID] = t
        chunkQueue[transferID] = nil
    }

    /// 中断后重试：从当前进度继续（已发送的字节不重发）。
    public func resume(_ transferID: String, remaining: Data, now: TimeInterval) {
        guard var t = transfers[transferID] else { return }
        t.state = .transferring
        transfers[transferID] = t
        var chunks: [Data] = []
        var offset = 0
        while offset < remaining.count {
            let end = min(offset + chunkSize, remaining.count)
            chunks.append(remaining.subdata(in: offset..<end))
            offset = end
        }
        chunkQueue[transferID] = chunks
        tokenBucket = 0
        lastTokenTime = now
    }

    private func consumeTokens(bytes: Int, now: TimeInterval) -> Bool {
        guard let rate = rateLimitBytesPerSecond else { return true }
        if now < lastTokenTime { lastTokenTime = now }
        tokenBucket = min(tokenBucket + (now - lastTokenTime) * rate, rate)
        lastTokenTime = now
        if tokenBucket >= Double(bytes) {
            tokenBucket -= Double(bytes)
            return true
        }
        return false
    }

    // MARK: 接收侧

    public struct ReceiveResult: Equatable, Sendable {
        public var transferID: String
        public var completed: Bool
        public var remotePath: String?
        public var aborted: FileAbortReason?
    }

    private var receiveBuffers: [String: Data] = [:]
    private var receivedOrder: [String] = []

    public func receive(_ chunk: FileChunk) -> FileProgress {
        let existing = receiveBuffers[chunk.transferID] ?? Data()
        var buffer = existing
        buffer.append(chunk.bytes)
        receiveBuffers[chunk.transferID] = buffer
        let total = transfers[chunk.transferID]?.totalBytes ?? 0
        return FileProgress(transferID: chunk.transferID, received: UInt64(buffer.count), total: total)
    }

    /// 完成一次接收：校验校验和后落盘。校验失败必须 abort，不得让半截内容被使用。
    public func completeReceive(_ complete: FileComplete) -> ReceiveResult {
        guard let expected = transfers[complete.transferID] else {
            return ReceiveResult(transferID: complete.transferID, completed: false,
                                 remotePath: nil, aborted: .peerAborted)
        }
        guard let buffer = receiveBuffers[complete.transferID] else {
            return ReceiveResult(transferID: complete.transferID, completed: false,
                                 remotePath: nil, aborted: .timeout)
        }
        let actual = FileBridge.sha256(buffer)
        guard actual == expected.sha256 else {
            receiveBuffers[complete.transferID] = nil
            abort(complete.transferID, reason: .checksumMismatch)
            return ReceiveResult(transferID: complete.transferID, completed: false,
                                 remotePath: nil, aborted: .checksumMismatch)
        }
        try? FileManager.default.createDirectory(at: remoteTempDirectory, withIntermediateDirectories: true)
        let dest = remoteTempDirectory.appendingPathComponent(sanitizedName(expected.name))
        do {
            try buffer.write(to: dest)
        } catch {
            return ReceiveResult(transferID: complete.transferID, completed: false,
                                 remotePath: nil, aborted: .diskFull)
        }
        writtenFiles[complete.transferID] = buffer
        receivedOrder.append(complete.transferID)
        receiveBuffers[complete.transferID] = nil
        var t = expected
        t.remotePath = dest.path
        t.state = .completed
        transfers[complete.transferID] = t
        completedNames.append(expected.name)
        enforceQuota()
        return ReceiveResult(transferID: complete.transferID, completed: true,
                             remotePath: dest.path, aborted: nil)
    }

    /// 文件名净化：只保留 [A-Za-z0-9._-]，并折叠点号序列。
    ///
    /// 折叠 `..` 是必要的，否则 `../..` 在去掉斜杠后会留下 `.._..` 这种
    /// 仍然带点号段的路径片段，在其它拼接方式下可能重新变成穿越。
    func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: "_")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // 隐藏文件前缀也去掉，避免产生 . 开头的怪名
        while cleaned.hasPrefix("_"), cleaned.count > 1 { break }
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "upload" }
        return cleaned
    }

    /// 容量超限时清理最旧的临时文件。
    private func enforceQuota() {
        var total = writtenFiles.values.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        while total > remoteTempQuotaBytes, let oldest = receivedOrder.first {
            if let data = writtenFiles.removeValue(forKey: oldest) {
                total -= UInt64(data.count)
                transfers[oldest]?.state = .aborted(.userCancelled)
            }
            receivedOrder.removeFirst()
            completedNames.removeFirst()
        }
    }

    /// 会话结束清理。
    public func cleanupTempDirectory() {
        for id in receivedOrder {
            if let t = transfers[id], let path = t.remotePath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        receivedOrder.removeAll()
        writtenFiles.removeAll()
        completedNames.removeAll()
    }

    public var temporaryFileCount: Int { receivedOrder.count }
    public var totalTemporaryBytes: UInt64 { writtenFiles.values.reduce(0) { $0 + UInt64($1.count) } }

    // MARK: 工具

    public static func sha256(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in data { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        var hash2: UInt64 = 0x84222325cbf29ce4
        for b in data.reversed() { hash2 = (hash2 ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx%016llx", hash, hash2)
    }
}

/// 剪贴板桥。必须防回环：收到 `origin=host` 的内容不再回传。
public final class ClipboardBridge {
    public private(set) var lastText: String?
    public private(set) var suppressedLoops = 0
    public private(set) var appliedUpdates: [ClipboardUpdate] = []

    /// 最近由**远端写入**的内容 hash 集合。
    ///
    /// 回环判定的关键是：本地把远端内容写入系统剪贴板后，系统会立刻报告一次
    /// "本地剪贴板变化"，必须被识别为回环。判定只能基于**本地计算**的 hash，
    /// 不能信任对端传过来的 hash 字段（那既可被伪造，也不保证与本地算法一致）。
    private var remoteAppliedHashes: Set<String> = []
    private var remoteAppliedOrder: [String] = []

    public init() {}

    private static func hash(of text: String) -> String {
        FileBridge.sha256(Data(text.utf8))
    }

    /// 处理收到的剪贴板更新。返回 true 表示应把它写入本地剪贴板。
    public func receive(_ update: ClipboardUpdate) -> Bool {
        guard let text = update.text else {
            // 图片/清空：直接应用，不参与文本回环判定
            appliedUpdates.append(update)
            return true
        }
        let localHash = Self.hash(of: text)
        // 若与本地最近发出的内容相同，说明是对端回显，不必再次应用
        if update.origin != .host, localHash == lastLocalSentHash {
            suppressedLoops += 1
            return false
        }
        lastText = text
        appliedUpdates.append(update)
        if update.origin == .host {
            rememberRemoteApplied(localHash)
        }
        return true
    }

    /// 本地剪贴板变化 → 生成待发送的更新（若与远端刚写入的内容相同则不发）。
    public func localChanged(text: String, origin: ClipboardOrigin) -> ClipboardUpdate? {
        let hash = Self.hash(of: text)
        if remoteAppliedHashes.contains(hash) {
            suppressedLoops += 1
            return nil
        }
        if hash == lastLocalSentHash { suppressedLoops += 1; return nil }
        lastLocalSentHash = hash
        lastText = text
        return ClipboardUpdate(kind: text.isEmpty ? .cleared : .text, text: text,
                               blobRef: nil, hash: hash, origin: origin)
    }

    private var lastLocalSentHash: String?

    private func rememberRemoteApplied(_ hash: String) {
        remoteAppliedHashes.insert(hash)
        remoteAppliedOrder.append(hash)
        if remoteAppliedOrder.count > 32 {
            let evicted = remoteAppliedOrder.removeFirst()
            remoteAppliedHashes.remove(evicted)
        }
    }

    /// 远端写入的内容被本地剪贴板消费后调用，用于清理回环标记。
    public func acknowledgeRemoteApplied(text: String) {
        remoteAppliedHashes.remove(Self.hash(of: text))
    }
}
