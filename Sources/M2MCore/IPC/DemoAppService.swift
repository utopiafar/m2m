import Foundation

/// 目标应用侧的服务端逻辑（运行在 demo 进程中）。
///
/// 它是"被代理的应用"的替身：持有窗口模型与文本状态，接受来自 Host 的
/// 窗口查询 / 尺寸修改 / 动作 / 输入事件请求。真实场景下这些能力由
/// AX + CGEvent 提供（见 PlatformAdapters），这里通过进程内模型 + UDS 提供，
/// 使得整条链路在**没有辅助功能与屏幕录制权限**时也能被真实执行与断言。
public final class DemoAppService {
    public let model: SyntheticAppModel
    public private(set) var requestCount = 0
    public private(set) var keyEventCount = 0
    public private(set) var pointerEventCount = 0
    public private(set) var resizeCount = 0
    public private(set) var rejectedInputCount = 0

    public init(model: SyntheticAppModel) { self.model = model }

    public func handle(_ request: DemoRequest) -> DemoResponse {
        requestCount += 1
        let response = handleInner(request)
        var withID = response
        withID.requestID = request.requestID
        return withID
    }

    private func handleInner(_ request: DemoRequest) -> DemoResponse {
        switch request.kind {
        case .textCommit:
            guard model.acceptsInput else {
                rejectedInputCount += 1
                return DemoResponse(ok: false, error: "输入已被撤销")
            }
            let intent = DemoRequest.textIntentFromName(request.commitIntent ?? "insertText")
            let text = request.text ?? ""
            if let loc = request.commitLocation, intent == .insertText || intent == .replaceSelection {
                model.caretOffset = loc
                model.selectionLength = request.commitLength ?? 0
            }
            switch intent {
            case .deleteBackward: deleteBackward()
            case .deleteForward: deleteForward()
            case .newline, .insertText, .replaceSelection: if !text.isEmpty { insert(text) }
            }
            if let uid = model.focusedWindowUID { model.updateContent(uid) { _ in } }
            return DemoResponse(ok: true, snapshot: snapshot())
        case .hello:
            return DemoResponse(ok: true, snapshot: snapshot())
        case .snapshot:
            return DemoResponse(ok: true, snapshot: snapshot())
        case .resize:
            guard let uid = request.uid, let w = request.width, let h = request.height else {
                return DemoResponse(ok: false, error: "缺少尺寸参数")
            }
            guard var win = model.windows[uid] else {
                return DemoResponse(ok: false, error: "窗口不存在")
            }
            let requested = Size(w, h)
            // 关键语义：应用可能拒绝请求，返回的是**实际**生效的尺寸
            let (clamped, _) = win.constraints.clamp(requested)
            guard win.constraints.resizable != .none else {
                return DemoResponse(ok: true, snapshot: nil, appliedWidth: win.contentSize.width,
                                    appliedHeight: win.contentSize.height, constrained: true)
            }
            win.contentSize = Size(clamped.width > 0 ? clamped.width : win.contentSize.width,
                                   clamped.height > 0 ? clamped.height : win.contentSize.height)
            model.windows[uid] = win
            model.updateContent(uid) { _ in }
            resizeCount += 1
            let constrained = win.contentSize != requested
            return DemoResponse(ok: true, snapshot: nil,
                                appliedWidth: win.contentSize.width,
                                appliedHeight: win.contentSize.height,
                                constrained: constrained)
        case .action:
            guard let uid = request.uid, let name = request.action,
                  let action = DemoRequest.actionFromName(name) else {
                return DemoResponse(ok: false, error: "未知动作")
            }
            switch action {
            case .activate: _ = model.focusedWindowUID = uid
            case .minimize: model.windows[uid]?.minimized = true
            case .unminimize: model.windows[uid]?.minimized = false
            case .close: model.removeWindow(uid)
            case .requestFullscreen:
                return DemoResponse(ok: false, error: "合成目标应用不支持全屏")
            }
            return DemoResponse(ok: true, snapshot: snapshot())
        case .key:
            guard let uid = request.windowUID, let code = request.keycode else {
                return DemoResponse(ok: false, error: "缺少按键参数")
            }
            guard model.acceptsInput else {
                rejectedInputCount += 1
                return DemoResponse(ok: false, error: "输入已被撤销")
            }
            guard model.windows[uid] != nil else {
                rejectedInputCount += 1
                return DemoResponse(ok: false, error: "目标窗口不存在")
            }
            let isDown = request.isDown ?? true
            keyEventCount += 1
            if isDown, let uni = request.unicode, !uni.isEmpty {
                insert(uni)
            } else if isDown {
                switch UInt16(code) {
                case KeyCode.delete: deleteBackward()
                case KeyCode.returnKey, KeyCode.keypadEnter: insert("\n")
                default: break
                }
            }
            model.updateContent(uid) { _ in }
            return DemoResponse(ok: true, snapshot: nil)
        case .pointer:
            guard let uid = request.windowUID else { return DemoResponse(ok: false, error: "缺少窗口") }
            guard model.acceptsInput else {
                rejectedInputCount += 1
                return DemoResponse(ok: false, error: "输入已被撤销")
            }
            guard model.windows[uid] != nil else {
                rejectedInputCount += 1
                return DemoResponse(ok: false, error: "目标窗口不存在")
            }
            pointerEventCount += 1
            if request.pointerKind == "scroll" {
                let dy = request.scrollDY ?? 0
                model.updateContent(uid) { $0.scrollOffset += dy }
            }
            return DemoResponse(ok: true, snapshot: nil)
        case .textContext:
            return DemoResponse(ok: true, snapshot: snapshot())
        case .setContent:
            model.textBuffer = request.text ?? ""
            model.caretOffset = request.caret ?? 0
            model.selectionLength = request.selection ?? 0
            if let uid = model.focusedWindowUID { model.updateContent(uid) { _ in } }
            return DemoResponse(ok: true, snapshot: snapshot())
        case .openSettings:
            let uid = model.openSettingsWindow()
            return DemoResponse(ok: true, snapshot: snapshot(), createdUID: uid)
        case .openModal:
            let uid = model.openModalDialog()
            return DemoResponse(ok: true, snapshot: snapshot(), createdUID: uid)
        case .openPopup:
            let uid = model.openPopupMenu()
            return DemoResponse(ok: true, snapshot: snapshot(), createdUID: uid)
        case .close:
            guard let uid = request.uid else { return DemoResponse(ok: false, error: "缺少窗口") }
            model.removeWindow(uid)
            return DemoResponse(ok: true, snapshot: snapshot())
        case .revokeInput:
            model.acceptsInput = !(request.revoke ?? false)
            return DemoResponse(ok: true, snapshot: snapshot())
        }
    }

