import Foundation

/// Viewer 侧运行时：本地窗口壳、媒体接收、文本桥、输入路由、文件/剪贴板。
///
/// 与 Host 一样，靠注入的传输层与显式 tick 驱动，因此可在无 GUI、无权限的环境下
/// 完整验证协议与状态机；有 GUI 时由 AppKit 层驱动同一套运行时。
public final class ViewerRuntime {
    public let bus: MessageBus
    public let session: Session
    public let windowTable = RemoteWindowTable()
    public let textBridge = TextBridge()
    public let inputRouter: InputRouter
    public let receiver = FrameReceiver()
    public let decoder: FrameDecoder
    public let fileBridge: FileBridge
    public let clipboard = ClipboardBridge()
    public let resizeCoalescer: ResizeCoalescer

    public private(set) var hostCapabilities: Capabilities?
    public private(set) var streams: [String: StreamInfo] = [:]
    /// streamID → windowUID
    public private(set) var streamToWindow: [String: String] = [:]
    /// 最新的可显示帧（按窗口）
    public private(set) var decodedFrames: [String: DecodedFrame] = [:]
    public private(set) var framesReceived = 0
    public private(set) var framesDroppedStale = 0
    public private(set) var keyframeRequestsSent = 0
    /// 运行时自身的提示（能力、窗口、文件等）。
    private var localNotices: [Notice] = []
    /// 面向 UI 的**唯一**提示清单：会话级提示（断线、撤销等）与运行时提示合并，
    /// 避免 UI 因为查了其中一份而漏掉另一份。
    public var notices: [Notice] { session.notices + localNotices }
    public private(set) var lastTickTime: TimeInterval = 0
    public private(set) var commitResults: [TextCommitResult] = []
    /// 本地已知的远端几何版本（来自最近一次窗口状态）
    public private(set) var layoutVersion: UInt64 = 0
    /// 是否有提交在途（超时判定由 TextBridge 负责，这里只做界面展示）。
    public var hasInflightCommit: Bool { textBridge.state.isCommitting }

    public init(bus: MessageBus, session: Session,
                decoder: FrameDecoder = ScreenRLEDecoder(),
                fileBridge: FileBridge,
                resizeCoalescer: ResizeCoalescer = ResizeCoalescer(interval: 0.1)) {
        self.bus = bus; self.session = session
        self.decoder = decoder
        self.fileBridge = fileBridge
        self.resizeCoalescer = resizeCoalescer
        self.inputRouter = InputRouter(epoch: session.epoch)
        registerHandlers()
    }

