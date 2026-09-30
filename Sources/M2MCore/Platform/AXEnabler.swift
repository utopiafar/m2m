import Foundation
import ApplicationServices

/// 让 Chromium 系（Electron）应用暴露辅助功能树。
///
/// **这是 Electron 目标能否使用本地输入法的前提。** Chromium 出于性能考虑，
/// 只在检测到辅助功能客户端时才构建无障碍树；在此之前 `kAXWindowsAttribute`
/// 可能是空的、焦点控件也读不到。实测（VS Code 1.139）表现为：
/// 窗口能枚举到（来自 CG），但 AX 侧"一个控件都没有"，
/// 于是插入点读取失败、文本写入无从下手，整体静默降级为"远端输入法"。
///
/// Chromium 为此提供了显式开关，外部客户端可以设置：
///   · `AXManualAccessibility` —— Electron 官方文档提到的第三方启用方式
///   · `AXEnhancedUserInterface` —— 更早期的辅助功能增强开关
/// 设置之后需要给应用一点时间构建树，因此采用"设置 → 轮询等待"的方式。
public enum AXAccessibilityEnabler {
    public struct Result: Sendable {
        /// 树在激活前就已经**可用**（不只是"有窗口"）
        public var wasAlreadyEnabled: Bool
        public var enabledByUs: Bool
        public var windowsVisibleAfter: Int
        public var focusedElementReadable: Bool
        public var attempts: [String]

        public var description: String {
            if wasAlreadyEnabled { return "辅助功能树本就可见（无需激活）" }
            guard enabledByUs else { return "激活失败：\(attempts.joined(separator: "；"))" }
            return "已激活（窗口 \(windowsVisibleAfter) 个，焦点控件可读=\(focusedElementReadable)）"
        }
    }

    /// 判断 AX 树是否**可用**。
    ///
    /// 只看"窗口列表非空"是不够的：实测 Electron 应用在无障碍树未完全启用时，
    /// 窗口列表能读到，但窗口的 `AXSize` 为空、焦点控件读不到
    /// ——这种"半可用"状态会让尺寸操作与插入点读取全部失败，却看起来像"已经好了"。
    /// 因此把"窗口有有效尺寸"或"焦点控件可读"作为可用判据。
    public static func isTreeUsable(pid: pid_t) -> Bool {
        if focusedElementReadable(pid: pid) { return true }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement], !list.isEmpty else { return false }
        for window in list {
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var size = CGSize.zero
            if AXValueGetValue(sv as! AXValue, .cgSize, &size), size.width > 1, size.height > 1 {
                return true
            }
        }
        return false
    }

    /// 兼容旧名：仅表示"窗口列表非空"。
    public static func isTreeVisible(pid: pid_t) -> Bool {
        windowCount(pid) > 0
    }

    /// 尝试激活辅助功能树。已可用时直接返回，不产生副作用。
    @discardableResult
    public static func enableIfNeeded(pid: pid_t, timeout: TimeInterval = 3.0) -> Result {
        var result = Result(wasAlreadyEnabled: false, enabledByUs: false,
                            windowsVisibleAfter: 0, focusedElementReadable: false, attempts: [])
        if isTreeUsable(pid: pid) {
            result.wasAlreadyEnabled = true
            result.windowsVisibleAfter = windowCount(pid)
            result.focusedElementReadable = focusedElementReadable(pid: pid)
            return result
        }
        let app = AXUIElementCreateApplication(pid)
        // 两个已知开关都试：不同 Chromium 版本认的键不完全一致
        for key in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let err = AXUIElementSetAttributeValue(app, key as CFString, kCFBooleanTrue)
            result.attempts.append("\(key) → \(err == .success ? "已设置" : "错误码 \(err.rawValue)")")
        }
        // 给 Chromium 时间构建树
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isTreeUsable(pid: pid) {
                result.enabledByUs = true
                break
            }
            usleep(150_000)
        }
        result.windowsVisibleAfter = windowCount(pid)
        result.focusedElementReadable = focusedElementReadable(pid: pid)
        return result
    }

    public static func windowCount(_ pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return 0 }
        return list.count
    }

    public static func focusedElementReadable(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value else { return false }
        return CFGetTypeID(v) == AXUIElementGetTypeID()
    }
}
