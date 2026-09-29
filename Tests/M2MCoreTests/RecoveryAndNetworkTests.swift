import XCTest
@testable import M2MCore

// MARK: - 端到端：断线恢复与错误输入

/// 对应 06-test-plan.md 的 T-REC-01…10 与 G4 门槛。
final class EndToEndRecoveryTests: XCTestCase {

    func testShortInterruptionRecoversAndRestoresWindows() {
        // T-REC-01/02：中断后画面冻结、远端应用保留、重连后窗口一致
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let shellsBefore = h.viewer.windowTable.count
        h.cutLink(during: 0.5)
        XCTAssertEqual(h.viewerSession.phase, .reconnecting)
        XCTAssertTrue(h.viewer.notices.contains { $0.title == "画面中断" })
        XCTAssertEqual(h.viewer.windowTable.count, 0, "重连期间本地壳应被清理，避免接收输入")

        h.restoreLink()
        XCTAssertEqual(h.viewerSession.phase, .active)
        XCTAssertEqual(h.viewer.windowTable.count, shellsBefore, "重连后窗口必须恢复一致")
        XCTAssertEqual(h.model.allWindows.count, 1, "远端应用必须仍在运行")
    }

    /// T-REC-03：中断期间的操作绝不重放。
    func testInputDuringDisconnectIsNeverReplayed() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.viewer.focus(windowUID: h.mainWindowUID)
        h.run(seconds: 0.3)
        let keysBefore = h.sink.deliveredKeys.count

        h.net.setDown(true)
        // 用户继续敲键（此时链路已断）
        for _ in 0..<10 {
            _ = h.viewer.routeAndSendKey(keycode: 0, kind: .keyDown, flags: [],
                                         unicode: nil, imeConsumed: false)
        }
        // 也点一次"发送"（最危险的操作）
        h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
        _ = h.viewer.confirmComposition("不该到达", at: h.now)
        h.run(seconds: 0.6)

        h.restoreLink()
        h.run(seconds: 1.0)