    private func registerHandlers() {
        bus.on([.helloAck]) { [weak self] env in
            guard let self, let ack = self.bus.decode(env, as: HelloAck.self) else { return }
            self.hostCapabilities = ack.acceptedCapabilities
            // 采纳 Host 权威指定的会话代次（重连时的关键步骤）
            if ack.epoch != self.session.epoch {
                self.session.adoptEpoch(ack.epoch, reason: "重连由远端确认")
                self.bus.setEpoch(ack.epoch)
                self.inputRouter.setEpoch(ack.epoch, targetWindow: nil)
                self.textBridge.invalidate(reason: .appRestarted)
            }
            self.session.noteReconnectCompleted()
            if let reason = ack.rejectionReason {
                self.session.fail(notice: Notice(severity: .error, scope: .auth,
                                                 title: "连接被拒绝", detail: reason,
                                                 code: "auth.rejected"))
                return
            }
            // 依据能力声明决定降级提示（不得静默降级）
            for app in ack.acceptedCapabilities.apps where !app.certified {
                self.localNotices.append(Notice(severity: .info, scope: .text,
                                           title: "\(app.displayName) 处于降级模式",
                                           detail: app.degradationReason ?? app.inputMode.localizedDescription,
                                           code: "text.degraded.\(app.bundleID)"))
            }
            if !ack.acceptedCapabilities.text.caretRect {
                self.localNotices.append(Notice(severity: .warning, scope: .text,
                                           title: "远端未提供插入点位置",
                                           detail: "候选窗将使用近似定位；该应用不会被标记为「本地输入法体验达标」。",
                                           code: "text.caretRect.unavailable"))
            }
            self.session.activate(degraded: !ack.acceptedCapabilities.text.caretRect)
        }
        bus.on([.windowSnapshot]) { [weak self] env in
            guard let self, let snap = self.bus.decode(env, as: WindowSnapshot.self) else { return }
            self.applySnapshot(snap)
        }
        bus.on([.windowDelta]) { [weak self] env in
            guard let self, let delta = self.bus.decode(env, as: WindowDelta.self) else { return }
            self.applyDelta(delta)
        }
        bus.on([.windowResizeResult]) { [weak self] env in
            guard let self, let r = self.bus.decode(env, as: WindowResizeResult.self) else { return }
            self.handleResizeResult(r)
        }
        bus.on([.streamInfo]) { [weak self] env in
            guard let self, let s = self.bus.decode(env, as: StreamInfo.self) else { return }
            self.streams[s.streamID] = s
            self.streamToWindow[s.streamID] = s.windowUID
        }
        bus.on([.streamState]) { [weak self] env in
            guard let self, let s = self.bus.decode(env, as: StreamState.self) else { return }
            if s.state != .live {
                self.localNotices.append(Notice(severity: .info, scope: .media,
                                           title: "画面暂停", detail: s.state.localizedDescription,
                                           code: "media.paused.\(s.streamID)"))
            } else {
                self.localNotices.removeAll { $0.code == "media.paused.\(s.streamID)" }
            }
        }
        bus.on([.textContext]) { [weak self] env in
            guard let self, let ctx = self.bus.decode(env, as: TextContext.self) else { return }
            self.textBridge.receive(context: ctx)
        }
        bus.on([.textContextInvalidated]) { [weak self] env in
            guard let self, let inv = self.bus.decode(env, as: TextContextInvalidated.self) else { return }
            self.textBridge.invalidate(reason: inv.reason)
        }
        bus.on([.textCommitResult]) { [weak self] env in
            guard let self, let r = self.bus.decode(env, as: TextCommitResult.self) else { return }
            self.commitResults.append(r)
            self.textBridge.receive(result: r)
        }
        bus.on([.fileProgress]) { [weak self] env in
            guard let self, let p = self.bus.decode(env, as: FileProgress.self) else { return }
            _ = p
        }
        bus.on([.fileAbort]) { [weak self] env in
            guard let self, let a = self.bus.decode(env, as: FileAbort.self) else { return }
            self.localNotices.append(Notice(severity: .error, scope: .file,
                                       title: "文件传输失败", detail: a.reason.localizedDescription,
                                       code: "file.abort.\(a.transferID)"))
        }
        bus.on([.clipboardUpdate]) { [weak self] env in
            guard let self, let u = self.bus.decode(env, as: ClipboardUpdate.self) else { return }
            _ = self.clipboard.receive(u)
        }
        bus.on([.errorReport]) { [weak self] env in
            guard let self, let e = self.bus.decode(env, as: ErrorReport.self) else { return }
            self.localNotices.append(Notice(severity: e.retryable ? .warning : .error, scope: e.scope,
                                       title: e.message, detail: "错误码：\(e.code)",
                                       code: "error.\(e.code)"))
        }
        bus.on([.sessionState]) { [weak self] env in
            guard let self, let s = self.bus.decode(env, as: SessionStateMsg.self) else { return }
            _ = s
            self.session.activate()
        }

        // 媒体通道是裸帧
        bus.onRaw(.media) { [weak self] data in
            self?.handleMediaFrame(data)
        }
    }

    private func applySnapshot(_ snap: WindowSnapshot) {
        layoutVersion = snap.layoutVersion
        let closed = windowTable.apply(snapshot: snap)
        if !closed.isEmpty {
            localNotices.append(Notice(severity: .info, scope: .window,
                                  title: "远端窗口已关闭",
                                  detail: "已关闭 \(closed.count) 个本地窗口壳，不再接收输入。",
                                  code: "window.closed"))
        }
        requestKeyframesIfNeeded()
    }

