import XCTest
@testable import M2MCore

// MARK: - 媒体管线

final class MediaPipelineTests: XCTestCase {

    private func frame(index: Int, layout: UInt64 = 1, size: Size = Size(64, 48)) -> CapturedFrame {
        let px = [UInt8](repeating: UInt8(index % 251), count: Int(size.width * size.height) * 4)
        return CapturedFrame(streamID: "s", size: size, contentScale: 2, layoutVersion: layout,
                             frameIndex: index, isStatic: false, pixels: px, capturedAt: Double(index))
    }

    func testEncoderQueueDropsOldestUnencodedFrameWhenOverCapacity() {
        // 规格 §4：可以丢弃尚未编码的过期画面
        let q = EncoderQueue(maxUnencoded: 2, maxEncoded: 8)
        for i in 0..<5 { q.enqueue(frame(index: i)) }
        XCTAssertEqual(q.pendingUnencoded.count, 2)
        XCTAssertEqual(q.droppedUnencoded, 3)
        XCTAssertEqual(q.pendingUnencoded.first?.frameIndex, 3, "应保留最新的帧")
    }

    func testEncoderQueueNeverReportsDroppingEncodedFramesInNormalUse() {
        // 不得丢弃已编码帧（参考依赖）
        let q = EncoderQueue(maxUnencoded: 2, maxEncoded: 100)
        let enc = RawFrameEncoder()
        for i in 0..<20 {
            q.enqueue(frame(index: i))
            _ = q.encodeOne(with: enc)
        }
        XCTAssertEqual(q.droppedEncoded, 0)
    }

    func testRawEncoderIsLosslessAndMarksKeyframe() {
        let enc = RawFrameEncoder()
        let f = frame(index: 1)
        let out = enc.encode(f, forceKeyframe: false)
        XCTAssertTrue(out.isKeyframe)
        XCTAssertEqual(out.pixelChecksum, f.checksum)
        XCTAssertEqual(out.byteCount, f.pixels.count)
    }

    func testBitrateGovernorSkipsWhenBudgetExhaustedButAllowsKeyframe() {
        let g = BitrateGovernor(targetBitsPerSecond: 100_000)
        // 每秒 100kbit = 12500 字节
        XCTAssertTrue(g.allow(estimatedBytes: 10_000, now: 0.0, forceKeyframe: false))
        XCTAssertFalse(g.allow(estimatedBytes: 10_000, now: 0.1, forceKeyframe: false))
        XCTAssertTrue(g.allow(estimatedBytes: 10_000, now: 0.2, forceKeyframe: true),
                      "关键帧必须放行，否则接收端无法起播")
        // 新的一秒重置预算
        XCTAssertTrue(g.allow(estimatedBytes: 10_000, now: 1.5, forceKeyframe: false))
    }

    func testFrameReceiverDropsFrameWithMismatchedLayoutVersion() throws {
        // 规则 B13：版本不一致时丢弃该帧，而不是显示错区域
        let enc = RawFrameEncoder()
        let dec = RawFrameDecoder()
        let r = FrameReceiver()
        let encoded = enc.encode(frame(index: 1, layout: 7), forceKeyframe: true)
        let out = try r.ingest(encoded, decoder: dec, currentLayoutVersion: 8)
        XCTAssertNil(out)
        XCTAssertEqual(r.droppedAsStale, 1)
    }

    func testFrameReceiverAcceptsMatchingVersionAndRecordsChecksum() throws {
        let enc = RawFrameEncoder(); let dec = RawFrameDecoder(); let r = FrameReceiver()
        let f = frame(index: 1, layout: 3)
        let encoded = enc.encode(f, forceKeyframe: true)
        let out = try r.ingest(encoded, decoder: dec, currentLayoutVersion: 3)
        XCTAssertEqual(out?.pixelChecksum, f.checksum, "端到端像素必须可校验")
        XCTAssertEqual(r.decodedChecksums.count, 1)
    }

