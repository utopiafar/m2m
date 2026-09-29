import Foundation
import AppKit
import M2MCore

// m2mviewer 的 AppKit 界面层。
//
// 这里承载"像原生 App 一样操作远端窗口"的全部本地交互：
//   · 窗口外壳由本地窗口系统管理（移动/缩放/最小化/与本地应用混排）
//   · 中文输入法在本地组合，候选窗跟随远端插入点
//   · 快捷键与输入法路径严格分开

final class ViewerWindowController: NSObject, NSApplicationDelegate {
    private let runtime: ViewerRuntime
    private let queue: DispatchQueue
    private var windows: [String: NSWindow] = [:]
    private var contentViews: [String: RemoteWindowView] = [:]
    private var hud: NSWindow?
    private var hudLabel: NSTextField?
    private var lastNoticeCount = -1
    private var hasConnected = false

    init(runtime: ViewerRuntime, queue: DispatchQueue) {
        self.runtime = runtime
        self.queue = queue
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        buildHUD()
        // 连接：握手后窗口状态会陆续到达
        queue.async { [runtime] in
            runtime.sendHello()
            logViewer("已发送握手")
        }
        if runtime.windowTable.count == 0 {
            showPlaceholder()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        writeViewerState()
    }

    // MARK: HUD（能力与提示）

    private func buildHUD() {
        let rect = NSRect(x: 40, y: 40, width: 520, height: 150)
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "m2m 状态"
        w.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "连接中…")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.frame = NSRect(x: 10, y: 10, width: 500, height: 128)
        label.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(label)
        w.orderFront(nil)
        hud = w
        hudLabel = label
    }

    private var placeholder: NSWindow?

    private func showPlaceholder() {
        let w = NSWindow(contentRect: NSRect(x: 120, y: 300, width: 360, height: 90),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "等待远端窗口"
        let label = NSTextField(labelWithString: "正在连接远端主机…\n连接成功后，远端窗口会以独立本地窗口出现。")
        label.font = NSFont.systemFont(ofSize: 12)
        label.maximumNumberOfLines = 0
        label.frame = NSRect(x: 12, y: 12, width: 336, height: 60)
        w.contentView?.addSubview(label)
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        placeholder = w
    }

    private func updateHUD() {
        let caps = runtime.hostCapabilities
        var lines: [String] = []
        lines.append("会话：\(runtime.session.phase.localizedDescription)    epoch \(runtime.session.epoch)")
        if let caps {
            lines.append("远端能力：插入点=\(caps.text.caretRect ? "可用" : "不可用")   AX=\(caps.text.axAvailable ? "可用" : "不可用")")
            let degraded = caps.apps.filter { !$0.certified }
            if degraded.isEmpty {
                lines.append("输入法：本地输入法（光标跟随）")
            } else {
                for app in degraded {
                    lines.append("输入法：\(app.displayName) 降级 → \(app.inputMode.localizedDescription)")
                }
            }
        } else {
            lines.append("远端能力：尚未协商完成")
        }
        lines.append("窗口：\(runtime.windowTable.count)   画面帧：\(runtime.framesReceived)   丢旧帧：\(runtime.framesDroppedStale)")
        lines.append("文本：\(runtime.textBridge.state.localizedDescription)")
        for n in runtime.notices.suffix(3) {
            lines.append("[\(n.severity.localizedDescription)] \(n.title)：\(n.detail)")
        }
        hudLabel?.stringValue = lines.joined(separator: "\n")
    }

    // MARK: 窗口同步

    func syncWindows() {
        if runtime.windowTable.count > 0, let p = placeholder {
            p.close(); placeholder = nil
        }
        let shells = runtime.windowTable.allShells
        var alive = Set<String>()

        for shell in shells {
            alive.insert(shell.windowUID)
            let decoded = runtime.decodedFrames[shell.windowUID]

            if let window = windows[shell.windowUID], let view = contentViews[shell.windowUID] {
                window.title = shell.title.isEmpty ? "远端窗口" : shell.title
                view.update(shell: shell, decoded: decoded, runtime: runtime)
                if shell.isLiveResizing {
                    // 拖动中：只改外框，画面暂按旧内容缩放显示
                }
            } else {
                let view = RemoteWindowView(runtime: runtime, queue: queue, windowUID: shell.windowUID)
                let size = NSSize(width: max(200, shell.localContentSize.width),
                                  height: max(150, shell.localContentSize.height))
                let style: NSWindow.StyleMask = shell.role == .popupMenu
                    ? [.titled, .closable, .utilityWindow]
                    : [.titled, .closable, .resizable, .miniaturizable]
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: style, backing: .buffered, defer: false)
                window.title = shell.title.isEmpty ? "远端窗口" : shell.title
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.delegate = view
                if let parent = shell.parentUID, let pw = windows[parent] {
                    pw.addChildWindow(window, ordered: .above)
                }
                let offset = CGFloat(windows.count) * 28
                window.setFrameOrigin(NSPoint(x: 260 + offset, y: 420 - offset))
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                windows[shell.windowUID] = window
                contentViews[shell.windowUID] = view
                view.update(shell: shell, decoded: decoded, runtime: runtime)
                logViewer("创建本地窗口壳 \(shell.windowUID) 「\(shell.title)」\(shell.role.localizedDescription)")
            }
        }

        for (uid, window) in windows where !alive.contains(uid) {
            window.close()
            windows.removeValue(forKey: uid)
            contentViews.removeValue(forKey: uid)
            logViewer("关闭本地窗口壳 \(uid)（远端窗口已消失）")
        }

        updateHUD()
    }
}

