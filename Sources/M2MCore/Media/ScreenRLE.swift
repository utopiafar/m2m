import Foundation

/// 屏幕内容的无损 RLE 编解码。
///
/// 为什么需要它：未压缩 BGRA 的一帧 560×380 就是 851 KB，会在码率预算下把帧率压到约 1fps，
/// 使带宽模拟与丢帧策略失去意义。屏幕内容（大面积纯色背景 + 文字块）用 RLE 能压到几个 KB，
/// 与真实屏幕编码的收益同量级，同时保持**无损**，因此像素级断言仍然成立。
///
/// 真实产品路径是 H.264/HEVC 硬件编解码（T4）；本编解码器用于合成/验证链路，
/// 以及在无硬件编码器环境下跑通整条管线。
public enum ScreenRLE {
    /// 魔数，用于快速识别与版本演进。
    static let magic: [UInt8] = [0x4D, 0x32, 0x52, 0x31]   // "M2R1"

    /// 压缩 BGRA 分组序列。
    /// 格式：magic || 分组数(varint) || 段*
    /// 段：0x00 重复段（count varint + 4 字节组）｜0x01 字面段（count varint + count×4 字节）
    public static func encode(_ pixels: [UInt8]) -> Data {
        var out = Data(magic)
        let groupCount = pixels.count / 4
        var w = BinaryWriter()
        w.writeUInt(UInt64(groupCount))
        out.append(w.data)

        var i = 0
        var body = Data()
        while i < groupCount {
            // 计算当前组的重复长度
            var run = 1
            let base = i * 4
            while i + run < groupCount,
                  pixels[(i + run) * 4] == pixels[base],
                  pixels[(i + run) * 4 + 1] == pixels[base + 1],
                  pixels[(i + run) * 4 + 2] == pixels[base + 2],
                  pixels[(i + run) * 4 + 3] == pixels[base + 3] {
                run += 1
            }
            if run >= 3 {
                var cw = BinaryWriter(); cw.writeUInt(UInt64(run))
                body.append(0x00)
                body.append(cw.data)
                body.append(contentsOf: pixels[base..<(base + 4)])
                i += run
            } else {
                // 收集字面段，直到遇到下一个长度 ≥3 的重复
                var literalCount = 0
                var scan = i
                while scan < groupCount {
                    var r = 1
                    let b = scan * 4
                    while scan + r < groupCount,
                          pixels[(scan + r) * 4] == pixels[b],
                          pixels[(scan + r) * 4 + 1] == pixels[b + 1],
                          pixels[(scan + r) * 4 + 2] == pixels[b + 2],
                          pixels[(scan + r) * 4 + 3] == pixels[b + 3] {
                        r += 1
                    }
                    if r >= 3 { break }
                    // 该重复长度为 1 或 2，可以并入字面段
                    scan += r
                    literalCount += r
                }
                if literalCount == 0 { literalCount = run; scan = i + run }
                var cw = BinaryWriter(); cw.writeUInt(UInt64(literalCount))
                body.append(0x01)
                body.append(cw.data)
                body.append(contentsOf: pixels[(i * 4)..<((i + literalCount) * 4)])
                i += literalCount
                _ = scan
            }
        }
        out.append(body)
        return out
    }

    /// 解压。返回 nil 表示数据损坏（调用方应请求关键帧而不是显示花屏）。
    public static func decode(_ data: Data) -> [UInt8]? {
        guard data.count > 4 else { return nil }
        let prefix = [UInt8](data.prefix(4))
        guard prefix == magic else { return nil }
        var reader = BinaryReader(Data(data.dropFirst(4)))
        guard let groupCount = try? reader.readUInt(), groupCount <= 1_000_000_000 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(Int(groupCount) * 4)
        var body = Data(data.dropFirst(4))
        // 跳过已解析的 groupCount 变长整数，重新定位 body 游标
        var w = BinaryWriter(); w.writeUInt(groupCount)
        body = Data(body.dropFirst(w.data.count))

        var idx = body.startIndex
        while out.count < Int(groupCount) * 4 {
            guard idx < body.endIndex else { return nil }
            let tag = body[idx]
            idx = body.index(after: idx)
            // 解析 count 变长整数
            var count: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard idx < body.endIndex else { return nil }
                let byte = body[idx]
                idx = body.index(after: idx)
                count |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                if shift > 63 { return nil }
            }
            if tag == 0x00 {
                guard idx + 4 <= body.endIndex else { return nil }
                let group = Array(body[idx..<(idx + 4)])
                idx += 4
                guard count > 0, count <= groupCount else { return nil }
                for _ in 0..<count { out.append(contentsOf: group) }
            } else if tag == 0x01 {
                let bytes = Int(count) * 4
                guard count > 0, idx + bytes <= body.endIndex else { return nil }
                out.append(contentsOf: body[idx..<(idx + bytes)])
                idx += bytes
            } else {
                return nil
            }
            if out.count > Int(groupCount) * 4 { return nil }
        }
        guard out.count == Int(groupCount) * 4 else { return nil }
        return out
    }

    /// 压缩率（用于报告）。
    public static func compressionRatio(originalBytes: Int, compressedBytes: Int) -> Double {
        guard compressedBytes > 0 else { return 0 }
        return Double(originalBytes) / Double(compressedBytes)
    }
}

/// 屏幕内容编码器（无损 RLE）。合成链路默认编码器。
public final class ScreenRLEEncoder: FrameEncoder {
    public let codec: CodecKind = .screenRLE
    private var index = 0
    public private(set) var totalRawBytes = 0
    public private(set) var totalEncodedBytes = 0

    public init() {}

    public func encode(_ frame: CapturedFrame, forceKeyframe: Bool) -> EncodedFrame {
        index += 1
        let payload = ScreenRLE.encode(frame.pixels)
        totalRawBytes += frame.pixels.count
        totalEncodedBytes += payload.count
        return EncodedFrame(streamID: frame.streamID, frameIndex: index,
                            isKeyframe: true, layoutVersion: frame.layoutVersion,
                            size: frame.size, byteCount: payload.count, codec: codec,
                            payload: payload, pixelChecksum: frame.checksum)
    }

    public var averageCompressionRatio: Double {
        ScreenRLE.compressionRatio(originalBytes: totalRawBytes, compressedBytes: totalEncodedBytes)
    }
}

/// 对应的解码器。解压失败时抛错，由上层请求关键帧。
public final class ScreenRLEDecoder: FrameDecoder {
    public init() {}

    public func decode(_ frame: EncodedFrame) throws -> DecodedFrame {
        guard frame.codec == .screenRLE else { throw DecodeError.unsupportedCodec(frame.codec) }
        guard let pixels = ScreenRLE.decode(frame.payload) else {
            throw DecodeError.corrupted("RLE 数据损坏")
        }
        guard let checksum = frame.pixelChecksum else { throw DecodeError.corrupted("缺少像素校验和") }
        return DecodedFrame(streamID: frame.streamID, size: frame.size,
                            layoutVersion: frame.layoutVersion, pixels: pixels,
                            isKeyframe: frame.isKeyframe, pixelChecksum: checksum)
    }
}
