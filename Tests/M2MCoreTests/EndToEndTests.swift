import XCTest
@testable import M2MCore

/// 单机端到端测试台：Viewer(endpointA) ↔ SimulatedNetwork ↔ Host(endpointB)。
///
/// 三端全部在同一进程内，但每条链路都经过真实的协议编解码、通道调度与时钟推进，
/// 因此能验证顺序、去重、弱网与恢复语义，而不依赖任何系统权限。
final class LoopbackHarness {
    let net: SimulatedNetwork
    let viewerBus: MessageBus
    let hostBus: MessageBus
    let host: HostRuntime
    let viewer: ViewerRuntime
    let model: SyntheticAppModel
    let hostSession: Session
    let viewerSession: Session
    let sink: SyntheticInputSink
    let textProvider: SyntheticTextContextProvider
    let hostTempDir: URL
    let viewerTempDir: URL

    init(conditions: LinkConditions = .lan,
         seed: UInt64 = 0xC0FFEE,
         capabilityReport: CapabilityReport? = nil,
         model: SyntheticAppModel? = nil,
         encoder: FrameEncoder = ScreenRLEEncoder(),
         decoder: FrameDecoder = ScreenRLEDecoder()) {
        net = SimulatedNetwork(conditions: conditions, seed: seed)
        let m = model ?? SyntheticAppModel()
        self.model = m

        hostTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m2m-host-\(UUID().uuidString.prefix(8))")
        viewerTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m2m-viewer-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: hostTempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: viewerTempDir, withIntermediateDirectories: true)

        hostSession = Session(epoch: 1)
        viewerSession = Session(epoch: 1)
        hostBus = MessageBus(epoch: 1)
        viewerBus = MessageBus(epoch: 1)
        hostBus.attach(net.endpointB)
        viewerBus.attach(net.endpointA)
        net.endpointA.start()
        net.endpointB.start()

        let sink = SyntheticInputSink(model: m)
        self.sink = sink
        let provider = SyntheticTextContextProvider(model: m, epoch: 1)
        self.textProvider = provider

        // 为每个窗口建立合成采集源
        var sources: [String: CaptureSource] = [:]
        for w in m.allWindows where w.role.requiresLocalShell {
            sources[w.uid] = SyntheticCaptureSource(streamID: "stream:\(w.uid)",
                                                    size: w.contentSize,
                                                    content: w.content)
        }

        let report = capabilityReport ?? CapabilityReport(
            screenRecording: .notRequired, accessibility: .notRequired,
            inputMonitoring: .notRequired, captureMode: .synthetic,
            inputMode: .recorded, textMode: .fullLocalIME)

