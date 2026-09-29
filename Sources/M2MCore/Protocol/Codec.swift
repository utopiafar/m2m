import Foundation

/// 紧凑二进制写入器。所有整数按小端、变长（LEB128）写入以节省空间。
public struct BinaryWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeUInt(_ value: UInt64) {
        var v = value
        while true {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
            if v == 0 { break }
        }
    }

    public mutating func writeInt(_ value: Int64) {
        // ZigZag 编码，负数不浪费空间
        let zig: UInt64 = value >= 0 ? UInt64(value) << 1 : (UInt64(bitPattern: -value) << 1) - 1
        writeUInt(zig)
    }

    public mutating func writeBool(_ value: Bool) { data.append(value ? 1 : 0) }

    public mutating func writeDouble(_ value: Double) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    public mutating func writeString(_ value: String) {
        let bytes = Data(value.utf8)
        writeUInt(UInt64(bytes.count))
        data.append(bytes)
    }

    public mutating func writeOptionalString(_ value: String?) {
        guard let value else { writeBool(false); return }
        writeBool(true)
        writeString(value)
    }

    public mutating func writeBytes(_ value: Data) {
        writeUInt(UInt64(value.count))
        data.append(value)
    }

    public mutating func writeEnum(_ raw: UInt8) { data.append(raw) }
}

/// 紧凑二进制读取器，与 `BinaryWriter` 对齐。
public struct BinaryReader {
    private let data: Data
    private var index: Data.Index

    public init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    public var isAtEnd: Bool { index >= data.endIndex }
    public var remaining: Int { data.endIndex - index }

    public mutating func readUInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < data.endIndex else { throw CodecError.truncated }
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { throw CodecError.malformed("varint overflow") }
        }
        return result
    }

    public mutating func readInt() throws -> Int64 {
        let zig = try readUInt()
        if zig & 1 == 0 { return Int64(zig >> 1) }
        return -Int64((zig >> 1) + 1)
    }

    public mutating func readBool() throws -> Bool {
        guard index < data.endIndex else { throw CodecError.truncated }
        let b = data[index]
        index = data.index(after: index)
        return b != 0
    }

    public mutating func readDouble() throws -> Double {
        guard remaining >= 8 else { throw CodecError.truncated }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(data[index + i]) << (8 * UInt64(i)) }
        index += 8
        return Double(bitPattern: bits)
    }

    public mutating func readString() throws -> String {
        let count = try Int(readUInt())
        guard count <= remaining, count >= 0 else { throw CodecError.truncated }
        let slice = data[index..<(index + count)]
        index += count
        guard let s = String(data: slice, encoding: .utf8) else { throw CodecError.malformed("bad utf8") }
        return s
    }

    public mutating func readOptionalString() throws -> String? {
        try readBool() ? readString() : nil
    }

    public mutating func readBytes() throws -> Data {
        let count = try Int(readUInt())
        guard count <= remaining, count >= 0 else { throw CodecError.truncated }
        let slice = data[index..<(index + count)]
        index += count
        return Data(slice)
    }

    public mutating func readEnum<T: RawRepresentable>(_ type: T.Type) throws -> T where T.RawValue == UInt8 {
        guard index < data.endIndex else { throw CodecError.truncated }
        let raw = data[index]
        index = data.index(after: index)
        guard let value = T(rawValue: raw) else {
            throw CodecError.malformed("unknown enum raw \(raw) for \(T.self)")
        }
        return value
    }
}

public enum CodecError: Error, Equatable {
    case truncated
    case malformed(String)
    case unknownMessageType(UInt8)
}

/// 所有协议消息遵循的编码接口。
public protocol BinaryCodable: Sendable {
    func encode(to writer: inout BinaryWriter)
    init(from reader: inout BinaryReader) throws
}

/// 让 `RawRepresentable` 且 `RawValue == UInt8` 的枚举（协议中的各类标签）自动获得编解码。
public extension BinaryCodable where Self: RawRepresentable, RawValue == UInt8 {
    func encode(to writer: inout BinaryWriter) { writer.writeEnum(rawValue) }
    init(from reader: inout BinaryReader) throws { self = try reader.readEnum(Self.self) }
}

public extension BinaryCodable {
    func encoded() -> Data {
        var w = BinaryWriter()
        encode(to: &w)
        return w.data
    }

    static func decode(_ data: Data) throws -> Self {
        var r = BinaryReader(data)
        let value = try Self(from: &r)
        return value
    }
}