    func testFrameReceiverRequiresKeyframeAfterReset() {
        let r = FrameReceiver()
        r.requestKeyframe()
        let enc = RawFrameEncoder()
        let nonKey = EncodedFrame(streamID: "s", frameIndex: 1, isKeyframe: false, layoutVersion: 1,
                                  size: Size(4, 4), byteCount: 0, codec: .rawBGRA, payload: Data(),
                                  pixelChecksum: 1)
        XCTAssertThrowsError(try r.ingest(nonKey, decoder: RawFrameDecoder(), currentLayoutVersion: 1)) { err in
            XCTAssertEqual(err as? DecodeError, .missingReferenceFrame)
        }
        let key = enc.encode(frame(index: 1), forceKeyframe: true)
        XCTAssertNoThrow(try r.ingest(key, decoder: RawFrameDecoder(), currentLayoutVersion: 1))
        _ = nonKey
    }

    func testDecoderRejectsUnsupportedCodec() {
        let bad = EncodedFrame(streamID: "s", frameIndex: 1, isKeyframe: true, layoutVersion: 1,
                               size: Size(4, 4), byteCount: 0, codec: .h264, payload: Data())
        XCTAssertThrowsError(try RawFrameDecoder().decode(bad))
    }

    func testDownsamplerHalvesDimensionsAndPreservesPixelCount() {
        let f = frame(index: 1, size: Size(64, 48))
        let half = FrameDownsampler.downsample(f, scale: .half)
        XCTAssertEqual(half.size, Size(32, 24))
        XCTAssertEqual(half.pixels.count, 32 * 24 * 4)
        let quarter = FrameDownsampler.downsample(f, scale: .quarter)
        XCTAssertEqual(quarter.size, Size(16, 12))
    }

    func testDownsamplerFullScaleIsIdentity() {
        let f = frame(index: 1)
        XCTAssertEqual(FrameDownsampler.downsample(f, scale: .full).pixels.count, f.pixels.count)
    }
}

// MARK: - 合成采集与渲染

final class SyntheticCaptureTests: XCTestCase {

    func testContentChangeProducesDifferentPixels() {
        var c = SyntheticWindowContent(title: "T", textContent: "abc")
        let a = SyntheticRenderer.render(c, size: Size(128, 96))
        c.textContent = "abc你好世界"
        let b = SyntheticRenderer.render(c, size: Size(128, 96))
        XCTAssertNotEqual(a, b, "内容变化必须导致画面变化，否则无法验证端到端")
    }

    func testSignatureReflectsEveryVisibleField() {
        var c = SyntheticWindowContent()
        let base = c.signature
        c.caretOffset = 3
        XCTAssertNotEqual(c.signature, base)
        c = SyntheticWindowContent(); c.selectionLength = 2
        XCTAssertNotEqual(c.signature, base)
        c = SyntheticWindowContent(); c.scrollOffset = 12
        XCTAssertNotEqual(c.signature, base)
        c = SyntheticWindowContent(); c.theme = .dark
        XCTAssertNotEqual(c.signature, base)
        c = SyntheticWindowContent(); c.badge = "降级"
        XCTAssertNotEqual(c.signature, base)
    }

    func testStaticContentIsThrottled() {
        // 静态内容降频：不应每帧都产出新画面
        let src = SyntheticCaptureSource(streamID: "s", size: Size(64, 64),
                                         content: SyntheticWindowContent(title: "静态"))
        var produced = 0
        for i in 0..<60 {
            if src.nextFrame(now: Double(i) * 0.03) != nil { produced += 1 }
        }
        XCTAssertLessThan(produced, 60, "静态内容必须降频")
        XCTAssertGreaterThan(produced, 0)
    }

    func testChangedContentProducesFrameImmediately() {
        let src = SyntheticCaptureSource(streamID: "s", size: Size(64, 64))
        XCTAssertNotNil(src.nextFrame(now: 0))
        src.content.textContent = "变化"
        XCTAssertNotNil(src.nextFrame(now: 0.01), "内容变化应立刻产生新帧")
    }

    func testPauseStopsFrameProduction() {
        let src = SyntheticCaptureSource(streamID: "s", size: Size(64, 64))
        src.pause()
        XCTAssertNil(src.nextFrame(now: 1.0))
        src.resume()
        XCTAssertNotNil(src.nextFrame(now: 1.1))
    }