        host = HostRuntime(bus: hostBus, session: hostSession, windowProvider: SyntheticWindowProvider(model: m),
                           inputSink: sink, captureSources: sources, encoder: encoder,
                           textProvider: provider,
                           fileBridge: FileBridge(remoteTempDirectory: hostTempDir, chunkSize: 32 * 1024,
                                                  rateLimitBytesPerSecond: nil),
                           capabilityReport: report)
        viewer = ViewerRuntime(bus: viewerBus, session: viewerSession, decoder: decoder,
                               fileBridge: FileBridge(remoteTempDirectory: viewerTempDir, chunkSize: 32 * 1024,
                                                      rateLimitBytesPerSecond: 256 * 1024))
    }

    /// 让采集源反映当前模型内容（模型变化后调用）。
    func syncCaptureSources() {
        for w in model.allWindows where w.role.requiresLocalShell {
            if let s = host.captureSources[w.uid] as? SyntheticCaptureSource {
                s.content = w.content
            } else {
                let src = SyntheticCaptureSource(streamID: "stream:\(w.uid)", size: w.contentSize, content: w.content)
                host.captureSources[w.uid] = src
            }
        }
    }

    /// 推进整条链路。
    func run(seconds: TimeInterval, step: TimeInterval = 0.01) {
        let end = net.currentTime + seconds
        while net.currentTime < end {
            net.advance(by: step)
            host.tick(now: net.currentTime)
            viewer.tick(now: net.currentTime)
        }
    }

    /// 握手并等到窗口状态就绪。
    func connect(seconds: TimeInterval = 1.0) {
        viewer.sendHello()
        net.drain()
        run(seconds: seconds)
    }

    var now: TimeInterval { net.currentTime }
    var mainWindowUID: String { model.allWindows.first { $0.role == .main }!.uid }
    var currentEditVersion: UInt64 { textProvider.currentContext()?.editVersion ?? 0 }

    /// 模拟一次真实的中文输入法交互：开始组合 → 更新组合 → 确认选词。
    @discardableResult
    func composeAndCommit(_ text: String, marked: String = "nihao") -> Int {
        let ctx = textProvider.currentContext()
        if let ctx, case .idle(let v) = viewer.textBridge.state, v == ctx.editVersion {
            viewer.textBridge.beginComposition(editVersion: ctx.editVersion)
            viewer.textBridge.updateComposition(marked)
        }
        return viewer.confirmComposition(text, at: now)
    }

    /// 把链路断开并让时间推进，使在途消息全部丢失。
    func cutLink(during seconds: TimeInterval = 0.5) {
        net.setDown(true)
        viewer.transportInterrupted()
        run(seconds: seconds)
    }

    func restoreLink(seconds: TimeInterval = 1.5) {
        net.setDown(false)
        viewer.reconnect()
        net.drain()
        run(seconds: seconds)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: hostTempDir)
        try? FileManager.default.removeItem(at: viewerTempDir)
    }
}

// MARK: - 端到端：连接与窗口

final class EndToEndWindowTests: XCTestCase {

    func testHandshakeDeliversCapabilities() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        XCTAssertEqual(h.viewerSession.phase, .active)
        XCTAssertNotNil(h.viewer.hostCapabilities)
        XCTAssertTrue(h.viewer.hostCapabilities!.text.caretRect, "合成链路应提供插入点能力")
    }

    func testWindowAppearsAsLocalShell() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        XCTAssertGreaterThanOrEqual(h.viewer.windowTable.count, 1)
        let shell = h.viewer.windowTable.shell(h.mainWindowUID)
        XCTAssertNotNil(shell, "远端主窗口必须映射为本地窗口壳")
        XCTAssertEqual(shell?.title, "Demo — 主窗口")
        XCTAssertFalse(shell!.isDegraded)
    }

    func testStreamInfoReceivedAndMapped() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        XCTAssertFalse(h.viewer.streams.isEmpty)
        XCTAssertEqual(h.viewer.streamToWindow["stream:\(h.mainWindowUID)"], h.mainWindowUID)
    }

    func testMissingAccessibilityDoesNotBlockWindowDisplay() {
        // 规格 §7：AX 读取失败不得导致窗口无法显示
        let degraded = CapabilityReport(screenRecording: .denied, accessibility: .denied,
                                        inputMonitoring: .denied, captureMode: .synthetic,
                                        inputMode: .recorded, textMode: .degradedCaret)
        let h = LoopbackHarness(capabilityReport: degraded)
        defer { h.cleanup() }
        h.connect()
        XCTAssertGreaterThanOrEqual(h.viewer.windowTable.count, 1, "AX 不可用也必须能看到窗口")
        XCTAssertEqual(h.viewerSession.phase, .degraded)
    }

    func testOptingANewWindowCreatesShellEndToEnd() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let before = h.viewer.windowTable.count
        let uid = h.model.openSettingsWindow()
        h.syncCaptureSources()
        h.run(seconds: 0.5)
        XCTAssertEqual(h.viewer.windowTable.count, before + 1)
        XCTAssertEqual(h.viewer.windowTable.shell(uid)?.role, .panel)
    }

    func testClosingRemoteWindowClosesLocalShell() {
        // T-WIN-12：不得留下僵尸窗口
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.model.openSettingsWindow()
        h.syncCaptureSources()
        h.run(seconds: 0.5)
        XCTAssertNotNil(h.viewer.windowTable.shell(uid))
        _ = h.host.windowProvider.perform(.close, on: uid)
        h.run(seconds: 0.5)
        XCTAssertNil(h.viewer.windowTable.shell(uid), "远端窗口消失后本地壳必须被关闭")
    }

    func testModalDialogIsRepresentedAsItsOwnShell() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.model.openModalDialog()
        h.syncCaptureSources()
        h.run(seconds: 0.5)
        XCTAssertEqual(h.viewer.windowTable.shell(uid)?.role, .dialog)
        XCTAssertTrue(h.viewer.windowTable.shell(uid)!.modal)
    }

    func testPopupMenuGetsShellAndIsNotTreatedAsDesktop() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.model.openPopupMenu()
        h.syncCaptureSources()
        h.run(seconds: 0.5)
        XCTAssertEqual(h.viewer.windowTable.shell(uid)?.role, .popupMenu)
        // 关键：不得因为出现未识别/特殊窗口就退化为共享整个远端桌面
        XCTAssertEqual(h.viewer.windowTable.count, h.model.allWindows.filter { $0.role.requiresLocalShell }.count)
    }

    func testMinimizedWindowPausesStream() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        _ = h.host.windowProvider.perform(.minimize, on: h.mainWindowUID)
        h.run(seconds: 0.5)
        XCTAssertTrue(h.viewer.notices.contains { $0.title == "画面暂停" })
    }
}

