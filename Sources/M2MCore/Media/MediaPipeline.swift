import Foundation

// MARK: - 帧

/// 一帧捕获结果。使用 BGRA 像素缓冲，使"合成采集"与"真实采集"能够走同一条下游链路，
/// 从而让无屏幕录制权限的环境也能端到端验证媒体管线。
public struct CapturedFrame: Sendable {
    public var streamID: String
    public var size: Size
    public var contentScale: Double
    public var layoutVersion: UInt64
    public var frameIndex: Int
    public var isStatic: Bool
    public var pixels: [UInt8]     // BGRA8, size.width*size.height*4
    public var capturedAt: TimeInterval

    public init(streamID: String, size: Size, contentScale: Double, layoutVersion: UInt64,
                frameIndex: Int, isStatic: Bool, pixels: [UInt8], capturedAt: TimeInterval) {
        self.streamID = streamID; self.size = size; self.contentScale = contentScale
        self.layoutVersion = layoutVersion; self.frameIndex = frameIndex
        self.isStatic = isStatic; self.pixels = pixels; self.capturedAt = capturedAt
    }

    public var pixelCount: Int { Int(size.width) * Int(size.height) }
    public var checksum: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in pixels { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

public struct EncodedFrame: Sendable {
    public var streamID: String
    public var frameIndex: Int
    public var isKeyframe: Bool
    public var layoutVersion: UInt64
    public var size: Size
    /// 编码后字节数（用于码率与带宽估算）。
    public var byteCount: Int
    public var codec: CodecKind
    public var payload: Data
    /// 未压缩路径下保留原始像素校验和，便于端到端比对。
    public var pixelChecksum: UInt64?

    public init(streamID: String, frameIndex: Int, isKeyframe: Bool, layoutVersion: UInt64,
                size: Size, byteCount: Int, codec: CodecKind, payload: Data, pixelChecksum: UInt64? = nil) {
        self.streamID = streamID; self.frameIndex = frameIndex; self.isKeyframe = isKeyframe
        self.layoutVersion = layoutVersion; self.size = size; self.byteCount = byteCount
        self.codec = codec; self.payload = payload; self.pixelChecksum = pixelChecksum
    }
}

// MARK: - 采集

public protocol CaptureSource: AnyObject {
    var streamID: String { get }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    /// 采集一帧。返回 nil 表示当前无新内容（例如窗口未变化）。
    func nextFrame(now: TimeInterval) -> CapturedFrame?
    func setLayoutVersion(_ v: UInt64)
    func pause()
    func resume()
}

/// 确定性合成采集源：把"远端窗口内容"渲染为 BGRA 位图。
///
/// 它不是为了替代真实采集，而是为了让**采集之后的所有环节**（编码、丢帧、
/// 排队、传输、解码、显示、几何一致性）在没有屏幕录制权限时仍可被真实执行与断言。
public final class SyntheticCaptureSource: CaptureSource {
    public let streamID: String
    public var isAvailable: Bool { true }
    public var unavailableReason: String? { nil }

    /// 窗口当前应显示的内容（由被代理的 demo 应用驱动）。
    public var content: SyntheticWindowContent
    public var size: Size
    public var contentScale: Double
    private var layoutVersion: UInt64 = 1
    private var frameIndex = 0
    private var paused = false
    private var lastRenderedSignature: String = ""

    public init(streamID: String, size: Size, contentScale: Double = 2.0,
                content: SyntheticWindowContent = .init()) {
        self.streamID = streamID; self.size = size; self.contentScale = contentScale
        self.content = content
    }

    public func setLayoutVersion(_ v: UInt64) { layoutVersion = v }

    public func pause() { paused = true }
    public func resume() { paused = false }

    public func nextFrame(now: TimeInterval) -> CapturedFrame? {
        guard !paused else { return nil }
        let signature = content.signature
        let isStatic = signature == lastRenderedSignature
        // 静态内容降频：每 30 帧才产生一次刷新帧（规格 §3 后台/静态降频策略）
        if isStatic && frameIndex % 30 != 0 { frameIndex += 1; return nil }
        lastRenderedSignature = signature
        defer { frameIndex += 1 }
        let pixels = SyntheticRenderer.render(content, size: size)
        return CapturedFrame(streamID: streamID, size: size, contentScale: contentScale,
                             layoutVersion: layoutVersion, frameIndex: frameIndex,
                             isStatic: isStatic, pixels: pixels, capturedAt: now)
    }

    public var producedFrames: Int { frameIndex }
}

/// 被代理窗口的内容模型。字段变化即视为"画面有变化"。
public struct SyntheticWindowContent: Sendable, Equatable {
    public var title: String
    public var textContent: String
    public var caretOffset: Int
    public var selectionLength: Int
    public var scrollOffset: Double
    public var badge: String?
    public var theme: Theme

    public enum Theme: String, Sendable, Codable, CaseIterable {
        case light, dark, highContrast
    }

    public init(title: String = "Demo Window", textContent: String = "", caretOffset: Int = 0,
                selectionLength: Int = 0, scrollOffset: Double = 0, badge: String? = nil,
                theme: Theme = .light) {
        self.title = title; self.textContent = textContent
        self.caretOffset = caretOffset; self.selectionLength = selectionLength
        self.scrollOffset = scrollOffset; self.badge = badge; self.theme = theme
    }

    /// 画面签名：任一可见字段变化都会改变它。
    public var signature: String {
        "\(title)|\(textContent)|\(caretOffset)|\(selectionLength)|\(scrollOffset)|\(badge ?? "")|\(theme.rawValue)"
    }
}

/// 极简位图渲染器：把窗口内容画成像素，用于可视化验证与像素级断言。
public enum SyntheticRenderer {
    public static func render(_ content: SyntheticWindowContent, size: Size) -> [UInt8] {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let (bg, fg, accent) = palette(for: content.theme)

        // 背景
        for i in 0..<(w * h) {
            px[i * 4 + 0] = bg.0; px[i * 4 + 1] = bg.1; px[i * 4 + 2] = bg.2; px[i * 4 + 3] = 255
        }
        // 标题栏（前 28 行）
        let barHeight = min(28, h)
        for y in 0..<barHeight {
            for x in 0..<w {
                let i = (y * w + x) * 4
                px[i] = accent.0; px[i + 1] = accent.1; px[i + 2] = accent.2; px[i + 3] = 255
            }
        }
        // 文本内容区：把字符编码为像素块，保证内容变化 → 像素变化
        let textBytes = Array(content.textContent.utf8)
        let cols = max(1, (w - 20) / 8)
        let startRow = content.scrollOffset > 0 ? Int(content.scrollOffset) % 8 : 0
        for (idx, byte) in textBytes.enumerated() {
            let col = (idx + startRow) % cols
            let row = ((idx + startRow) / cols) % max(1, (h - 40) / 10)
            let x0 = 10 + col * 8
            let y0 = 36 + row * 10
            guard x0 + 6 < w, y0 + 7 < h else { continue }
            drawGlyph(&px, w: w, x: x0, y: y0, value: UInt8(byte % 32), fg: fg)
        }
        // 光标：垂直条
        let caretCol = min(content.caretOffset, max(0, cols - 1))
        let caretRow = min(content.caretOffset / max(1, cols), max(0, (h - 40) / 10 - 1))
        let cx = 10 + caretCol * 8 + 6
        let cy = 36 + caretRow * 10
        if cx < w - 1, cy + 7 < h {
            for y in cy..<(cy + 8) { let i = (y * w + cx) * 4; px[i] = fg.0; px[i+1] = fg.1; px[i+2] = fg.2 }
        }
        // 选区标记
        if content.selectionLength > 0 {
            let selW = min(content.selectionLength * 8, w - 12)
            for y in max(36, cy - 2)..<min(h, cy + 10) {
                for x in 10..<(10 + selW) {
                    let i = (y * w + x) * 4
                    px[i] = min(255, px[i] / 2 + 60); px[i+1] = min(255, px[i+1] / 2 + 60)
                    px[i+2] = min(255, px[i+2] / 2 + 140)
                }
            }
        }
        // 徽标（用于标记降级状态等）
        if let badge = content.badge {
            for (idx, byte) in Array(badge.utf8).prefix(32).enumerated() {
                let x0 = 12 + idx * 6
                let y0 = min(h - 10, max(30, h - 24))
                guard x0 + 4 < w else { continue }
                drawGlyph(&px, w: w, x: x0, y: y0, value: UInt8(byte % 32), fg: (255, 90, 90))
            }
        }
        return px
    }

    private static func palette(for theme: SyntheticWindowContent.Theme) -> ((UInt8, UInt8, UInt8), (UInt8, UInt8, UInt8), (UInt8, UInt8, UInt8)) {
        switch theme {
        case .light: return ((245, 245, 247), (28, 28, 30), (60, 120, 200))
        case .dark: return ((28, 28, 30), (235, 235, 240), (90, 90, 100))
        case .highContrast: return ((0, 0, 0), (255, 255, 0), (0, 128, 255))
        }
    }

    private static func drawGlyph(_ px: inout [UInt8], w: Int, x: Int, y: Int, value: UInt8,
                                  fg: (UInt8, UInt8, UInt8)) {
        for row in 0..<7 {
            let bits = (value >> UInt8(row)) & 0b11111
            for col in 0..<5 {
                guard bits & (1 << UInt8(col)) != 0 else { continue }
                let xx = x + col, yy = y + row
                guard xx >= 0, yy >= 0, xx < w else { continue }
                let idx = (yy * w + xx) * 4
                guard idx + 3 < px.count else { continue }
                px[idx] = fg.0; px[idx + 1] = fg.1; px[idx + 2] = fg.2; px[idx + 3] = 255
            }
        }
    }
}

// MARK: - 编码

public protocol FrameEncoder: AnyObject {
    var codec: CodecKind { get }
    func encode(_ frame: CapturedFrame, forceKeyframe: Bool) -> EncodedFrame
}

/// 无损"未压缩"编码器：单机验证与像素级断言使用。
/// 它让下游（丢帧策略、排队、传输、解码、显示）能在没有硬件编码器的环境下被真实验证。
public final class RawFrameEncoder: FrameEncoder {
    public let codec: CodecKind = .rawBGRA
    private var index = 0

    public init() {}

    public func encode(_ frame: CapturedFrame, forceKeyframe: Bool) -> EncodedFrame {
        index += 1
        let payload = Data(frame.pixels)
        return EncodedFrame(streamID: frame.streamID, frameIndex: index,
                            isKeyframe: true, layoutVersion: frame.layoutVersion,
                            size: frame.size, byteCount: payload.count, codec: codec,
                            payload: payload, pixelChecksum: frame.checksum)
    }
}

// MARK: - 排队与丢帧

/// 有界编码队列。
///
/// 承载规格 §4 的两条硬规则：
/// 1. 可以丢弃**尚未编码**的过期画面；
/// 2. **不得**丢弃已编码帧（参考依赖）。
public final class EncoderQueue {
    public private(set) var pendingUnencoded: [CapturedFrame] = []
    public private(set) var encoded: [EncodedFrame] = []
    public private(set) var droppedUnencoded = 0
    public private(set) var droppedEncoded = 0
    public let maxUnencoded: Int
    public let maxEncoded: Int

    public init(maxUnencoded: Int = 2, maxEncoded: Int = 8) {
        self.maxUnencoded = maxUnencoded; self.maxEncoded = maxEncoded
    }

    /// 入队一帧捕获结果。超出上界时丢弃**最旧的未编码帧**。
    public func enqueue(_ frame: CapturedFrame) {
        pendingUnencoded.append(frame)
        while pendingUnencoded.count > maxUnencoded {
            pendingUnencoded.removeFirst()
            droppedUnencoded += 1
        }
    }

    /// 编码一步。返回被编码的帧（若有）。
    public func encodeOne(with encoder: FrameEncoder, forceKeyframe: Bool = false) -> EncodedFrame? {
        guard !pendingUnencoded.isEmpty else { return nil }
        let frame = pendingUnencoded.removeFirst()
        let out = encoder.encode(frame, forceKeyframe: forceKeyframe)
        encoded.append(out)
        while encoded.count > maxEncoded {
            encoded.removeFirst()
            droppedEncoded += 1
        }
        return out
    }

    /// 取出待发送的编码帧。
    public func dequeueEncoded() -> EncodedFrame? {
        guard !encoded.isEmpty else { return nil }
        return encoded.removeFirst()
    }

    public var isBackpressured: Bool { pendingUnencoded.count >= maxUnencoded }
}

/// 发送侧码率控制器：按目标码率决定是否**跳过尚未编码的帧**（绝不丢弃已编码帧）。
///
/// 预算必须以**编码后的实际字节数**估算。若用原始像素量估算，一帧 1400×1000 的
/// 未压缩数据就是 5.6 MB，会把整秒预算一次吃光，导致每秒钟只放行一帧画面。
/// 这里采用自适应估算：用同一路流上一帧的真实编码字节数预测下一帧。
public final class BitrateGovernor {
    public var targetBitsPerSecond: Double
    /// 首帧的保守压缩比假设（屏幕内容通常远高于此）。
    public var initialCompressionRatio: Double = 40

    private var windowStart: TimeInterval = 0
    private var bitsInWindow: Double = 0
    private var lastEncodedBytes: [String: Int] = [:]
    public private(set) var skippedForBudget = 0
    public private(set) var observedFrames = 0

    public init(targetBitsPerSecond: Double = 8_000_000) {
        self.targetBitsPerSecond = targetBitsPerSecond
    }

    /// 估算下一帧的编码后大小（按流分别跟踪）。
    public func estimatedBytes(streamID: String, rawBytes: Int) -> Int {
        if let last = lastEncodedBytes[streamID], last > 0 { return last }
        return max(1, Int(Double(rawBytes) / initialCompressionRatio))
    }

    /// 是否允许再编一帧。
    public func allow(estimatedBytes: Int, now: TimeInterval, forceKeyframe: Bool) -> Bool {
        if forceKeyframe { return true }
        if now - windowStart >= 1.0 { windowStart = now; bitsInWindow = 0 }
        let next = bitsInWindow + Double(estimatedBytes) * 8
        if next > targetBitsPerSecond {
            skippedForBudget += 1
            return false
        }
        bitsInWindow = next
        return true
    }

    /// 反馈实际编码后字节数，用于下一次估算。
    public func observe(streamID: String, encodedBytes: Int) {
        lastEncodedBytes[streamID] = encodedBytes
        observedFrames += 1
    }

    public var achievedBitsPerSecond: Double { bitsInWindow }
}

// MARK: - 解码与显示

/// 解码器：把编码帧还原为可显示位图。真实实现是 VideoToolbox 硬件解码（T3/T4）。
public protocol FrameDecoder: AnyObject {
    func decode(_ frame: EncodedFrame) throws -> DecodedFrame
}

public struct DecodedFrame: Sendable {
    public var streamID: String
    public var size: Size
    public var layoutVersion: UInt64
    public var pixels: [UInt8]
    public var isKeyframe: Bool
    public var pixelChecksum: UInt64
}

public enum DecodeError: Error, Equatable {
    case unsupportedCodec(CodecKind)
    case corrupted(String)
    /// 缺少参考帧：必须请求关键帧，而不是显示错误内容。
    case missingReferenceFrame
}

public final class RawFrameDecoder: FrameDecoder {
    public init() {}
    public func decode(_ frame: EncodedFrame) throws -> DecodedFrame {
        guard frame.codec == .rawBGRA else { throw DecodeError.unsupportedCodec(frame.codec) }
        guard let checksum = frame.pixelChecksum else { throw DecodeError.corrupted("缺少像素校验和") }
        return DecodedFrame(streamID: frame.streamID, size: frame.size, layoutVersion: frame.layoutVersion,
                            pixels: [UInt8](frame.payload), isKeyframe: frame.isKeyframe,
                            pixelChecksum: checksum)
    }
}

/// 接收侧：负责"帧与几何版本一致"的校验（规格 §1.2 规则 4 / B13）。
public final class FrameReceiver {
    public private(set) var lastLayoutVersion: UInt64 = 0
    public private(set) var droppedAsStale: Int = 0
    public private(set) var needsKeyframe = true
    public private(set) var decodedChecksums: [UInt64] = []

    public init() {}

    /// 返回可显示的帧；版本不一致时返回 nil 并要求关键帧。
    public func ingest(_ frame: EncodedFrame, decoder: FrameDecoder,
                       currentLayoutVersion: UInt64) throws -> DecodedFrame? {
        guard frame.layoutVersion == currentLayoutVersion else {
            droppedAsStale += 1
            return nil
        }
        if needsKeyframe && !frame.isKeyframe {
            throw DecodeError.missingReferenceFrame
        }
        let decoded = try decoder.decode(frame)
        if frame.isKeyframe { needsKeyframe = false }
        lastLayoutVersion = frame.layoutVersion
        decodedChecksums.append(decoded.pixelChecksum)
        return decoded
    }

    public func requestKeyframe() { needsKeyframe = true }

    public func markDecodeFailure() {
        needsKeyframe = true
        decodedChecksums.removeAll()
    }
}

// MARK: - 帧分析
//
// 用途：区分"真实屏幕采集"与"合成渲染"。
// 合成渲染只用少数几种色块（背景/前景/强调色 + 字形），而真实窗口截图包含
// 标题栏渐变、抗锯齿文字、阴影、子像素混合，颜色种类高出几个数量级。
// 这让"真实采集是否真的生效"成为可自动断言的性质，而不是靠肉眼确认。
public enum FrameAnalysis {
    public struct Signature: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var checksum: UInt64
        /// 抽样统计出的不同颜色数（RGB 去低位后计数）
        public var distinctColors: Int
        /// 抽样点的平均亮度，用于识别"全黑/全白"的异常画面
        public var averageLuma: Double

        public var looksLikeRealScreenContent: Bool {
            distinctColors >= 64 && averageLuma > 4 && averageLuma < 251
        }
    }

    /// 抽样分析一帧。`stride` 越大越快；默认每 7 个像素取 1 个。
    public static func analyze(_ frame: DecodedFrame, stride: Int = 7) -> Signature {
        let pixels = frame.pixels
        var colors = Set<UInt32>()
        var lumaSum = 0.0
        var count = 0
        var i = 0
        let step = max(1, stride) * 4
        while i + 3 < pixels.count {
            let b = UInt32(pixels[i]), g = UInt32(pixels[i + 1])
            let r = UInt32(pixels[i + 2]), a = UInt32(pixels[i + 3])
            guard a > 0 else { i += step; continue }
            // 去掉低 3 位，避免抗锯齿造成的过度细分同时仍保留真实渐变
            let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            colors.insert(key)
            lumaSum += 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            count += 1
            i += step
        }
        return Signature(width: Int(frame.size.width), height: Int(frame.size.height),
                         checksum: frame.pixelChecksum, distinctColors: colors.count,
                         averageLuma: count > 0 ? lumaSum / Double(count) : 0)
    }
}