    func testThemeAffectsPixels() {
        var c = SyntheticWindowContent(textContent: "x")
        let light = SyntheticRenderer.render(c, size: Size(64, 64))
        c.theme = .dark
        let dark = SyntheticRenderer.render(c, size: Size(64, 64))
        XCTAssertNotEqual(light, dark)
    }

    func testHighContrastThemeIsRenderable() {
        var c = SyntheticWindowContent(textContent: "高对比")
        c.theme = .highContrast
        let px = SyntheticRenderer.render(c, size: Size(64, 64))
        XCTAssertEqual(px.count, 64 * 64 * 4)
    }

    func testContentChangeOnHostModelUpdatesWindowPixels() {
        // 端到端可验证性的基础：模型变化 → 采集像素变化
        let model = SyntheticAppModel()
        let uid = model.focusedWindowUID!
        let src = SyntheticCaptureSource(streamID: "s", size: Size(200, 150),
                                         content: model.focusableWindow!.content)
        let before = src.nextFrame(now: 0)!.checksum
        model.textBuffer = "输入的文字"
        model.caretOffset = 5
        model.updateContent(uid) { _ in }
        src.content = model.focusableWindow!.content
        let after = src.nextFrame(now: 0.1)!.checksum
        XCTAssertNotEqual(before, after)
    }
}

// MARK: - 文件桥与剪贴板

final class FileBridgeTests: XCTestCase {

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("m2m-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testFileRoundTripVerifiesChecksum() {
        let dir = tempDir()
        let bridge = FileBridge(remoteTempDirectory: dir, chunkSize: 1024)
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let offer = bridge.offer(transferID: "t1", name: "test.bin", data: payload)
        XCTAssertEqual(offer.size, 5000)
        bridge.beginTransfer("t1")
        var now = 0.0
        var sent = 0
        while let chunk = bridge.nextChunk(transferID: "t1", now: now) {
            _ = bridge.receive(chunk)
            sent += 1
            now += 0.01
            if sent > 100 { break }
        }
        let result = bridge.completeReceive(FileComplete(transferID: "t1", remotePath: "ignored"))
        XCTAssertTrue(result.completed)
        XCTAssertEqual(bridge.completedNames, ["test.bin"])
        let written = try? Data(contentsOf: URL(fileURLWithPath: result.remotePath!))
        XCTAssertEqual(written, payload)
        bridge.cleanupTempDirectory()
        XCTAssertEqual(bridge.temporaryFileCount, 0)
    }