// MARK: - 端到端：媒体

final class EndToEndMediaTests: XCTestCase {

    func testFramesArriveAndPixelsMatchHostCapture() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.run(seconds: 1.0)
        XCTAssertGreaterThan(h.viewer.framesReceived, 0, "必须收到画面帧")
        let decoded = h.viewer.decodedFrames[h.mainWindowUID]
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.size, Size(560, 380))
    }

    func testFramePixelChecksumMatchesEncoderOutput() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.run(seconds: 1.0)
        guard let decoded = h.viewer.decodedFrames[h.mainWindowUID] else { return XCTFail("没有解码帧") }
        // 采样：直接用相同渲染参数重算，验证端到端像素无损
        let expected = SyntheticRenderer.render(h.model.focusableWindow!.content, size: Size(560, 380))
        var checksum: UInt64 = 0xcbf29ce484222325
        for b in expected { checksum = (checksum ^ UInt64(b)) &* 0x100000001b3 }
        XCTAssertEqual(decoded.pixelChecksum, checksum, "端到端像素必须与远端渲染一致")
    }

    func testTextChangePropagatesToViewerPixels() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.run(seconds: 0.5)
        let before = h.viewer.decodedFrames[h.mainWindowUID]?.pixelChecksum
        h.model.textBuffer = "在远端输入的文字"
        h.model.caretOffset = 8
        h.model.updateContent(h.mainWindowUID) { _ in }
        h.syncCaptureSources()
        h.run(seconds: 1.0)
        let after = h.viewer.decodedFrames[h.mainWindowUID]?.pixelChecksum
        XCTAssertNotEqual(before, after, "远端内容变化必须反映到本地画面")
    }

    func testFrameWithStaleLayoutVersionIsDropped() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.run(seconds: 0.5)
        let before = h.viewer.framesReceived
        // 手工注入一个旧版本帧
        let stale = MediaFrameWire(codec: .rawBGRA, isKeyframe: true, layoutVersion: 0,
                                   frameIndex: 1, width: 8, height: 8, pixelChecksum: 1,
                                   streamID: "stream:\(h.mainWindowUID)", payload: Data(repeating: 0, count: 256))
        h.net.endpointB.channel(.media).send(stale.encoded())
        h.net.drain()
        XCTAssertEqual(h.viewer.framesReceived, before, "旧版本帧不得被显示")
        XCTAssertGreaterThan(h.viewer.framesDroppedStale, 0)
    }

    func testHeavyLossStillDeliversFramesAfterKeyframeRequest() {
        var conditions = LinkConditions.rtt(80)
        conditions.lossRate = 0.3
        let h = LoopbackHarness(conditions: conditions)
        defer { h.cleanup() }
        h.connect(seconds: 1.0)
        h.run(seconds: 2.0)
        XCTAssertGreaterThan(h.viewer.framesReceived, 0, "有丢包时仍应能收到画面（关键帧机制）")
    }
}

