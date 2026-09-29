import Foundation

// MARK: - 合成窗口提供者与输入执行（无需任何系统权限）

/// 被代理的"目标应用"的窗口模型。真实实现是 `AXWindowProvider`（需要辅助功能权限）；
/// 这个实现承载同样的语义，使完整链路在无权限环境可被真实验证。
public final class SyntheticAppModel {
    public struct AppWindow {
        public var uid: String
        public var title: String
        public var role: WindowRole
        public var contentSize: Size
        public var constraints: SizeConstraints
        public var content: SyntheticWindowContent
        public var minimized: Bool
        public var parentUID: String?
        public var modal: Bool
        public var focusable: Bool
        public var zOrder: Int32
    }

    public var bundleID: String
    public var displayName: String
    public var appLaunchID: String
    public var pid: Int32
    public var contentScale: Double
    public internal(set) var windows: [String: AppWindow] = [:]
    private var order: [String] = []
    /// 远端编辑控件状态（文本会话据此产生上下文）。
    public var textBuffer: String = ""
    public var caretOffset: Int = 0
    public var selectionLength: Int = 0
    public var focusedWindowUID: String?
    public var acceptsUnicodeEvents: Bool
    public var supportsCommit: Bool
    public var caretRectValid: Bool
    public var remoteMarked = false
    /// 由宿主授予的"接受输入"开关（对应控制撤销）。
    public var acceptsInput = true

    public init(bundleID: String = "dev.m2m.demoapp", displayName: String = "M2M Demo App",
                appLaunchID: String = UUID().uuidString, pid: Int32 = 0,
                contentScale: Double = 2.0, acceptsUnicodeEvents: Bool = true,
                supportsCommit: Bool = true, caretRectValid: Bool = true) {
        self.bundleID = bundleID; self.displayName = displayName
        self.appLaunchID = appLaunchID; self.pid = pid; self.contentScale = contentScale
        self.acceptsUnicodeEvents = acceptsUnicodeEvents
        self.supportsCommit = supportsCommit; self.caretRectValid = caretRectValid
        _ = addWindow(AppWindow(uid: "demo.main.\(appLaunchID)", title: "Demo — 主窗口",
                                role: .main, contentSize: Size(560, 380),
                                constraints: SizeConstraints(minSize: Size(320, 200), maxSize: Size(1200, 900), resizable: .both),
                                content: SyntheticWindowContent(title: "Demo — 主窗口"),
                                minimized: false, parentUID: nil, modal: false, focusable: true, zOrder: 0))
    }

    @discardableResult
    public func addWindow(_ w: AppWindow) -> String {
        windows[w.uid] = w
        if !order.contains(w.uid) { order.append(w.uid) }
        if focusedWindowUID == nil, w.focusable { focusedWindowUID = w.uid }
        return w.uid
    }

    public func removeWindow(_ uid: String) {
        windows.removeValue(forKey: uid)
        order.removeAll { $0 == uid }
        if focusedWindowUID == uid { focusedWindowUID = order.first }
    }

    /// 直接设置某窗口的内容尺寸（演示/测试用来构造初始布局）。
    @discardableResult
    public func setSize(_ uid: String, _ size: Size) -> Bool {
        guard var w = windows[uid] else { return false }
        w.contentSize = size
        windows[uid] = w
        updateContent(uid) { _ in }
        return true
    }

    public func setTitle(_ uid: String, _ title: String) {
        guard var w = windows[uid] else { return }
        w.title = title
        windows[uid] = w
        updateContent(uid) { _ in }
    }

    public func updateContent(_ uid: String, _ mutate: (inout SyntheticWindowContent) -> Void) {
        guard var w = windows[uid] else { return }
        mutate(&w.content)
        // 文本缓冲与窗口内容保持一致，使"远端窗口画面"能反映文字变化
        w.content.textContent = textBuffer
        w.content.caretOffset = caretOffset
        w.content.selectionLength = selectionLength
        windows[uid] = w
    }

    public var allWindows: [AppWindow] { order.compactMap { windows[$0] } }

    public var focusableWindow: AppWindow? {
        guard let uid = focusedWindowUID else { return order.first.flatMap { windows[$0] } }
        return windows[uid]
    }

