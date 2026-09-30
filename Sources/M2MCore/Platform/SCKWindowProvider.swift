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
        // SCWindow 给出的是包含标题栏的窗口框；内容区按标题栏高度估算，
        // 真实内容尺寸会在采集到首帧后由像素尺寸校正（见 HostRuntime 的流信息回填）。
        let titleBar: Double = 28
        let content = Size(max(1, frame.width), max(1, frame.height - titleBar))
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
