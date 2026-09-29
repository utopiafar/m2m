import XCTest
@testable import M2MCore

// MARK: - 按键路由闸门

/// 对应验收用例 T-CN-06 / T-CN-07 / T-CN-08 / T-CN-12。
/// 这是"选词的 Enter 绝不能顺便变成发送"的机器可验证形式。
final class InputGateTests: XCTestCase {

    private let gate = InputGate()

    func testEnterDuringCompositionStaysLocal() {
        // 最高优先级用例：组合中按 Enter 只完成选词
        let route = gate.route(keycode: KeyCode.returnKey, flags: [], isComposing: true, imeConsumed: false)
        XCTAssertEqual(route, .localIME, "组合中的 Enter 必须留在本地，否则会误触发送")
    }

    func testKeypadEnterDuringCompositionStaysLocal() {
        let route = gate.route(keycode: KeyCode.keypadEnter, flags: [], isComposing: true, imeConsumed: false)
        XCTAssertEqual(route, .localIME)
    }

    func testDigitsDuringCompositionSelectCandidatesLocally() {
        for digit in KeyCode.digits {
            let route = gate.route(keycode: digit, flags: [], isComposing: true, imeConsumed: false)
            XCTAssertEqual(route, .localIME, "数字键在组合中用于选词，不得外发")
        }
    }

    func testArrowsDuringCompositionStayLocal() {
        for key in KeyCode.arrowKeys {
            let route = gate.route(keycode: key, flags: [], isComposing: true, imeConsumed: false)
            XCTAssertEqual(route, .localIME, "方向键在组合中用于翻页选词")
        }
    }

    func testSpaceDuringCompositionStaysLocal() {
        let route = gate.route(keycode: KeyCode.space, flags: [], isComposing: true, imeConsumed: false)
        XCTAssertEqual(route, .localIME)
    }

    func testBackspaceDuringCompositionStaysLocal() {
        let route = gate.route(keycode: KeyCode.delete, flags: [], isComposing: true, imeConsumed: false)
        XCTAssertEqual(route, .localIME, "退格应作用于组合文本，不得删除远端已提交文字")
    }

    func testEscapeCancelsCompositionLocally() {
        let route = gate.route(keycode: KeyCode.escape, flags: [], isComposing: true, imeConsumed: false)
        XCTAssertEqual(route, .localIME)
    }

    func testIMEConsumedKeyNeverGoesRemote() {
        let route = gate.route(keycode: 0, flags: [], isComposing: false, imeConsumed: true)
        XCTAssertEqual(route, .localIME)
    }

    func testCommandShortcutGoesRemote() {
        let route = gate.route(keycode: 8, flags: [.command], isComposing: false, imeConsumed: false)  // Cmd+C
        XCTAssertEqual(route, .remote(.shortcut))
    }

    func testCommandShiftShortcutGoesRemote() {
        let route = gate.route(keycode: 8, flags: [.command, .shift], isComposing: false, imeConsumed: false)
        XCTAssertEqual(route, .remote(.shortcut))
    }

    func testPlainArrowGoesRemoteAsNavigationWhenNotComposing() {
        let route = gate.route(keycode: KeyCode.leftArrow, flags: [], isComposing: false, imeConsumed: false)
        XCTAssertEqual(route, .remote(.navigation))
    }

    func testPlainReturnGoesRemoteAsEditingWhenNotComposing() {
        let route = gate.route(keycode: KeyCode.returnKey, flags: [], isComposing: false, imeConsumed: false)
        XCTAssertEqual(route, .remote(.editing), "非组合态的回车属于应用操作（发送/换行）")
    }

    func testPlainLetterGoesToLocalIMEToAllowNewComposition() {
        let route = gate.route(keycode: 0, flags: [], isComposing: false, imeConsumed: false)
        XCTAssertEqual(route, .localIME)
    }

    func testControlSpaceIsConsumedLocallyForIMESwitch() {
        let route = gate.route(keycode: KeyCode.space, flags: [.control], isComposing: false, imeConsumed: false)
        if case .consumedLocally = route { } else {
            XCTFail("Ctrl+Space 应本地消费（切换输入法），实际 \(route)")
        }
    }

