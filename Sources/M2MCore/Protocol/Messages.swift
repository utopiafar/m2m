import Foundation

// MARK: - 消息类型标签

public enum MessageType: UInt8, Sendable {
    case hello = 1
    case helloAck = 2
    case windowSnapshot = 10
    case windowDelta = 11
    case windowResizeRequest = 12
    case windowResizeResult = 13
    case windowAction = 14
    case streamInfo = 20
    case keyframeRequest = 21
    case streamAdjustRequest = 22
    case streamState = 23
    case textContext = 30
    case textContextInvalidated = 31
    /// Host → Viewer：运行时的能力更新。
    ///
    /// 能力不是常量：插入点是否可用取决于读取时刻的焦点状态，应用也可能重启后
    /// 改变输入模式。只在握手时下发一次，会让 Viewer 长期显示过期的能力与降级标识。
    case capabilityUpdate = 37

    /// Viewer → Host：请重新下发编辑上下文。
    /// 没有它，Viewer 一旦主动丢弃上下文（切窗口、重连）就无法恢复——
    /// 因为 Host 只在 editVersion 变化时才推送。
    case textContextRequest = 36
    case textCommit = 32
    case textCommitResult = 33
    case keyEvent = 34
    case pointerEvent = 35
    case clipboardUpdate = 40
    case fileOffer = 41
    case fileChunk = 42
    case fileComplete = 43
    case fileAbort = 44
    case fileProgress = 45
    case sessionState = 50
    case revokeControl = 51
    case errorReport = 52

    /// 每条消息所属的逻辑通道，用于调度与优先级。
    public var channel: Channel {
        switch self {
        case .hello, .helloAck, .sessionState, .revokeControl, .errorReport:
            return .control
        // 提交与其结果同属输入通道：结果必须及时且与提交保序，
        // 否则界面的"提交中"状态会被低优先级的状态消息拖住。
        case .keyEvent, .pointerEvent, .textCommit, .textCommitResult:
            return .input
        case .windowSnapshot, .windowDelta, .windowResizeRequest, .windowResizeResult,
             .windowAction, .streamInfo, .streamState, .textContext, .textContextInvalidated,
             .clipboardUpdate, .keyframeRequest, .streamAdjustRequest, .textContextRequest,
             .capabilityUpdate:
            return .state
        // 文件相关消息必须**全部**在同一通道上：若 offer/chunk 走 file 而 complete 走 state，
        // 优先级调度会让"完成"先于"数据"到达，接收端就会判定为传输超时。
        case .fileOffer, .fileChunk, .fileComplete, .fileAbort, .fileProgress:
            return .file
        }
    }
}

// MARK: - 会话协商

public struct Hello: BinaryCodable, Sendable {
    public var protocolVersion: UInt32
    public var deviceID: String
    public var deviceName: String
    public var nonce: Data
    public var capabilities: Capabilities

    public init(protocolVersion: UInt32 = ProtocolVersion.current,
                deviceID: String, deviceName: String, nonce: Data, capabilities: Capabilities) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.nonce = nonce
        self.capabilities = capabilities
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(UInt64(protocolVersion))
        writer.writeString(deviceID)
        writer.writeString(deviceName)
        writer.writeBytes(nonce)
        capabilities.encode(to: &writer)
    }
    public init(from reader: inout BinaryReader) throws {
        protocolVersion = UInt32(try reader.readUInt())
        deviceID = try reader.readString()
        deviceName = try reader.readString()
        nonce = try reader.readBytes()
        capabilities = try Capabilities(from: &reader)
    }
}

public struct HelloAck: BinaryCodable, Sendable {
    public var protocolVersion: UInt32
    public var deviceID: String
    public var nonce: Data
    /// 会话代次，**由 Host 权威决定**。
    ///
    /// 重连时 Viewer 先用旧 epoch 发送 Hello（否则被对端按过期消息丢弃），
    /// Host 推进 epoch 后用**旧 epoch** 回 HelloAck，Viewer 从本字段采纳新值。
    /// 这样两端不会各自推进而导致互相丢弃消息。
    public var epoch: UInt64
    public var acceptedCapabilities: Capabilities
    /// 若协商失败，给出人类可读原因（不得静默失败）。
    public var rejectionReason: String?

    public init(protocolVersion: UInt32 = ProtocolVersion.current, deviceID: String, nonce: Data,
                epoch: UInt64 = 1,
                acceptedCapabilities: Capabilities, rejectionReason: String? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.nonce = nonce
        self.epoch = epoch
        self.acceptedCapabilities = acceptedCapabilities
        self.rejectionReason = rejectionReason
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(UInt64(protocolVersion))
        writer.writeString(deviceID)
        writer.writeBytes(nonce)
        writer.writeUInt(epoch)
        acceptedCapabilities.encode(to: &writer)
        writer.writeOptionalString(rejectionReason)
    }
    public init(from reader: inout BinaryReader) throws {
        protocolVersion = UInt32(try reader.readUInt())
        deviceID = try reader.readString()
        nonce = try reader.readBytes()
        epoch = try reader.readUInt()
        acceptedCapabilities = try Capabilities(from: &reader)
        rejectionReason = try reader.readOptionalString()
    }
}

public enum ProtocolVersion {
    public static let current: UInt32 = 1
}

// MARK: - 窗口

public enum WindowRole: UInt8, BinaryCodable, Sendable, CaseIterable {
    case main = 0
    case panel = 1
    case dialog = 2
    case popupMenu = 3
    case child = 4
    case unknown = 5

