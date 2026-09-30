import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// MARK: - 真实窗口采集路径（仅需屏幕录制权限）
//
// 辅助功能权限缺失时会失去 AX 能力（改尺寸、读控件、注入输入），但**屏幕录制权限
// 足以枚举与采集窗口**。把这条路径单独实现出来，可以让"真实像素"这一段被真机验证，
// 而不是因为拿不到辅助功能权限就整体退回到合成链路。

/// 基于 ScreenCaptureKit 的窗口枚举。
///
/// 与 `AXWindowProvider` 的分工：
/// - 本类只做"有哪些窗口、多大、标题是什么"，以及提供可采集的 `SCWindow` 引用
/// - 改尺寸 / 激活 / 最小化仍需要 AX；缺失时如实报告受约束，而不是假装成功
public final class SCKWindowProvider: WindowProvider {
    public let targetPID: pid_t
    public let bundleID: String
    public let appDisplayName: String
    public let appLaunchID: String

    private var cachedWindows: [SCWindow] = []
    private var cachedInfos: [WindowInfo] = []
    private let lock = NSLock()

    public private(set) var lastEnumerationError: String?
    public private(set) var enumerationCount = 0

    public init(targetPID: pid_t, bundleID: String, displayName: String) {
        self.targetPID = targetPID
        self.bundleID = bundleID
        self.appDisplayName = displayName
        self.appLaunchID = "sck-\(targetPID)-\(bundleID)"
    }

    public var appBundleID: String { bundleID }

    /// 屏幕录制权限是否具备（这是本提供者的唯一前提）。
    public var available: Bool { CGPreflightScreenCaptureAccess() }

    public var unavailableReason: String? {
        available ? nil : "缺少屏幕录制权限，无法枚举与采集窗口"
    }