    func testChecksumMismatchAbortsAndDoesNotLeaveUsableFile() {
        let dir = tempDir()
        let bridge = FileBridge(remoteTempDirectory: dir, chunkSize: 512)
        let payload = Data(repeating: 7, count: 1000)
        _ = bridge.offer(transferID: "t2", name: "bad.bin", data: payload)
        bridge.beginTransfer("t2")
        // 注入一个被篡改的分块
        let tampered = FileChunk(transferID: "t2", index: 0, bytes: Data(repeating: 9, count: 1000))
        _ = bridge.receive(tampered)
        let result = bridge.completeReceive(FileComplete(transferID: "t2", remotePath: "x"))
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.aborted, .checksumMismatch)
        XCTAssertFalse(bridge.completedNames.contains("bad.bin"))
    }

    func testRateLimitActuallyThrottlesChunks() {
        let dir = tempDir()
        // 50 KB/s，分块 1 KB → 约 20ms 一块
        let bridge = FileBridge(remoteTempDirectory: dir, chunkSize: 1024,
                                rateLimitBytesPerSecond: 50_000)
        let payload = Data(repeating: 3, count: 10 * 1024)
        _ = bridge.offer(transferID: "t3", name: "big.bin", data: payload)
        bridge.beginTransfer("t3")
        var now = 0.0
        var chunks = 0
        // 在 0.1 秒内最多应发出约 5 块（50000*0.1/1024 ≈ 4.8）
        while now < 0.1 {
            if bridge.nextChunk(transferID: "t3", now: now) != nil { chunks += 1 }
            now += 0.001
        }
        XCTAssertLessThanOrEqual(chunks, 8, "限速未生效：0.1 秒内发出了 \(chunks) 块")
        XCTAssertGreaterThan(chunks, 0)
    }

    func testUnlimitedRateSendsAllChunksImmediately() {
        let dir = tempDir()
        let bridge = FileBridge(remoteTempDirectory: dir, chunkSize: 512, rateLimitBytesPerSecond: nil)
        _ = bridge.offer(transferID: "t4", name: "f.bin", data: Data(repeating: 1, count: 4096))
        bridge.beginTransfer("t4")
        var count = 0
        while bridge.nextChunk(transferID: "t4", now: 0) != nil { count += 1 }
        XCTAssertEqual(count, 8)
    }

    func testAbortThenResumeContinuesFromProgress() {
        let dir = tempDir()
        let bridge = FileBridge(remoteTempDirectory: dir, chunkSize: 1000, rateLimitBytesPerSecond: nil)
        let total = Data(repeating: 5, count: 4000)
        _ = bridge.offer(transferID: "t5", name: "r.bin", data: total)
        bridge.beginTransfer("t5")
        _ = bridge.nextChunk(transferID: "t5", now: 0)
        XCTAssertEqual(bridge.transfers["t5"]?.sentBytes, 1000)
        let remaining = total.subdata(in: 1000..<4000)
        bridge.resume("t5", remaining: remaining, now: 1.0)
        var n = 0
        while bridge.nextChunk(transferID: "t5", now: 1.0) != nil { n += 1 }
        XCTAssertEqual(n, 3, "续传只应发送剩余分块")
        XCTAssertEqual(bridge.transfers["t5"]?.sentBytes, 4000)
    }

    func testQuotaEvictsOldestTemporaryFile() {
        let dir = tempDir()
        let bridge = FileBridge(remoteTempDirectory: dir, chunkSize: 4096,
                                rateLimitBytesPerSecond: nil, remoteTempQuotaBytes: 3000)
        for i in 0..<3 {
            let id = "q\(i)"
            _ = bridge.offer(transferID: id, name: "f\(i).bin", data: Data(repeating: UInt8(i), count: 2000))
            bridge.beginTransfer(id)
            while let c = bridge.nextChunk(transferID: id, now: 0) { _ = bridge.receive(c) }
            _ = bridge.completeReceive(FileComplete(transferID: id, remotePath: "x"))
        }
        XCTAssertLessThanOrEqual(bridge.totalTemporaryBytes, 3000, "配额必须生效")
        XCTAssertLessThan(bridge.temporaryFileCount, 3, "应淘汰最旧的临时文件")
    }

    func testPathTraversalInFilenameIsSanitized() {
        let dir = tempDir()
        let bridge = FileBridge(remoteTempDirectory: dir, chunkSize: 4096, rateLimitBytesPerSecond: nil)
        _ = bridge.offer(transferID: "safe", name: "../../etc/passwd", data: Data([1, 2, 3]))
        bridge.beginTransfer("safe")
        while let c = bridge.nextChunk(transferID: "safe", now: 0) { _ = bridge.receive(c) }
        let r = bridge.completeReceive(FileComplete(transferID: "safe", remotePath: "x"))
        XCTAssertTrue(r.completed)
        let path = r.remotePath!
        XCTAssertFalse(path.contains(".."), "文件名必须被净化，防止路径穿越")
        XCTAssertTrue(path.hasPrefix(dir.path))
    }
}

final class ClipboardBridgeTests: XCTestCase {

    func testHostOriginContentIsNotEchoedBack() {
        let b = ClipboardBridge()
        let fromHost = ClipboardUpdate(kind: .text, text: "来自远端", hash: "h1", origin: .host)
        XCTAssertTrue(b.receive(fromHost))
        // 本地剪贴板内容与已知相同 → 不应产生回传
        XCTAssertNil(b.localChanged(text: "来自远端", origin: .viewer))
        XCTAssertEqual(b.suppressedLoops, 1)
    }