    private func insert(_ text: String) {
        var chars = Array(model.textBuffer)
        var loc = min(model.caretOffset, chars.count)
        let sel = min(model.selectionLength, chars.count - loc)
        if sel > 0 { chars.removeSubrange(loc..<(loc + sel)) }
        chars.insert(contentsOf: Array(text), at: loc)
        loc += text.count
        model.textBuffer = String(chars)
        model.caretOffset = loc
        model.selectionLength = 0
    }

    private func deleteForward() {
        var chars = Array(model.textBuffer)
        let loc = min(model.caretOffset, chars.count)
        guard loc < chars.count else { return }
        chars.removeSubrange(loc..<(loc + 1))
        model.textBuffer = String(chars)
    }

    private func deleteBackward() {
        var chars = Array(model.textBuffer)
        let loc = min(model.caretOffset, chars.count)
        guard loc > 0 else { return }
        chars.removeSubrange((loc - 1)..<loc)
        model.textBuffer = String(chars)
        model.caretOffset = loc - 1
    }

    public func snapshot() -> DemoSnapshot {
        let wins = model.allWindows.map { w in
            DemoSnapshot.Win(uid: w.uid, title: w.title, role: DemoRequest.roleName(w.role),
                             width: w.contentSize.width, height: w.contentSize.height,
                             minWidth: w.constraints.minSize?.width ?? 0,
                             minHeight: w.constraints.minSize?.height ?? 0,
                             resizable: w.constraints.resizable != .none,
                             minimized: w.minimized, modal: w.modal,
                             parentUID: w.parentUID, focusable: w.focusable,
                             zOrder: Int(w.zOrder))
        }
        let cols = 8.0
        let line = Double(model.caretOffset / 60)
        let col = Double(model.caretOffset % 60)
        let text = DemoSnapshot.TextState(
            buffer: model.textBuffer, caret: model.caretOffset, selection: model.selectionLength,
            focusedWindowUID: model.focusedWindowUID,
            caretRectValid: model.caretRectValid,
            caretX: 10 + col * cols, caretY: 36 + line * 10,
            acceptsInput: model.acceptsInput)
        return DemoSnapshot(bundleID: model.bundleID, displayName: model.displayName,
                            launchID: model.appLaunchID, pid: model.pid,
                            contentScale: model.contentScale, windows: wins, text: text)
    }