// MARK: - 端到端：缩放

final class EndToEndResizeTests: XCTestCase {

    func testResizeRoundTripUpdatesRemoteAndLocalSize() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.mainWindowUID
        h.viewer.beginResize(windowUID: uid, requested: Size(800, 600))
        h.viewer.endResize(windowUID: uid, finalSize: Size(800, 600))
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.windows[uid]?.contentSize, Size(800, 600), "远端窗口尺寸必须改变")
        XCTAssertEqual(h.viewer.windowTable.shell(uid)?.remoteContentSize, Size(800, 600))
        XCTAssertEqual(h.viewer.windowTable.shell(uid)?.localContentSize, Size(800, 600))
    }

    func testResizeBelowAppMinimumIsConstrainedAndReported() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.mainWindowUID
        h.viewer.beginResize(windowUID: uid, requested: Size(100, 80))
        h.viewer.endResize(windowUID: uid, finalSize: Size(100, 80))
        h.run(seconds: 0.5)
        // 应用最小值是 320x200
        XCTAssertEqual(h.model.windows[uid]?.contentSize, Size(320, 200), "必须接受应用约束")
        XCTAssertTrue(h.viewer.notices.contains { $0.title == "尺寸受应用限制" },
                      "被约束时必须给出可见提示")
    }

    func testNonResizableWindowRejectsResize() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.model.openModalDialog()   // 不可缩放
        h.syncCaptureSources()
        h.run(seconds: 0.5)
        let original = h.model.windows[uid]?.contentSize
        h.viewer.beginResize(windowUID: uid, requested: Size(800, 800))
        h.viewer.endResize(windowUID: uid, finalSize: Size(800, 800))
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.windows[uid]?.contentSize, original, "不可缩放窗口的尺寸不得改变")
    }

    func testRapidResizeIsCoalescedNotStorm() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.mainWindowUID
        // 模拟拖动：每 5ms 一次，共 40 次
        for i in 0..<40 {
            h.viewer.beginResize(windowUID: uid, requested: Size(600 + Double(i), 500))
            h.run(seconds: 0.005, step: 0.005)
        }
        h.viewer.endResize(windowUID: uid, finalSize: Size(640, 500))
        h.run(seconds: 0.5)
        let sent = h.host.resizeRequestsApplied
        XCTAssertLessThan(sent, 40, "拖动风暴必须被合并（实际远端处理 \(sent) 次）")
        XCTAssertEqual(h.model.windows[uid]?.contentSize, Size(640, 500), "最终尺寸必须生效")
    }

    func testLayoutVersionAdvancesWithResize() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let uid = h.mainWindowUID
        let before = h.viewer.layoutVersion
        h.viewer.endResize(windowUID: uid, finalSize: Size(700, 520))
        h.run(seconds: 0.5)
        XCTAssertGreaterThan(h.viewer.layoutVersion, before)
        // 本地壳版本必须与最新布局版本一致，否则会显示错区域
        XCTAssertEqual(h.viewer.windowTable.shell(uid)?.layoutVersion, h.viewer.layoutVersion)
    }
}

// MARK: - 端到端：中文输入

/// 对应 04-text-input.md §7 的 T-CN-01…16 在真实协议链路上的可执行形式。
final class EndToEndTextTests: XCTestCase {

