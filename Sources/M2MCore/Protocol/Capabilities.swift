import Foundation

/// 连接协商时交换的能力声明。
///
/// 规则（规格 §7）：这是**声明**而非承诺；实际行为由真机验证结果决定。
/// AX 读取失败不得导致窗口无法显示，但也不得宣称"原生中文输入已达标"。
public struct Capabilities: BinaryCodable, Equatable, Sendable {
    public var media: MediaCapabilities
    public var text: TextCapabilities
    public var adapters: [String]
    public var apps: [AppCapability]

    public init(media: MediaCapabilities, text: TextCapabilities,
                adapters: [String] = [], apps: [AppCapability] = []) {
        self.media = media; self.text = text; self.adapters = adapters; self.apps = apps
    }

    public func encode(to writer: inout BinaryWriter) {
        media.encode(to: &writer)
        text.encode(to: &writer)
        writer.writeUInt(UInt64(adapters.count)); for a in adapters { writer.writeString(a) }
        writer.writeUInt(UInt64(apps.count)); for a in apps { a.encode(to: &writer) }
    }
    public init(from reader: inout BinaryReader) throws {
        media = try MediaCapabilities(from: &reader)
        text = try TextCapabilities(from: &reader)
        var ads: [String] = []
        for _ in 0..<Int(try reader.readUInt()) { ads.append(try reader.readString()) }
        adapters = ads
        var aps: [AppCapability] = []
        for _ in 0..<Int(try reader.readUInt()) { aps.append(try AppCapability(from: &reader)) }
        apps = aps
    }

    /// 取两端声明的交集：只有双方都支持的能力才可用。
    ///
    /// `apps` **不参与交集**：应用清单是 Host 侧关于"被代理了哪些应用"的事实声明，
    /// Viewer 并不持有它。若对它求交集，Viewer 的空清单会把 Host 的认证信息抹掉，
    /// 导致降级状态无法上报给用户。
    public func intersected(with other: Capabilities) -> Capabilities {
        Capabilities(
            media: media.intersected(with: other.media),
            text: text.intersected(with: other.text),
            adapters: adapters.filter { other.adapters.contains($0) },
            apps: apps
        )
    }
}

public struct MediaCapabilities: BinaryCodable, Equatable, Sendable {
    public var codecs: [CodecKind]
    public var maxFPS: UInt8
    /// 是否具备真实硬件编码能力（不要求具备，合成链路也能工作）。
    public var hardwareEncode: Bool

    public init(codecs: [CodecKind], maxFPS: UInt8, hardwareEncode: Bool) {
        self.codecs = codecs; self.maxFPS = maxFPS; self.hardwareEncode = hardwareEncode
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(UInt64(codecs.count)); for c in codecs { writer.writeEnum(c.rawValue) }
        writer.writeUInt(UInt64(maxFPS)); writer.writeBool(hardwareEncode)
    }
    public init(from reader: inout BinaryReader) throws {
        var cs: [CodecKind] = []
        for _ in 0..<Int(try reader.readUInt()) { cs.append(try reader.readEnum(CodecKind.self)) }
        codecs = cs
        maxFPS = UInt8(try reader.readUInt()); hardwareEncode = try reader.readBool()
    }

    public func intersected(with other: MediaCapabilities) -> MediaCapabilities {
        MediaCapabilities(codecs: codecs.filter { other.codecs.contains($0) },
                          maxFPS: min(maxFPS, other.maxFPS),
                          hardwareEncode: hardwareEncode && other.hardwareEncode)
    }
}

/// 文本能力的五个维度，直接对应规格 §7 的能力上报与 §4 的候选窗定位要求。
public struct TextCapabilities: BinaryCodable, Equatable, Sendable {
    public var axAvailable: Bool
    public var focusTracking: Bool
    public var selectionRead: Bool
    /// 能否稳定拿到插入点矩形。**这是候选窗能否"贴近插入点"的前提**（P2）。
    public var caretRect: Bool
    public var compositionSupport: Bool

    public init(axAvailable: Bool, focusTracking: Bool, selectionRead: Bool,
                caretRect: Bool, compositionSupport: Bool) {
        self.axAvailable = axAvailable; self.focusTracking = focusTracking
        self.selectionRead = selectionRead; self.caretRect = caretRect
        self.compositionSupport = compositionSupport
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeBool(axAvailable); writer.writeBool(focusTracking)
        writer.writeBool(selectionRead); writer.writeBool(caretRect); writer.writeBool(compositionSupport)
    }
    public init(from reader: inout BinaryReader) throws {
        axAvailable = try reader.readBool(); focusTracking = try reader.readBool()
        selectionRead = try reader.readBool(); caretRect = try reader.readBool()
        compositionSupport = try reader.readBool()
    }

    public func intersected(with other: TextCapabilities) -> TextCapabilities {
        TextCapabilities(axAvailable: axAvailable && other.axAvailable,
                         focusTracking: focusTracking && other.focusTracking,
                         selectionRead: selectionRead && other.selectionRead,
                         caretRect: caretRect && other.caretRect,
                         compositionSupport: compositionSupport && other.compositionSupport)
    }
}

/// 输入模式：决定"本地输入法"能否适用（协议 §3.4）。
public enum InputMode: UInt8, BinaryCodable, Sendable, CaseIterable {
    /// 认证模式：本地组合、本地候选窗、TextCommit 提交。
    case localIME = 0
    /// 降级：原样转发按键，使用远端输入法。
    case remoteIME = 1
    /// 降级：直接发 Unicode 事件，无组合支持。
    case directText = 2
    /// 完全不支持文本输入（只读区域）。
    case none = 3

    public var isDegraded: Bool { self != .localIME }

    public var localizedDescription: String {
        switch self {
        case .localIME: return "本地输入法（原生体验）"
        case .remoteIME: return "降级：使用远端输入法"
        case .directText: return "降级：仅直接发送文字，无候选窗"
        case .none: return "该区域不接受文字输入"
        }
    }
}

public struct AppCapability: BinaryCodable, Equatable, Sendable {
    public var bundleID: String
    public var displayName: String
    /// 是否通过一期兼容性验收（可宣称"本地输入法体验"）。
    public var certified: Bool
    public var inputMode: InputMode
    /// 未能认证时的原因，用于 UI 提示（不得静默降级）。
    public var degradationReason: String?

    public init(bundleID: String, displayName: String, certified: Bool,
                inputMode: InputMode, degradationReason: String? = nil) {
        self.bundleID = bundleID; self.displayName = displayName
        self.certified = certified; self.inputMode = inputMode
        self.degradationReason = degradationReason
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(bundleID); writer.writeString(displayName)
        writer.writeBool(certified); writer.writeEnum(inputMode.rawValue)
        writer.writeOptionalString(degradationReason)
    }
    public init(from reader: inout BinaryReader) throws {
        bundleID = try reader.readString(); displayName = try reader.readString()
        certified = try reader.readBool(); inputMode = try reader.readEnum(InputMode.self)
        degradationReason = try reader.readOptionalString()
    }
}