    /// 运行一个 UDS 服务端循环（demo 进程使用）。
    public func serve(socketPath: String, onEvent: ((DemoResponse) -> Void)? = nil) throws -> IPCListener {
        let listener = IPCListener(path: socketPath, label: "m2m.demo")
        listener.maxConnections = 4
        listener.onAccept = { [weak self] conn in
            guard let self else { return }
            conn.onReceive = { [weak self] data in
                guard let self else { return }
                guard let req = try? JSONDecoder().decode(DemoRequest.self, from: data) else {
                    let resp = DemoResponse(ok: false, error: "无法解析请求")
                    if let d = try? JSONEncoder().encode(resp) { conn.send(d) }
                    return
                }
                let resp = self.handle(req)
                if let d = try? JSONEncoder().encode(resp) { conn.send(d) }
                onEvent?(resp)
            }
        }
        try listener.start()
        return listener
    }
}

/// Host 侧的 demo 客户端。把本地模型的能力映射为远程调用，
/// 使 Host 的其余部分（注册表、采集、文本会话、输入执行）与真实模式完全一致。
public final class DemoAppProxy: WindowProvider, InputSink, TextContextProvider {
    private let connection: IPCConnection
    private let lock = NSLock()
    private var lastSnapshot: DemoSnapshot?
    private var editVersion: UInt64 = 1
    public private(set) var callCount = 0
    public private(set) var failures: [String] = []

    /// 调用串行队列：保证同一时刻只有一个在途请求，避免响应交错与超时误判。
    private let callQueue = DispatchQueue(label: "m2m.demo.proxy")
    private var pending: [String: DemoResponse] = [:]
    private var pendingOrder: [String] = []
    private var requestSeq: UInt64 = 0

    public init(connection: IPCConnection) {
        self.connection = connection
        // 回调只设置一次，按 requestID 分派（不使用"替换回调"的写法，那会产生竞态）
        connection.onReceive = { [weak self] data in
            guard let self, let resp = try? JSONDecoder().decode(DemoResponse.self, from: data) else { return }
            self.lock.lock()
            if let id = resp.requestID {
                self.pending[id] = resp
                self.pendingOrder.append(id)
                if self.pendingOrder.count > 256 {
                    let evicted = self.pendingOrder.removeFirst()
                    self.pending.removeValue(forKey: evicted)
                }
            }
            if let s = resp.snapshot { self.lastSnapshot = s }
            self.lock.unlock()
        }
    }

    public var appBundleID: String { cachedSnapshot?.bundleID ?? "" }
    public var appDisplayName: String { cachedSnapshot?.displayName ?? "目标应用" }