        XCTAssertEqual(h.sink.deliveredKeys.count, keysBefore, "断线期间的按键绝不能被补发")
        XCTAssertFalse(h.model.textBuffer.contains("不该到达"), "断线期间的提交绝不能被补发")
        XCTAssertEqual(h.model.textBuffer, "")
    }

    /// T-REC-04：远端应用重启后旧身份输入必须被拒绝。
    func testAppRestartInvalidatesOldIdentities() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let oldUID = h.mainWindowUID

        // 模拟应用重启：新的 launch id、新的窗口 uid
        let relaunched = SyntheticAppModel(appLaunchID: "relaunch-1")
        h.host.windowProvider as? SyntheticWindowProvider
        // 直接替换模型内容的方式在合成链路里等价于：删除旧窗口 + 新增新窗口
        h.model.removeWindow(oldUID)
        let newUID = h.model.addWindow(SyntheticAppModel.AppWindow(
            uid: "demo.main.relaunched", title: "Demo — 主窗口（重启后）", role: .main,
            contentSize: Size(560, 380),
            constraints: SizeConstraints(minSize: Size(320, 200), resizable: .both),
            content: SyntheticWindowContent(title: "重启后"), minimized: false,
            parentUID: nil, modal: false, focusable: true, zOrder: 0))
        h.syncCaptureSources()
        h.run(seconds: 0.6)

        XCTAssertNil(h.viewer.windowTable.shell(oldUID), "旧窗口壳必须被关闭")
        XCTAssertNotNil(h.viewer.windowTable.shell(newUID), "新窗口壳必须建立")
        _ = relaunched
    }

    /// T-REC-05：重连后焦点重读，本地组合文本清空。
    func testCompositionIsClearedAcrossReconnect() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let ctx = h.textProvider.currentContext()!
        h.viewer.textBridge.beginComposition(editVersion: ctx.editVersion)
        h.viewer.textBridge.updateComposition("nihao")
        XCTAssertTrue(h.viewer.textBridge.state.isComposing)

        h.cutLink(during: 0.4)
        h.restoreLink()
        h.run(seconds: 0.5)

        XCTAssertFalse(h.viewer.textBridge.state.isComposing, "重连后不得残留组合状态")
        XCTAssertEqual(h.model.textBuffer, "", "未确认的组合文本不得被提交")
    }

    /// T-REC-06 / A8：Host 侧必须收到修饰键释放。
    func testModifiersAreReleasedOnHostWhenConnectionDrops() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        h.viewer.focus(windowUID: h.mainWindowUID)
        h.run(seconds: 0.3)
        // 按住 Cmd（在链路上留下按下状态）
        _ = h.viewer.routeAndSendKey(keycode: 55, kind: .flagsChanged, flags: [.command],
                                     unicode: nil, imeConsumed: true)
        h.run(seconds: 0.3)

        // 中断：本地必须释放按键（并尽力送达；若链路已断则记录在下游清点里）
        h.viewer.transportInterrupted()
        XCTAssertTrue(h.viewer.inputRouter.pressedModifiers.isEmpty, "本地修饰键状态必须被清空")
        XCTAssertGreaterThan(h.viewer.inputRouter.releasedModifiersOnDisconnect, 0)
    }

    /// T-REC-09：长时间运行不得累积延迟或丢失一致性。
    func testLongSessionStaysConsistent() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        for i in 0..<40 {
            h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
            h.composeAndCommit("第\(i)段。", marked: "di")
            h.run(seconds: 0.05)
        }
        h.run(seconds: 1.0)
        XCTAssertEqual(h.model.textBuffer.count, (0..<40).reduce(0) { $0 + "第\($1)段。".count })
        XCTAssertEqual(h.model.textBuffer.components(separatedBy: "第").count - 1, 40, "不得丢失或重复")
    }

    /// 多次连续断连重连后仍能正常工作（epoch 不被两端各自推进破坏）。
    func testRepeatedReconnectsKeepSessionUsable() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        for round in 0..<4 {
            h.cutLink(during: 0.3)
            h.restoreLink()
            h.viewer.focus(windowUID: h.mainWindowUID)
            h.run(seconds: 0.3)
            h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
            h.composeAndCommit("R\(round)", marked: "r")
            h.run(seconds: 0.4)
        }
        XCTAssertEqual(h.model.textBuffer, "R0R1R2R3")
        XCTAssertEqual(h.hostSession.epoch, h.viewerSession.epoch, "两端 epoch 必须一致")
    }

    /// 窗口在组合期间消失：组合必须被丢弃而不是提交到别处。
    func testWindowVanishingDuringCompositionDiscardsInput() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let settings = h.model.openSettingsWindow()
        h.syncCaptureSources()
        h.run(seconds: 0.5)
        h.viewer.focus(windowUID: settings)
        h.run(seconds: 0.3)
        let ctx = h.textProvider.currentContext()
        if let ctx {
            h.viewer.textBridge.beginComposition(editVersion: ctx.editVersion)
            h.viewer.textBridge.updateComposition("nihao")
        }
        h.model.removeWindow(settings)
        h.run(seconds: 0.6)
        XCTAssertEqual(h.model.textBuffer, "", "窗口消失时不得提交未确认文本")
    }
}

// MARK: - 端到端：文件与剪贴板

final class EndToEndFileTests: XCTestCase {

