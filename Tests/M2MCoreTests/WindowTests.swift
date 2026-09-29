import XCTest
@testable import M2MCore

// MARK: - 几何与坐标系

final class GeometryTests: XCTestCase {

    func testCapturePixelsUsesRemoteContentScale() {
        // 规格 §5.1：远端逻辑点 → 采集像素必须乘远端 contentScale
        let m = GeometryMapping(layoutVersion: 1, remoteContentScale: 2.0, localBackingScale: 2.0)
        XCTAssertEqual(m.capturePixels(forRemoteContent: Size(1200, 800)), Size(2400, 1600))
    }

    func testLocalToRemoteRoundTrip() {
        let m = GeometryMapping(layoutVersion: 1, remoteContentScale: 2.0, localBackingScale: 2.0)
        let remote = Size(640, 480)
        let local = Size(1280, 960)
        let p = Point(100, 200)
        let localP = m.localLogical(fromRemoteLogical: p, localContentSize: local, remoteContentSize: remote)
        XCTAssertEqual(localP, Point(200, 400))
        let back = m.remoteLogical(fromLocalLogical: localP, localContentSize: local, remoteContentSize: remote)
        XCTAssertEqual(back.x, p.x, accuracy: 0.0001)
        XCTAssertEqual(back.y, p.y, accuracy: 0.0001)
    }

    func testLocalBackingPixelsToRemoteAccountsForBackingScale() {
        let m = GeometryMapping(layoutVersion: 1, remoteContentScale: 2.0, localBackingScale: 2.0)
        // 本地像素 (400,800) → 本地逻辑点 (200,400) → 远端逻辑点 (100,200)
        let r = m.remoteLogical(fromLocalBackingPixels: Point(400, 800),
                                localContentSize: Size(1280, 960), remoteContentSize: Size(640, 480))
        XCTAssertEqual(r.x, 100, accuracy: 0.0001)
        XCTAssertEqual(r.y, 200, accuracy: 0.0001)
    }

    func testDegenerateSizesDoNotProduceNaNOrCrash() {
        let m = GeometryMapping(layoutVersion: 1, remoteContentScale: 1, localBackingScale: 1)
        let p = m.localLogical(fromRemoteLogical: Point(5, 5), localContentSize: .zero, remoteContentSize: .zero)
        XCTAssertEqual(p, Point(0, 0))
        let q = m.remoteLogical(fromLocalLogical: Point(5, 5), localContentSize: .zero, remoteContentSize: Size(10, 10))
        XCTAssertEqual(q, Point(0, 0))
    }

    func testScaleIsClampedToAvoidZeroDivision() {
        let m = GeometryMapping(layoutVersion: 1, remoteContentScale: 0, localBackingScale: 0)
        XCTAssertGreaterThan(m.remoteContentScale, 0)
        XCTAssertGreaterThan(m.localBackingScale, 0)
    }
}

// MARK: - 尺寸约束

final class SizeConstraintsTests: XCTestCase {

    func testClampToAppMinimumReportsConstraint() {
        let c = SizeConstraints(minSize: Size(320, 200), maxSize: nil, resizable: .both)
        let (size, by) = c.clamp(Size(200, 150))
        XCTAssertEqual(size, Size(320, 200))
        XCTAssertEqual(by, .appMin)
    }

    func testClampToAppMaximumReportsConstraint() {
        let c = SizeConstraints(minSize: nil, maxSize: Size(800, 600), resizable: .both)
        let (size, by) = c.clamp(Size(1000, 900))
        XCTAssertEqual(size, Size(800, 600))
        XCTAssertEqual(by, .appMax)
    }

    func testNonResizableWindowReturnsAppMaxConstraint() {
        // 不可缩放窗口：本地应禁用缩放 UI，而不是允许拖动后回弹
        let c = SizeConstraints(resizable: .none)
        let (_, by) = c.clamp(Size(500, 500))
        XCTAssertEqual(by, .appMax)
    }

    func testWidthOnlyResizableZeroesHeight() {
        let c = SizeConstraints(resizable: .width)
        let (size, _) = c.clamp(Size(500, 400))
        XCTAssertEqual(size.width, 500)
        XCTAssertEqual(size.height, 0, "高度不可缩放时不应请求高度变化")
    }

    func testWithinRangeReportsNoConstraint() {
        let c = SizeConstraints(minSize: Size(100, 100), maxSize: Size(500, 500), resizable: .both)
        let (size, by) = c.clamp(Size(300, 300))
        XCTAssertEqual(size, Size(300, 300))
        XCTAssertEqual(by, .none)
    }
}