    func testTabDuringCompositionStaysLocal() {
        let route = gate.route(keycode: KeyCode.tab, flags: [], isComposing: true, imeConsumed: false)
        XCTAssertEqual(route, .localIME)
    }
}

// MARK: - 文本桥状态机

/// 对应验收用例 T-CN-12 / T-CN-14 / T-CN-15 与规格 §6.1 状态规则表。
final class TextBridgeTests: XCTestCase {

    private func context(editVersion: UInt64 = 1, selection: SelectionInfo = SelectionInfo(valid: false),
                         caretValid: Bool = true, remoteMarked: Bool = false,
                         acceptsUnicode: Bool = true) -> TextContext {
        TextContext(epoch: 1, editVersion: editVersion, windowUID: "w1", nodeID: "field",
                    role: .contentEditable, editable: true, acceptsUnicodeEvents: acceptsUnicode,
                    caret: CaretInfo(valid: caretValid, rectInWindow: Rect(10, 36, 2, 10), lineHeight: 10),
                    selection: selection, remoteMarkedPresent: remoteMarked,
                    remoteMarkedLength: remoteMarked ? 1 : 0)
    }

    func testInitialStateHasNoContext() {
        let b = TextBridge()
        if case .noContext = b.state { } else { XCTFail("初始状态应为 noContext") }
    }