    public var localizedDescription: String {
        switch self {
        case .main: return "主窗口"
        case .panel: return "面板"
        case .dialog: return "对话框"
        case .popupMenu: return "弹出菜单"
        case .child: return "子窗口"
        case .unknown: return "未识别窗口类型"
        }
    }

    /// 规格 §1.3：unknown 仍要建壳，但必须标注，且不得退化为共享整桌面。
    public var requiresLocalShell: Bool { self != .child }

    public var isModalCandidate: Bool { self == .dialog || self == .panel }
}

public struct WindowInfo: BinaryCodable, Equatable, Sendable {
    public var windowUID: String
    public var appPID: Int32
    public var appLaunchID: String
    public var bundleID: String
    public var title: String
    public var role: WindowRole
    public var parentUID: String?
    public var modal: Bool
    public var contentRect: Rect
    public var contentScale: Double
    public var constraints: SizeConstraints
    public var minimized: Bool
    public var focusable: Bool
    public var zOrder: Int32

    public init(windowUID: String, appPID: Int32, appLaunchID: String, bundleID: String, title: String,
                role: WindowRole, parentUID: String? = nil, modal: Bool = false,
                contentRect: Rect, contentScale: Double = 2.0,
                constraints: SizeConstraints = SizeConstraints(), minimized: Bool = false,
                focusable: Bool = true, zOrder: Int32 = 0) {
        self.windowUID = windowUID
        self.appPID = appPID
        self.appLaunchID = appLaunchID
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.parentUID = parentUID
        self.modal = modal
        self.contentRect = contentRect
        self.contentScale = contentScale
        self.constraints = constraints
        self.minimized = minimized
        self.focusable = focusable
        self.zOrder = zOrder
    }

    public var contentSize: Size { contentRect.size }

    /// 采集像素尺寸。编码像素量预算据此计算（规格 §5.1）。
    public var captureSize: Size { Size(contentRect.size.width * contentScale, contentRect.size.height * contentScale) }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(windowUID)
        writer.writeInt(Int64(appPID))
        writer.writeString(appLaunchID)
        writer.writeString(bundleID)
        writer.writeString(title)
        writer.writeEnum(role.rawValue)
        writer.writeOptionalString(parentUID)
        writer.writeBool(modal)
        contentRect.encode(to: &writer)
        writer.writeDouble(contentScale)
        writer.writeOptionalString(constraints.minSize.map { "\($0.width)x\($0.height)" })
        writer.writeOptionalString(constraints.maxSize.map { "\($0.width)x\($0.height)" })
        writer.writeEnum(constraints.resizable.rawValue)
        writer.writeBool(minimized)
        writer.writeBool(focusable)
        writer.writeInt(Int64(zOrder))
    }

    public init(from reader: inout BinaryReader) throws {
        windowUID = try reader.readString()
        appPID = Int32(try reader.readInt())
        appLaunchID = try reader.readString()
        bundleID = try reader.readString()
        title = try reader.readString()
        role = try reader.readEnum(WindowRole.self)
        parentUID = try reader.readOptionalString()
        modal = try reader.readBool()
        contentRect = try Rect(from: &reader)
        contentScale = try reader.readDouble()
        let minS = try reader.readOptionalString()
        let maxS = try reader.readOptionalString()
        let resizable = try reader.readEnum(SizeConstraints.Resizable.self)
        minimized = try reader.readBool()
        focusable = try reader.readBool()
        zOrder = Int32(try reader.readInt())
        constraints = SizeConstraints(
            minSize: minS.flatMap(SizeConstraints.parseSize),
            maxSize: maxS.flatMap(SizeConstraints.parseSize),
            resizable: resizable
        )
    }
}

public extension SizeConstraints {
    static func parseSize(_ s: String) -> Size? {
        let parts = s.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return Size(w, h)
    }
}

public struct WindowSnapshot: BinaryCodable, Sendable {
    public var epoch: UInt64
    public var layoutVersion: UInt64
    public var windows: [WindowInfo]

    public init(epoch: UInt64, layoutVersion: UInt64, windows: [WindowInfo]) {
        self.epoch = epoch
        self.layoutVersion = layoutVersion
        self.windows = windows
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch)
        writer.writeUInt(layoutVersion)
        writer.writeUInt(UInt64(windows.count))
        for w in windows { w.encode(to: &writer) }
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt()
        layoutVersion = try reader.readUInt()
        let count = try Int(reader.readUInt())
        var list: [WindowInfo] = []
        list.reserveCapacity(count)
        for _ in 0..<count { list.append(try WindowInfo(from: &reader)) }
        windows = list
    }
}

public struct WindowDelta: BinaryCodable, Sendable {
    public var epoch: UInt64
    public var layoutVersion: UInt64
    public var added: [WindowInfo]
    public var removed: [String]
    public var changed: [WindowInfo]

    public init(epoch: UInt64, layoutVersion: UInt64, added: [WindowInfo] = [],
                removed: [String] = [], changed: [WindowInfo] = []) {
        self.epoch = epoch
        self.layoutVersion = layoutVersion
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch)
        writer.writeUInt(layoutVersion)
        writer.writeUInt(UInt64(added.count)); for w in added { w.encode(to: &writer) }
        writer.writeUInt(UInt64(removed.count)); for r in removed { writer.writeString(r) }
        writer.writeUInt(UInt64(changed.count)); for w in changed { w.encode(to: &writer) }
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt()
        layoutVersion = try reader.readUInt()
        var a: [WindowInfo] = []
        for _ in 0..<Int(try reader.readUInt()) { a.append(try WindowInfo(from: &reader)) }
        var r: [String] = []
        for _ in 0..<Int(try reader.readUInt()) { r.append(try reader.readString()) }
        var c: [WindowInfo] = []
        for _ in 0..<Int(try reader.readUInt()) { c.append(try WindowInfo(from: &reader)) }
        added = a; removed = r; changed = c
    }
}