    /// 同步刷新窗口列表。SCK 的枚举接口是 async，这里做一次同步桥接。
    @discardableResult
    public func refresh(timeout: TimeInterval = 3.0) -> Bool {
        guard available else {
            lastEnumerationError = unavailableReason
            return false
        }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<[SCWindow], Error>?
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                  onScreenWindowsOnly: true)
                let mine = content.windows.filter { $0.owningApplication?.processID == self.targetPID }
                result = .success(mine)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else {
            lastEnumerationError = "SCShareableContent 枚举超时"
            return false
        }
        switch result {
        case .success(let windows):
            lock.lock()
            cachedWindows = windows.sorted { ($0.windowID) < ($1.windowID) }
            cachedInfos = windows.enumerated().map { idx, w in
                Self.info(from: w, index: idx, provider: self)
            }
            lock.unlock()
            enumerationCount += 1
            lastEnumerationError = nil
            return true
        case .failure(let error):
            lastEnumerationError = error.localizedDescription
            return false
        case .none:
            lastEnumerationError = "枚举未返回结果"
            return false
        }
    }

    private static func info(from w: SCWindow, index: Int, provider: SCKWindowProvider) -> WindowInfo {
        let frame = w.frame
        // SCK 的 frame 与 AX 的 AXSize 语义一致（都是窗口框），尺寸语义见 AXWindowProvider
        let content = Size(max(1, frame.width), max(1, frame.height))
        return WindowInfo(
            windowUID: "sck:\(provider.targetPID):\(w.windowID)",
            appPID: provider.targetPID,
            appLaunchID: provider.appLaunchID,
            bundleID: provider.bundleID,
            title: (w.title?.isEmpty == false ? w.title! : provider.appDisplayName),
            role: role(for: w),
            parentUID: nil,
            modal: false,
            contentRect: Rect(origin: Point(frame.origin.x, frame.origin.y), size: content),
            contentScale: Double(NSScreen.main?.backingScaleFactor ?? 2.0),
            constraints: SizeConstraints(resizable: AXIsProcessTrusted() ? .both : .none),
            minimized: false,
            focusable: true,
            zOrder: Int32(index))
    }

    /// SCWindow 不直接给出 role；用窗口层级推断，未知的一律标为 unknown（会被本地建壳并标注，
    /// 但**不会**退化为共享整个桌面）。
    private static func role(for w: SCWindow) -> WindowRole {
        switch w.windowLayer {
        case 0: return .main
        case 1...25: return w.title?.isEmpty == false ? .panel : .popupMenu
        default: return .unknown
        }
    }

    // MARK: WindowProvider

    /// 返回窗口列表。
    ///
    /// 枚举失败时**沿用上次成功的结果**：瞬时的 SCK 枚举超时如果表现为"窗口全部消失"，
    /// 上层会据此关闭本地窗口壳并停止接收输入，把一次瞬时故障放大成用户可见的窗口丢失。
    public func currentWindows() -> [WindowInfo] {
        let ok = refresh()
        lock.lock(); defer { lock.unlock() }
        if !ok && !cachedInfos.isEmpty {
            consecutiveEnumerationFailures += 1
            return cachedInfos
        }
        if ok { consecutiveEnumerationFailures = 0 }
        return cachedInfos
    }

    /// 连续枚举失败次数。仅用于诊断与提示，不用于判定窗口消失。
    public private(set) var consecutiveEnumerationFailures = 0

    /// 按 (标题, 尺寸) 匹配一个 SCWindow。
    ///
    /// 用几何与标题匹配而不是用 SCK 自己的 windowID：AX 侧拿不到 SCK 的 windowID，
    /// 而两侧都拿得到标题与尺寸。尺寸容差考虑到标题栏估算带来的偏差。
    public func matchWindow(title: String, size: Size) -> SCWindow? {
        lock.lock(); let windows = cachedWindows; lock.unlock()
        guard !windows.isEmpty else { return nil }
        var best: (SCWindow, Double)?
        for w in windows {
            // SCK 的 frame 与 AX 的 AXSize 都是窗口框，可直接比较
            let frame = w.frame
            let dw = abs(frame.width - size.width)
            let dh = abs(frame.height - size.height)
            let distance = dw + dh
            let titleMatches = (w.title ?? "").isEmpty || title.isEmpty || w.title == title
            let penalty: Double = titleMatches ? 0 : 200
            let total = distance + penalty
            if best == nil || total < best!.1 { best = (w, total) }
        }
        // 容差：标题与尺寸都不能差太远，否则宁可失败也不要采错窗口
        guard let (window, score) = best, score < 160 else { return nil }
        return window
    }

    /// 采集用的 SCWindow（HostRuntime 在建立流时取用）。
    public func captureWindow(for uid: String) -> SCWindow? {
        refresh()
        lock.lock(); defer { lock.unlock() }
        let wid = uid.split(separator: ":").last.flatMap { UInt32($0) }
        guard let wid else { return cachedWindows.first }
        return cachedWindows.first { $0.windowID == wid }
    }

    /// 改尺寸需要辅助功能权限。没有权限时必须如实报告"受约束"，不能假装成功。
    public func applySize(_ uid: String, requested: Size) -> (actual: Size, constrainedBy: SizeConstraint) {
        guard AXIsProcessTrusted() else {
            let current = currentWindows().first { $0.windowUID == uid }?.contentSize ?? requested
            return (current, .system)
        }
        let ax = AXWindowProvider(targetPID: targetPID, bundleID: bundleID, displayName: appDisplayName)
        return ax.applySize(uid, requested: requested)
    }

    public func perform(_ action: WindowActionKind, on uid: String) -> Bool {
        // 没有辅助功能权限时无法操作系统窗口，如实返回失败
        guard AXIsProcessTrusted() else { return false }
        let ax = AXWindowProvider(targetPID: targetPID, bundleID: bundleID, displayName: appDisplayName)
        return ax.perform(action, on: uid)
    }

    public func activate(_ uid: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return NSRunningApplication(processIdentifier: targetPID)?
            .activate(options: []) ?? false
    }

    /// 目标应用是否仍在运行。
    public var isTargetAlive: Bool {
        NSRunningApplication(processIdentifier: targetPID) != nil
    }
}

// MARK: - 真实采集源工厂

public enum RealCaptureFactory {
    public struct Result {
        public var source: CaptureSource?
        public var reason: String?
        public var windowFound: Bool
    }

    /// 为目标窗口建立真实采集源。
    ///
    /// 失败时必须给出可读原因（权限、窗口不存在、SCK 错误），由上层决定是降级到合成源
    /// 还是把该窗口标为不可用——不静默降级。
    public static func makeSource(provider: SCKWindowProvider,
                                  uid: String,
                                  streamID: String) -> Result {
        guard provider.available else {
            return Result(source: nil, reason: provider.unavailableReason, windowFound: false)
        }
        guard let window = provider.captureWindow(for: uid) else {
            return Result(source: nil, reason: "未找到可采集的窗口（可能已关闭或不在屏幕上）",
                          windowFound: false)
        }
        let source = SCKWindowCaptureSource(streamID: streamID, window: window)
        guard source.isAvailable else {
            return Result(source: nil, reason: source.unavailableReason, windowFound: true)
        }
        return Result(source: source, reason: nil, windowFound: true)
    }
}

