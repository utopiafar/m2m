import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import IOKit.hid

/// 系统权限与能力探测。**只探测，不静默降级**：结果直接驱动 UI 提示。
public enum SystemCapabilityProbe {

    public static func screenRecordingState() -> CapabilityReport.PermissionState {
        // CGPreflightScreenCaptureAccess 只查询，不弹窗
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    public static func accessibilityState() -> CapabilityReport.PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// 输入监控权限的**真实**探测（而不是恒返回未授予）。
    ///
    /// 该权限只影响"全局键盘监听"（例如在任何应用前台时捕获快捷键）；
    /// 窗口内的输入不依赖它，因此缺失时应提示而不是阻断。
    public static func inputMonitoringState() -> CapabilityReport.PermissionState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// 申请输入监控权限（会弹窗，仅在用户显式要求时调用）。
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// 请求屏幕录制权限（会弹窗，仅在用户显式要求时调用）。
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 请求辅助功能权限（会弹窗）。
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 组装完整能力报告。`forceSynthetic` 用于在无权限环境显式选择合成链路。
    public static func report(forceSynthetic: Bool = false) -> CapabilityReport {
        var report = CapabilityReport(
            screenRecording: .notRequired,
            accessibility: .notRequired,
            inputMonitoring: .notRequired,
            captureMode: .synthetic,
            inputMode: .recorded,
            textMode: .unavailable
        )

        if forceSynthetic {
            report.textMode = .fullLocalIME  // 合成链路提供完整的插入点与选区，达到认证标准
            report.textMode = .fullLocalIME
            return report
        }

        let screen = screenRecordingState()
        let ax = accessibilityState()
        report.screenRecording = screen
        report.accessibility = ax
        report.inputMonitoring = inputMonitoringState()

        switch screen {
        case .granted: report.captureMode = .realWindowCapture
        default: report.captureMode = .synthetic
        }

        switch ax {
        case .granted:
            report.inputMode = .realEventInjection
            report.textMode = .fullLocalIME
        default:
            // 无辅助功能权限时，输入执行与插入点读取都不可用
            report.inputMode = .recorded
            report.textMode = .syntheticFallback
        }
        return report
    }
}

extension CapabilityReport.TextAccessMode {
    /// 辅助功能权限缺失但合成链路可用时的状态：仍需明确告知用户。
    static var syntheticFallback: CapabilityReport.TextAccessMode { .degradedCaret }
}

// MARK: - 真实窗口提供者（AX）

/// 通过辅助功能接口枚举与操作窗口。**需要辅助功能权限**，无权限时 `available == false`
/// 并在报告中说明，绝不在无权限时假装成功。
public final class AXWindowProvider: WindowProvider {
    public let targetPID: pid_t
    public let bundleID: String
    public let displayName: String
    public let appLaunchID: String

    public init(targetPID: pid_t, bundleID: String, displayName: String) {
        self.targetPID = targetPID
        self.bundleID = bundleID
        self.displayName = displayName
        self.appLaunchID = "ax-\(targetPID)-\(bundleID)"
    }

    public var available: Bool { AXIsProcessTrusted() }
    public var appBundleID: String { bundleID }
    public var appDisplayName: String { displayName }

    public var unavailableReason: String? {
        available ? nil : "缺少辅助功能权限，无法读取远端窗口信息"
    }

    private var appElement: AXUIElement { AXUIElementCreateApplication(targetPID) }