    private func applyDelta(_ delta: WindowDelta) {
        layoutVersion = delta.layoutVersion
        // 增量合并为一次全量应用，复用同一套壳管理逻辑
        var current: [String: WindowInfo] = [:]
        for uid in windowTable.lastKnownRemoteUIDs {
            if let shell = windowTable.shell(uid) {
                current[uid] = WindowInfo(windowUID: uid, appPID: 0, appLaunchID: "", bundleID: "",
                                          title: shell.title, role: shell.role,
                                          parentUID: shell.parentUID, modal: shell.modal,
                                          contentRect: Rect(origin: .zero, size: shell.remoteContentSize),
                                          contentScale: 1.0, constraints: SizeConstraints(),
                                          minimized: false, focusable: true, zOrder: 0)
            }
        }
        for w in delta.added { current[w.windowUID] = w }
        for w in delta.changed { current[w.windowUID] = w }
        for uid in delta.removed { current.removeValue(forKey: uid) }
        let snap = WindowSnapshot(epoch: delta.epoch, layoutVersion: delta.layoutVersion,
                                  windows: Array(current.values))
        let closed = windowTable.apply(snapshot: snap)
        if !closed.isEmpty {
            localNotices.append(Notice(severity: .info, scope: .window,
                                  title: "远端窗口已关闭",
                                  detail: "已关闭 \(closed.count) 个本地窗口壳。",
                                  code: "window.closed"))
        }
    }

    private func handleResizeResult(_ r: WindowResizeResult) {
        // 只接受最新请求的结果：过期结果不得回退本地窗口尺寸
        guard resizeCoalescer.isNewest(seq: r.requestSeq) else {
            return
        }
        let uid = windowTable.allShells.first { $0.layoutVersion <= r.layoutVersion }?.windowUID
            ?? windowTable.allShells.first?.windowUID
        guard let target = uid else { return }
        windowTable.endLiveResize(uid: target, actual: r.actualContentSize, layoutVersion: r.layoutVersion)
        layoutVersion = r.layoutVersion
        if r.constrainedBy != .none {
            localNotices.append(Notice(severity: .info, scope: .window,
                                  title: "尺寸受应用限制",
                                  detail: "已按远端实际尺寸调整：\(r.constrainedBy.localizedDescription)",
                                  code: "window.constrained"))
        }
        // 尺寸变化后必须重新请求关键帧，避免继续显示旧分辨率画面
        requestKeyframes(for: target)
    }

    // MARK: 媒体

    private func handleMediaFrame(_ data: Data) {
        guard let wire = try? MediaFrameWire.decode(data) else { return }
        let frame = wire.asEncodedFrame
        guard let windowUID = streamToWindow[wire.streamID] ?? streams[wire.streamID]?.windowUID else { return }
        do {
            if let decoded = try receiver.ingest(frame, decoder: decoder, currentLayoutVersion: layoutVersion) {
                decodedFrames[windowUID] = decoded
                framesReceived += 1
            } else {
                framesDroppedStale += 1
            }
        } catch DecodeError.missingReferenceFrame {
            requestKeyframes(for: windowUID)
        } catch {
            receiver.markDecodeFailure()
            requestKeyframes(for: windowUID)
        }
    }

    private func requestKeyframesIfNeeded() {
        for (streamID, _) in streams {
            _ = streamID
        }
        receiver.requestKeyframe()
        bus.send(KeyframeRequest(streamID: "*", reason: .connect), type: .keyframeRequest)
        keyframeRequestsSent += 1
    }

    public func requestKeyframes(for windowUID: String) {
        guard let stream = streams.values.first(where: { $0.windowUID == windowUID }) else { return }
        receiver.requestKeyframe()
        bus.send(KeyframeRequest(streamID: stream.streamID, reason: .decodeError), type: .keyframeRequest)
        keyframeRequestsSent += 1
    }

