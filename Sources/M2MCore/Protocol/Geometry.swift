import Foundation

/// 逻辑点（与坐标原点无关的尺寸/位置容器）。
public struct Point: BinaryCodable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Point(0, 0)

    public func encode(to writer: inout BinaryWriter) {
        writer.writeDouble(x); writer.writeDouble(y)
    }
    public init(from reader: inout BinaryReader) throws {
        x = try reader.readDouble(); y = try reader.readDouble()
    }
}

public struct Size: BinaryCodable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
    public static let zero = Size(0, 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func encode(to writer: inout BinaryWriter) {
        writer.writeDouble(width); writer.writeDouble(height)
    }
    public init(from reader: inout BinaryReader) throws {
        width = try reader.readDouble(); height = try reader.readDouble()
    }
}

public struct Rect: BinaryCodable, Equatable, Sendable {
    public var origin: Point
    public var size: Size
    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.origin = Point(x, y); self.size = Size(w, h)
    }
    public static let zero = Rect(0, 0, 0, 0)

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    public func encode(to writer: inout BinaryWriter) {
        origin.encode(to: &writer); size.encode(to: &writer)
    }
    public init(from reader: inout BinaryReader) throws {
        origin = try Point(from: &reader); size = try Size(from: &reader)
    }
}

/// `docs/05-media-performance.md` §5.1 的四个坐标系。
///
/// 这条映射链是候选窗定位与缩放正确性的基础，任一环使用错误的 scale 都会导致
/// 候选窗偏移或点偏位置。
public enum CoordinateSpace: String, Sendable, CaseIterable {
    /// 远端窗口的逻辑点（AX 报出的窗口内容区坐标）
    case remoteLogicalPoints
    /// 远端采集像素（= remoteLogicalPoints × contentScale）
    case remoteCapturePixels
    /// 本地窗口逻辑点（NSWindow contentRect）
    case localLogicalPoints
    /// 本地屏幕像素（= localLogicalPoints × localBackingScale）
    case localBackingPixels
}

/// 一次完整坐标系变换所需的全部比例因子。
///
/// 关键约束（T6 / 协议 §1.2 规则 4）：`layoutVersion` 必须与画面帧一致，
/// 否则调用方应丢弃该帧而不是显示错区域。
public struct GeometryMapping: Equatable, Sendable {
    public var layoutVersion: UInt64
    /// 远端逻辑点 → 采集像素
    public var remoteContentScale: Double
    /// 本地逻辑点 → 本地像素
    public var localBackingScale: Double

    public init(layoutVersion: UInt64, remoteContentScale: Double, localBackingScale: Double) {
        self.layoutVersion = layoutVersion
        self.remoteContentScale = max(0.01, remoteContentScale)
        self.localBackingScale = max(0.01, localBackingScale)
    }

    /// 远端窗口局部逻辑点 → 采集像素点
    public func remotePixels(fromRemoteLogical p: Point) -> Point {
        Point(p.x * remoteContentScale, p.y * remoteContentScale)
    }

    /// 远端窗口局部逻辑点 → 本地窗口内容视图逻辑点
    public func localLogical(fromRemoteLogical p: Point, localContentSize: Size, remoteContentSize: Size) -> Point {
        guard !remoteContentSize.isEmpty else { return Point(0, 0) }
        let sx = localContentSize.width / remoteContentSize.width
        let sy = localContentSize.height / remoteContentSize.height
        return Point(p.x * sx, p.y * sy)
    }

    /// 本地窗口内容视图逻辑点 → 远端窗口局部逻辑点（用于把点击位置发回远端）
    public func remoteLogical(fromLocalLogical p: Point, localContentSize: Size, remoteContentSize: Size) -> Point {
        guard !localContentSize.isEmpty else { return Point(0, 0) }
        let sx = remoteContentSize.width / localContentSize.width
        let sy = remoteContentSize.height / localContentSize.height
        return Point(p.x * sx, p.y * sy)
    }

    public func remoteLogical(fromLocalBackingPixels p: Point, localContentSize: Size, remoteContentSize: Size) -> Point {
        let logical = Point(p.x / localBackingScale, p.y / localBackingScale)
        return remoteLogical(fromLocalLogical: logical, localContentSize: localContentSize, remoteContentSize: remoteContentSize)
    }

    /// 采集像素尺寸（用于计算编码像素量与码率预算）。
    public func capturePixels(forRemoteContent size: Size) -> Size {
        Size(size.width * remoteContentScale, size.height * remoteContentScale)
    }
}

/// 尺寸变更被谁约束（协议 §1.1 `constrained_by`）。
public enum SizeConstraint: UInt8, BinaryCodable, Sendable, CaseIterable {
    case none = 0
    case appMin = 1
    case appMax = 2
    case screen = 3
    case system = 4

    public var localizedDescription: String {
        switch self {
        case .none: return "无约束"
        case .appMin: return "目标应用设置了最小尺寸"
        case .appMax: return "目标应用设置了最大尺寸"
        case .screen: return "超出远端屏幕可用区域"
        case .system: return "系统限制"
        }
    }
}

/// 远端尺寸约束模型。用于在本地提前钳制请求，减少来回抖动。
public struct SizeConstraints: Equatable, Sendable {
    public var minSize: Size?
    public var maxSize: Size?
    public var resizable: Resizable

    public enum Resizable: UInt8, BinaryCodable, Sendable {
        case none = 0, width = 1, height = 2, both = 3

        public var allowsWidth: Bool { self == .width || self == .both }
        public var allowsHeight: Bool { self == .height || self == .both }
    }

    public init(minSize: Size? = nil, maxSize: Size? = nil, resizable: Resizable = .both) {
        self.minSize = minSize
        self.maxSize = maxSize
        self.resizable = resizable
    }

    /// 把请求尺寸钳制到应用允许的范围，并报告被谁约束。
    ///
    /// 对应规格 §1.2 规则 2 与 §5.3：本地必须先接受约束再发请求，
    /// 避免"请求 → 拒绝 → 再请求"的抖动。
    public func clamp(_ requested: Size) -> (size: Size, constrainedBy: SizeConstraint) {
        var w = requested.width
        var h = requested.height
        var constraint: SizeConstraint = .none

        if resizable == .none {
            return (Size(0, 0), .appMax)
        }
        if !resizable.allowsWidth { w = 0 }
        if !resizable.allowsHeight { h = 0 }

        if let minSize {
            if resizable.allowsWidth, w < minSize.width { w = minSize.width; constraint = .appMin }
            if resizable.allowsHeight, h < minSize.height { h = minSize.height; constraint = .appMin }
        }
        if let maxSize {
            if resizable.allowsWidth, maxSize.width > 0, w > maxSize.width { w = maxSize.width; constraint = .appMax }
            if resizable.allowsHeight, maxSize.height > 0, h > maxSize.height { h = maxSize.height; constraint = .appMax }
        }
        return (Size(w, h), constraint)
    }
}