    func testNewLocalContentProducesUpdate() {
        let b = ClipboardBridge()
        _ = b.receive(ClipboardUpdate(kind: .text, text: "远端内容", hash: "h1", origin: .host))
        let out = b.localChanged(text: "本地新内容", origin: .viewer)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.text, "本地新内容")
    }

    func testRepeatedIdenticalLocalContentIsSuppressed() {
        let b = ClipboardBridge()
        _ = b.localChanged(text: "相同", origin: .viewer)
        XCTAssertNil(b.localChanged(text: "相同", origin: .viewer), "相同内容不应反复往返")
    }

    func testClearedClipboardIsRepresentedAsClearedKind() {
        let b = ClipboardBridge()
        let out = b.localChanged(text: "", origin: .viewer)
        XCTAssertEqual(out?.kind, .cleared)
    }
}

// MARK: - 输入路由

final class InputRouterTests: XCTestCase {

    func testPointerMoveIsCoalesced() {
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w")
        r.pointerCoalesceInterval = 1.0
        for i in 0..<20 {
            _ = r.handlePointer(kind: .move, position: Point(Double(i), Double(i)), now: 0.001)
        }
        XCTAssertGreaterThan(r.pendingMoveSamples, 1)
        r.resetEmitted()
        let disp = r.flushPointer(now: 0.5)
        guard case .sent(let e) = disp else { return XCTFail("应发出合并后的移动") }
        XCTAssertEqual(e.kind, .moveCoalesced)
        XCTAssertEqual(e.positionInWindow, Point(19, 19), "应保留最新位置")
        XCTAssertGreaterThanOrEqual(e.coalescedSampleCount, 2)
    }

    func testNonMoveEventFlushesPendingMoveFirst() {
        // 顺序正确性：点击前必须先把挂起的移动送达，否则会点错位置
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w")
        r.pointerCoalesceInterval = 100
        _ = r.handlePointer(kind: .move, position: Point(10, 10), now: 0)
        r.resetEmitted()
        _ = r.handlePointer(kind: .down, position: Point(20, 20), button: .left, now: 0.001)
        XCTAssertEqual(r.emitted.count, 2)
        if case .pointer(let first) = r.emitted[0] {
            XCTAssertEqual(first.positionInWindow, Point(10, 10))
        } else { XCTFail("应先发出挂起的移动") }
        if case .pointer(let second) = r.emitted[1] {
            XCTAssertEqual(second.kind, .down)
        } else { XCTFail("然后才是点击") }
    }

    func testPointerRejectedWithoutTargetWindow() {
        let r = InputRouter(epoch: 1)
        let disp = r.handlePointer(kind: .down, position: Point(1, 1), now: 0)
        if case .rejected = disp { } else { XCTFail("没有目标窗口时必须拒绝") }
    }

    func testWrongWindowInputIsRejectedAndCounted() {
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w1")
        XCTAssertFalse(r.validateTarget("w2"))
        XCTAssertEqual(r.droppedWrongWindow, 1)
    }

    func testModifierKeysReleasedOnDisconnect() {
        // A8：连接丢失必须释放所有按下的修饰键
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w")
        _ = r.handleKey(keycode: 55, kind: .flagsChanged, flags: [.command], unicode: nil, route: .remote(.shortcut))
        XCTAssertTrue(r.pressedModifiers.contains(.command))
        let released = r.releaseAllKeys()
        XCTAssertFalse(released.isEmpty)
        XCTAssertTrue(r.pressedModifiers.isEmpty)
        XCTAssertEqual(r.releasedModifiersOnDisconnect, 1)
    }

    func testPressedKeysReleasedOnDisconnect() {
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w")
        _ = r.handleKey(keycode: 0, kind: .keyDown, flags: [], unicode: nil, route: .remote(.rawKey))
        XCTAssertTrue(r.pressedKeys.contains(0))
        _ = r.releaseAllKeys()
        XCTAssertTrue(r.pressedKeys.isEmpty)
    }

    func testTargetSwitchReleasesHeldKeys() {
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w1")
        _ = r.handleKey(keycode: 0, kind: .keyDown, flags: [], unicode: nil, route: .remote(.rawKey))
        r.setTargetWindow("w2")
        XCTAssertTrue(r.pressedKeys.isEmpty, "切换窗口不得把按住状态带过去")
    }

    func testLocalIMERouteDoesNotEmitToRemote() {
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w")
        let disp = r.handleKey(keycode: KeyCode.returnKey, kind: .keyDown, flags: [],
                              unicode: nil, route: .localIME)
        if case .heldForIME = disp { } else { XCTFail("本地输入法路由不得外发") }
        XCTAssertTrue(r.emitted.isEmpty)
    }