    /// 打开设置窗口（用于弹窗与父子关系验证）。
    public func openSettingsWindow() -> String {
        let uid = "demo.settings.\(UUID().uuidString.prefix(8))"
        return addWindow(AppWindow(uid: uid, title: "设置", role: .panel,
                                   contentSize: Size(360, 240),
                                   constraints: SizeConstraints(minSize: Size(300, 200), resizable: .both),
                                   content: SyntheticWindowContent(title: "设置", badge: "panel"),
                                   minimized: false, parentUID: focusedWindowUID, modal: false,
                                   focusable: true, zOrder: 1))
    }

    /// 打开模态对话框。
    public func openModalDialog() -> String {
        let uid = "demo.dialog.\(UUID().uuidString.prefix(8))"
        return addWindow(AppWindow(uid: uid, title: "确认", role: .dialog,
                                   contentSize: Size(320, 180),
                                   constraints: SizeConstraints(resizable: .none),
                                   content: SyntheticWindowContent(title: "确认", badge: "modal"),
                                   minimized: false, parentUID: focusedWindowUID, modal: true,
                                   focusable: true, zOrder: 2))
    }

    /// 打开右键菜单（弹出窗口）。
    public func openPopupMenu() -> String {
        let uid = "demo.menu.\(UUID().uuidString.prefix(8))"
        return addWindow(AppWindow(uid: uid, title: "上下文菜单", role: .popupMenu,
                                   contentSize: Size(180, 120),
                                   constraints: SizeConstraints(resizable: .none),
                                   content: SyntheticWindowContent(title: "菜单", badge: "popup"),
                                   minimized: false, parentUID: focusedWindowUID, modal: false,
                                   focusable: true, zOrder: 3))
    }
}

public final class SyntheticWindowProvider: WindowProvider {
    public let model: SyntheticAppModel
    public init(model: SyntheticAppModel) { self.model = model }
    public var appBundleID: String { model.bundleID }
    public var appDisplayName: String { model.displayName }

    public func currentWindows() -> [WindowInfo] {
        model.allWindows.map { w in
            WindowInfo(windowUID: w.uid, appPID: model.pid, appLaunchID: model.appLaunchID,
                       bundleID: model.bundleID, title: w.title, role: w.role,
                       parentUID: w.parentUID, modal: w.modal,
                       contentRect: Rect(origin: Point(0, 0), size: w.contentSize),
                       contentScale: model.contentScale, constraints: w.constraints,
                       minimized: w.minimized, focusable: w.focusable, zOrder: w.zOrder)
        }
    }

    /// 尺寸"读回"语义：应用可能拒绝请求，返回的是**实际**值。
    public func applySize(_ uid: String, requested: Size) -> (actual: Size, constrainedBy: SizeConstraint) {
        guard var w = model.windows[uid] else { return (requested, .system) }
        let (clamped, by) = w.constraints.clamp(requested)
        if w.constraints.resizable == .none { return (w.contentSize, .appMax) }
        w.contentSize = Size(clamped.width > 0 ? clamped.width : w.contentSize.width,
                             clamped.height > 0 ? clamped.height : w.contentSize.height)
        model.windows[uid] = w
        return (w.contentSize, by)
    }

    public func perform(_ action: WindowActionKind, on uid: String) -> Bool {
        guard var w = model.windows[uid] else { return false }
        switch action {
        case .minimize: w.minimized = true
        case .unminimize: w.minimized = false
        case .activate: model.focusedWindowUID = uid
        case .close: model.removeWindow(uid); return true
        case .requestFullscreen: return false   // 合成模型不支持全屏，如实返回失败
        }
        model.windows[uid] = w
        return true
    }

    public func activate(_ uid: String) -> Bool {
        guard model.windows[uid] != nil else { return false }
        model.focusedWindowUID = uid
        return true
    }
}

/// 合成输入执行：把事件作用到模型上。真实实现是 `CGEventInputSink`。
public final class SyntheticInputSink: InputSink {
    public let model: SyntheticAppModel
    public private(set) var deliveredKeys: [KeyEvent] = []
    public private(set) var deliveredPointers: [PointerEvent] = []
    public private(set) var modifierReleases: [String] = []
    public private(set) var rejectedBecauseNoFocus = 0
    public var available: Bool { true }
    public var unavailableReason: String? { nil }