    func testTextCommitReachesHostModel() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        XCTAssertEqual(h.model.textBuffer, "")
        h.composeAndCommit("你好")
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.textBuffer, "你好", "文字必须真正出现在远端")
    }

    func testContextIsPublishedToViewer() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        XCTAssertNotNil(h.viewer.textBridge.context, "Viewer 必须拿到远端编辑上下文")
        if case .idle = h.viewer.textBridge.state { } else {
            XCTFail("有上下文后应进入 idle，实际 \(h.viewer.textBridge.state)")
        }
    }

    /// T-CN-06：**最高优先级**。组合中的 Enter 绝不能变成"发送"。
    func testEnterDuringCompositionNeverReachesHost() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let ctx = h.textProvider.currentContext()!
        h.viewer.textBridge.beginComposition(editVersion: ctx.editVersion)
        h.viewer.textBridge.updateComposition("nihao")

        // 情况 1：输入法报告已消费
        let r1 = h.viewer.routeAndSendKey(keycode: KeyCode.returnKey, kind: .keyDown,
                                          flags: [], unicode: nil, imeConsumed: true)
        // 情况 2：输入法报告未消费（异常路径），闸门仍须拦截
        let r2 = h.viewer.routeAndSendKey(keycode: KeyCode.returnKey, kind: .keyDown,
                                          flags: [], unicode: nil, imeConsumed: false)
        h.run(seconds: 0.3)

        if case .heldForIME = r1 { } else { XCTFail("情况 1 应留在本地，实际 \(r1)") }
        if case .heldForIME = r2 { } else { XCTFail("情况 2 应留在本地，实际 \(r2)") }
        XCTAssertTrue(h.sink.deliveredKeys.isEmpty, "组合中的 Enter 绝不能作为按键送到远端")
        XCTAssertEqual(h.model.textBuffer, "", "更不得触发远端发送动作")
    }

    func testDigitsAndArrowsDuringCompositionNeverReachHost() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let ctx = h.textProvider.currentContext()!
        h.viewer.textBridge.beginComposition(editVersion: ctx.editVersion)
        h.viewer.textBridge.updateComposition("ni")
        for key in [KeyCode.digits.first!, KeyCode.leftArrow, KeyCode.space, KeyCode.delete] {
            _ = h.viewer.routeAndSendKey(keycode: key, kind: .keyDown, flags: [],
                                        unicode: nil, imeConsumed: false)
        }
        h.run(seconds: 0.3)
        XCTAssertTrue(h.sink.deliveredKeys.isEmpty, "选词相关按键不得外发")
        XCTAssertEqual(h.model.textBuffer, "")
    }

    /// T-CN-12：组合中切换窗口，绝不能让未确认的拼音落到任何控件。
    func testCompositionDiscardedWhenFocusMovesToAnotherWindow() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let settings = h.model.openSettingsWindow()
        h.syncCaptureSources()
        h.run(seconds: 0.5)

        let ctx = h.textProvider.currentContext()!
        h.viewer.textBridge.beginComposition(editVersion: ctx.editVersion)
        h.viewer.textBridge.updateComposition("nihao")
        _ = h.viewer.textBridge.takeEffects()

        // 用户点了另一个窗口
        h.viewer.focus(windowUID: settings)
        h.run(seconds: 0.5)

        XCTAssertEqual(h.model.textBuffer, "", "未确认的组合文本绝不能被提交")
        if case .noContext = h.viewer.textBridge.state { } else if case .idle = h.viewer.textBridge.state { } else {
            XCTFail("焦点变化后应丢弃组合，实际 \(h.viewer.textBridge.state)")
        }
        // 运行时会在 tick 中取走文本桥的副作用（并发出上下文刷新请求），
        // 面向 UI 的那部分由 takeUIEffects 暴露。
        let uiEffects = h.viewer.takeUIEffects()
        XCTAssertTrue(uiEffects.contains {
            if case .clearCompositionDisplay = $0 { return true }; return false
        } || uiEffects.contains {
            if case .showNotice(let n) = $0 { return n.contains("丢弃") || n.contains("已取消") }
            return false
        }, "焦点变化时必须清空组合显示，实际副作用：\(uiEffects)")
    }

    /// T-CN-09：选区替换必须保留前后文本。
    func testSelectionReplacementPreservesSurroundingText() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.model.textBuffer = "abcdef"
        h.model.caretOffset = 2
        h.model.selectionLength = 2
        h.textProvider.bumpVersion()
        h.run(seconds: 0.5)

        h.composeAndCommit("XY", marked: "xuan")
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.textBuffer, "abXYef")
    }

    /// T-CN-10：换行提交不得被当成"发送"以外的其他语义。
    func testNewlineCommit() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.composeAndCommit("第一行")
        h.run(seconds: 0.3)
        let v = h.textProvider.currentContext()!.editVersion
        h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
        _ = h.viewer.textBridge.confirmComposition("\n", intent: .newline)
        h.viewer.flushOutgoingCommits(at: h.now)
        h.run(seconds: 0.3)
        XCTAssertEqual(h.model.textBuffer, "第一行\n")
        _ = v
    }

    /// T-CN-15：结果不明后重连，**不得出现重复文字**。
    func testCommitInFlightDuringDisconnectDoesNotDuplicateAfterReconnect() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.composeAndCommit("你好")
        h.run(seconds: 0.3)
        XCTAssertEqual(h.model.textBuffer, "你好")

        // 再输入一条，但在它被确认前断链
        h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
        h.viewer.textBridge.commitTimeout = 0.2
        let sent = h.composeAndCommit("世界")
        XCTAssertEqual(sent, 1, "应发出第二条提交")
        h.net.setDown(true)
        h.viewer.transportInterrupted()
        h.run(seconds: 0.6)   // 超时 → pendingUnknown

        if case .pendingUnknown = h.viewer.textBridge.state { } else {
            XCTFail("断链后应进入 pendingUnknown，实际 \(h.viewer.textBridge.state)")
        }
        XCTAssertEqual(h.model.textBuffer, "你好", "未送达的提交不得生效")

        h.restoreLink()
        // 关键断言：重连后**不得自动补发**，远端不得出现重复
        XCTAssertFalse(h.model.textBuffer.contains("世界"), "结果不明的提交绝不能被自动重试")
        XCTAssertEqual(h.model.textBuffer.components(separatedBy: "你好").count - 1, 1,
                       "已成功的文字不得重复")
    }

    /// T-CN-15 的另一面：结果不明后由用户重新提交，只应生效一次。
    func testUserResubmissionAfterUnknownAppliesExactlyOnce() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.viewer.textBridge.commitTimeout = 0.1
        h.composeAndCommit("你好")
        h.net.setDown(true)
        h.viewer.transportInterrupted()
        h.run(seconds: 0.4)
        XCTAssertEqual(h.model.textBuffer, "", "断链期间的提交不得到达")

        h.restoreLink()
        h.run(seconds: 0.5)
        // 用户看到"未确认"，重新输入
        h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
        h.composeAndCommit("你好")
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.textBuffer, "你好")
        XCTAssertEqual(h.model.textBuffer.count, 2, "重发后也只能有一份文字")
    }

    /// 版本过期必须被拒绝，且不得写入任何内容。
    func testStaleCommitIsRejectedEndToEnd() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        // 用错误的 editVersion 直接构造提交
        let ctx = h.textProvider.currentContext()!
        let stale = TextCommit(epoch: h.viewerSession.epoch, windowUID: ctx.windowUID,
                               nodeID: ctx.nodeID, editVersion: ctx.editVersion &+ 99,
                               commitSeq: 999, text: "不该出现", fromLocalMarked: true,
                               intent: .insertText)
        h.viewerBus.send(stale, type: .textCommit)
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.textBuffer, "", "版本不匹配的提交必须被拒绝")
        XCTAssertTrue(h.viewer.commitResults.contains { $0.status == .rejectedStale })
    }

    /// 幂等：同一条提交被重传两次，只生效一次。
    func testDuplicateCommitOverTheWireAppliesOnce() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let ctx = h.textProvider.currentContext()!
        let commit = TextCommit(epoch: h.viewerSession.epoch, windowUID: ctx.windowUID,
                                nodeID: ctx.nodeID, editVersion: ctx.editVersion,
                                commitSeq: 42, text: "唯一", fromLocalMarked: true,
                                intent: .insertText)
        // 用不同 msgID 发两次（模拟传输层重传而应用层去重失效的情况）
        h.viewerBus.send(commit, type: .textCommit)
        h.viewerBus.send(commit, type: .textCommit)
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.textBuffer, "唯一", "同一 commitSeq 只应生效一次")
    }

    /// 连续输入多条：顺序与内容都必须正确。
    func testSequentialCommitsAccumulateInOrder() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        for s in ["第一", "第二", "第三"] {
            h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
            h.composeAndCommit(s)
            h.run(seconds: 0.3)
        }
        XCTAssertEqual(h.model.textBuffer, "第一第二第三")
    }

    /// 中英混输。
    func testMixedChineseAndEnglishInput() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        for s in ["你好", "hello", "世界", "2026"] {
            h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
            h.composeAndCommit(s)
            h.run(seconds: 0.3)
        }
        XCTAssertEqual(h.model.textBuffer, "你好hello世界2026")
    }

    /// 长文本提交不得截断、不得乱序。
    func testLongTextCommitIsNotTruncatedOverTheWire() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let long = String(repeating: "长文本压力测试。", count: 300)
        h.composeAndCommit(long, marked: "chang")
        h.run(seconds: 1.0)
        XCTAssertEqual(h.model.textBuffer.count, long.count)
        XCTAssertEqual(h.model.textBuffer, long)
    }

    /// 快捷键必须送到远端（与输入法路径区分开）。
    func testCommandShortcutReachesHost() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.viewer.focus(windowUID: h.mainWindowUID)
        h.run(seconds: 0.3)
        let disp = h.viewer.routeAndSendKey(keycode: 8, kind: .keyDown,
                                            flags: [.command], unicode: nil, imeConsumed: false)
        h.run(seconds: 0.3)
        if case .sent(let e) = disp {
            XCTAssertEqual(e.category, .shortcut)
            XCTAssertTrue(e.flags & ModifierFlags.command.rawValue != 0)
        } else {
            XCTFail("快捷键应被发往远端，实际 \(disp)")
        }
        XCTAssertTrue(h.sink.deliveredKeys.contains { $0.category == .shortcut })
    }

    /// 无焦点窗口时不得向远端发输入。
    func testInputWithoutTargetWindowIsRejected() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        // 从未设置目标窗口
        let disp = h.viewer.routeAndSendKey(keycode: 8, kind: .keyDown,
                                            flags: [.command], unicode: nil, imeConsumed: false)
        if case .rejected = disp { } else { XCTFail("没有目标窗口时必须拒绝，实际 \(disp)") }
        h.run(seconds: 0.2)
        XCTAssertTrue(h.sink.deliveredKeys.isEmpty)
    }

    /// 降级能力必须在 Viewer 侧产生可见提示，且不得被标记为认证通过。
    func testDegradedCaretCapabilityProducesNoticeAndBlocksCertification() {
        let degraded = CapabilityReport(screenRecording: .granted, accessibility: .granted,
                                        inputMonitoring: .notRequired, captureMode: .realWindowCapture,
                                        inputMode: .realEventInjection, textMode: .degradedCaret)
        let h = LoopbackHarness(capabilityReport: degraded)
        defer { h.cleanup() }
        h.connect()
        XCTAssertFalse(h.viewer.hostCapabilities!.apps.first!.certified)
        XCTAssertTrue(h.viewer.notices.contains { $0.title == "Demo App 处于降级模式" || $0.title.contains("降级") },
                      "降级必须有可见提示，不得静默")
    }
}
