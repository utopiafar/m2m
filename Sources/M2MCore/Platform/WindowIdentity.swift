import Foundation
import CoreGraphics
import ApplicationServices

/// 窗口的稳定身份。
///
/// 教训：不要用"尺寸/位置"派生窗口身份。那些属性会在缩放时改变，
/// 于是"改尺寸"这个操作本身会让窗口身份失效，后续按身份查找必然失败
/// （实测表现：尺寸请求发出去但窗口纹丝不动）。
///
/// 改用 CoreGraphics 的窗口号（`kCGWindowNumber`）：它在窗口生命周期内稳定，
/// 且 AX 与 ScreenCaptureKit 两侧都能通过 (标题, 尺寸) 与它对应起来。
public struct CGWindowEntry: Equatable, Sendable {
    public var number: UInt32
    public var title: String
    /// CG 坐标下的窗口框（含标题栏，原点在左上）
    public var bounds: CGRect
    public var layer: Int
    public var ownerPID: pid_t

    /// 窗口框尺寸。协议中的窗口尺寸对真实 AX 窗口即采用此值（见 AXWindowProvider）。
    public var frameSize: Size {
        Size(Double(bounds.width), Double(bounds.height))
    }
}

public enum CGWindowCatalog {
    /// 枚举某个进程的窗口。屏幕录制权限可让 `kCGWindowName` 可读；
    /// 没有它标题会是空串，此时身份仍可用窗口号，只是匹配会退化为按尺寸。
    public static func windows(forPID pid: pid_t,
                               onScreenOnly: Bool = true) -> [CGWindowEntry] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [CGWindowEntry] = []
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            guard let number = info[kCGWindowNumber as String] as? UInt32 else { continue }
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            var bounds = CGRect.zero
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                bounds = rect
            }
            out.append(CGWindowEntry(number: number, title: title, bounds: bounds,
                                     layer: layer, ownerPID: owner))
        }
        return out.sorted { $0.number < $1.number }
    }

    public static func uid(pid: pid_t, windowNumber: UInt32) -> String {
        "cg:\(pid):\(windowNumber)"
    }

    public static func parseUID(_ uid: String) -> (pid: pid_t, number: UInt32)? {
        let parts = uid.split(separator: ":")
        guard parts.count == 3, parts[0] == "cg",
              let pid = Int32(parts[1]), let number = UInt32(parts[2]) else { return nil }
        return (pid, number)
    }
}

/// AX 窗口元素与 CG 窗口条目的对应关系。
public enum AXWindowMatcher {
    /// 在 AX 窗口列表里找到与给定 CG 条目对应的元素。
    ///
    /// 先按"标题 + 尺寸最接近"匹配；尺寸容差放宽是为了容忍标题栏估算偏差。
    public static func match(entry: CGWindowEntry,
                             candidates: [AXUIElement],
                             title: (AXUIElement) -> String?,
                             size: (AXUIElement) -> CGSize?) -> AXUIElement? {
        var best: (AXUIElement, Double)?
        for element in candidates {
            let t = title(element) ?? ""
            let s = size(element) ?? .zero
            let titlePenalty: Double = (t.isEmpty || entry.title.isEmpty || t == entry.title) ? 0 : 300
            let dw = abs(Double(s.width) - Double(entry.bounds.width))
            let dh = abs(Double(s.height) - Double(entry.bounds.height))
            let score = titlePenalty + dw + dh
            if best == nil || score < best!.1 { best = (element, score) }
        }
        // 距离过大说明根本对不上，宁可不操作也不要操作错窗口
        guard let (element, score) = best, score < 300 else { return nil }
        return element
    }
}