public struct WindowResizeRequest: BinaryCodable, Sendable {
    public var epoch: UInt64
    public var windowUID: String
    public var requestedContentSize: Size
    /// 同一窗口的合并序号；接收方只处理最新（规格 §1.2 规则 3）。
    public var requestSeq: UInt32

    public init(epoch: UInt64, windowUID: String, requestedContentSize: Size, requestSeq: UInt32) {
        self.epoch = epoch
        self.windowUID = windowUID
        self.requestedContentSize = requestedContentSize
        self.requestSeq = requestSeq
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch); writer.writeString(windowUID)
        requestedContentSize.encode(to: &writer); writer.writeUInt(UInt64(requestSeq))
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt(); windowUID = try reader.readString()
        requestedContentSize = try Size(from: &reader); requestSeq = UInt32(try reader.readUInt())
    }
}

public struct WindowResizeResult: BinaryCodable, Sendable {
    public var requestSeq: UInt32
    public var actualContentSize: Size
    public var layoutVersion: UInt64
    public var constrainedBy: SizeConstraint

    public init(requestSeq: UInt32, actualContentSize: Size, layoutVersion: UInt64, constrainedBy: SizeConstraint) {
        self.requestSeq = requestSeq
        self.actualContentSize = actualContentSize
        self.layoutVersion = layoutVersion
        self.constrainedBy = constrainedBy
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(UInt64(requestSeq)); actualContentSize.encode(to: &writer)
        writer.writeUInt(layoutVersion); writer.writeEnum(constrainedBy.rawValue)
    }
    public init(from reader: inout BinaryReader) throws {
        requestSeq = UInt32(try reader.readUInt())
        actualContentSize = try Size(from: &reader)
        layoutVersion = try reader.readUInt()
        constrainedBy = try reader.readEnum(SizeConstraint.self)
    }
}

public enum WindowActionKind: UInt8, BinaryCodable, Sendable, CaseIterable {
    case activate = 0
    case minimize = 1
    case unminimize = 2
    case close = 3
    case requestFullscreen = 4

    public var localizedDescription: String {
        switch self {
        case .activate: return "激活"
        case .minimize: return "最小化"
        case .unminimize: return "恢复"
        case .close: return "关闭远端窗口"
        case .requestFullscreen: return "全屏"
        }
    }
}

public struct WindowAction: BinaryCodable, Equatable, Sendable {
    public var epoch: UInt64
    public var windowUID: String
    public var action: WindowActionKind

    public init(epoch: UInt64, windowUID: String, action: WindowActionKind) {
        self.epoch = epoch; self.windowUID = windowUID; self.action = action
    }
    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch); writer.writeString(windowUID); writer.writeEnum(action.rawValue)
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt(); windowUID = try reader.readString()
        action = try reader.readEnum(WindowActionKind.self)
    }
}

// MARK: - 媒体元数据

public enum CodecKind: UInt8, BinaryCodable, Sendable, CaseIterable {
    case h264 = 0
    case hevc = 1
    case rawBGRA = 2
    /// 屏幕内容无损 RLE，用于合成/验证链路。
    /// 真实产品路径是 H.264/HEVC 硬件编解码（T4）；该 codec 使整条管线
    /// 在没有硬件编码器的环境下也能被真实执行与像素级断言。
    case screenRLE = 3

    public var localizedDescription: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .rawBGRA: return "未压缩 BGRA"
        case .screenRLE: return "屏幕内容 RLE（无损）"
        }
    }
}

public struct StreamInfo: BinaryCodable, Sendable {
    public var streamID: String
    public var windowUID: String
    public var layoutVersion: UInt64
    public var contentSizePx: Size
    public var contentScale: Double
    public var codec: CodecKind
    public var targetFPS: UInt8
    /// 静态内容降频标记（规格 §3 采集策略）。
    public var isStatic: Bool

    public init(streamID: String, windowUID: String, layoutVersion: UInt64, contentSizePx: Size,
                contentScale: Double, codec: CodecKind, targetFPS: UInt8, isStatic: Bool = false) {
        self.streamID = streamID
        self.windowUID = windowUID
        self.layoutVersion = layoutVersion
        self.contentSizePx = contentSizePx
        self.contentScale = contentScale
        self.codec = codec
        self.targetFPS = targetFPS
        self.isStatic = isStatic
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(streamID); writer.writeString(windowUID); writer.writeUInt(layoutVersion)
        contentSizePx.encode(to: &writer); writer.writeDouble(contentScale)
        writer.writeEnum(codec.rawValue); writer.writeUInt(UInt64(targetFPS)); writer.writeBool(isStatic)
    }
    public init(from reader: inout BinaryReader) throws {
        streamID = try reader.readString(); windowUID = try reader.readString()
        layoutVersion = try reader.readUInt(); contentSizePx = try Size(from: &reader)
        contentScale = try reader.readDouble(); codec = try reader.readEnum(CodecKind.self)
        targetFPS = UInt8(try reader.readUInt()); isStatic = try reader.readBool()
    }
}

public enum KeyframeReason: UInt8, BinaryCodable, Sendable, CaseIterable {
    case connect = 0
    case decodeError = 1
    case resume = 2
    case manual = 3
}

public struct KeyframeRequest: BinaryCodable, Sendable {
    public var streamID: String
    public var reason: KeyframeReason
    public init(streamID: String, reason: KeyframeReason) { self.streamID = streamID; self.reason = reason }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(streamID); writer.writeEnum(reason.rawValue)
    }
    public init(from reader: inout BinaryReader) throws {
        streamID = try reader.readString(); reason = try reader.readEnum(KeyframeReason.self)
    }
}