    // MARK: 窗口操作

    public func beginResize(windowUID: String, requested: Size) {
        windowTable.beginLiveResize(uid: windowUID, localSize: requested)
        if let req = resizeCoalescer.submit(uid: windowUID, size: requested, now: lastTickTime) {
            bus.send(WindowResizeRequest(epoch: session.epoch, windowUID: windowUID,
                                         requestedContentSize: req.size, requestSeq: req.seq),
                     type: .windowResizeRequest)
        }
    }

    public func endResize(windowUID: String, finalSize: Size) {
        let flushed = resizeCoalescer.flush(uid: windowUID, size: finalSize)
        bus.send(WindowResizeRequest(epoch: session.epoch, windowUID: windowUID,
                                     requestedContentSize: flushed.size, requestSeq: flushed.seq),
                 type: .windowResizeRequest)
    }

    public func perform(action: WindowActionKind, on windowUID: String) {
        bus.send(WindowAction(epoch: session.epoch, windowUID: windowUID, action: action),
                 type: .windowAction)
    }

    // MARK: 文本与输入

    public func focus(windowUID: String) {
        inputRouter.setTargetWindow(windowUID)
        textBridge.invalidate(reason: .focusMoved)
        bus.send(WindowAction(epoch: session.epoch, windowUID: windowUID, action: .activate),
                 type: .windowAction)
        requestTextContext(reason: "focus-changed")
    }

    /// 请 Host 重新下发编辑上下文。
    ///
    /// 必要：Viewer 主动丢弃上下文（切窗口 / 重连）后，如果 editVersion 没变，
    /// Host 不会自动重发，Viewer 就会一直处于"无法输入"且无从恢复的状态。
    public func requestTextContext(reason: String) {
        bus.send(TextContextRequest(reason: reason), type: .textContextRequest)
    }

    /// 确认选词并发送。提交只从 `outgoing` 队列取，保证不会重复发送。
    @discardableResult
    public func confirmComposition(_ text: String, at now: TimeInterval) -> Int {
        _ = textBridge.confirmComposition(text, at: now)
        return flushOutgoingCommits(at: now)
    }

    /// 把文本桥产生的提交发出去。返回本次发送的条数。
    @discardableResult
    public func flushOutgoingCommits(at now: TimeInterval) -> Int {
        let commits = textBridge.takeOutgoingCommits()
        for commit in commits {
            bus.send(commit, type: .textCommit)
        }
        return commits.count
    }

    public func routeAndSendKey(keycode: UInt16, kind: KeyKind, flags: ModifierFlags,
                                unicode: String?, imeConsumed: Bool) -> InputRouter.KeyDisposition {
        let route = textBridge.routeKey(keycode: keycode, flags: flags, imeConsumed: imeConsumed)
        let disposition = inputRouter.handleKey(keycode: keycode, kind: kind, flags: flags,
                                               unicode: unicode, route: route)
        // 只有真正被判定为"发往远端"的按键才上线；本地输入法与本地消费一律不外发
        if case .sent(let event) = disposition {
            bus.send(event, type: .keyEvent)
        }
        return disposition
    }

    /// 指针事件的发送入口（移动已被合并，只有 flush 出来的才会发送）。
    @discardableResult
    public func routeAndSendPointer(kind: PointerKind, position: Point,
                                    button: PointerButton = .none,
                                    scrollDX: Double = 0, scrollDY: Double = 0,
                                    at now: TimeInterval) -> Int {
        let disposition = inputRouter.handlePointer(kind: kind, position: position, button: button,
                                                   scrollDX: scrollDX, scrollDY: scrollDY, now: now)
        switch disposition {
        case .sent(let event):
            bus.send(event, type: .pointerEvent)
            return 1
        case .coalesced, .rejected:
            return 0
        }
    }