// MARK: - 窗口注册表

final class WindowRegistryTests: XCTestCase {

    private func info(_ uid: String, size: Size = Size(640, 480), role: WindowRole = .main) -> WindowInfo {
        WindowInfo(windowUID: uid, appPID: 1, appLaunchID: "L1", bundleID: "b", title: uid,
                   role: role, contentRect: Rect(origin: .zero, size: size))
    }

    func testUpsertBumpsLayoutVersionOnlyOnChange() {
        let r = WindowRegistry(epoch: 1)
        XCTAssertTrue(r.upsert(info("a")))
        let v1 = r.layoutVersion
        XCTAssertFalse(r.upsert(info("a")), "内容未变化不应产生新版本")
        XCTAssertEqual(r.layoutVersion, v1)
        XCTAssertTrue(r.upsert(info("a", size: Size(700, 500))))
        XCTAssertGreaterThan(r.layoutVersion, v1)
    }

    func testRemoveBumpsLayoutVersionAndShrinksTable() {
        let r = WindowRegistry(epoch: 1)
        r.upsert(info("a")); r.upsert(info("b"))
        let v = r.layoutVersion
        XCTAssertTrue(r.remove("b"))
        XCTAssertGreaterThan(r.layoutVersion, v)
        XCTAssertEqual(r.count, 1)
        XCTAssertFalse(r.remove("nope"))
    }

    func testResetClearsEverythingIncludingUIDSpace() {
        let r = WindowRegistry(epoch: 1)
        r.upsert(info("a"))
        r.reset(epoch: 2)
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.layoutVersion, 0)
        XCTAssertEqual(r.epoch, 2)
    }

    func testApplyResizeReadsBackActualSizeNotRequest() {
        // 规格 §1.2 规则 2：读回的是事实
        let r = WindowRegistry(epoch: 1)
        r.upsert(WindowInfo(windowUID: "a", appPID: 1, appLaunchID: "L", bundleID: "b", title: "a",
                            role: .main, contentRect: Rect(0, 0, 640, 480),
                            constraints: SizeConstraints(minSize: Size(500, 400), resizable: .both)))
        // 远端只放大到 500x400，而不是请求的 200x100
        let result = r.applyResize(uid: "a", requested: Size(200, 100)) { _, req in (Size(500, 400), .appMin) }
        XCTAssertEqual(result?.actualContentSize, Size(500, 400))
        XCTAssertEqual(result?.constrainedBy, .appMin)
        XCTAssertEqual(r.window("a")?.contentSize, Size(500, 400))
    }

    func testVanishedUIDsFindsWindowsThatDisappeared() {
        let r = WindowRegistry(epoch: 1)
        r.upsert(info("a")); r.upsert(info("b"))
        let vanished = r.vanishedUIDs(comparedTo: ["a", "c"])
        XCTAssertEqual(vanished, ["c"], "本地存在但远端已消失的窗口必须被识别出来")
    }
}

// MARK: - 尺寸请求合并

final class ResizeCoalescerTests: XCTestCase {

    func testRequestsAreCoalescedToConfiguredInterval() {
        let c = ResizeCoalescer(interval: 0.1)
        // 高频率拖动：0.1s 内多次提交只发一次
        var emitted = 0
        for i in 0..<20 {
            let t = Double(i) * 0.005   // 每 5ms 一次
            if c.submit(uid: "w", size: Size(Double(300 + i), 400), now: t) != nil { emitted += 1 }
        }
        XCTAssertLessThanOrEqual(emitted, 2, "10Hz 节流应把 20 次请求压到不超过 2 次")
    }

    func testOnlyNewestRequestSurvivesCoalescing() {
        let c = ResizeCoalescer(interval: 0.1)
        _ = c.submit(uid: "w", size: Size(300, 300), now: 0)
        let second = c.submit(uid: "w", size: Size(400, 400), now: 0.05)
        XCTAssertNil(second, "未到间隔不发")
        let third = c.submit(uid: "w", size: Size(500, 500), now: 0.2)
        XCTAssertEqual(third?.size, Size(500, 500), "应发出最新值，而不是被丢弃的中间值")
    }

    func testFlushIgnoresThrottle() {
        let c = ResizeCoalescer(interval: 1.0)
        _ = c.submit(uid: "w", size: Size(300, 300), now: 0)
        let flushed = c.flush(uid: "w", size: Size(600, 500))
        XCTAssertEqual(flushed.size, Size(600, 500))
        XCTAssertTrue(c.isNewest(seq: flushed.seq))
    }