/// 降级顺序遵循 P10：先降帧率 → 再适度降画质 → 最后才降分辨率。
public enum QualityBias: UInt8, BinaryCodable, Sendable, CaseIterable {
    case text = 0
    case motion = 1
}

public enum ResolutionScale: UInt8, BinaryCodable, Sendable, CaseIterable {
    case full = 0, half = 1, quarter = 2

    public var divisor: Double {
        switch self { case .full: return 1; case .half: return 2; case .quarter: return 4 }
    }
}

public struct StreamAdjustRequest: BinaryCodable, Sendable {
    public var streamID: String
    public var fpsMax: UInt8?
    public var scale: ResolutionScale?
    public var qualityBias: QualityBias?

    public init(streamID: String, fpsMax: UInt8? = nil, scale: ResolutionScale? = nil, qualityBias: QualityBias? = nil) {
        self.streamID = streamID; self.fpsMax = fpsMax; self.scale = scale; self.qualityBias = qualityBias
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(streamID)
        writer.writeBool(fpsMax != nil); if let fpsMax { writer.writeUInt(UInt64(fpsMax)) }
        writer.writeBool(scale != nil); if let scale { writer.writeEnum(scale.rawValue) }
        writer.writeBool(qualityBias != nil); if let q = qualityBias { writer.writeEnum(q.rawValue) }
    }
    public init(from reader: inout BinaryReader) throws {
        streamID = try reader.readString()
        if try reader.readBool() { fpsMax = UInt8(try reader.readUInt()) } else { fpsMax = nil }
        if try reader.readBool() { scale = try reader.readEnum(ResolutionScale.self) } else { scale = nil }
        if try reader.readBool() { qualityBias = try reader.readEnum(QualityBias.self) } else { qualityBias = nil }
    }
}

public enum StreamRunState: UInt8, BinaryCodable, Sendable {
    case live = 0
    case pausedAppHidden = 1
    case windowMinimized = 2
    case closed = 3

    public var localizedDescription: String {
        switch self {
        case .live: return "运行中"
        case .pausedAppHidden: return "应用已隐藏，画面暂停"
        case .windowMinimized: return "窗口已最小化，画面暂停"
        case .closed: return "窗口已关闭"
        }
    }
}

public struct StreamState: BinaryCodable, Sendable {
    public var streamID: String
    public var state: StreamRunState
    public init(streamID: String, state: StreamRunState) { self.streamID = streamID; self.state = state }

    public func encode(to writer: inout BinaryWriter) { writer.writeString(streamID); writer.writeEnum(state.rawValue) }
    public init(from reader: inout BinaryReader) throws {
        streamID = try reader.readString(); state = try reader.readEnum(StreamRunState.self)
    }
}

// MARK: - 文本上下文

public enum TextNodeRole: UInt8, BinaryCodable, Sendable, CaseIterable {
    case textField = 0
    case textArea = 1
    case contentEditable = 2
    case unknown = 3

    public var localizedDescription: String {
        switch self {
        case .textField: return "单行输入框"
        case .textArea: return "多行文本框"
        case .contentEditable: return "网页可编辑区"
        case .unknown: return "未识别的输入控件"
        }
    }
}

public struct CaretInfo: BinaryCodable, Equatable, Sendable {
    /// 规格 §4.3：false 时必须走显式降级链路，不得伪装为正常路径。
    public var valid: Bool
    public var rectInWindow: Rect
    public var lineHeight: Double

    public init(valid: Bool, rectInWindow: Rect = .zero, lineHeight: Double = 0) {
        self.valid = valid; self.rectInWindow = rectInWindow; self.lineHeight = lineHeight
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeBool(valid); rectInWindow.encode(to: &writer); writer.writeDouble(lineHeight)
    }
    public init(from reader: inout BinaryReader) throws {
        valid = try reader.readBool()
        rectInWindow = try Rect(from: &reader)
        lineHeight = try reader.readDouble()
    }
}

public struct SelectionInfo: BinaryCodable, Equatable, Sendable {
    public var valid: Bool
    public var location: Int
    public var length: Int

    public init(valid: Bool, location: Int = 0, length: Int = 0) {
        self.valid = valid; self.location = location; self.length = length
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeBool(valid); writer.writeInt(Int64(location)); writer.writeInt(Int64(length))
    }
    public init(from reader: inout BinaryReader) throws {
        valid = try reader.readBool()
        location = Int(try reader.readInt())
        length = Int(try reader.readInt())
    }
}

public struct TextContext: BinaryCodable, Sendable {
    public var epoch: UInt64
    public var editVersion: UInt64
    public var windowUID: String
    public var nodeID: String
    public var role: TextNodeRole
    public var editable: Bool
    /// 实测结论，不是猜测（规格 §5 表）。
    public var acceptsUnicodeEvents: Bool
    public var caret: CaretInfo
    public var selection: SelectionInfo
    /// 远端是否已有组合文本（一般应为空；用于异常检测）。
    public var remoteMarkedPresent: Bool
    public var remoteMarkedLength: Int
    public var contextBefore: String
    public var contextAfter: String
    public var contextTruncated: Bool