// MARK: - 真实模式下的窗口提供者（AX 枚举 + SCK 采集）

/// 真实模式的窗口提供者：**枚举与操作走 AX，采集走 SCK**。
///
/// 为什么必须统一：AX 给出的窗口身份用于注册表、尺寸请求与文本归属；
/// SCK 只负责"把这个窗口的画面采下来"。如果枚举用 SCK 而改尺寸用 AX，
/// 两套 UID 无法对应，尺寸请求会落到错误的窗口上（实测表现为改错窗口或改不动）。
/// 这里用 (PID, 标题, 尺寸) 把两侧对应起来。
public final class RealWindowProvider: WindowProvider {
    public let ax: AXWindowProvider
    public let sck: SCKWindowProvider

    public private(set) var matchFailures: [String] = []
    public private(set) var filteredDegenerateWindows = 0

    /// 由采集到的真实像素尺寸校正过的内容尺寸（窗口 UID → 尺寸）。
    ///
    /// 为什么需要它：CG 的窗口框含标题栏，标题栏高度只能估算（不同 macOS 版本、
    /// 不同窗口样式都不一样）。任何估算都会让"请求尺寸"与"读回尺寸"产生固定偏差，
    /// 而**采集到的像素尺寸是事实**——用 `像素 / contentScale` 即真实内容尺寸。
    /// 一旦拿到像素就以此为准，估算只在首帧之前使用。
    private var measuredContentSizes: [String: Size] = [:]

    public func setMeasuredContentSize(uid: String, size: Size) {
        measuredContentSizes[uid] = size
    }

    public func measuredContentSize(for uid: String) -> Size? { measuredContentSizes[uid] }

    /// 尺寸小于此阈值的窗口视为应用内部窗口（如 1 像素高的辅助窗口），
    /// 不建立本地窗口壳，也不参与采集——给它们建壳只会在本地显示一个空窗口。
    public static let minimumMeaningfulSize: Double = 20

    public init(ax: AXWindowProvider, sck: SCKWindowProvider) {
        self.ax = ax
        self.sck = sck
    }

    public var appBundleID: String { ax.appBundleID }
    public var appDisplayName: String { ax.appDisplayName }
    public var available: Bool { ax.available }

    public func currentWindows() -> [WindowInfo] {
        ax.currentWindows().compactMap { w in
            guard w.contentSize.width >= Self.minimumMeaningfulSize,
                  w.contentSize.height >= Self.minimumMeaningfulSize else {
                filteredDegenerateWindows += 1
                return nil
            }
            // 有实测像素就用实测值，否则用 CG 框减去估算的标题栏高度
            guard let measured = measuredContentSizes[w.windowUID] else { return w }
            var updated = w
            updated.contentRect = Rect(origin: w.contentRect.origin, size: measured)
            return updated
        }
    }

    public func applySize(_ uid: String, requested: Size) -> (actual: Size, constrainedBy: SizeConstraint) {
        let result = ax.applySize(uid, requested: requested)
        // 实测优先：AX 读回的窗口框尺寸含标题栏，与内容尺寸存在估算偏差；
        // 如果该窗口已经有实测像素尺寸，以实测为准，避免"请求 450 却读回 421"这类假偏差。
        if let measured = measuredContentSizes[uid] {
            let constrained = abs(measured.width - requested.width) > 2
                || abs(measured.height - requested.height) > 2
            return (measured, constrained ? result.constrainedBy == .none ? .appMin : result.constrainedBy
                                          : .none)
        }
        return result
    }

    public func perform(_ action: WindowActionKind, on uid: String) -> Bool {
        ax.perform(action, on: uid)
    }

    public func activate(_ uid: String) -> Bool {
        ax.activate(uid)
    }

    /// 为某个 AX 窗口建立采集源：用 (标题, 尺寸) 从 SCK 的枚举结果里找对应窗口。
    public func makeCaptureSource(for info: WindowInfo, streamID: String) -> CaptureSource? {
        guard ax.available, sck.available else { return nil }
        // 触发一次 SCK 枚举以刷新缓存
        _ = sck.refresh()
        let candidate = sck.matchWindow(title: info.title, size: info.contentSize)
        guard let window = candidate else {
            matchFailures.append("\(info.title) \(Int(info.contentSize.width))x\(Int(info.contentSize.height))")
            return nil
        }
        let source = SCKWindowCaptureSource(streamID: streamID, window: window)
        return source.isAvailable ? source : nil
    }
}