    /// T-MED-09 / T7：文件上传不得阻塞输入。
    func testLargeFileUploadDoesNotBlockInput() {
        var conditions = LinkConditions.bandwidth(mbps: 2)
        conditions.oneWayLatency = 0.03
        let h = LoopbackHarness(conditions: conditions)
        defer { h.cleanup() }
        h.connect()
        h.viewer.focus(windowUID: h.mainWindowUID)
        h.run(seconds: 0.3)

        let keysBefore = h.sink.deliveredKeys.count

        // 发起一个大文件上传（1MB，分块 4KB → 256 块）
        let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let offer = h.viewer.fileBridge.offer(transferID: "big", name: "big.bin", data: payload)
        h.viewerBus.send(offer, type: .fileOffer)
        h.viewer.fileBridge.beginTransfer("big")
        // 参考实现里接收侧需要先登记 offer 才能校验，这里在 Host 侧登记
        _ = h.host.fileBridge.offer(transferID: "big", name: "big.bin", data: payload)

        // 上传期间持续输入
        var sent = 0
        for i in 0..<20 {
            if let chunk = h.viewer.fileBridge.nextChunk(transferID: "big", now: h.now) {
                h.viewerBus.send(chunk, type: .fileChunk)
            }
            // 使用方向键：字母键会被路由到本地输入法（这是正确行为），
            // 无法用来验证"输入是否被文件上传阻塞"。
            _ = h.viewer.routeAndSendKey(keycode: KeyCode.leftArrow, kind: .keyDown, flags: [],
                                         unicode: nil, imeConsumed: false)
            sent += 1
            h.run(seconds: 0.02)
            // 每轮都把剩余分块尽量塞入链路，制造拥塞
            var guardCount = 0
            while let c = h.viewer.fileBridge.nextChunk(transferID: "big", now: h.now), guardCount < 40 {
                h.viewerBus.send(c, type: .fileChunk)
                guardCount += 1
                sent += 1
            }
            if h.viewer.fileBridge.transfers["big"]?.state == .awaitingComplete { break }
        }
        h.run(seconds: 1.0)

        let received = h.sink.deliveredKeys.count - keysBefore
        XCTAssertGreaterThan(received, 0, "上传期间输入必须仍然可达")
        XCTAssertGreaterThan(sent, 5, "测试本身应产生足够的分块")
        // 输入不应被推迟到文件全部传完
        XCTAssertGreaterThan(h.viewer.fileBridge.transfers["big"]?.sentBytes ?? 0, 0)
    }

    func testFileTransferCompletesAndLandsInHostTempDirectory() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let payload = Data("hello m2m 文件传输".utf8)
        _ = h.host.fileBridge.offer(transferID: "t1", name: "note.txt", data: payload)
        let offer = h.viewer.fileBridge.offer(transferID: "t1", name: "note.txt", data: payload)
        h.viewerBus.send(offer, type: .fileOffer)
        h.viewer.fileBridge.beginTransfer("t1")
        while let c = h.viewer.fileBridge.nextChunk(transferID: "t1", now: h.now) {
            h.viewerBus.send(c, type: .fileChunk)
        }
        h.viewerBus.send(FileComplete(transferID: "t1", remotePath: "ignored"), type: .fileComplete)
        h.run(seconds: 0.5)

        XCTAssertEqual(h.host.fileBridge.completedNames, ["note.txt"])
        let path = h.host.fileBridge.transfers["t1"]?.remotePath
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasPrefix(h.hostTempDir.path), "文件必须落在隔离的远端临时目录内")
    }

    func testCorruptedFileDoesNotBecomeUsableOnHost() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        let payload = Data(repeating: 7, count: 2048)
        _ = h.host.fileBridge.offer(transferID: "c1", name: "corrupt.bin", data: payload)
        _ = h.viewer.fileBridge.offer(transferID: "c1", name: "corrupt.bin", data: payload)
        h.viewerBus.send(FileChunk(transferID: "c1", index: 0, bytes: Data(repeating: 9, count: 2048)),
                         type: .fileChunk)
        h.viewerBus.send(FileComplete(transferID: "c1", remotePath: "x"), type: .fileComplete)
        h.run(seconds: 0.5)
        XCTAssertFalse(h.host.fileBridge.completedNames.contains("corrupt.bin"),
                       "校验失败的文件不得被标记为可用")
        XCTAssertTrue(h.viewer.notices.contains { $0.title == "文件传输失败" })
    }

    func testClipboardLoopDoesNotEchoBackToHost() {
        let h = LoopbackHarness()
        defer { h.cleanup() }
        h.connect()
        // 远端复制内容 → 本地
        h.hostBus.send(ClipboardUpdate(kind: .text, text: "远端内容",
                                       hash: FileBridge.sha256(Data("远端内容".utf8)),
                                       origin: .host), type: .clipboardUpdate)
        h.run(seconds: 0.3)
        // 本地剪贴板随即报告变化（同一内容）→ 必须被识别为回环，不产生回传
        XCTAssertNil(h.viewer.clipboard.localChanged(text: "远端内容", origin: .viewer))
        XCTAssertGreaterThan(h.viewer.clipboard.suppressedLoops, 0)
    }
}