    public init(epoch: UInt64, editVersion: UInt64, windowUID: String, nodeID: String,
                role: TextNodeRole, editable: Bool, acceptsUnicodeEvents: Bool,
                caret: CaretInfo, selection: SelectionInfo,
                remoteMarkedPresent: Bool = false, remoteMarkedLength: Int = 0,
                contextBefore: String = "", contextAfter: String = "", contextTruncated: Bool = false) {
        self.epoch = epoch; self.editVersion = editVersion
        self.windowUID = windowUID; self.nodeID = nodeID
        self.role = role; self.editable = editable; self.acceptsUnicodeEvents = acceptsUnicodeEvents
        self.caret = caret; self.selection = selection
        self.remoteMarkedPresent = remoteMarkedPresent; self.remoteMarkedLength = remoteMarkedLength
        self.contextBefore = contextBefore; self.contextAfter = contextAfter
        self.contextTruncated = contextTruncated
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch); writer.writeUInt(editVersion)
        writer.writeString(windowUID); writer.writeString(nodeID)
        writer.writeEnum(role.rawValue); writer.writeBool(editable); writer.writeBool(acceptsUnicodeEvents)
        writer.writeBool(caret.valid); caret.rectInWindow.encode(to: &writer); writer.writeDouble(caret.lineHeight)
        writer.writeBool(selection.valid); writer.writeInt(Int64(selection.location)); writer.writeInt(Int64(selection.length))
        writer.writeBool(remoteMarkedPresent); writer.writeInt(Int64(remoteMarkedLength))
        writer.writeString(contextBefore); writer.writeString(contextAfter); writer.writeBool(contextTruncated)
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt(); editVersion = try reader.readUInt()
        windowUID = try reader.readString(); nodeID = try reader.readString()
        role = try reader.readEnum(TextNodeRole.self)
        editable = try reader.readBool(); acceptsUnicodeEvents = try reader.readBool()
        let caretValid = try reader.readBool()
        let caretRect = try Rect(from: &reader)
        let lineHeight = try reader.readDouble()
        caret = CaretInfo(valid: caretValid, rectInWindow: caretRect, lineHeight: lineHeight)
        let selValid = try reader.readBool()
        let loc = Int(try reader.readInt()); let len = Int(try reader.readInt())
        selection = SelectionInfo(valid: selValid, location: loc, length: len)
        remoteMarkedPresent = try reader.readBool()
        remoteMarkedLength = Int(try reader.readInt())
        contextBefore = try reader.readString(); contextAfter = try reader.readString()
        contextTruncated = try reader.readBool()
    }
}

public struct TextContextRequest: BinaryCodable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }

    public func encode(to writer: inout BinaryWriter) { writer.writeString(reason) }
    public init(from reader: inout BinaryReader) throws { reason = try reader.readString() }
}

public enum ContextInvalidationReason: UInt8, BinaryCodable, Sendable {
    case focusMoved = 0
    case windowClosed = 1
    case nodeGone = 2
    case appRestarted = 3

    public var localizedDescription: String {
        switch self {
        case .focusMoved: return "焦点已转移到其他控件"
        case .windowClosed: return "窗口已关闭"
        case .nodeGone: return "输入控件已不存在"
        case .appRestarted: return "远端应用已重启"
        }
    }
}

public struct TextContextInvalidated: BinaryCodable, Sendable {
    public var epoch: UInt64
    public var reason: ContextInvalidationReason
    public init(epoch: UInt64, reason: ContextInvalidationReason) { self.epoch = epoch; self.reason = reason }

    public func encode(to writer: inout BinaryWriter) { writer.writeUInt(epoch); writer.writeEnum(reason.rawValue) }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt(); reason = try reader.readEnum(ContextInvalidationReason.self)
    }
}

public enum TextIntent: UInt8, BinaryCodable, Sendable, CaseIterable {
    case insertText = 0
    case replaceSelection = 1
    case deleteBackward = 2
    case deleteForward = 3
    case newline = 4

    public var localizedDescription: String {
        switch self {
        case .insertText: return "插入文字"
        case .replaceSelection: return "替换选区"
        case .deleteBackward: return "向后删除"
        case .deleteForward: return "向前删除"
        case .newline: return "换行"
        }
    }
}

public struct TextCommit: BinaryCodable, Equatable, Sendable {
    public var epoch: UInt64
    public var windowUID: String
    public var nodeID: String
    /// 本地发起时的上下文版本；远端不匹配则拒绝执行（规格 §3.1）。
    public var editVersion: UInt64
    /// 本地单调递增，用于去重。
    public var commitSeq: UInt32
    public var text: String
    /// 该次提交是否替换本地组合文本。
    public var fromLocalMarked: Bool
    public var replaceRange: SelectionInfo?
    public var intent: TextIntent

    public init(epoch: UInt64, windowUID: String, nodeID: String, editVersion: UInt64, commitSeq: UInt32,
                text: String, fromLocalMarked: Bool = true, replaceRange: SelectionInfo? = nil,
                intent: TextIntent = .insertText) {
        self.epoch = epoch; self.windowUID = windowUID; self.nodeID = nodeID
        self.editVersion = editVersion; self.commitSeq = commitSeq
        self.text = text; self.fromLocalMarked = fromLocalMarked
        self.replaceRange = replaceRange; self.intent = intent
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch); writer.writeString(windowUID); writer.writeString(nodeID)
        writer.writeUInt(editVersion); writer.writeUInt(UInt64(commitSeq))
        writer.writeString(text); writer.writeBool(fromLocalMarked)
        writer.writeBool(replaceRange != nil)
        if let r = replaceRange { writer.writeBool(r.valid); writer.writeInt(Int64(r.location)); writer.writeInt(Int64(r.length)) }
        writer.writeEnum(intent.rawValue)
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt(); windowUID = try reader.readString(); nodeID = try reader.readString()
        editVersion = try reader.readUInt(); commitSeq = UInt32(try reader.readUInt())
        text = try reader.readString(); fromLocalMarked = try reader.readBool()
        if try reader.readBool() {
            let v = try reader.readBool(); let l = Int(try reader.readInt()); let n = Int(try reader.readInt())
            replaceRange = SelectionInfo(valid: v, location: l, length: n)
        } else { replaceRange = nil }
        intent = try reader.readEnum(TextIntent.self)
    }
}