/// 承载远端窗口画面的本地视图，同时是本地输入法的输入客户端。
final class RemoteWindowView: NSView, NSTextInputClient, NSWindowDelegate {
    private let runtime: ViewerRuntime
    private let queue: DispatchQueue
    private let windowUID: String

    private var markedText = NSMutableAttributedString()
    private var latestImage: CGImage?
    private var latestDecoded: DecodedFrame?
    private var lastShell: RemoteWindowTable.Shell?
    private var resizing = false
    private var resizeStart: NSSize = .zero
    private var pendingComposition: String = ""

    init(runtime: ViewerRuntime, queue: DispatchQueue, windowUID: String) {
        self.runtime = runtime
        self.queue = queue
        self.windowUID = windowUID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 渲染

    func update(shell: RemoteWindowTable.Shell, decoded: DecodedFrame?, runtime: ViewerRuntime) {
        lastShell = shell
        if let decoded, decoded.pixelChecksum != latestDecoded?.pixelChecksum {
            latestDecoded = decoded
            latestImage = Self.makeImage(decoded)
        }
        needsDisplay = true
    }

    private static func makeImage(_ decoded: DecodedFrame) -> CGImage? {
        let w = Int(decoded.size.width), h = Int(decoded.size.height)
        guard w > 0, h > 0, decoded.pixels.count >= w * h * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(decoded.pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        if let image = latestImage {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: bounds)
        } else {
            let msg = "等待画面…"
            (msg as NSString).draw(at: NSPoint(x: 12, y: bounds.height - 26), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        // 组合文本提示：证明组合在本地进行
        if !markedText.string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.75),
            ]
            ("拼音：" + markedText.string as NSString)
                .draw(at: NSPoint(x: 10, y: 10), withAttributes: attrs)
        }
    }

    // MARK: 输入法（NSTextInputClient）

    func hasMarkedText() -> Bool { !markedText.string.isEmpty }