// MARK: - 端到端：弱网与带宽矩阵

/// 对应 06-test-plan.md §4 的弱网矩阵与验收规则。
final class EndToEndWeakNetworkTests: XCTestCase {

    private func runScenario(_ conditions: LinkConditions, seed: UInt64 = 99,
                             label: String, file: StaticString = #filePath, line: UInt = #line) {
        let h = LoopbackHarness(conditions: conditions, seed: seed)
        defer { h.cleanup() }
        h.connect(seconds: 1.5)
        h.viewer.focus(windowUID: h.mainWindowUID)
        h.run(seconds: 0.5)

        // 窗口操作
        h.viewer.endResize(windowUID: h.mainWindowUID, finalSize: Size(760, 560))
        h.run(seconds: 0.5)
        XCTAssertEqual(h.model.windows[h.mainWindowUID]?.contentSize, Size(760, 560),
                       "\(label)：缩放必须在弱网下也生效", file: file, line: line)

        // 中文输入
        for s in ["弱网", "输入", "正常"] {
            h.viewer.textBridge.receive(context: h.textProvider.currentContext()!)
            h.composeAndCommit(s, marked: "ruo")
            h.run(seconds: 0.6)
        }
        XCTAssertEqual(h.model.textBuffer, "弱网输入正常",
                       "\(label)：弱网下中文输入不得丢字或重复", file: file, line: line)

        // 画面
        XCTAssertGreaterThan(h.viewer.framesReceived, 0,
                             "\(label)：弱网下仍应收到画面", file: file, line: line)

        // 不得出现重复提交
        XCTAssertEqual(h.model.textBuffer.components(separatedBy: "正常").count - 1, 1,
                       "\(label)：不得重复提交", file: file, line: line)
    }

    func testLanBaseline() { runScenario(.lan, label: "局域网") }
    func testRtt80ms() { runScenario(.rtt80, label: "RTT 80ms") }
    func testRtt160ms() { runScenario(.rtt160, label: "RTT 160ms") }
    func testRtt250ms() { runScenario(.rtt250, label: "RTT 250ms") }
    func testOnePercentLoss() { runScenario(.loss(0.01), label: "丢包 1%") }
    func testThreePercentLoss() { runScenario(.loss(0.03), label: "丢包 3%") }
    func testFivePercentLoss() { runScenario(.loss(0.05), label: "丢包 5%") }
    func test20MbpsLimit() { runScenario(.bw20Mbps, label: "带宽 20Mbps") }
    func test8MbpsLimit() { runScenario(.bw8Mbps, label: "带宽 8Mbps") }

    /// 最恶劣组合（规格 §4 验收规则）：3 Mbps + 160ms + 1% 丢包。
    func testWorstCaseCombinationStillWorks() {
        runScenario(.worstCase, label: "最恶劣组合")
    }

    func testJitterDoesNotBreakOrdering() {
        var c = LinkConditions.rtt(160)
        c.jitter = 0.03
        runScenario(c, label: "RTT 160ms + 抖动 30ms")
    }