    func testConsumedLocallyRouteIsNotSent() {
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w")
        let disp = r.handleKey(keycode: KeyCode.space, kind: .keyDown, flags: [.control],
                               unicode: nil, route: .consumedLocally(reason: "切换输入法"))
        if case .consumedLocally = disp { } else { XCTFail() }
        XCTAssertTrue(r.emitted.isEmpty)
    }

    func testEpochIsAttachedToOutgoingEvents() {
        let r = InputRouter(epoch: 7)
        r.setTargetWindow("w")
        _ = r.handleKey(keycode: 0, kind: .keyDown, flags: [], unicode: nil, route: .remote(.rawKey))
        guard case .key(let e) = r.emitted.first else { return XCTFail() }
        XCTAssertEqual(e.epoch, 7)
    }

    func testEpochUpdateChangesSubsequentEvents() {
        let r = InputRouter(epoch: 1)
        r.setTargetWindow("w")
        r.setEpoch(9, targetWindow: "w")
        _ = r.handleKey(keycode: 0, kind: .keyDown, flags: [], unicode: nil, route: .remote(.rawKey))
        guard case .key(let e) = r.emitted.last else { return XCTFail() }
        XCTAssertEqual(e.epoch, 9)
    }
}

// MARK: - 会话状态机

final class SessionTests: XCTestCase {

    func testPhasesProgressAndAreRecorded() {
        let s = Session()
        XCTAssertEqual(s.phase, .disconnected)
        s.beginNegotiation()
        s.activate()
        XCTAssertEqual(s.phase, .active)
        XCTAssertEqual(s.phaseHistory, [.negotiating, .active])
    }

    func testInterruptionEntersReconnectingWithNotice() {
        let s = Session()
        s.beginNegotiation(); s.activate()
        s.transportInterrupted(detail: nil)
        XCTAssertEqual(s.phase, .reconnecting)
        XCTAssertTrue(s.notices.contains { $0.title == "画面中断" })
    }

    func testReconnectBumpsEpochAndClearsNotice() {
        // 重连必须推进 epoch，使旧消息自动失效
        let s = Session(epoch: 4)
        s.beginNegotiation(); s.activate()
        s.transportInterrupted(detail: nil)
        s.reconnectSucceeded()
        XCTAssertEqual(s.epoch, 5)
        XCTAssertEqual(s.phase, .active)
        XCTAssertFalse(s.notices.contains { $0.title == "画面中断" })
        XCTAssertEqual(s.reconnectCount, 1)
    }

    func testReconnectTriggersResyncCallback() {
        let s = Session()
        s.beginNegotiation(); s.activate()
        var called = false
        s.onReconnect = { called = true }
        s.reconnectSucceeded()
        XCTAssertTrue(called, "重连必须触发重新同步（窗口表、组合文本、关键帧）")
    }

    func testInterruptionDuringDisconnectedIsIgnored() {
        let s = Session()
        s.transportInterrupted(detail: "noise")
        XCTAssertEqual(s.phase, .disconnected)
    }

    func testSuspendKeepsRemoteAppAlive() {
        let s = Session()
        s.beginNegotiation(); s.activate()
        s.suspend(reason: "用户挂起")
        XCTAssertEqual(s.phase, .suspended)
        XCTAssertTrue(s.notices.contains { $0.detail.contains("挂起") })
    }

    func testRevokeRecordsReason() {
        let s = Session()
        s.beginNegotiation(); s.activate()
        s.revoke(.userRemote)
        XCTAssertEqual(s.phase, .revoked)
        XCTAssertTrue(s.notices.contains { $0.title == "控制已撤销" })
    }

    func testReconnectChecklistCoversAllFiveRequiredActions() {
        let s = Session()
        XCTAssertEqual(s.reconnectChecklist.count, 5)
        let joined = s.reconnectChecklist.joined()
        XCTAssertTrue(joined.contains("窗口"))
        XCTAssertTrue(joined.contains("不重放"))
        XCTAssertTrue(joined.contains("关键帧"))
        XCTAssertTrue(joined.contains("组合"))
        XCTAssertTrue(joined.contains("修饰键"))
    }