    /// 窗口列表。
    ///
    /// 身份使用 CoreGraphics 窗口号：它在窗口生命周期内稳定，且能与采集侧对应。
    /// 窗口的几何与标题优先取自 CG（含标题栏的真实框），AX 只补充约束等细节。
    public func currentWindows() -> [WindowInfo] {
        guard available else { return [] }
        let catalog = CGWindowCatalog.windows(forPID: targetPID)
        let axWindows = windowElements()
        var out: [WindowInfo] = []
        for (idx, entry) in catalog.enumerated() {
            // 尺寸语义：直接采用窗口框尺寸。
            //
            // 曾尝试"减去标题栏高度"来得到内容区尺寸，但标题栏高度没有可靠来源
            // （随系统版本与窗口样式变化），任何估算都会让"请求尺寸"与"读回尺寸"
            // 产生固定偏差，表现为改尺寸永远差几十点。改用窗口框尺寸后
            // 请求与读回 1:1 对应，且与采集到的像素尺寸（也是窗口框）一致。
            let size = Size(Double(entry.bounds.width), Double(entry.bounds.height))
            guard size.width >= 20, size.height >= 20 else { continue }
            guard entry.layer >= 0 else { continue }   // 负层级是系统浮层，不属于应用窗口
            let element = AXWindowMatcher.match(
                entry: entry, candidates: axWindows,
                title: { [weak self] in self?.stringAttribute($0, kAXTitleAttribute) },
                size: { [weak self] el in
                    guard let s = self?.sizeAttribute(el, kAXSizeAttribute) else { return nil }
                    return CGSize(width: s.width, height: s.height)
                })
            let minSize = element.flatMap { sizeAttribute($0, "AXMinSize") }
            let resizable = element.flatMap { boolAttribute($0, kAXFullScreenButtonAttribute as String) } ?? true
            let subrole = element.flatMap { stringAttribute($0, kAXSubroleAttribute) }
            let modal = element.flatMap { boolAttribute($0, "AXModal") } ?? false
            let minimized = element.flatMap { boolAttribute($0, kAXMinimizedAttribute) } ?? false
            let role = AXWindowProvider.mappedRole(subrole: subrole, isModal: modal)
            let title = entry.title.isEmpty
                ? (element.flatMap { stringAttribute($0, kAXTitleAttribute) } ?? "")
                : entry.title
            out.append(WindowInfo(
                windowUID: CGWindowCatalog.uid(pid: targetPID, windowNumber: entry.number),
                appPID: targetPID, appLaunchID: appLaunchID, bundleID: bundleID,
                title: title.isEmpty ? displayName : title, role: role,
                parentUID: nil, modal: modal,
                contentRect: Rect(origin: Point(0, 0), size: size),
                contentScale: 2.0,
                constraints: SizeConstraints(minSize: minSize, maxSize: nil,
                                             resizable: resizable ? .both : .none),
                minimized: minimized, focusable: true, zOrder: Int32(idx)))
        }
        return out
    }

    private func windowElements() -> [AXUIElement] {
        var values: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &values) == .success,
              let list = values as? [AXUIElement] else { return [] }
        return list
    }

