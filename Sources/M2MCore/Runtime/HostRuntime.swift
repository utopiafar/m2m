import Foundation

/// Host 侧运行时：把窗口注册表、媒体管线、文本会话、输入执行、文件接收串起来。
///
/// 所有平台相关调用都通过协议注入（C3），使同一份运行时代码既能在真机权限下工作，
/// 也能在无权限的合成环境下被完整验证。
public final class HostRuntime {
    public let bus: MessageBus
    public let session: Session
    public let registry: WindowRegistry
    public let windowProvider: WindowProvider
    public let inputSink: InputSink
    public let textProvider: TextContextProvider?
    public let textSession: TextSession
    public let fileBridge: FileBridge
    public let clipboard = ClipboardBridge()

    public var captureSources: [String: CaptureSource]
    public var encoder: FrameEncoder
    public let encoderQueue: EncoderQueue
    public let bitrate: BitrateGovernor
    public var capabilityReport: CapabilityReport

    /// 已声明的流（windowUID → StreamInfo）
    public private(set) var streams: [String: StreamInfo] = [:]
    /// 待发关键帧的流
    public private(set) var keyframeRequests: Set<String> = ["*"]
    public private(set) var layoutVersionAtLastSnapshot: UInt64 = 0
    public private(set) var framesSent = 0
    public private(set) var framesSkippedForBudget = 0
    public private(set) var framesSkippedNoChange = 0
    public private(set) var resizeRequestsApplied = 0
    public private(set) var coalescedResizeDropped = 0
    /// 记录最后一次收到的 resize 请求序号，用于实现"只处理最新"
    private var lastResizeSeq: [String: UInt32] = [:]
    private var localNotices: [Notice] = []
    /// 面向报告的提示清单：能力提示 + 会话提示。
    public var notices: [Notice] { localNotices + session.notices }
    public private(set) var sentWindowStateAt: TimeInterval = 0

    public var targetFPS: Double = 30
    /// 最近一次 tick 的时间，供消息回调内部使用（避免引入额外时钟源）。
    public private(set) var lastTickTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private var lastSnapshotWindows: [String: WindowInfo] = [:]
    private var peerCapabilities: Capabilities?

    public init(bus: MessageBus,
                session: Session,
                windowProvider: WindowProvider,
                inputSink: InputSink,
                captureSources: [String: CaptureSource],
                encoder: FrameEncoder = ScreenRLEEncoder(),
                textProvider: TextContextProvider? = nil,
                commitExecutor: TextCommitExecutor? = nil,
                fileBridge: FileBridge,
                capabilityReport: CapabilityReport) {
        self.bus = bus; self.session = session
        self.windowProvider = windowProvider; self.inputSink = inputSink
        self.captureSources = captureSources; self.encoder = encoder
        self.textProvider = textProvider
        self.fileBridge = fileBridge
        self.capabilityReport = capabilityReport
        self.registry = WindowRegistry(epoch: session.epoch)
        self.encoderQueue = EncoderQueue(maxUnencoded: 2, maxEncoded: 8)
        self.bitrate = BitrateGovernor()
        if let textProvider {
            // 有目标应用的文本上下文时，必须同时提供提交执行器；
            // 缺了它就会出现"能看到上下文但提交永远失败"的静默降级。
            // 进程内合成目标应用时自动推导；外部代理必须显式注入（见 DemoTextCommitExecutor）。
            let executor: TextCommitExecutor
            if let commitExecutor {
                executor = commitExecutor
            } else if let synthetic = textProvider as? SyntheticTextContextProvider {
                executor = SyntheticCommitExecutor(provider: synthetic)
            } else {
                executor = UnsupportedTextCommitExecutor()
            }
            self.textSession = TextSession(provider: textProvider, executor: executor)
        } else {
            // 无文本上下文：明确的"不支持"状态，而不是假装可输入
            self.textSession = TextSession(provider: MutableTextContextProvider(),
                                           executor: UnsupportedTextCommitExecutor())
        }
        localNotices = capabilityReport.userFacingNotices
        registerHandlers()
    }