    /// 同步往返调用，串行执行。UDS 上的本地调用，延迟在微秒级。
    @discardableResult
    private func call(_ request: DemoRequest, timeout: TimeInterval = 2.0) -> DemoResponse? {
        callQueue.sync {
            callCount += 1
            requestSeq &+= 1
            var req = request
            let id = "req-\(requestSeq)"
            req.requestID = id
            guard let data = try? JSONEncoder().encode(req) else { return nil }
            connection.send(data)

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let resp = pending[id]
                if resp != nil { pending.removeValue(forKey: id) }
                lock.unlock()
                if let resp {
                    if !resp.ok { failures.append("\(request.kind.rawValue)：\(resp.error ?? "未知错误")") }
                    return resp
                }
                usleep(2_000)
            }
            failures.append("请求超时：\(request.kind.rawValue)")
            return nil
        }
    }

    public func refreshSnapshot() -> DemoSnapshot? {
        call(.snapshot())?.snapshot
    }

    private var cachedSnapshot: DemoSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return lastSnapshot
    }

    // MARK: WindowProvider

    public func currentWindows() -> [WindowInfo] {
        let snap = refreshSnapshot() ?? cachedSnapshot
        guard let snap else { return [] }
        return snap.windows.map { w in
            WindowInfo(windowUID: w.uid, appPID: snap.pid, appLaunchID: snap.launchID,
                       bundleID: snap.bundleID, title: w.title,
                       role: DemoRequest.roleFromName(w.role),
                       parentUID: w.parentUID, modal: w.modal,
                       contentRect: Rect(origin: Point(0, 0), size: Size(w.width, w.height)),
                       contentScale: snap.contentScale,
                       constraints: SizeConstraints(
                        minSize: w.minWidth > 0 ? Size(w.minWidth, w.minHeight) : nil,
                        maxSize: nil, resizable: w.resizable ? .both : .none),
                       minimized: w.minimized, focusable: w.focusable, zOrder: Int32(w.zOrder))
        }
    }

    public func applySize(_ uid: String, requested: Size) -> (actual: Size, constrainedBy: SizeConstraint) {
        let r = call(.resize(uid: uid, width: requested.width, height: requested.height))
        guard let r, let w = r.appliedWidth, let h = r.appliedHeight else { return (requested, .system) }
        return (Size(w, h), (r.constrained ?? false) ? .appMin : .none)
    }

    public func perform(_ action: WindowActionKind, on uid: String) -> Bool {
        let r = call(.action(uid: uid, action: action))
        if let snap = r?.snapshot { lock.lock(); lastSnapshot = snap; lock.unlock() }
        return r?.ok ?? false
    }

    public func activate(_ uid: String) -> Bool { perform(.activate, on: uid) }

    // MARK: InputSink

    public var available: Bool { true }
    public var unavailableReason: String? { nil }

    public func deliver(_ event: KeyEvent) { call(.key(event)) }
    public func deliver(_ event: PointerEvent) { call(.pointer(event)) }
    public func releaseAllModifiers(forWindow uid: String) {
        // 修饰键释放以 keyUp 形式送达，保证目标应用不残留按下状态
        for keycode in [55, 56, 58, 59, 63] {
            let e = KeyEvent(epoch: 0, windowUID: uid, kind: .keyUp,
                             keycode: UInt16(keycode), flags: 0, unicode: nil)
            call(.key(e))
        }
    }

    // MARK: TextContextProvider

    public var cachedTextState: DemoSnapshot.TextState? { cachedSnapshot?.text }
    public var cachedSnapshotPublic: DemoSnapshot? { cachedSnapshot }

    public func currentContext() -> TextContext? {
        let snap = cachedSnapshot ?? refreshSnapshot()
        guard let snap else { return nil }
        let text = snap.text
        guard text.acceptsInput, let focused = text.focusedWindowUID else { return nil }
        let caret = CaretInfo(valid: text.caretRectValid,
                              rectInWindow: Rect(text.caretX, text.caretY, 2, 10), lineHeight: 10)
        let chars = Array(text.buffer)
        let loc = min(text.caret, chars.count)
        let before = String(chars[max(0, loc - 64)..<loc])
        let after = String(chars[loc..<min(chars.count, loc + 64)])
        return TextContext(epoch: 1, editVersion: editVersion, windowUID: focused,
                           nodeID: "demo.textfield", role: .contentEditable, editable: true,
                           acceptsUnicodeEvents: false,
                           caret: caret,
                           selection: SelectionInfo(valid: text.selection > 0, location: loc,
                                                    length: text.selection),
                           remoteMarkedPresent: false, remoteMarkedLength: 0,
                           contextBefore: before, contextAfter: after,
                           contextTruncated: loc > 64 || chars.count - loc > 64)
    }

    @discardableResult
    public func advanceEditVersion() -> UInt64 {
        lock.lock(); editVersion &+= 1; let v = editVersion; lock.unlock()
        return v
    }

    /// 刷新快照（Host 主循环调用）。
    public func refresh() { _ = refreshSnapshot() }
}

/// 通过 demo 协议执行文本提交。
///
/// 提交走独立的 `.textCommit` 指令，**不复用 `.key`**：把提交和按键混用会让
/// 同一段文字既被提交又被按键，从而重复输入（规格 A3）。
public final class DemoTextCommitExecutor: TextCommitExecutor {
    private let proxy: DemoAppProxy
    public init(proxy: DemoAppProxy) { self.proxy = proxy }

    public func execute(_ commit: TextCommit, context: TextContext) -> TextCommitResult {
        let r = proxy.submit(commit)
        guard let r else {
            // 本地往返失败：结果不明，绝不谎报成功
            return TextCommitResult(commitSeq: commit.commitSeq, status: .unknown,
                                    detail: "与目标应用的本地往返失败")
        }
        guard r.ok else {
            let message = r.error ?? "未知错误"
            let status: TextCommitStatus
            if message.contains("撤销") { status = .rejectedNoFocus }
            else if message.contains("不存在") { status = .rejectedStale }
            else { status = .rejectedUnsupported }
            return TextCommitResult(commitSeq: commit.commitSeq, status: status, detail: message)
        }
        let applied = r.snapshot?.text.buffer
        return TextCommitResult(commitSeq: commit.commitSeq, status: .applied,
                                appliedRange: SelectionInfo(valid: true, location: commit.replaceRange?.location ?? 0,
                                                            length: commit.text.count),
                                detail: applied.map { "远端文本长度 \($0.count)" })
    }
}

extension DemoAppProxy {
    /// 提交一次文本编辑（供 `DemoTextCommitExecutor` 使用）。
    func submit(_ commit: TextCommit) -> DemoResponse? { call(.textCommit(commit)) }
}