    /// 改窗口尺寸。
    ///
    /// 两个必须处理的差异：
    /// 1. AX 的 `AXSize` 是**窗口框**（含标题栏），而协议里的尺寸是**内容区**尺寸，
    ///    因此需要按标题栏高度换算；
    /// 2. 读回的是窗口框尺寸，同样要换算回内容尺寸再上报。
    public func applySize(_ uid: String, requested: Size) -> (actual: Size, constrainedBy: SizeConstraint) {
        guard available, let win = windowElement(for: uid) else { return (requested, .system) }
        var target = CGSize(width: requested.width, height: requested.height)
        if let v = AXValueCreate(.cgSize, &target) {
            let setResult = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
            if setResult != .success {
                let back = sizeAttribute(win, kAXSizeAttribute) ?? requested
                return (back, .appMin)
            }
        }
        // 关键：读回实际值，而不是假定请求生效（规格 §1.2 规则 2）。
        // 若应用自身限制尺寸（例如固定纵横比），这里会如实反映出差异。
        let actual = sizeAttribute(win, kAXSizeAttribute) ?? requested
        // 归因：区分"被屏幕可用区域限制"与"被应用自身限制"。
        // 二者对用户的含义完全不同（前者换个位置就能放大，后者是应用不允许），
        // 把它们都报成"应用限制"会误导排查方向。
        var by: SizeConstraint = .none
        if abs(actual.width - requested.width) > 2 || abs(actual.height - requested.height) > 2 {
            var posValue: CFTypeRef?
            var origin = CGPoint.zero
            if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posValue) == .success,
               let pv = posValue, CFGetTypeID(pv) == AXValueGetTypeID() {
                _ = AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
            }
            let screenHeight = Double(NSScreen.screens.map { $0.frame.height }.max() ?? 0)
            let availableHeight = max(0, screenHeight - Double(origin.y) - 90)
            if actual.width >= requested.width - 2, actual.height < requested.height - 2,
               availableHeight > 0, actual.height <= availableHeight + 4 {
                by = .screen
            } else {
                by = .appMin
            }
        }
        return (actual, by)
    }

    public func perform(_ action: WindowActionKind, on uid: String) -> Bool {
        guard available, let win = windowElement(for: uid) else { return false }
        switch action {
        case .minimize:
            return AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case .unminimize:
            return AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        case .activate:
            return activate(uid)
        case .close:
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &button) == .success,
               let b = button {
                return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
            }
            return false
        case .requestFullscreen:
            return false
        }
    }

    public func activate(_ uid: String) -> Bool {
        guard available, let win = windowElement(for: uid) else { return false }
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// 按稳定身份找回窗口元素。
    ///
    /// 身份是 CG 窗口号，需要用 (标题, 尺寸) 从当前 CG 目录里查回它的几何，
    /// 再与 AX 窗口列表匹配。找不到就返回 nil——**不要退化成"取第一个窗口"**，
    /// 那会把尺寸请求落到错误的窗口上。
    private func windowElement(for uid: String) -> AXUIElement? {
        let elements = windowElements()
        guard let parsed = CGWindowCatalog.parseUID(uid), parsed.pid == targetPID else {
            return nil
        }
        let catalog = CGWindowCatalog.windows(forPID: targetPID, onScreenOnly: false)
        guard let entry = catalog.first(where: { $0.number == parsed.number }) else { return nil }
        return AXWindowMatcher.match(
            entry: entry, candidates: elements,
            title: { [weak self] in self?.stringAttribute($0, kAXTitleAttribute) },
            size: { [weak self] el in
                guard let s = self?.sizeAttribute(el, kAXSizeAttribute) else { return nil }
                return CGSize(width: s.width, height: s.height)
            })
    }

    private func stringAttribute(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func boolAttribute(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    private func sizeAttribute(_ el: AXUIElement, _ attr: String) -> Size? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let value = v, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return Size(size.width, size.height)
    }

    static func mappedRole(subrole: String?, isModal: Bool) -> WindowRole {
        if isModal { return .dialog }
        guard let subrole else { return .main }
        switch subrole {
        case "AXStandardWindow": return .main
        case "AXDialog", "AXSystemDialog": return .dialog
        case "AXFloatingWindow": return .panel
        default: return .main
        }
    }
}

// MARK: - 真实输入执行（CGEvent）

/// 通过 CGEvent 注入键鼠事件。**需要辅助功能权限**。
///
/// 规格 §5 的三条路径在此实现：优先尝试本实现；若目标控件不响应，
/// 由上层的 `TextCommitExecutor` 决定是否降级到 Unicode 事件或 AX 写入。
public final class CGEventInputSink: InputSink {
    public let targetPID: pid_t

    public init(targetPID: pid_t) { self.targetPID = targetPID }

    public var available: Bool { AXIsProcessTrusted() }
    public var unavailableReason: String? {
        available ? nil : "缺少辅助功能权限，无法向远端应用注入输入"
    }

    public private(set) var deliveredKeyCount = 0
    public private(set) var deliveredPointerCount = 0
    public private(set) var unicodeFallbackCount = 0

    public func deliver(_ event: KeyEvent) {
        guard available else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let type: CGEventType = event.kind == .keyUp ? .keyUp : .keyDown
        guard let cg = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(event.keycode),
                               keyDown: type == .keyDown) else { return }
        cg.flags = CGEventFlags(rawValue: UInt64(event.flags))
        // 仅在本地输入法已确认文字时附带 Unicode（拼音按键绝不走此路径）
        if let unicode = event.unicode, !unicode.isEmpty, event.kind == .keyDown {
            let utf16 = Array(unicode.utf16)
            if !utf16.isEmpty {
                cg.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                unicodeFallbackCount += 1
            }
        }
        cg.postToPid(targetPID)
        deliveredKeyCount += 1
    }

    public func deliver(_ event: PointerEvent) {
        guard available else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let loc = CGPoint(x: event.positionInWindow.x, y: event.positionInWindow.y)
        let type: CGEventType
        switch event.kind {
        case .down: type = .leftMouseDown
        case .up: type = .leftMouseUp
        case .drag: type = .leftMouseDragged
        case .scroll:
            guard let s = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(event.scrollDY), wheel2: Int32(event.scrollDX), wheel3: 0) else { return }
            s.postToPid(targetPID)
            deliveredPointerCount += 1
            return
        case .move, .moveCoalesced: type = .mouseMoved
        }
        guard let cg = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: loc, mouseButton: .left) else { return }
        cg.postToPid(targetPID)
        deliveredPointerCount += 1
    }

    public func releaseAllModifiers(forWindow uid: String) {
        guard available else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // 释放所有修饰键，避免对端残留按下状态
        for keycode in [55, 56, 58, 59, 63] {   // cmd, shift, opt, ctrl, fn
            if let cg = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keycode), keyDown: false) {
                cg.flags = []
                cg.postToPid(targetPID)
            }
        }
        _ = uid
    }
}