    func testConfirmWithoutContextIsRejected() {
        let b = TextBridge()
        XCTAssertFalse(b.confirmComposition("你好", at: 0))
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty)
        XCTAssertEqual(b.takeEffects(), [.rejectInput(reason: "没有可用的远端输入上下文")])
    }

    func testContextArrivalEnablesIdleState() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 5))
        XCTAssertEqual(b.state, .idle(editVersion: 5))
    }

    func testConfirmProducesExactlyOneCommit() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 3))
        XCTAssertTrue(b.confirmComposition("你好", at: 0))
        let commits = b.takeOutgoingCommits()
        XCTAssertEqual(commits.count, 1, "一次确认只能产生一次提交，否则会重复输入")
        XCTAssertEqual(commits[0].text, "你好")
        XCTAssertEqual(commits[0].editVersion, 3)
        XCTAssertEqual(commits[0].commitSeq, 1)
        XCTAssertTrue(commits[0].fromLocalMarked)
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty, "取出后不得再次产生提交")
        let uiSends = b.takeEffects().filter { if case .sendCommit = $0 { return true }; return false }
        XCTAssertTrue(uiSends.isEmpty, "UI 副作用队列不得携带提交，否则存在重复发送风险")
    }

    func testCommitWithSelectionBecomesReplaceSelection() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1, selection: SelectionInfo(valid: true, location: 2, length: 3)))
        _ = b.confirmComposition("替换", at: 0)
        guard let c = b.takeOutgoingCommits().first else { return XCTFail("应产生一次提交") }
        XCTAssertEqual(c.intent, .replaceSelection)
        XCTAssertEqual(c.replaceRange?.location, 2)
        XCTAssertEqual(c.replaceRange?.length, 3)
    }

    func testAppliedResultReturnsToIdleWithNewVersion() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        b.receive(result: TextCommitResult(commitSeq: 1, status: .applied, newEditVersion: 2))
        XCTAssertEqual(b.state, .idle(editVersion: 2))
    }

    func testStaleResultDoesNotRetryAndRequestsRefresh() {
        // 规格 §3.2：版本不匹配不自动重发，交回用户决定
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        XCTAssertEqual(b.takeOutgoingCommits().count, 1)
        b.receive(result: TextCommitResult(commitSeq: 1, status: .rejectedStale))
        let effects = b.takeEffects()
        XCTAssertTrue(effects.contains { if case .requestContextRefresh = $0 { return true }; return false })
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty, "被判定为过期后绝不能自动重发")
        XCTAssertEqual(b.state, .idle(editVersion: 1))
    }

    func testUnknownResultEntersPendingUnknownWithoutRetry() {
        // 最高优先级：结果不明时不得自动重试
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        XCTAssertEqual(b.takeOutgoingCommits().count, 1)
        _ = b.takeEffects()
        b.receive(result: TextCommitResult(commitSeq: 1, status: .unknown))
        guard case .pendingUnknown(_, let text, _) = b.state else {
            return XCTFail("unknown 结果必须进入 pendingUnknown，实际 \(b.state)")
        }
        XCTAssertEqual(text, "你好")
        let effects = b.takeEffects()
        XCTAssertTrue(effects.contains { if case .showNotice(let n) = $0 { return n.contains("未确认") }; return false })
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty, "结果不明时绝不能自动重发")
    }

    func testFurtherInputIsBlockedWhilePendingUnknown() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        XCTAssertEqual(b.takeOutgoingCommits().count, 1)
        b.receive(result: TextCommitResult(commitSeq: 1, status: .unknown))
        _ = b.takeEffects()
        XCTAssertFalse(b.confirmComposition("世界", at: 0), "结果未确认期间必须阻断新的提交")
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty)
        let effects = b.takeEffects()
        XCTAssertTrue(effects.contains { if case .rejectInput = $0 { return true }; return false })
    }

    func testKeysAreConsumedLocallyWhilePendingUnknown() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        _ = b.takeOutgoingCommits()
        b.receive(result: TextCommitResult(commitSeq: 1, status: .unknown))
        let route = b.routeKey(keycode: 8, flags: [.command], imeConsumed: false)
        if case .consumedLocally = route { } else {
            XCTFail("结果未确认期间不得向远端发送任何输入，实际 \(route)")
        }
    }

    func testContextRefreshAfterUnknownRecoversToIdle() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        _ = b.takeOutgoingCommits()
        b.receive(result: TextCommitResult(commitSeq: 1, status: .unknown))
        _ = b.takeEffects()
        b.receive(context: context(editVersion: 2))
        XCTAssertEqual(b.state, .idle(editVersion: 2))
        let effects = b.takeEffects()
        XCTAssertTrue(effects.contains { if case .showNotice(let n) = $0 { return n.contains("重新同步") }; return false })
    }

    func testCompositionCancelledOnContextInvalidationAndMarkedTextDiscarded() {
        // T-CN-12：组合中切窗口，绝不把未确认的拼音提交到任何控件
        let b = TextBridge()
        b.receive(context: context())
        b.beginComposition(editVersion: 1)
        b.updateComposition("nihao")
        _ = b.takeEffects()
        b.invalidate(reason: .focusMoved)
        let effects = b.takeEffects()
        XCTAssertTrue(effects.contains(.clearCompositionDisplay))
        XCTAssertTrue(effects.contains { if case .showNotice(let n) = $0 { return n.contains("nihao") }; return false })
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty, "组合文本绝不能被自动提交")
        if case .noContext = b.state { } else { XCTFail("失效后应回到 noContext") }
    }

    func testRemoteMarkedTextTriggersResyncNotice() {
        let b = TextBridge()
        b.receive(context: context(remoteMarked: true))
        let effects = b.takeEffects()
        XCTAssertTrue(effects.contains { if case .requestContextRefresh = $0 { return true }; return false })
        XCTAssertTrue(effects.contains { if case .showNotice(let n) = $0 { return n.contains("组合文本") }; return false })
    }

    func testLateOrDuplicateResultIsIgnored() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        _ = b.takeOutgoingCommits()
        b.receive(result: TextCommitResult(commitSeq: 1, status: .applied, newEditVersion: 2))
        _ = b.takeEffects()
        // 迟到的重复结果
        b.receive(result: TextCommitResult(commitSeq: 1, status: .applied, newEditVersion: 3))
        XCTAssertEqual(b.state, .idle(editVersion: 2), "迟到结果不得改写状态")
        XCTAssertTrue(b.takeEffects().isEmpty)
    }

    func testCommitTimeoutTransitionsToPendingUnknown() {
        let b = TextBridge()
        b.commitTimeout = 1.0
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        XCTAssertEqual(b.takeOutgoingCommits().count, 1)
        _ = b.takeEffects()
        b.tick(now: 2.0)
        guard case .pendingUnknown = b.state else { return XCTFail("超时必须转入 pendingUnknown") }
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty, "超时后不得自动重发")
    }

    func testQueuedCommitDuringInFlightIsSentAfterCompletion() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("第一", at: 0)
        _ = b.takeEffects()
        XCTAssertEqual(b.takeOutgoingCommits().count, 1)
        // 提交中排队
        XCTAssertFalse(b.confirmComposition("第二", at: 0))
        XCTAssertEqual(b.pendingQueueCount, 1)
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty)
        _ = b.takeEffects()
        // 第一条完成 → 队列自动发出第二条
        b.receive(result: TextCommitResult(commitSeq: 1, status: .applied, newEditVersion: 2))
        let queued = b.takeOutgoingCommits()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.text, "第二")
    }

    func testEmptyConfirmCancelsCompositionInsteadOfSending() {
        let b = TextBridge()
        b.receive(context: context())
        b.beginComposition(editVersion: 1)
        b.updateComposition("ni")
        _ = b.takeEffects()
        XCTAssertFalse(b.confirmComposition("", at: 0))
        let effects = b.takeEffects()
        XCTAssertTrue(effects.contains(.clearCompositionDisplay))
        XCTAssertTrue(b.takeOutgoingCommits().isEmpty)
    }

    func testRejectedNoFocusReturnsToIdleWithNotice() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        _ = b.takeOutgoingCommits()
        _ = b.takeEffects()
        b.receive(result: TextCommitResult(commitSeq: 1, status: .rejectedNoFocus))
        XCTAssertEqual(b.state, .idle(editVersion: 1))
        XCTAssertTrue(b.takeEffects().contains { if case .showNotice(let n) = $0 { return n.contains("未聚焦") }; return false })
    }

    func testUnsupportedCommitSwitchesToDegradedNotice() {
        let b = TextBridge()
        b.receive(context: context(editVersion: 1))
        _ = b.confirmComposition("你好", at: 0)
        _ = b.takeOutgoingCommits()
        _ = b.takeEffects()
        b.receive(result: TextCommitResult(commitSeq: 1, status: .rejectedUnsupported))
        XCTAssertTrue(b.takeEffects().contains { if case .showNotice(let n) = $0 { return n.contains("降级") }; return false })
    }
}