    func testStaleSeqIsNotNewest() {
        let c = ResizeCoalescer(interval: 0)
        let s1 = c.submit(uid: "w", size: Size(300, 300), now: 0)!
        let s2 = c.submit(uid: "w", size: Size(400, 400), now: 1.0)!
        XCTAssertFalse(c.isNewest(seq: s1.seq), "旧请求的结果必须被识别为过期")
        XCTAssertTrue(c.isNewest(seq: s2.seq))
    }
}

// MARK: - 本地窗口壳表

final class RemoteWindowTableTests: XCTestCase {

    private func win(_ uid: String, role: WindowRole = .main, size: Size = Size(640, 480),
                     parent: String? = nil, modal: Bool = false) -> WindowInfo {
        WindowInfo(windowUID: uid, appPID: 1, appLaunchID: "L", bundleID: "b", title: uid,
                   role: role, parentUID: parent, modal: modal,
                   contentRect: Rect(origin: .zero, size: size))
    }

    private func snap(_ windows: [WindowInfo], version: UInt64 = 1) -> WindowSnapshot {
        WindowSnapshot(epoch: 1, layoutVersion: version, windows: windows)
    }

    func testMainWindowCreatesShell() {
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("a")]))
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.shell("a")?.remoteContentSize, Size(640, 480))
        XCTAssertEqual(t.shell("a")?.localContentSize, Size(640, 480))
    }

    func testUnknownRoleCreatesShellAndIsMarkedDegraded() {
        // 规格 §1.3：unknown 必须建壳并标注，不得退化为共享整桌面
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("u", role: .unknown)]))
        XCTAssertNotNil(t.shell("u"))
        XCTAssertTrue(t.shell("u")!.isDegraded)
        XCTAssertNotNil(t.shell("u")?.degradedReason)
    }

    func testChildWindowIsNotGivenASeparateShell() {
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("main"), win("c", role: .child)]))
        XCTAssertNotNil(t.shell("main"))
        XCTAssertNil(t.shell("c"), "子窗口随主窗口画面显示，不单独建壳")
    }

    func testDialogAndPanelGetShells() {
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("d", role: .dialog), win("p", role: .panel), win("m", role: .popupMenu)]))
        XCTAssertEqual(t.count, 3)
    }

    func testVanishedRemoteWindowClosesLocalShell() {
        // T-WIN-12：不得留下接收输入的僵尸窗口
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("a"), win("b")]))
        XCTAssertEqual(t.count, 2)
        let closed = t.apply(snapshot: snap([win("a")], version: 2))
        XCTAssertEqual(closed, ["b"])
        XCTAssertNil(t.shell("b"))
        XCTAssertEqual(t.count, 1)
    }

    func testLiveResizeDoesNotSnapBackToRemoteSize() {
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("a")]))
        t.beginLiveResize(uid: "a", localSize: Size(900, 700))
        XCTAssertEqual(t.shell("a")?.localContentSize, Size(900, 700))
        // 拖动中到达的旧快照不得把本地尺寸拉回
        _ = t.apply(snapshot: snap([win("a")], version: 5))
        XCTAssertEqual(t.shell("a")?.localContentSize, Size(900, 700), "拖动中不应被远端旧尺寸打断")
    }

    func testEndLiveResizeUsesRemoteActualSize() {
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("a")]))
        t.beginLiveResize(uid: "a", localSize: Size(900, 700))
        // 远端只接受 800x600
        t.endLiveResize(uid: "a", actual: Size(800, 600), layoutVersion: 9)
        XCTAssertEqual(t.shell("a")?.localContentSize, Size(800, 600), "必须以远端实际尺寸为准")
        XCTAssertEqual(t.shell("a")?.layoutVersion, 9)
        XCTAssertFalse(t.shell("a")!.isLiveResizing)
    }

    func testConsistencyCheckDetectsMismatch() {
        let t = RemoteWindowTable()
        let s = snap([win("a"), win("b")])
        _ = t.apply(snapshot: s)
        XCTAssertTrue(t.isConsistent(with: s))
        _ = t.apply(snapshot: snap([win("a")], version: 2))
        XCTAssertFalse(t.isConsistent(with: s))
    }

    func testResetForReconnectClearsShells() {
        let t = RemoteWindowTable()
        _ = t.apply(snapshot: snap([win("a")]))
        t.resetForReconnect()
        XCTAssertEqual(t.count, 0)
    }
}