    func markedRange() -> NSRange {
        markedText.string.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.string.count)
    }

    func selectedRange() -> NSRange {
        let ctx = runtime.textBridge.context
        guard let ctx, ctx.selection.valid else { return NSRange(location: 0, length: 0) }
        return NSRange(location: ctx.selection.location, length: ctx.selection.length)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let s = string as? NSAttributedString { text = s.string }
        else { text = "" }
        markedText = NSMutableAttributedString(string: text)
        queue.async { [runtime] in
            if !runtime.textBridge.state.isComposing {
                if let ctx = runtime.textBridge.context {
                    runtime.textBridge.beginComposition(editVersion: ctx.editVersion)
                }
            }
            runtime.textBridge.updateComposition(text)
        }
        needsDisplay = true
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        queue.async { [runtime] in runtime.textBridge.cancelComposition() }
        needsDisplay = true
    }

    /// 输入法确认文字 → 走文本提交通道（绝不走按键通道）
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let s = string as? NSAttributedString { text = s.string }
        else { text = "" }
        markedText = NSMutableAttributedString()
        guard !text.isEmpty else { needsDisplay = true; return }
        queue.async { [runtime] in
            let now = Date().timeIntervalSinceReferenceDate
            runtime.textBridge.receive(context: runtime.textBridge.context ?? TextContext(
                epoch: 1, editVersion: 0, windowUID: self.windowUID, nodeID: "",
                role: .unknown, editable: false, acceptsUnicodeEvents: true,
                caret: CaretInfo(valid: false), selection: SelectionInfo(valid: false)))
            _ = runtime.confirmComposition(text, at: now)
        }
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        // 输入法未消费该按键 → 作为应用操作发往远端
        queue.async { [runtime] in
            let keycode = Self.keycode(for: selector)
            let kind: KeyKind = .keyDown
            _ = runtime.routeAndSendKey(keycode: keycode, kind: kind, flags: [],
                                        unicode: nil, imeConsumed: false)
            _ = runtime.routeAndSendKey(keycode: keycode, kind: .keyUp, flags: [],
                                        unicode: nil, imeConsumed: false)
        }
    }

    private static func keycode(for selector: Selector) -> UInt16 {
        switch NSStringFromSelector(selector) {
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:": return KeyCode.returnKey
        case "insertTab:": return KeyCode.tab
        case "deleteBackward:": return KeyCode.delete
        case "deleteForward:": return KeyCode.forwardDelete
        case "moveLeft:", "moveBackward:": return KeyCode.leftArrow
        case "moveRight:", "moveForward:": return KeyCode.rightArrow
        case "moveUp:": return KeyCode.upArrow
        case "moveDown:": return KeyCode.downArrow
        case "moveToBeginningOfLine:", "moveToBeginningOfDocument:": return KeyCode.home
        case "moveToEndOfLine:", "moveToEndOfDocument:": return KeyCode.end
        case "pageUp:", "scrollPageUp:": return KeyCode.pageUp
        case "pageDown:", "scrollPageDown:": return KeyCode.pageDown
        case "cancelOperation:": return KeyCode.escape
        default: return 0
        }
    }

    /// 候选窗位置：由远端插入点映射而来（**不是**鼠标最后点击位置）
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let ctx = runtime.textBridge.context
        guard let ctx, ctx.caret.valid, let shell = lastShell, let window else {
            // 降级：无插入点时退回到窗口内一个稳定位置，并在 HUD 标注
            let fallback = NSRect(x: 24, y: bounds.height - 48, width: 2, height: 16)
            ViewerUIBridge.shared.lastCaretLocalRect = nil
            return window?.convertToScreen(convert(fallback, to: nil)) ?? .zero
        }
        let mapping = GeometryMapping(layoutVersion: shell.layoutVersion,
                                      remoteContentScale: 2.0, localBackingScale: window.backingScaleFactor)
        let localPoint = mapping.localLogical(fromRemoteLogical: Point(ctx.caret.rectInWindow.origin.x,
                                                                      ctx.caret.rectInWindow.origin.y),
                                              localContentSize: shell.localContentSize,
                                              remoteContentSize: shell.remoteContentSize)
        let viewRect = NSRect(x: localPoint.x, y: bounds.height - localPoint.y - 20,
                              width: max(2, ctx.caret.rectInWindow.size.width),
                              height: max(10, ctx.caret.rectInWindow.size.height))
        ViewerUIBridge.shared.lastCaretLocalRect = Rect(Double(viewRect.origin.x), Double(viewRect.origin.y),
                                                        Double(viewRect.size.width), Double(viewRect.size.height))
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    // MARK: 键盘与鼠标

    override func keyDown(with event: NSEvent) {
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        // 组合期间的按键必须由本地输入法优先处理
        let composing = runtime.textBridge.state.isComposing
        if composing || !flags.hasCommandLikeModifier {
            // 交给输入法解释：它要么产生组合文本，要么回调 doCommand(by:)
            interpretKeyEvents([event])
            // 方向/编辑键会走 doCommand；普通字符产生组合文本
            if markedText.string.isEmpty, !composing, isNavigationKey(event.keyCode) {
                sendNavigation(event)
            }
            return
        }
        sendShortcut(event)
    }

    override func keyUp(with event: NSEvent) {
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        guard flags.hasCommandLikeModifier else { return }
        queue.async { [runtime] in
            _ = runtime.routeAndSendKey(keycode: event.keyCode, kind: .keyUp, flags: flags,
                                        unicode: nil, imeConsumed: false)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        queue.async { [runtime] in
            _ = runtime.routeAndSendKey(keycode: event.keyCode, kind: .flagsChanged, flags: flags,
                                        unicode: nil, imeConsumed: true)
        }
    }

    private func isNavigationKey(_ keycode: UInt16) -> Bool {
        KeyCode.arrowKeys.contains(keycode) || [KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown].contains(keycode)
    }

    private func sendNavigation(_ event: NSEvent) {
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        queue.async { [runtime] in
            _ = runtime.routeAndSendKey(keycode: event.keyCode, kind: .keyDown, flags: flags,
                                        unicode: nil, imeConsumed: false)
            _ = runtime.routeAndSendKey(keycode: event.keyCode, kind: .keyUp, flags: flags,
                                        unicode: nil, imeConsumed: false)
        }
    }

    private func sendShortcut(_ event: NSEvent) {
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        queue.async { [runtime] in
            _ = runtime.routeAndSendKey(keycode: event.keyCode, kind: .keyDown, flags: flags,
                                        unicode: nil, imeConsumed: false)
            _ = runtime.routeAndSendKey(keycode: event.keyCode, kind: .keyUp, flags: flags,
                                        unicode: nil, imeConsumed: false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let point = remotePoint(p)
        queue.async { [runtime] in
            let now = Date().timeIntervalSinceReferenceDate
            _ = runtime.routeAndSendPointer(kind: .down, position: point, button: .left, at: now)
            _ = runtime.routeAndSendPointer(kind: .up, position: point, button: .left, at: now)
        }
        if runtime.textBridge.context == nil {
            queue.async { [runtime] in runtime.focus(windowUID: self.windowUID) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let point = remotePoint(p)
        queue.async { [runtime] in
            let now = Date().timeIntervalSinceReferenceDate
            _ = runtime.routeAndSendPointer(kind: .drag, position: point, button: .left, at: now)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let point = remotePoint(p)
        queue.async { [runtime] in
            let now = Date().timeIntervalSinceReferenceDate
            _ = runtime.routeAndSendPointer(kind: .scroll, position: point,
                                            scrollDX: Double(event.scrollingDeltaX),
                                            scrollDY: Double(event.scrollingDeltaY), at: now)
        }
    }

    /// 本地坐标 → 远端窗口逻辑坐标（缩放后仍正确）
    private func remotePoint(_ local: NSPoint) -> Point {
        guard let shell = lastShell else { return Point(Double(local.x), Double(local.y)) }
        let flipped = Point(Double(local.x), Double(bounds.height - local.y))
        return GeometryMapping(layoutVersion: shell.layoutVersion, remoteContentScale: 2.0, localBackingScale: 1)
            .remoteLogical(fromLocalLogical: flipped,
                           localContentSize: shell.localContentSize,
                           remoteContentSize: shell.remoteContentSize)
    }

    // MARK: 缩放

    func windowWillStartLiveResize(_ notification: Notification) {
        resizing = true
        resizeStart = bounds.size
        if let shell = lastShell {
            queue.async { [runtime] in
                runtime.beginResize(windowUID: shell.windowUID, requested: shell.localContentSize)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard resizing, let shell = lastShell, let window else { return }
        // 拖动中：本地立即改变外框，远端请求按频率合并发送
        queue.async { [runtime] in
            runtime.beginResize(windowUID: shell.windowUID,
                                requested: Size(Double(window.contentView?.bounds.width ?? 0),
                                                Double(window.contentView?.bounds.height ?? 0)))
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        resizing = false
        guard let shell = lastShell, let window else { return }
        let size = Size(Double(window.contentView?.bounds.width ?? 0),
                        Double(window.contentView?.bounds.height ?? 0))
        // 松手后提交最终尺寸：远端重新排版，随后画面恢复清晰
        queue.async { [runtime] in runtime.endResize(windowUID: shell.windowUID, finalSize: size) }
    }
}