// MARK: - Host 侧文本会话

final class TextSessionTests: XCTestCase {

    private func makeSession(buffer: String = "", caret: Int = 0) -> (TextSession, MutableTextContextProvider, RecordingTextCommitExecutor) {
        let provider = MutableTextContextProvider()
        let executor = RecordingTextCommitExecutor()
        executor.buffer = buffer
        executor.caret = caret
        provider.context = TextContext(epoch: 1, editVersion: 1, windowUID: "w", nodeID: "n",
                                       role: .textField, editable: true, acceptsUnicodeEvents: true,
                                       caret: CaretInfo(valid: true), selection: SelectionInfo(valid: false))
        let session = TextSession(provider: provider, executor: executor)
        return (session, provider, executor)
    }

    private func commit(seq: UInt32, version: UInt64, text: String,
                        window: String = "w", node: String = "n",
                        intent: TextIntent = .insertText,
                        replace: SelectionInfo? = nil) -> TextCommit {
        TextCommit(epoch: 1, windowUID: window, nodeID: node, editVersion: version,
                   commitSeq: seq, text: text, fromLocalMarked: true,
                   replaceRange: replace, intent: intent)
    }

    func testMatchingVersionIsAppliedAndVersionAdvances() {
        let (s, _, exec) = makeSession()
        let r = s.handle(commit(seq: 1, version: 1, text: "你好"))
        XCTAssertEqual(r.status, .applied)
        XCTAssertEqual(r.newEditVersion, 2)
        XCTAssertEqual(exec.buffer, "你好")
        XCTAssertEqual(s.currentEditVersion, 2)
    }

    func testVersionMismatchIsRejectedAsStaleWithoutExecuting() {
        // 规格 §3.2：远端不匹配则拒绝执行，绝不猜
        let (s, _, exec) = makeSession()
        let r = s.handle(commit(seq: 1, version: 99, text: "你好"))
        XCTAssertEqual(r.status, .rejectedStale)
        XCTAssertTrue(exec.executed.isEmpty, "版本不匹配时不得执行")
        XCTAssertEqual(exec.buffer, "")
    }