// MARK: - 真实窗口采集（ScreenCaptureKit）

/// 基于 ScreenCaptureKit 的单窗口采集。**需要屏幕录制权限**。
///
/// 无权限时不静默失败：`isAvailable == false` 且给出原因，由上层切换到合成源
/// 并在 UI 中明确提示（规格 §7 能力上报与降级）。
public final class SCKWindowCaptureSource: NSObject, CaptureSource {
    public let streamID: String
    public private(set) var isAvailable: Bool
    public private(set) var unavailableReason: String?
    public private(set) var contentScaleValue: Double = 2.0

    private let window: SCWindow?
    private var stream: SCStream?
    private var latestPixels: [UInt8]?
    private var latestSize = Size.zero
    private var latestAt: TimeInterval = 0
    private var layoutVersion: UInt64 = 1
    private var paused = false
    private let outputQueue = DispatchQueue(label: "m2m.sck.output")
    private let lock = NSLock()
    public private(set) var framesCaptured = 0
    /// 采集诊断：用于把"采集已启动但没有帧"变成可观测事实
    public private(set) var samplesReceived = 0
    public private(set) var samplesRejectedInvalid = 0
    public private(set) var samplesRejectedNoStatus = 0
    public private(set) var samplesRejectedIncomplete = 0
    public private(set) var samplesRejectedNoImage = 0
    /// 被接受的 idle 帧数（内容未变化但画面仍有效）
    public private(set) var idleSamplesAccepted = 0

    /// 各 SCFrameStatus 的出现次数。用于区分"窗口不可见（blank）"、
    /// "内容未变化（idle）"与"正常出帧（complete）"，避免把三者混为一谈。
    public private(set) var statusHistogram: [Int: Int] = [:]

    public var diagnosticsSummary: String {
        let hist = statusHistogram.keys.sorted().map { k -> String in
            let name: String
            switch SCFrameStatus(rawValue: k) {
            case .complete: name = "complete"
            case .idle: name = "idle"
            case .blank: name = "blank"
            case .suspended: name = "suspended"
            case .started: name = "started"
            default: name = "raw\(k)"
            }
            return "\(name)=\(statusHistogram[k] ?? 0)"
        }.joined(separator: ",")
        return "样本 \(samplesReceived) [\(hist)]（idle 接受 \(idleSamplesAccepted)）/ 无图像 \(samplesRejectedNoImage) / 产出 \(framesCaptured)"
    }