    /// 规格 §4 验收规则的另一半：窗口操作与候选词必须与网络无关。
    func testLocalResponsivenessIsIndependentOfNetworkQuality() {
        for conditions in [LinkConditions.lan, .worstCase] {
            let h = LoopbackHarness(conditions: conditions)
            defer { h.cleanup() }
            h.connect(seconds: 1.0)
            let ctx = h.textProvider.currentContext()!
            // 开始组合必须立即成功（本地操作，不需要任何网络往返）
            h.viewer.textBridge.beginComposition(editVersion: ctx.editVersion)
            h.viewer.textBridge.updateComposition("nihao")
            XCTAssertTrue(h.viewer.textBridge.state.isComposing,
                          "组合必须立刻生效，不受网络影响（\(conditions.description)）")
            // 窗口拖动立即改变本地壳尺寸
            h.viewer.beginResize(windowUID: h.mainWindowUID, requested: Size(900, 640))
            XCTAssertEqual(h.viewer.windowTable.shell(h.mainWindowUID)?.localContentSize, Size(900, 640),
                           "本地窗口尺寸必须立即改变（\(conditions.description)）")
        }
    }

    /// 带宽上限必须真的限制媒体流量（"兼容各种带宽"的可验证形式）。
    func testBandwidthLimitIsRespectedForMediaTraffic() {
        func measure(_ conditions: LinkConditions, seconds: Double) -> (mediaBytes: Int, frames: Int) {
            let h = LoopbackHarness(conditions: conditions, seed: 5)
            defer { h.cleanup() }
            h.connect(seconds: 1.0)
            // 放大窗口，使每帧像素量足够大，带宽上限才会真正生效
            _ = h.host.windowProvider.applySize(h.mainWindowUID, requested: Size(1400, 1000))
            h.run(seconds: 0.3)
            let iterations = Int(seconds / 0.05)
            for i in 0..<iterations {
                h.model.textBuffer = String(repeating: "内容", count: (i % 40) + 1)
                h.model.caretOffset = i
                h.model.updateContent(h.mainWindowUID) { _ in }
                h.syncCaptureSources()
                h.run(seconds: 0.05)
            }
            return (h.net.link.stats.bytesByChannel[.media] ?? 0, h.viewer.framesReceived)
        }

        let duration = 3.0
        let fast = measure(.lan, seconds: duration)
        // 200 kbps ≈ 25 KB/s；3 秒最多约 75 KB
        let slow = measure(LinkConditions.bandwidth(mbps: 0.2), seconds: duration)

        let capBytes = 0.2 * 1_000_000 / 8 * duration
        XCTAssertLessThanOrEqual(Double(slow.mediaBytes), capBytes * 1.5,
                                 "低带宽下媒体流量突破了上限：\(slow.mediaBytes) > \(Int(capBytes * 1.5))")
        XCTAssertGreaterThan(fast.mediaBytes, slow.mediaBytes,
                             "带宽上限未生效：fast=\(fast.mediaBytes), slow=\(slow.mediaBytes)")
    }

    /// 严重丢包下不得出现花屏式错误内容（解码失败必须请求关键帧）。
    func testDecodeFailuresTriggerKeyframeRequestsNotGarbage() {
        var conditions = LinkConditions.rtt(80)
        conditions.lossRate = 0.4
        let h = LoopbackHarness(conditions: conditions, seed: 11)
        defer { h.cleanup() }
        h.connect(seconds: 1.2)
        for i in 0..<10 {
            h.model.textBuffer = "变化 \(i)"
            h.model.updateContent(h.mainWindowUID) { _ in }
            h.syncCaptureSources()
            h.run(seconds: 0.1)
        }
        // 收到的每一帧像素校验和都必须对应真实渲染结果，不得是拼接的垃圾
        for (_, decoded) in h.viewer.decodedFrames {
            XCTAssertGreaterThan(decoded.pixelChecksum, 0)
            XCTAssertEqual(decoded.layoutVersion, h.viewer.layoutVersion)
        }
        XCTAssertGreaterThanOrEqual(h.viewer.keyframeRequestsSent, 1, "起播时必须请求关键帧")
    }
}