    /// 无文本上下文时的提交执行器：明确拒绝，而不是假装成功。
    public final class UnsupportedTextCommitExecutor: TextCommitExecutor {
        public init() {}
        public func execute(_ commit: TextCommit, context: TextContext) -> TextCommitResult {
            TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedUnsupported,
                             detail: "当前目标应用未提供可编辑文本上下文")
        }
    }

    /// 合成模式下的提交执行器：把提交作用到模型（对应真实的 AX 写入 / Unicode 事件路径）。
    public final class SyntheticCommitExecutor: TextCommitExecutor {
        let provider: SyntheticTextContextProvider
        let recorder = RecordingTextCommitExecutor()
        public init(provider: SyntheticTextContextProvider) {
            self.provider = provider
            recorder.buffer = provider.model.textBuffer
            recorder.caret = provider.model.caretOffset
            recorder.focused = true
        }
        public func execute(_ commit: TextCommit, context: TextContext) -> TextCommitResult {
            // 按优先级尝试：真实编辑事件路径 → AX 写入 → Unicode 事件
            guard provider.model.acceptsInput else {
                return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedNoFocus,
                                        detail: "远端已撤销输入权限")
            }
            guard provider.model.supportsCommit else {
                return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedUnsupported,
                                        detail: "控件不支持语义写入")
            }
            recorder.buffer = provider.model.textBuffer
            recorder.caret = provider.model.caretOffset
            let result = recorder.execute(commit, context: context)
            if result.status.isApplied {
                provider.model.textBuffer = recorder.buffer
                provider.model.caretOffset = recorder.caret
                provider.model.selectionLength = 0
                if let uid = provider.model.focusedWindowUID { provider.model.updateContent(uid) { _ in } }
                // 版本推进由 TextSession 统一负责，这里不再重复推进
            }
            return result
        }
    }

    // MARK: 消息处理

    private func registerHandlers() {
        bus.on([.hello]) { [weak self] env in
            guard let self, let hello = self.bus.decode(env, as: Hello.self) else { return }
            self.handleHello(hello)
        }
        bus.on([.windowResizeRequest]) { [weak self] env in
            guard let self, let req = self.bus.decode(env, as: WindowResizeRequest.self) else { return }
            self.handleResize(req)
        }
        bus.on([.windowAction]) { [weak self] env in
            guard let self, let act = self.bus.decode(env, as: WindowAction.self) else { return }
            self.handleWindowAction(act)
        }
        bus.on([.keyEvent]) { [weak self] env in
            guard let self, let k = self.bus.decode(env, as: KeyEvent.self) else { return }
            // 输入的目标窗口必须仍然存在，否则丢弃
            guard self.registry.window(k.windowUID) != nil else { return }
            self.inputSink.deliver(k)
        }
        bus.on([.pointerEvent]) { [weak self] env in
            guard let self, let p = self.bus.decode(env, as: PointerEvent.self) else { return }
            guard self.registry.window(p.windowUID) != nil else { return }
            self.inputSink.deliver(p)
        }
        bus.on([.textCommit]) { [weak self] env in
            guard let self, let c = self.bus.decode(env, as: TextCommit.self) else { return }
            let result = self.textSession.handle(c)
            self.bus.send(result, type: .textCommitResult)
            // 提交后立刻回推新版本，让 Viewer 拿到权威 editVersion
            self.publishTextContext()
        }
        bus.on([.textContextRequest]) { [weak self] env in
            guard let self else { return }
            _ = self.bus.decode(env, as: TextContextRequest.self)
            // 请求即强制重发（不看 editVersion 是否变化）
            self.forcePublishTextContext()
        }
        bus.on([.keyframeRequest]) { [weak self] env in
            guard let self, let r = self.bus.decode(env, as: KeyframeRequest.self) else { return }
            self.keyframeRequests.insert(r.streamID)
        }
        bus.on([.streamAdjustRequest]) { [weak self] env in
            guard let self, let a = self.bus.decode(env, as: StreamAdjustRequest.self) else { return }
            self.handleStreamAdjust(a)
        }
        bus.on([.fileOffer]) { [weak self] env in
            guard let self, let o = self.bus.decode(env, as: FileOffer.self) else { return }
            _ = o
            self.bus.send(SessionStateMsg(phase: .active, detail: "已接收文件提议"), type: .sessionState)
        }
        bus.on([.fileChunk]) { [weak self] env in
            guard let self, let c = self.bus.decode(env, as: FileChunk.self) else { return }
            let progress = self.fileBridge.receive(c)
            self.bus.send(progress, type: .fileProgress)
        }
        bus.on([.fileComplete]) { [weak self] env in
            guard let self, let c = self.bus.decode(env, as: FileComplete.self) else { return }
            let result = self.fileBridge.completeReceive(c)
            if let aborted = result.aborted {
                self.bus.send(FileAbort(transferID: c.transferID, reason: aborted), type: .fileAbort)
            } else {
                self.bus.send(FileProgress(transferID: c.transferID,
                                           received: UInt64(self.fileBridge.transfers[c.transferID]?.totalBytes ?? 0),
                                           total: UInt64(self.fileBridge.transfers[c.transferID]?.totalBytes ?? 0)),
                              type: .fileProgress)
            }
        }
        bus.on([.clipboardUpdate]) { [weak self] env in
            guard let self, let u = self.bus.decode(env, as: ClipboardUpdate.self) else { return }
            _ = self.clipboard.receive(u)
        }
        bus.on([.revokeControl]) { [weak self] env in
            guard let self, let r = self.bus.decode(env, as: RevokeControl.self) else { return }
            self.session.revoke(r.reason)
            // 撤销必须立即生效：释放所有修饰键，停止接受输入
            for w in self.registry.allWindows { self.inputSink.releaseAllModifiers(forWindow: w.windowUID) }
        }
    }

    private func handleHello(_ hello: Hello) {
        peerCapabilities = hello.capabilities
        // 已有活动会话时收到新的 Hello ⇒ 这是一次重连
        let isRehandshake = (session.phase == .active || session.phase == .degraded)
        let previousEpoch = session.epoch
        if isRehandshake {
            session.reconnectSucceeded()          // 推进 Host 侧 epoch
            bus.setEpoch(session.epoch)
            reestablish()
            localNotices.append(Notice(severity: .info, scope: .media,
                                  title: "会话已重连", detail: "已重建窗口注册表并要求关键帧",
                                  code: "media.reconnected"))
        }
        let accepted = advertisedCapabilities()
        let effective = accepted.intersected(with: hello.capabilities)
        // 用**旧 epoch** 回复，否则 Viewer 会把它当作过期消息丢弃而永远无法采纳新 epoch
        bus.send(HelloAck(deviceID: hostDeviceID, nonce: hello.nonce,
                          epoch: session.epoch,
                          acceptedCapabilities: effective),
                 type: .helloAck, epoch: previousEpoch)
        session.activate(degraded: capabilityReport.textMode != .fullLocalIME)
        // 立刻推送全量窗口状态
        publishSnapshot(force: true, now: lastTickTime)
    }

    private func handleResize(_ req: WindowResizeRequest) {
        // 只处理最新请求（规格 §1.2 规则 3）
        if let last = lastResizeSeq[req.windowUID], req.requestSeq < last {
            coalescedResizeDropped += 1
            return
        }
        lastResizeSeq[req.windowUID] = req.requestSeq
        let clamped = registry.clampForApp(req.windowUID, requested: req.requestedContentSize)
        let applied = windowProvider.applySize(req.windowUID, requested: clamped.0)
        let result = registry.applyResize(uid: req.windowUID, requested: req.requestedContentSize) { _, _ in
            (applied.actual, applied.constrainedBy == .none ? clamped.1 : applied.constrainedBy)
        }
        resizeRequestsApplied += 1
        if let result {
            bus.send(WindowResizeResult(requestSeq: req.requestSeq,
                                        actualContentSize: result.actualContentSize,
                                        layoutVersion: registry.layoutVersion,
                                        constrainedBy: result.constrainedBy), type: .windowResizeResult)
        }
        // 尺寸变化立即刷新窗口状态与流信息
        publishDelta(force: true)
        let uid = req.windowUID
        if var info = registry.window(uid), var stream = streams[uid] {
            stream.contentSizePx = info.captureSize
            stream.layoutVersion = registry.layoutVersion
            streams[uid] = stream
            bus.send(stream, type: .streamInfo)
            keyframeRequests.insert(uid)
        }
    }

    private func handleWindowAction(_ act: WindowAction) {
        if act.action == .activate {
            _ = windowProvider.activate(act.windowUID)
        } else {
            _ = windowProvider.perform(act.action, on: act.windowUID)
        }
        publishDelta(force: true)
        // 焦点变化会改变编辑上下文，必须立刻让 Viewer 拿到新的
        forcePublishTextContext()
    }

    private func handleStreamAdjust(_ a: StreamAdjustRequest) {
        guard var stream = streams[a.streamID] else { return }
        if let fps = a.fpsMax { stream.targetFPS = fps }
        streams[a.streamID] = stream
        keyframeRequests.insert(a.streamID)
        bus.send(stream, type: .streamInfo)
    }

    // MARK: 定时驱动

    /// 由外部时钟驱动。`now` 必须与传输层时钟一致。
    public func tick(now: TimeInterval) {
        lastTickTime = now
        publishDelta(force: false)
        publishTextContext()
        // 周期性重发全量窗口快照。
        //
        // 只在握手时发一次快照是不够的：快照可能丢失，对端也可能在快照之后才完成接入，
        // 此时又没有任何窗口变化来触发增量，于是接收端会长时间停在"一个窗口都没有"。
        // 周期重发让状态收敛不再依赖"握手与快照恰好配对成功"。
        if now - lastSnapshotAt >= snapshotRefreshInterval {
            lastSnapshotAt = now
            publishSnapshot(force: true, now: now)
        }
        pumpCapture(now: now)
    }

    /// 全量快照的重发间隔。几百字节的状态消息，代价可以忽略。
    public var snapshotRefreshInterval: TimeInterval = 3.0
    private var lastSnapshotAt: TimeInterval = 0

    /// 周期性重估文本输入能力，并在变化时更新能力上报。
    ///
    /// 为什么不能只在启动时算一次：插入点读取能力取决于**读取时刻**的焦点状态。
    /// 主机启动时目标应用可能还没被激活/聚焦，此时算出的能力是"降级"，
    /// 但用户真正使用时会话已经就绪、插入点其实可用。
    /// 沿用启动时的结论会让界面长期显示错误的降级提示（或反过来谎报可用）。
    public func refreshTextCapability(probe: () -> CapabilityReport.TextAccessMode) {
        let mode = probe()
        guard mode != capabilityReport.textMode else { return }
        let previous = capabilityReport.textMode
        capabilityReport.textMode = mode
        localNotices.removeAll { $0.code == "text.capabilityChanged" }
        localNotices.append(Notice(severity: mode.meetsCertifiedBar ? .info : .warning,
                                   scope: .text,
                                   title: "输入法能力已更新",
                                   detail: "§\(previous.localizedDescription) → \(mode.localizedDescription)",
                                   code: "text.capabilityChanged"))
        // 把更新后的能力发给 Viewer：能力只在握手时下发过一次，
        // 若不在运行时补发，Viewer 会一直显示过期（通常是错误的降级）状态。
        bus.send(advertisedCapabilities(), type: .capabilityUpdate)
        publishSnapshot(force: true, now: lastTickTime)
    }

    /// 当前面向应用的输入模式（随能力变化）。
    public var currentInputMode: InputMode { inputModeForCurrentCapability }

    /// 更新某窗口流的**采集像素尺寸**。
    ///
    /// 只更新媒体侧事实（编码像素量 / 发送端几何），不触碰窗口逻辑尺寸，
    /// 因此不会引起 layoutVersion 抖动。
    public func noteCapturePixelSize(windowUID: String, size: Size) {
        guard var stream = streams[windowUID] else { return }
        guard stream.contentSizePx != size else { return }
        stream.contentSizePx = size
        streams[windowUID] = stream
        bus.send(stream, type: .streamInfo)
    }

    /// 强制重发编辑上下文（响应 Viewer 的请求，或焦点变化时）。
    public func forcePublishTextContext() {
        lastPublishedEditVersion = .max
        lastPublishedNodeID = ""
        lastPublishedWindowUID = ""
        publishTextContext()
    }

    /// 编辑上下文变化时推送给 Viewer。
    ///
    /// 只在 `editVersion`/控件/窗口变化时发送，避免状态通道被周期性消息淹没；
    /// Viewer 需要主动刷新时走 `textContextRequest`。
    public func publishTextContext() {
        guard let provider = textProvider, let ctx = provider.currentContext() else { return }
        guard ctx.editVersion != lastPublishedEditVersion
            || ctx.nodeID != lastPublishedNodeID
            || ctx.windowUID != lastPublishedWindowUID else { return }
        lastPublishedEditVersion = ctx.editVersion
        lastPublishedNodeID = ctx.nodeID
        lastPublishedWindowUID = ctx.windowUID
        bus.send(ctx, type: .textContext)
    }

    private func pumpCapture(now: TimeInterval) {
        guard session.phase == .active || session.phase == .degraded else { return }
        guard !streams.isEmpty else { return }
        let frames = registry.allWindows
        for info in frames {
            guard let source = captureSources[info.windowUID] else { continue }
            guard var stream = streams[info.windowUID] else { continue }
            if info.minimized {
                bus.send(StreamState(streamID: stream.streamID, state: .windowMinimized), type: .streamState)
                continue
            }
            source.setLayoutVersion(registry.layoutVersion)
            guard let captured = source.nextFrame(now: now) else {
                framesSkippedNoChange += 1
                continue
            }
            // 帧率控制
            let minInterval = 1.0 / Double(max(1, stream.targetFPS))
            if now - lastFrameTime < minInterval { continue }
            // 仅丢弃"尚未编码"的帧（这是允许的方向）
            encoderQueue.enqueue(captured)
            let needKey = keyframeRequests.contains(stream.streamID) || keyframeRequests.contains("*")
            // 预算是"编码后字节数"的预算，必须用自适应估算，而不是原始像素量
            let estimated = bitrate.estimatedBytes(streamID: stream.streamID,
                                                   rawBytes: captured.pixels.count)
            guard bitrate.allow(estimatedBytes: estimated, now: now, forceKeyframe: needKey) else {
                framesSkippedForBudget += 1
                continue
            }
            guard let encoded = encoderQueue.encodeOne(with: encoder, forceKeyframe: needKey) else { continue }
            bitrate.observe(streamID: stream.streamID, encodedBytes: encoded.byteCount)
            if needKey {
                keyframeRequests.remove(stream.streamID)
                if keyframeRequests.contains("*") && !streams.keys.contains(where: { keyframeRequests.contains($0) }) {
                    keyframeRequests.remove("*")
                }
            }
            lastFrameTime = now
            var wireFrame = encoded
            // 分辨率降级（P10 最后一级）：仅在请求时生效，已由 stream.targetFPS 之外控制
            if stream.contentSizePx != encoded.size {
                stream.contentSizePx = encoded.size
                streams[info.windowUID] = stream
                bus.send(stream, type: .streamInfo)
            }
            wireFrame.streamID = stream.streamID
            wireFrame.layoutVersion = registry.layoutVersion
            let wire = MediaFrameWire(wireFrame)
            bus.sendRaw(wire.encoded(), channel: .media)
            framesSent += 1
        }
    }

    private var lastPublishedLayout: UInt64 = .max
    private var lastPublishedEditVersion: UInt64 = .max
    private var lastPublishedNodeID: String = ""
    private var lastPublishedWindowUID: String = ""

    /// 发布窗口状态。`force` 为 true 时无条件发送增量。
    public func publishDelta(force: Bool) {
        guard session.phase == .active || session.phase == .degraded else { return }
        let current = windowProvider.currentWindows()
        var dict: [String: WindowInfo] = [:]
        for w in current { dict[w.windowUID] = w }
        if !force && dict == lastSnapshotWindows && registry.layoutVersion == lastPublishedLayout { return }

        var added: [WindowInfo] = []
        var changed: [WindowInfo] = []
        var removed: [String] = []
        for w in current {
            if let old = lastSnapshotWindows[w.windowUID] {
                if old != w { changed.append(w) }
            } else {
                added.append(w)
            }
        }
        for uid in lastSnapshotWindows.keys where dict[uid] == nil { removed.append(uid) }

        if added.isEmpty && changed.isEmpty && removed.isEmpty && !force { return }
        lastSnapshotWindows = dict
        lastPublishedLayout = registry.layoutVersion

        for w in current {
            registry.upsert(w)
            // 为新窗口建立流
            if streams[w.windowUID] == nil, w.role.requiresLocalShell {
                let streamID = "stream:\(w.windowUID)"
                let stream = StreamInfo(streamID: streamID, windowUID: w.windowUID,
                                        layoutVersion: registry.layoutVersion,
                                        contentSizePx: w.captureSize, contentScale: w.contentScale,
                                        codec: encoder.codec, targetFPS: UInt8(targetFPS),
                                        isStatic: false)
                streams[w.windowUID] = stream
                bus.send(stream, type: .streamInfo)
                keyframeRequests.insert(streamID)
            }
        }
        for uid in removed { streams[uid] = nil }

        bus.send(WindowDelta(epoch: session.epoch, layoutVersion: registry.layoutVersion,
                             added: added, removed: removed, changed: changed), type: .windowDelta)
        sentWindowStateAt = 0
    }

    /// 重连：重建注册表、清空流、请求关键帧（规格 §5.2）。
    public func reestablish() {
        registry.reset(epoch: session.epoch)
        streams.removeAll()
        keyframeRequests = ["*"]
        lastSnapshotWindows.removeAll()
        lastPublishedLayout = .max
        lastPublishedEditVersion = .max
        encoderQueueReset()
        publishSnapshot(force: true, now: 0)
        publishTextContext()
    }

    private func encoderQueueReset() {
        // 丢弃所有未编码与已编码帧，避免重放旧画面
        while encoderQueue.dequeueEncoded() != nil {}
    }

    public func publishSnapshot(force: Bool, now: TimeInterval) {
        guard force || session.phase == .active else { return }
        let wins = windowProvider.currentWindows()
        for w in wins { registry.upsert(w) }
        bus.send(WindowSnapshot(epoch: session.epoch, layoutVersion: registry.layoutVersion, windows: wins),
                 type: .windowSnapshot)
        lastSnapshotAt = lastTickTime
        var dict: [String: WindowInfo] = [:]
        for w in wins { dict[w.windowUID] = w }
        lastSnapshotWindows = dict
        // 幂等重发已有流的描述。
        //
        // StreamInfo 只发一次是不够的：丢一次（或对端在发送之后才接入）之后，
        // 接收端永远不知道该流属于哪个窗口，于是**静默丢弃该窗口的全部画面**，
        // 表现为"主机一直在发帧、本地一帧都没有"。周期性重发让状态自愈。
        for (_, stream) in streams {
            bus.send(stream, type: .streamInfo)
        }
        for w in wins where streams[w.windowUID] == nil && w.role.requiresLocalShell {
            let streamID = "stream:\(w.windowUID)"
            let stream = StreamInfo(streamID: streamID, windowUID: w.windowUID,
                                    layoutVersion: registry.layoutVersion,
                                    contentSizePx: w.captureSize, contentScale: w.contentScale,
                                    codec: encoder.codec, targetFPS: UInt8(targetFPS))
            streams[w.windowUID] = stream
            bus.send(stream, type: .streamInfo)
            keyframeRequests.insert(streamID)
        }
        _ = now
    }

    /// 本机当前对外声明的能力（握手与运行时更新共用同一份逻辑）。
    public func advertisedCapabilities() -> Capabilities {
        Capabilities(
            media: MediaCapabilities(codecs: [encoder.codec], maxFPS: UInt8(targetFPS), hardwareEncode: false),
            text: capabilityReport.textCapabilities,
            adapters: ["generic-macos", "synthetic"],
            apps: [AppCapability(bundleID: appBundleID, displayName: appDisplayName,
                                 certified: capabilityReport.textMode.meetsCertifiedBar,
                                 inputMode: inputModeForCurrentCapability,
                                 degradationReason: capabilityReport.textMode.meetsCertifiedBar
                                    ? nil
                                    : capabilityReport.textMode.degradationExplanation)]
        )
    }

    public var appBundleID: String {
        let id = windowProvider.appBundleID
        return id.isEmpty ? "unknown.bundle" : id
    }
    public var appDisplayName: String {
        let name = windowProvider.appDisplayName
        return name.isEmpty ? "目标应用" : name
    }
    public var inputModeForCurrentCapability: InputMode {
        switch capabilityReport.textMode {
        case .fullLocalIME: return .localIME
        case .degradedCaret: return .directText
        case .remoteIMEOnly: return .remoteIME
        case .unavailable: return .none
        }
    }
    public var hostDeviceID: String = "host-\(UUID().uuidString.prefix(8))"
}