    /// 把挂起的鼠标移动发出去（例如滚动/点击前、或拖动结束）。
    @discardableResult
    public func flushPendingPointer(at now: TimeInterval) -> Int {
        if case .sent(let event) = inputRouter.flushPointer(now: now) {
            bus.send(event, type: .pointerEvent)
            return 1
        }
        return 0
    }

    /// 连接中断时的按键释放也必须在链路上生效（A8）。
    @discardableResult
    public func releaseKeysOnLink() -> Int {
        let events = inputRouter.releaseAllKeys()
        for e in events { bus.send(e, type: .keyEvent) }
        return events.count
    }

    /// 直接发送一个已确认文本（等价于"用户完成选词并提交"）。
    @discardableResult
    public func sendKey(_ event: KeyEvent) -> UInt64 {
        bus.send(event, type: .keyEvent)
    }

    @discardableResult
    public func sendPointer(_ event: PointerEvent) -> UInt64 {
        bus.send(event, type: .pointerEvent)
    }

    // MARK: 定时驱动

    public func tick(now: TimeInterval) {
        lastTickTime = now
        // 提交超时判定：转入"结果不明"，不自动重试。
        // 时间基准与传输层一致（调用方时钟），不引入第二个时钟源。
        textBridge.tick(now: now)
        // 文本桥请求刷新上下文（例如版本过期、远端已有组合文本）时，真正发出请求
        for effect in textBridge.takeEffects() {
            if case .requestContextRefresh(let reason) = effect {
                requestTextContext(reason: reason)
            } else {
                pendingEffects.append(effect)
            }
        }
    }

    /// 未被运行时消费的 UI 副作用（提示、组合显示等）。
    private var pendingEffects: [TextBridgeEffect] = []

    /// 取出面向 UI 的副作用。
    public func takeUIEffects() -> [TextBridgeEffect] {
        let e = pendingEffects; pendingEffects.removeAll(); return e
    }

    // MARK: 重连

    /// 网络中断：释放修饰键、不重放任何输入（规格 §5.2）。
    public func transportInterrupted() {
        session.transportInterrupted(detail: nil)
        _ = inputRouter.releaseAllKeys()
        windowTable.resetForReconnect()
        decodedFrames.removeAll()
        receiver.requestKeyframe()
    }

    /// 重连：本地清理后**用当前 epoch** 发送 Hello，等待 Host 回 HelloAck 并采纳新 epoch。
    ///
    /// 本地不得自行推进 epoch —— 两端各自推进会让对方的合法消息被判为过期。
    /// 也不重放离线期间的任何输入（规格 §5.2）。
    public func reconnect() {
        // 1) 释放按键、丢弃未确认上下文、丢弃画面
        _ = inputRouter.releaseAllKeys()
        inputRouter.setTargetWindow(nil)
        textBridge.invalidate(reason: .focusMoved)
        windowTable.resetForReconnect()
        streams.removeAll()
        streamToWindow.removeAll()
        decodedFrames.removeAll()
        receiver.markDecodeFailure()
        receiver.requestKeyframe()
        // 2) 重新握手（用旧 epoch，便于对端接受）
        sendHello()
    }

    public var viewerDeviceID: String = "viewer-\(UUID().uuidString.prefix(8))"
    public var unacknowledgedCommit: Bool { hasInflightCommit }

    /// 清除某条提示（运行时与会话两处都清）。
    public func clearNotice(code: String) {
        localNotices.removeAll { $0.code == code }
        session.clearNotice(code: code)
    }

    public func sendHello() {
        bus.send(Hello(deviceID: viewerDeviceID, deviceName: "Viewer",
                       nonce: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                       capabilities: Capabilities(
                        media: MediaCapabilities(codecs: [.rawBGRA, .h264, .hevc], maxFPS: 60, hardwareEncode: false),
                        text: TextCapabilities(axAvailable: true, focusTracking: true, selectionRead: true,
                                               caretRect: true, compositionSupport: true))),
                 type: .hello)
    }
}