    func testDegradedActivationIsDistinctFromActive() {
        let s = Session()
        s.beginNegotiation()
        s.activate(degraded: true)
        XCTAssertEqual(s.phase, .degraded)
    }

    func testDiscardedPendingInputAccounting() {
        let s = Session()
        s.recordDiscardedPendingInput(count: 3)
        XCTAssertEqual(s.discardedPendingInputs, 3)
    }
}

// MARK: - 能力报告与 UI 提示

final class CapabilityReportTests: XCTestCase {

    func testDeniedScreenRecordingProducesUserFacingNotice() {
        var r = CapabilityReport(screenRecording: .denied, accessibility: .granted,
                                 inputMonitoring: .notRequired, captureMode: .synthetic,
                                 inputMode: .realEventInjection, textMode: .fullLocalIME)
        r.screenRecording = .denied
        let notices = r.userFacingNotices
        XCTAssertTrue(notices.contains { $0.title.contains("屏幕录制") })
        XCTAssertTrue(notices.contains { $0.severity == .warning })
    }

    func testDeniedAccessibilityExplainsInputImpact() {
        let r = CapabilityReport(screenRecording: .granted, accessibility: .denied,
                                 inputMonitoring: .denied, captureMode: .realWindowCapture,
                                 inputMode: .recorded, textMode: .degradedCaret)
        let notices = r.userFacingNotices
        XCTAssertTrue(notices.contains { $0.title.contains("辅助功能") })
        XCTAssertTrue(notices.contains { $0.title.contains("候选窗") })
    }

    func testRemoteIMEOnlyIsLabelledAsDegradedNotAsNative() {
        // P2：不得把降级静默呈现为达标
        let r = CapabilityReport(screenRecording: .granted, accessibility: .granted,
                                 inputMonitoring: .notRequired, captureMode: .realWindowCapture,
                                 inputMode: .realEventInjection, textMode: .remoteIMEOnly)
        XCTAssertFalse(r.textMode.meetsCertifiedBar)
        XCTAssertTrue(r.userFacingNotices.contains { $0.title.contains("远端输入法") })
    }

    func testFullLocalIMEMeetsCertifiedBarAndHasNoTextNotice() {
        let r = CapabilityReport(screenRecording: .granted, accessibility: .granted,
                                 inputMonitoring: .notRequired, captureMode: .realWindowCapture,
                                 inputMode: .realEventInjection, textMode: .fullLocalIME)
        XCTAssertTrue(r.textMode.meetsCertifiedBar)
        XCTAssertFalse(r.userFacingNotices.contains { $0.scope == .text })
    }

    func testCaretRectCapabilityDrivesTextCapabilities() {
        let full = CapabilityReport(screenRecording: .granted, accessibility: .granted,
                                    inputMonitoring: .notRequired, captureMode: .realWindowCapture,
                                    inputMode: .realEventInjection, textMode: .fullLocalIME)
        XCTAssertTrue(full.textCapabilities.caretRect)
        let degraded = CapabilityReport(screenRecording: .granted, accessibility: .granted,
                                        inputMonitoring: .notRequired, captureMode: .realWindowCapture,
                                        inputMode: .realEventInjection, textMode: .degradedCaret)
        XCTAssertFalse(degraded.textCapabilities.caretRect, "无稳定插入点时 caretRect 必须为 false")
    }

    func testSyntheticReportIsUsableWithoutAnyPermission() {
        let r = SystemCapabilityProbe.report(forceSynthetic: true)
        XCTAssertEqual(r.captureMode, .synthetic)
        XCTAssertTrue(r.textMode.meetsCertifiedBar)
        XCTAssertTrue(r.userFacingNotices.isEmpty)
    }
}

// MARK: - 屏幕内容 RLE 编解码

final class ScreenRLETests: XCTestCase {

    func testRoundTripIsLosslessOnFlatContent() {
        let px = [UInt8](repeating: 200, count: 64 * 64 * 4)
        let packed = ScreenRLE.encode(px)
        XCTAssertEqual(ScreenRLE.decode(packed), px, "RLE 必须无损")
    }

