import Foundation

/// 媒体帧的线格式。与 `Envelope` 不同，媒体帧走裸通道（不经过消息信封），
/// 但仍携带 `layoutVersion` 以便接收端做一致性校验（规则 B13）。
public struct MediaFrameWire: BinaryCodable, Sendable {
    public var codec: CodecKind
    public var isKeyframe: Bool
    public var layoutVersion: UInt64
    public var frameIndex: UInt32
    public var width: Double
    public var height: Double
    public var pixelChecksum: UInt64
    public var streamID: String
    public var payload: Data

    public init(codec: CodecKind, isKeyframe: Bool, layoutVersion: UInt64, frameIndex: UInt32,
                width: Double, height: Double, pixelChecksum: UInt64, streamID: String, payload: Data) {
        self.codec = codec; self.isKeyframe = isKeyframe; self.layoutVersion = layoutVersion
        self.frameIndex = frameIndex; self.width = width; self.height = height
        self.pixelChecksum = pixelChecksum; self.streamID = streamID; self.payload = payload
    }

    public init(_ frame: EncodedFrame) {
        self.init(codec: frame.codec, isKeyframe: frame.isKeyframe, layoutVersion: frame.layoutVersion,
                  frameIndex: UInt32(truncatingIfNeeded: frame.frameIndex),
                  width: frame.size.width, height: frame.size.height,
                  pixelChecksum: frame.pixelChecksum ?? 0, streamID: frame.streamID,
                  payload: frame.payload)
    }

    public var asEncodedFrame: EncodedFrame {
        EncodedFrame(streamID: streamID, frameIndex: Int(frameIndex), isKeyframe: isKeyframe,
                     layoutVersion: layoutVersion, size: Size(width, height),
                     byteCount: payload.count, codec: codec, payload: payload,
                     pixelChecksum: pixelChecksum == 0 ? nil : pixelChecksum)
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeEnum(codec.rawValue)
        writer.writeBool(isKeyframe)
        writer.writeUInt(layoutVersion)
        writer.writeUInt(UInt64(frameIndex))
        writer.writeDouble(width)
        writer.writeDouble(height)
        writer.writeUInt(pixelChecksum)
        writer.writeString(streamID)
        writer.writeBytes(payload)
    }

    public init(from reader: inout BinaryReader) throws {
        codec = try reader.readEnum(CodecKind.self)
        isKeyframe = try reader.readBool()
        layoutVersion = try reader.readUInt()
        frameIndex = UInt32(try reader.readUInt())
        width = try reader.readDouble()
        height = try reader.readDouble()
        pixelChecksum = try reader.readUInt()
        streamID = try reader.readString()
        payload = try reader.readBytes()
    }
}

// MARK: - 媒体降分辨率（P10 降级顺序的最后一级）

public enum FrameDownsampler {
    /// 盒式降采样。用于"先降帧率 → 再降画质 → 最后降分辨率"的最后一级。
    public static func downsample(_ frame: CapturedFrame, scale: ResolutionScale) -> CapturedFrame {
        guard scale != .full else { return frame }
        let factor = Int(scale.divisor)
        let w = max(1, Int(frame.size.width) / factor)
        let h = max(1, Int(frame.size.height) / factor)
        let srcW = Int(frame.size.width)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var acc = (0, 0, 0, 0)
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let sx = x * factor + dx, sy = y * factor + dy
                        guard sx < srcW, sy < Int(frame.size.height) else { continue }
                        let i = (sy * srcW + sx) * 4
                        acc.0 += Int(frame.pixels[i]); acc.1 += Int(frame.pixels[i+1])
                        acc.2 += Int(frame.pixels[i+2]); acc.3 += Int(frame.pixels[i+3])
                    }
                }
                let n = factor * factor
                let o = (y * w + x) * 4
                out[o] = UInt8(acc.0 / n); out[o+1] = UInt8(acc.1 / n)
                out[o+2] = UInt8(acc.2 / n); out[o+3] = UInt8(acc.3 / n)
            }
        }
        var f = frame
        f.pixels = out
        f.size = Size(Double(w), Double(h))
        return f
    }
}