public enum TextCommitStatus: UInt8, BinaryCodable, Sendable, CaseIterable {
    case applied = 0
    case appliedPartial = 1
    /// 已执行，但**目标控件不提供可读内容**，因此无法校验是否真的生效。
    ///
    /// 这个状态不是"可能失败"，而是"无法确认"。它必须与 `rejectedUnsupported`
    /// 区分开：Chromium（Electron）的 contenteditable 正是这种情况——
    /// `AXSelectedTextAttribute` 写入会被忽略，而 CGEvent Unicode 注入**确实生效**，
    /// 但控件不暴露 `AXValue`，程序无法读回校验。
    /// 把它误判成"不支持"会让用户以为输入失败；误判成"已生效"则是谎报。
    case appliedUnverified = 6
    case rejectedStale = 2
    case rejectedUnsupported = 3
    case rejectedNoFocus = 4
    /// 超时/连接中断，**执行结果不明** —— 禁止自动重试（规格 §3.2）。
    case unknown = 5

    public var isApplied: Bool {
        self == .applied || self == .appliedPartial || self == .appliedUnverified
    }
    /// 是否需要在界面上说明"未能校验"
    public var needsVerificationNotice: Bool { self == .appliedUnverified }
    public var isRejected: Bool {
        switch self { case .rejectedStale, .rejectedUnsupported, .rejectedNoFocus: return true; default: return false }
    }
    public var isIndeterminate: Bool { self == .unknown }

    public var localizedDescription: String {
        switch self {
        case .applied: return "已提交"
        case .appliedPartial: return "部分提交"
        case .appliedUnverified: return "已执行（该控件不支持校验，未能确认结果）"
        case .rejectedStale: return "远端编辑状态已变化，本次未执行"
        case .rejectedUnsupported: return "该输入控件不接受此提交方式"
        case .rejectedNoFocus: return "目标输入框未聚焦"
        case .unknown: return "上一条输入结果未确认"
        }
    }
}

public struct TextCommitResult: BinaryCodable, Sendable {
    public var commitSeq: UInt32
    public var status: TextCommitStatus
    public var newEditVersion: UInt64?
    public var appliedRange: SelectionInfo?
    public var detail: String?

    public init(commitSeq: UInt32, status: TextCommitStatus, newEditVersion: UInt64? = nil,
                appliedRange: SelectionInfo? = nil, detail: String? = nil) {
        self.commitSeq = commitSeq; self.status = status
        self.newEditVersion = newEditVersion; self.appliedRange = appliedRange; self.detail = detail
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(UInt64(commitSeq)); writer.writeEnum(status.rawValue)
        writer.writeBool(newEditVersion != nil); if let v = newEditVersion { writer.writeUInt(v) }
        writer.writeBool(appliedRange != nil)
        if let r = appliedRange { writer.writeBool(r.valid); writer.writeInt(Int64(r.location)); writer.writeInt(Int64(r.length)) }
        writer.writeOptionalString(detail)
    }
    public init(from reader: inout BinaryReader) throws {
        commitSeq = UInt32(try reader.readUInt()); status = try reader.readEnum(TextCommitStatus.self)
        if try reader.readBool() { newEditVersion = try reader.readUInt() } else { newEditVersion = nil }
        if try reader.readBool() {
            let v = try reader.readBool(); let l = Int(try reader.readInt()); let n = Int(try reader.readInt())
            appliedRange = SelectionInfo(valid: v, location: l, length: n)
        } else { appliedRange = nil }
        detail = try reader.readOptionalString()
    }
}

// MARK: - 输入

public enum KeyKind: UInt8, BinaryCodable, Sendable, CaseIterable {
    case keyDown = 0
    case keyUp = 1
    case flagsChanged = 2
}

/// 按键语义分类。组合期间的键必须先给本地输入法（规格 §2.1 B2）。
public enum KeyCategory: UInt8, BinaryCodable, Sendable, CaseIterable {
    case shortcut = 0
    case navigation = 1
    case editing = 2
    case rawKey = 3

    public var localizedDescription: String {
        switch self {
        case .shortcut: return "快捷键"
        case .navigation: return "导航键"
        case .editing: return "编辑键"
        case .rawKey: return "普通按键"
        }
    }
}

public struct KeyEvent: BinaryCodable, Equatable, Sendable {
    public var epoch: UInt64
    public var windowUID: String
    public var kind: KeyKind
    public var keycode: UInt16
    public var flags: UInt32
    /// 仅当本地输入法已确认文字时使用；拼音按键绝不走此字段（规格 §3.3）。
    public var unicode: String?
    public var category: KeyCategory

    public init(epoch: UInt64, windowUID: String, kind: KeyKind, keycode: UInt16, flags: UInt32,
                unicode: String? = nil, category: KeyCategory = .rawKey) {
        self.epoch = epoch; self.windowUID = windowUID; self.kind = kind
        self.keycode = keycode; self.flags = flags; self.unicode = unicode; self.category = category
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch); writer.writeString(windowUID); writer.writeEnum(kind.rawValue)
        writer.writeUInt(UInt64(keycode)); writer.writeUInt(UInt64(flags))
        writer.writeOptionalString(unicode); writer.writeEnum(category.rawValue)
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt(); windowUID = try reader.readString()
        kind = try reader.readEnum(KeyKind.self)
        keycode = UInt16(try reader.readUInt()); flags = UInt32(try reader.readUInt())
        unicode = try reader.readOptionalString(); category = try reader.readEnum(KeyCategory.self)
    }
}