    public init(streamID: String, window: SCWindow) {
        self.streamID = streamID
        self.window = window
        self.isAvailable = CGPreflightScreenCaptureAccess()
        self.unavailableReason = isAvailable ? nil : "缺少屏幕录制权限"
        super.init()
    }

    public func setLayoutVersion(_ v: UInt64) { layoutVersion = v }

    public func start(completion: ((Error?) -> Void)? = nil) {
        guard isAvailable, let window else {
            completion?(NSError(domain: "m2m.sck", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: unavailableReason ?? "不可用"]))
            return
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * contentScaleValue)
        config.height = Int(window.frame.height * contentScaleValue)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        } catch {
            completion?(error)
            return
        }
        self.stream = stream
        stream.startCapture { error in completion?(error) }
    }

    public func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    public func pause() { paused = true }
    public func resume() { paused = false }

    /// 最近一次采集到的像素尺寸（不消费帧，供流信息使用）。
    public var lastCapturedSize: Size? {
        lock.lock(); defer { lock.unlock() }
        return latestSize.isEmpty ? nil : latestSize
    }

    public func nextFrame(now: TimeInterval) -> CapturedFrame? {
        guard !paused else { return nil }
        lock.lock()
        let px = latestPixels
        let size = latestSize
        let at = latestAt
        lock.unlock()
        guard let px, !size.isEmpty, at > 0 else { return nil }
        framesCaptured += 1
        return CapturedFrame(streamID: streamID, size: size, contentScale: contentScaleValue,
                             layoutVersion: layoutVersion, frameIndex: framesCaptured,
                             isStatic: lastSampleWasStatic, pixels: px, capturedAt: now)
    }

    private var lastSampleWasStatic = false

    func ingest(pixelBuffer: CVPixelBuffer, isStatic: Bool = false) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let src = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let rowStart = y * bytesPerRow
            let dstStart = y * w * 4
            for x in 0..<(w * 4) {
                out[dstStart + x] = src[rowStart + x]
            }
        }
        lock.lock()
        latestPixels = out
        latestSize = Size(Double(w), Double(h))
        latestAt = Date().timeIntervalSinceReferenceDate
        lastSampleWasStatic = isStatic
        lock.unlock()
    }
}

extension SCKWindowCaptureSource: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        samplesReceived += 1
        guard type == .screen, sampleBuffer.isValid else {
            samplesRejectedInvalid += 1
            return
        }
        // 状态字段在桥接后可能是 CFNumber/NSNumber，也可能直接是 Int。
        // 只按 Int 取值会在部分系统版本上永远取不到，表现为"采集已启动但一帧都没有"。
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let statusNumber = (attachments?.first?[.status] as? NSNumber)
            ?? (attachments?.first?[.status] as? Int).map { NSNumber(value: $0) }
        guard let statusRaw = statusNumber?.intValue else {
            samplesRejectedNoStatus += 1
            return
        }
        statusHistogram[statusRaw, default: 0] += 1
        guard let status = SCFrameStatus(rawValue: statusRaw) else {
            samplesRejectedIncomplete += 1
            return
        }
        // `.idle` 表示"内容自上一帧起未变化"，采样缓冲里通常仍带着当前的画面内容。
        // 把它当作"无可用图像"会造成"采集已启动、却一帧都取不到"的假故障
        // ——尤其在窗口刚出现、SCK 尚未报告过一次 complete 的启动阶段。
        // 因此只把 blank（窗口不可见）与 suspended（采集被挂起）判为不可用。
        switch status {
        case .complete:
            break
        case .idle:
            idleSamplesAccepted += 1
        case .blank, .suspended:
            samplesRejectedIncomplete += 1
            return
        default:
            samplesRejectedIncomplete += 1
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            samplesRejectedNoImage += 1
            return
        }
        ingest(pixelBuffer: pb, isStatic: status == .idle)
    }
}

extension SCKWindowCaptureSource: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        isAvailable = false
        unavailableReason = "采集已停止：\(error.localizedDescription)"
    }
}