    public init(model: SyntheticAppModel) { self.model = model }

    public func deliver(_ event: KeyEvent) {
        guard model.acceptsInput else { return }
        guard model.windows[event.windowUID] != nil else { return }
        deliveredKeys.append(event)
        if event.kind == .keyDown, let unicode = event.unicode, !unicode.isEmpty {
            insertText(unicode)
        } else if event.kind == .keyDown, event.category == .editing || event.category == .rawKey {
            switch event.keycode {
            case KeyCode.delete:
                if model.caretOffset > 0 {
                    let chars = Array(model.textBuffer)
                    var idx = min(model.caretOffset, chars.count)
                    if idx > 0 {
                        var arr = chars
                        arr.removeSubrange((idx - 1)..<idx)
                        model.textBuffer = String(arr)
                        idx -= 1
                        model.caretOffset = idx
                    }
                }
            case KeyCode.returnKey, KeyCode.keypadEnter:
                insertText("\n")
            default:
                break
            }
        }
        if let uid = model.focusedWindowUID {
            model.updateContent(uid) { _ in }
        }
    }

    public func deliver(_ event: PointerEvent) {
        guard model.acceptsInput else { return }
        guard model.windows[event.windowUID] != nil else { return }
        deliveredPointers.append(event)
        if event.kind == .scroll {
            model.updateContent(event.windowUID) { $0.scrollOffset += event.scrollDY }
        }
    }

    public func releaseAllModifiers(forWindow uid: String) {
        modifierReleases.append(uid)
    }

    private func insertText(_ text: String) {
        let chars = Array(model.textBuffer)
        var loc = min(model.caretOffset, chars.count)
        let sel = min(model.selectionLength, chars.count - loc)
        var arr = chars
        if sel > 0 { arr.removeSubrange(loc..<(loc + sel)) }
        arr.insert(contentsOf: Array(text), at: loc)
        loc += text.count
        model.textBuffer = String(arr)
        model.caretOffset = loc
        model.selectionLength = 0
    }
}

// MARK: - Host 侧文本上下文提供者

public final class SyntheticTextContextProvider: TextContextProvider {
    public let model: SyntheticAppModel
    public private(set) var epoch: UInt64
    public private(set) var editVersion: UInt64 = 1
    public var lastEditVersionSeenByRemote: UInt64 { editVersion }

    public init(model: SyntheticAppModel, epoch: UInt64 = 1) {
        self.model = model; self.epoch = epoch
    }

    public func bumpVersion() { editVersion &+= 1 }

    /// 提交生效后由 `TextSession` 调用，保证版本只有一个推进点。
    @discardableResult
    public func advanceEditVersion() -> UInt64 {
        bumpVersion()
        return editVersion
    }

    public func currentContext() -> TextContext? {
        guard let w = model.focusableWindow, w.focusable else { return nil }
        // 光标矩形：文本区从 y=36 起，每行约 10pt，列宽 8pt
        let cols = 8.0
        let line = Double(model.caretOffset / 60)
        let col = Double(model.caretOffset % 60)
        let caret = CaretInfo(valid: model.caretRectValid,
                              rectInWindow: Rect(10 + col * cols, 36 + line * 10, 2, 10),
                              lineHeight: 10)
        let chars = Array(model.textBuffer)
        let loc = min(model.caretOffset, chars.count)
        let before = String(chars[max(0, loc - 64)..<loc])
        let after = String(chars[loc..<min(chars.count, loc + 64)])
        return TextContext(epoch: epoch, editVersion: editVersion,
                           windowUID: w.uid, nodeID: "demo.textfield",
                           role: .contentEditable, editable: true,
                           acceptsUnicodeEvents: model.acceptsUnicodeEvents,
                           caret: caret,
                           selection: SelectionInfo(valid: model.selectionLength > 0,
                                                    location: loc, length: model.selectionLength),
                           remoteMarkedPresent: model.remoteMarked,
                           remoteMarkedLength: model.remoteMarked ? 1 : 0,
                           contextBefore: before, contextAfter: after,
                           contextTruncated: loc > 64 || chars.count - loc > 64)
    }
}