public enum PointerKind: UInt8, BinaryCodable, Sendable, CaseIterable {
    case move = 0
    case down = 1
    case up = 2
    case drag = 3
    case scroll = 4
    /// 合并后的移动（只保留最新位置 + 采样数）。
    case moveCoalesced = 5
}

public enum PointerButton: UInt8, BinaryCodable, Sendable, CaseIterable {
    case none = 0, left = 1, right = 2, middle = 3
}

public struct PointerEvent: BinaryCodable, Equatable, Sendable {
    public var epoch: UInt64
    public var windowUID: String
    public var kind: PointerKind
    public var positionInWindow: Point
    public var button: PointerButton
    public var scrollDX: Double
    public var scrollDY: Double
    public var scrollPrecise: Bool
    public var coalescedSampleCount: UInt32

    public init(epoch: UInt64, windowUID: String, kind: PointerKind, positionInWindow: Point,
                button: PointerButton = .none, scrollDX: Double = 0, scrollDY: Double = 0,
                scrollPrecise: Bool = true, coalescedSampleCount: UInt32 = 1) {
        self.epoch = epoch; self.windowUID = windowUID; self.kind = kind
        self.positionInWindow = positionInWindow; self.button = button
        self.scrollDX = scrollDX; self.scrollDY = scrollDY
        self.scrollPrecise = scrollPrecise; self.coalescedSampleCount = coalescedSampleCount
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeUInt(epoch); writer.writeString(windowUID); writer.writeEnum(kind.rawValue)
        positionInWindow.encode(to: &writer); writer.writeEnum(button.rawValue)
        writer.writeDouble(scrollDX); writer.writeDouble(scrollDY); writer.writeBool(scrollPrecise)
        writer.writeUInt(UInt64(coalescedSampleCount))
    }
    public init(from reader: inout BinaryReader) throws {
        epoch = try reader.readUInt(); windowUID = try reader.readString()
        kind = try reader.readEnum(PointerKind.self)
        positionInWindow = try Point(from: &reader); button = try reader.readEnum(PointerButton.self)
        scrollDX = try reader.readDouble(); scrollDY = try reader.readDouble()
        scrollPrecise = try reader.readBool()
        coalescedSampleCount = UInt32(try reader.readUInt())
    }
}

// MARK: - 文件与剪贴板

public enum ClipboardKind: UInt8, BinaryCodable, Sendable, CaseIterable {
    case text = 0, image = 1, cleared = 2
}

public enum ClipboardOrigin: UInt8, BinaryCodable, Sendable, CaseIterable {
    case viewer = 0, host = 1
}

public struct ClipboardUpdate: BinaryCodable, Sendable {
    public var kind: ClipboardKind
    public var text: String?
    public var blobRef: String?
    public var hash: String
    public var origin: ClipboardOrigin

    public init(kind: ClipboardKind, text: String? = nil, blobRef: String? = nil, hash: String,
                origin: ClipboardOrigin) {
        self.kind = kind; self.text = text; self.blobRef = blobRef; self.hash = hash; self.origin = origin
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeEnum(kind.rawValue); writer.writeOptionalString(text); writer.writeOptionalString(blobRef)
        writer.writeString(hash); writer.writeEnum(origin.rawValue)
    }
    public init(from reader: inout BinaryReader) throws {
        kind = try reader.readEnum(ClipboardKind.self)
        text = try reader.readOptionalString(); blobRef = try reader.readOptionalString()
        hash = try reader.readString(); origin = try reader.readEnum(ClipboardOrigin.self)
    }
}

public struct FileOffer: BinaryCodable, Sendable {
    public var transferID: String
    public var name: String
    public var size: UInt64
    public var mime: String
    public var sha256: String

    public init(transferID: String, name: String, size: UInt64, mime: String, sha256: String) {
        self.transferID = transferID; self.name = name; self.size = size; self.mime = mime; self.sha256 = sha256
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(transferID); writer.writeString(name); writer.writeUInt(size)
        writer.writeString(mime); writer.writeString(sha256)
    }
    public init(from reader: inout BinaryReader) throws {
        transferID = try reader.readString(); name = try reader.readString()
        size = try reader.readUInt(); mime = try reader.readString(); sha256 = try reader.readString()
    }
}

public struct FileChunk: BinaryCodable, Sendable {
    public var transferID: String
    public var index: UInt32
    public var bytes: Data

    public init(transferID: String, index: UInt32, bytes: Data) {
        self.transferID = transferID; self.index = index; self.bytes = bytes
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(transferID); writer.writeUInt(UInt64(index)); writer.writeBytes(bytes)
    }
    public init(from reader: inout BinaryReader) throws {
        transferID = try reader.readString(); index = UInt32(try reader.readUInt()); bytes = try reader.readBytes()
    }
}

public struct FileComplete: BinaryCodable, Sendable {
    public var transferID: String
    public var remotePath: String
    public init(transferID: String, remotePath: String) { self.transferID = transferID; self.remotePath = remotePath }

    public func encode(to writer: inout BinaryWriter) { writer.writeString(transferID); writer.writeString(remotePath) }
    public init(from reader: inout BinaryReader) throws {
        transferID = try reader.readString(); remotePath = try reader.readString()
    }
}

public enum FileAbortReason: UInt8, BinaryCodable, Sendable, CaseIterable {
    case userCancelled = 0
    case checksumMismatch = 1
    case diskFull = 2
    case peerAborted = 3
    case timeout = 4