    func testRoundTripIsLosslessOnMixedContent() {
        var px = [UInt8]()
        for i in 0..<(128 * 96) {
            let v = UInt8((i / 7) % 251)
            px.append(contentsOf: [v, v &+ 1, v &+ 2, 255])
        }
        let packed = ScreenRLE.encode(px)
        XCTAssertEqual(ScreenRLE.decode(packed), px)
    }

    func testRoundTripOnRealSyntheticRender() {
        let content = SyntheticWindowContent(title: "窗口", textContent: "一段中文与 English 混合的内容 12345")
        let px = SyntheticRenderer.render(content, size: Size(560, 380))
        let packed = ScreenRLE.encode(px)
        XCTAssertEqual(ScreenRLE.decode(packed), px)
    }

    func testCompressionIsSubstantialForScreenContent() {
        // 这是把帧率从 ~1fps 提升到可用水平的关键
        let px = SyntheticRenderer.render(SyntheticWindowContent(title: "T"), size: Size(560, 380))
        let packed = ScreenRLE.encode(px)
        let ratio = ScreenRLE.compressionRatio(originalBytes: px.count, compressedBytes: packed.count)
        XCTAssertGreaterThan(ratio, 20, "屏幕内容压缩率过低（实际 \(ratio)），带宽模拟将失去意义")
    }

    func testSingleGroupContent() {
        let px: [UInt8] = [1, 2, 3, 4]
        XCTAssertEqual(ScreenRLE.decode(ScreenRLE.encode(px)), px)
    }

    func testTwoGroupNonRepeatingContent() {
        let px: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(ScreenRLE.decode(ScreenRLE.encode(px)), px)
    }

    func testAlternatingContentForcesLiteralRuns() {
        var px = [UInt8]()
        for i in 0..<1000 {
            let v = UInt8(i % 2 == 0 ? 0 : 255)
            px.append(contentsOf: [v, v, v, 255])
        }
        XCTAssertEqual(ScreenRLE.decode(ScreenRLE.encode(px)), px)
    }

    func testCorruptedPayloadReturnsNilInsteadOfGarbage() {
        let px = [UInt8](repeating: 42, count: 400)
        var packed = ScreenRLE.encode(px)
        packed.removeLast(3)
        XCTAssertNil(ScreenRLE.decode(packed), "损坏数据必须被识别，由上层请求关键帧")
    }

    func testWrongMagicReturnsNil() {
        XCTAssertNil(ScreenRLE.decode(Data([0, 1, 2, 3, 4, 5])))
    }

    func testDecoderRejectsMismatchedCodec() {
        let f = EncodedFrame(streamID: "s", frameIndex: 1, isKeyframe: true, layoutVersion: 1,
                             size: Size(2, 2), byteCount: 4, codec: .h264, payload: Data([1, 2, 3, 4]),
                             pixelChecksum: 1)
        XCTAssertThrowsError(try ScreenRLEDecoder().decode(f))
    }

    func testEncoderPreservesPixelChecksumForEndToEndVerification() {
        let enc = ScreenRLEEncoder()
        let px = [UInt8](repeating: 9, count: 16 * 16 * 4)
        let frame = CapturedFrame(streamID: "s", size: Size(16, 16), contentScale: 1, layoutVersion: 1,
                                  frameIndex: 1, isStatic: false, pixels: px, capturedAt: 0)
        let out = enc.encode(frame, forceKeyframe: true)
        XCTAssertEqual(out.pixelChecksum, frame.checksum)
        XCTAssertEqual(out.codec, .screenRLE)
    }

    func testDecodedPixelsMatchOriginalThroughEncoderDecoder() throws {
        let enc = ScreenRLEEncoder(); let dec = ScreenRLEDecoder()
        let px = SyntheticRenderer.render(SyntheticWindowContent(title: "端到端"), size: Size(200, 150))
        let frame = CapturedFrame(streamID: "s", size: Size(200, 150), contentScale: 1, layoutVersion: 1,
                                  frameIndex: 1, isStatic: false, pixels: px, capturedAt: 0)
        let encoded = enc.encode(frame, forceKeyframe: true)
        let decoded = try dec.decode(encoded)
        XCTAssertEqual(decoded.pixels, px)
    }
}