    func testSecondCommitWithOldVersionIsRejected() {
        let (s, _, exec) = makeSession()
        _ = s.handle(commit(seq: 1, version: 1, text: "第一"))
        let r = s.handle(commit(seq: 2, version: 1, text: "第二"))
        XCTAssertEqual(r.status, .rejectedStale)
        XCTAssertEqual(exec.buffer, "第一")
    }

    func testSameCommitSeqIsIdempotent() {
        // 网络重传场景：同一 commitSeq 只能执行一次
        let (s, _, exec) = makeSession()
        _ = s.handle(commit(seq: 7, version: 1, text: "你好"))
        let again = s.handle(commit(seq: 7, version: 1, text: "你好"))
        XCTAssertEqual(again.status, .applied)
        XCTAssertEqual(exec.buffer, "你好", "重复提交不得产生重复文字")
        XCTAssertEqual(exec.executed.count, 1)
    }

    func testWrongNodeIsRejectedAsStale() {
        let (s, _, _) = makeSession()
        let r = s.handle(commit(seq: 1, version: 1, text: "你好", node: "other"))
        XCTAssertEqual(r.status, .rejectedStale)
    }

    func testNoFocusIsRejected() {
        let (s, provider, _) = makeSession()
        provider.context = nil
        let r = s.handle(commit(seq: 1, version: 1, text: "你好"))
        XCTAssertEqual(r.status, .rejectedNoFocus)
    }

    func testUnsupportedControlIsRejected() {
        let (s, _, exec) = makeSession()
        exec.supportsCommit = false
        let r = s.handle(commit(seq: 1, version: 1, text: "你好"))
        XCTAssertEqual(r.status, .rejectedUnsupported)
        XCTAssertEqual(exec.buffer, "")
    }

    func testSelectionReplacementPreservesSurroundingText() {
        let (s, _, exec) = makeSession(buffer: "abcdef", caret: 2)
        let r = s.handle(commit(seq: 1, version: 1, text: "XY",
                                intent: .replaceSelection,
                                replace: SelectionInfo(valid: true, location: 2, length: 2)))
        XCTAssertEqual(r.status, .applied)
        XCTAssertEqual(exec.buffer, "abXYef", "选区替换必须保留前后文本")
    }

    func testDeleteBackwardRemovesOneCharacter() {
        let (s, _, exec) = makeSession(buffer: "你好", caret: 2)
        _ = s.handle(commit(seq: 1, version: 1, text: "", intent: .deleteBackward))
        XCTAssertEqual(exec.buffer, "你")
    }

    func testDeleteBackwardAtStartIsNoOp() {
        let (s, _, exec) = makeSession(buffer: "你好", caret: 0)
        _ = s.handle(commit(seq: 1, version: 1, text: "", intent: .deleteBackward))
        XCTAssertEqual(exec.buffer, "你好")
    }

    func testNewlineInsertion() {
        let (s, _, exec) = makeSession(buffer: "ab", caret: 2)
        _ = s.handle(commit(seq: 1, version: 1, text: "\n", intent: .newline))
        XCTAssertEqual(exec.buffer, "ab\n")
    }

    func testLongTextCommitIsNotTruncated() {
        let (s, _, exec) = makeSession()
        let long = String(repeating: "长文本测试。", count: 200)
        let r = s.handle(commit(seq: 1, version: 1, text: long))
        XCTAssertEqual(r.status, .applied)
        XCTAssertEqual(exec.buffer.count, long.count)
    }

    func testRemoteEditBumpInvalidatesInFlightVersion() {
        let (s, _, _) = makeSession()
        _ = s.handle(commit(seq: 1, version: 1, text: "第一"))
        let newVersion = s.bumpEditVersion(reason: "用户在远端直接输入")
        XCTAssertEqual(newVersion, 3)
        let r = s.handle(commit(seq: 2, version: 2, text: "第二"))
        XCTAssertEqual(r.status, .rejectedStale, "远端状态变化后，旧版本提交必须被拒绝")
    }
}