    public var localizedDescription: String {
        switch self {
        case .userCancelled: return "已取消"
        case .checksumMismatch: return "校验失败"
        case .diskFull: return "远端磁盘空间不足"
        case .peerAborted: return "对端中止"
        case .timeout: return "传输超时"
        }
    }
}

public struct FileAbort: BinaryCodable, Sendable {
    public var transferID: String
    public var reason: FileAbortReason
    public init(transferID: String, reason: FileAbortReason) { self.transferID = transferID; self.reason = reason }

    public func encode(to writer: inout BinaryWriter) { writer.writeString(transferID); writer.writeEnum(reason.rawValue) }
    public init(from reader: inout BinaryReader) throws {
        transferID = try reader.readString(); reason = try reader.readEnum(FileAbortReason.self)
    }
}

public struct FileProgress: BinaryCodable, Sendable {
    public var transferID: String
    public var received: UInt64
    public var total: UInt64
    public init(transferID: String, received: UInt64, total: UInt64) {
        self.transferID = transferID; self.received = received; self.total = total
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeString(transferID); writer.writeUInt(received); writer.writeUInt(total)
    }
    public init(from reader: inout BinaryReader) throws {
        transferID = try reader.readString(); received = try reader.readUInt(); total = try reader.readUInt()
    }
}

// MARK: - 会话状态与错误

public enum SessionPhase: UInt8, BinaryCodable, Sendable, CaseIterable {
    case disconnected = 0
    case negotiating = 1
    case active = 2
    case degraded = 3
    case reconnecting = 4
    case suspended = 5
    case revoked = 6
    case error = 7

    public var localizedDescription: String {
        switch self {
        case .disconnected: return "未连接"
        case .negotiating: return "正在协商"
        case .active: return "已连接"
        case .degraded: return "已连接（部分能力降级）"
        case .reconnecting: return "正在重连"
        case .suspended: return "已挂起（远端应用仍在运行）"
        case .revoked: return "控制已被撤销"
        case .error: return "连接错误"
        }
    }
}

public struct SessionStateMsg: BinaryCodable, Sendable {
    public var phase: SessionPhase
    public var detail: String?
    public init(phase: SessionPhase, detail: String? = nil) { self.phase = phase; self.detail = detail }

    public func encode(to writer: inout BinaryWriter) { writer.writeEnum(phase.rawValue); writer.writeOptionalString(detail) }
    public init(from reader: inout BinaryReader) throws {
        phase = try reader.readEnum(SessionPhase.self); detail = try reader.readOptionalString()
    }
}

public enum RevokeReason: UInt8, BinaryCodable, Sendable, CaseIterable {
    case userLocal = 0
    case userRemote = 1
    case policy = 2

    public var localizedDescription: String {
        switch self {
        case .userLocal: return "本地用户手动撤销了控制"
        case .userRemote: return "远端用户撤销了控制"
        case .policy: return "策略撤销"
        }
    }
}

public struct RevokeControl: BinaryCodable, Sendable {
    public var reason: RevokeReason
    public init(reason: RevokeReason) { self.reason = reason }
    public func encode(to writer: inout BinaryWriter) { writer.writeEnum(reason.rawValue) }
    public init(from reader: inout BinaryReader) throws { reason = try reader.readEnum(RevokeReason.self) }
}

public enum ErrorScope: UInt8, BinaryCodable, Sendable, CaseIterable {
    case media = 0, text = 1, window = 2, file = 3, auth = 4, permission = 5

    public var localizedDescription: String {
        switch self {
        case .media: return "媒体"
        case .text: return "文本输入"
        case .window: return "窗口"
        case .file: return "文件"
        case .auth: return "认证"
        case .permission: return "权限"
        }
    }
}

public struct ErrorReport: BinaryCodable, Sendable {
    public var scope: ErrorScope
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(scope: ErrorScope, code: String, message: String, retryable: Bool) {
        self.scope = scope; self.code = code; self.message = message; self.retryable = retryable
    }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeEnum(scope.rawValue); writer.writeString(code)
        writer.writeString(message); writer.writeBool(retryable)
    }
    public init(from reader: inout BinaryReader) throws {
        scope = try reader.readEnum(ErrorScope.self); code = try reader.readString()
        message = try reader.readString(); retryable = try reader.readBool()
    }
}

// MARK: - 信封

/// 所有控制/状态/输入/文件消息的统一信封。
///
/// 承载规格 §0 要求的 `msg_id` / `epoch` / `seq` 三元组：
/// - `epoch`：会话代次，用于识别过期消息
/// - `seq`：通道内递增，用于检测丢失与乱序
/// - `msgID`：用于接收方去重（幂等）
public struct Envelope: Sendable {
    public var type: MessageType
    public var epoch: UInt64
    public var seq: UInt64
    public var msgID: UInt64
    public var payload: Data

    public init(type: MessageType, epoch: UInt64, seq: UInt64, msgID: UInt64, payload: Data) {
        self.type = type; self.epoch = epoch; self.seq = seq; self.msgID = msgID; self.payload = payload
    }

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeEnum(type.rawValue)
        w.writeUInt(epoch)
        w.writeUInt(seq)
        w.writeUInt(msgID)
        w.writeBytes(payload)
        return w.data
    }

    public static func decode(_ data: Data) throws -> Envelope {
        var r = BinaryReader(data)
        let type = try r.readEnum(MessageType.self)
        let epoch = try r.readUInt()
        let seq = try r.readUInt()
        let msgID = try r.readUInt()
        let payload = try r.readBytes()
        return Envelope(type: type, epoch: epoch, seq: seq, msgID: msgID, payload: payload)
    }
}
