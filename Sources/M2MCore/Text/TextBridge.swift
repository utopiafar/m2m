import Foundation

// MARK: - 键码与修饰键

/// macOS 虚拟键码中本项目需要识别的部分。
public enum KeyCode {
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51        // Backspace
    public static let forwardDelete: UInt16 = 117
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121

    /// 数字键 0–9（ANSI 布局）
    public static let digits: Set<UInt16> = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]

    public static let arrowKeys: Set<UInt16> = [leftArrow, rightArrow, downArrow, upArrow]
}

/// 修饰键位（与 NSEvent.ModifierFlags 的原始值一致，便于直接桥接）。
public struct ModifierFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = ModifierFlags(rawValue: 0x20000)
    public static let control = ModifierFlags(rawValue: 0x40000)
    public static let option = ModifierFlags(rawValue: 0x80000)
    public static let command = ModifierFlags(rawValue: 0x100000)
    public static let function = ModifierFlags(rawValue: 0x800000)

    /// 会改变按键语义的修饰键集合（用于判断是否属于快捷键）。
    public var hasCommandLikeModifier: Bool {
        contains(.command) || contains(.control) || contains(.option)
    }

    public var isCommandOnlyShift: Bool {
        contains(.command) && contains(.shift) && !contains(.control) && !contains(.option)
    }

    public static let allModifiers: [ModifierFlags] = [.shift, .control, .option, .command, .function]
}

// MARK: - 按键路由

/// 一个按键应当交给本地输入法，还是发往远端。
public enum KeyRoute: Equatable, Sendable {
    /// 交给本地输入法（组合文本、候选窗、选词）。
    case localIME
    /// 发往远端应用。
    case remote(KeyCategory)
    /// 本地消费但不外发（例如切换输入法的 Cmd+Space）。
    case consumedLocally(reason: String)
}

/// 输入路由闸门。
///
/// 这是规格 §2 "选词的 Enter 绝不能顺便变成发送" 与 §2 第三点
/// "文字提交与物理按键必须分成两条逻辑" 的落点。
public struct InputGate: Sendable {
    public init() {}

    /// 判断一个按键的去向。
    ///
    /// - Parameters:
    ///   - isComposing: 本地输入法当前是否有未确认的组合文本
    ///   - imeConsumed: 本地输入法是否已消费该按键（`NSTextInputClient` 路径的结果）
    public func route(keycode: UInt16, flags: ModifierFlags,
                      isComposing: Bool, imeConsumed: Bool) -> KeyRoute {
        // 本地输入法已经消费：一律本地，绝不外发
        if imeConsumed { return .localIME }

        if isComposing {
            // 组合期间：候选选择、翻页、取消、退格全部留在本地
            switch keycode {
            case KeyCode.escape, KeyCode.delete, KeyCode.forwardDelete,
                 KeyCode.space, KeyCode.tab,
                 KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow:
                return .localIME
            case KeyCode.returnKey, KeyCode.keypadEnter:
                // 组合期间的回车属于"确认选词"，不是发送
                return .localIME
            default:
                if KeyCode.digits.contains(keycode) { return .localIME }
                if KeyCode.arrowKeys.contains(keycode) { return .localIME }
                // 组合期间的方向键之外，仍留在本地直到组合结束
                return .localIME
            }
        }

        // 非组合态：输入法切换等本地快捷键
        if flags.contains(.control) && keycode == KeyCode.space {
            return .consumedLocally(reason: "切换输入法")
        }
        // 不带修饰键的普通字符键：先给本地输入法（可能触发新的组合）
        if !flags.hasCommandLikeModifier {
            switch keycode {
            case KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow,
                 KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown:
                return .remote(.navigation)
            case KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.tab:
                return .remote(.editing)
            case KeyCode.delete, KeyCode.forwardDelete, KeyCode.escape:
                return .remote(.editing)
            default:
                // 普通字符：交给本地输入法判断是直接输入还是开始组合
                return .localIME
            }
        }
        // 带修饰键：快捷键，发往远端
        return .remote(.shortcut)
    }

    /// 组合文本是否已确认。用于决定是否产生 `TextCommit`。
    public func isCommitText(_ marked: String) -> Bool { !marked.isEmpty }
}

// MARK: - 文本桥状态机（Viewer 侧）

public enum TextBridgeState: Equatable, Sendable {
    case noContext(reason: String)
    case idle(editVersion: UInt64)
    case composing(marked: String, editVersion: UInt64)
    case committing(commitSeq: UInt32, text: String)
    /// 提交结果不明：**禁止自动重试**（规格 §3.2 / §6.1）。
    case pendingUnknown(commitSeq: UInt32, text: String, since: TimeInterval)

    public var isComposing: Bool { if case .composing = self { return true }; return false }
    public var isCommitting: Bool { if case .committing = self { return true }; return false }

    public var localizedDescription: String {
        switch self {
        case .noContext(let r): return "无可用输入上下文（\(r)）"
        case .idle: return "就绪"
        case .composing(let m, _): return "组合中：\(m)"
        case .committing(_, let t): return "提交中：\(t)"
        case .pendingUnknown(_, let t, _): return "上一条输入结果未确认：\(t)"
        }
    }
}

/// 状态机的副作用输出。UI 与网络层据此动作，状态机本身不产生 IO。
public enum TextBridgeEffect: Equatable, Sendable {
    case sendCommit(TextCommit)
    case updateCompositionDisplay(String)
    case clearCompositionDisplay
    /// 非阻塞提示（不得显示为"已发送"）。
    case showNotice(String)
    case requestContextRefresh(reason: String)
    /// 阻断输入并说明原因。
    case rejectInput(reason: String)
}

/// Viewer 侧文本桥。
///
/// 设计目标（规格 §6.1）：所有规则都在状态机内可测，不依赖真实输入法即可验证
/// 顺序、去重、禁止重试等不变量。真实输入法只负责产生 `beginComposition` /
/// `updateComposition` / `confirmComposition` 三个事件。
public final class TextBridge {
    public private(set) var state: TextBridgeState = .noContext(reason: "尚未收到远端上下文")
    public private(set) var context: TextContext?
    /// 面向 UI 的副作用（提示、组合显示等）。**不含提交**，提交走 outgoing 队列。
    public private(set) var effects: [TextBridgeEffect] = []
    /// 待发送的提交。只有这一个出口，杜绝"既用返回值又用 effects 发送"造成的重复提交。
    private var outgoing: [TextCommit] = []
    public private(set) var commitSeq: UInt32 = 0

    /// 提交确认超时。超时后进入 `pendingUnknown`，不自动重试。
    public var commitTimeout: TimeInterval = 2.0
    /// 是否允许在 `committing` 期间排队新输入。
    public var queueDuringCommit = true

    private var queuedText: [String] = []
    /// 提交发起时刻，使用**调用方时钟**（与传输层同一时间基准）。
    /// 混用真实时钟与模拟时钟会让超时判定永远不触发。
    private var pendingCommitAt: TimeInterval?
    /// 提交在途时到达的新上下文版本，等提交确认后再采用，避免打断确认流程。
    private var pendingContextVersion: UInt64?
    private let gate = InputGate()

    public init() {}

    // MARK: 事件

    public func receive(context ctx: TextContext) {
        context = ctx
        // 远端已有组合文本：属于异常，交由适配层解释，此处仅提示
        if ctx.remoteMarkedPresent {
            effects.append(.showNotice("远端输入框存在未确认的组合文本，已请求重新同步"))
            effects.append(.requestContextRefresh(reason: "remoteMarked"))
        }
        switch state {
        case .committing:
            // 提交在途时到达的新上下文**不得打断提交确认**。
            // 否则会丢掉 applied 确认，进而被超时逻辑误判为"结果不明"。
            pendingContextVersion = ctx.editVersion
            return
        case .composing:
            // 组合中远端编辑状态变化：丢弃本地组合，绝不把未确认的拼音写进新控件
            effects.append(.showNotice("远端编辑状态已变化，未确认的输入已丢弃"))
            effects.append(.clearCompositionDisplay)
        case .pendingUnknown:
            // 结果由新的上下文揭示，不自动重试
            effects.append(.showNotice("已重新同步远端编辑状态"))
        default:
            break
        }
        state = .idle(editVersion: ctx.editVersion)
        drainQueueIfIdle()
    }

    /// 收到失效通知：立即清空组合区并丢弃未提交的组合文本（规格 §6.1）。
    public func invalidate(reason: ContextInvalidationReason) {
        if case .composing(let marked, _) = state, !marked.isEmpty {
            effects.append(.showNotice("输入焦点已变化，未确认的「\(marked)」已丢弃"))
        }
        if case .pendingUnknown(_, let text, _) = state {
            effects.append(.showNotice("编辑上下文已失效，此前未确认的「\(text)」不会再自动发送"))
        }
        context = nil
        state = .noContext(reason: reason.localizedDescription)
        effects.append(.clearCompositionDisplay)
        queuedText.removeAll()
        pendingContextVersion = nil
    }

    public func beginComposition(editVersion: UInt64) {
        guard case .idle(let v) = state, v == editVersion else {
            effects.append(.rejectInput(reason: "当前不在可输入状态"))
            return
        }
        state = .composing(marked: "", editVersion: editVersion)
    }

    public func updateComposition(_ marked: String) {
        guard case .composing(_, let v) = state else { return }
        state = .composing(marked: marked, editVersion: v)
        effects.append(.updateCompositionDisplay(marked))
    }

    public func cancelComposition() {
        guard case .composing = state else { return }
        state = .idle(editVersion: context?.editVersion ?? 0)
        effects.append(.clearCompositionDisplay)
    }

    /// 用户确认选词 → 产生一次文本提交。
    ///
    /// 提交只进入 `outgoing` 队列（由调用方通过 `takeOutgoingCommits()` 取出），
    /// `effects` 仅承载 UI 提示。两者不重叠，避免重复提交。
    @discardableResult
    public func confirmComposition(_ text: String, intent: TextIntent = .insertText,
                                   at now: TimeInterval = 0) -> Bool {
        guard let ctx = context else {
            effects.append(.rejectInput(reason: "没有可用的远端输入上下文"))
            return false
        }
        guard !text.isEmpty else {
            cancelComposition()
            return false
        }
        // 结果不明未解决前不允许继续提交，避免在未知状态下叠加新编辑
        if case .pendingUnknown = state {
            effects.append(.rejectInput(reason: "上一条输入结果未确认，请先确认远端状态"))
            return false
        }
        if case .committing = state {
            if queueDuringCommit {
                queuedText.append(text)
                effects.append(.showNotice("上一条输入仍在等待确认，本条已排队"))
                return false
            } else {
                effects.append(.rejectInput(reason: "上一条输入仍在提交中"))
                return false
            }
        }
        commitSeq &+= 1
        let selection = ctx.selection.valid && ctx.selection.length > 0 ? ctx.selection : nil
        let commit = TextCommit(epoch: ctx.epoch, windowUID: ctx.windowUID, nodeID: ctx.nodeID,
                                editVersion: ctx.editVersion, commitSeq: commitSeq,
                                text: text, fromLocalMarked: true,
                                replaceRange: selection,
                                intent: selection != nil ? .replaceSelection : intent)
        state = .committing(commitSeq: commitSeq, text: text)
        pendingCommitAt = now
        effects.append(.clearCompositionDisplay)
        outgoing.append(commit)
        return true
    }

    public func receive(result: TextCommitResult) {
        guard case .committing(let seq, let text) = state, seq == result.commitSeq else {
            // 迟到或重复的结果：忽略，不改状态（幂等）
            return
        }
        pendingCommitAt = nil
        switch result.status {
        case .applied, .appliedPartial:
            if result.status == .appliedPartial {
                effects.append(.showNotice("本次输入仅部分生效：\(result.detail ?? "远端已接受部分内容")"))
            }
            let resolved = max(result.newEditVersion ?? 0, pendingContextVersion ?? 0)
            pendingContextVersion = nil
            state = .idle(editVersion: resolved == 0 ? (context?.editVersion ?? 0) : resolved)
            drainQueueIfIdle()
        case .rejectedStale:
            // 不重发，交回用户决定（规格 §3.2）
            effects.append(.showNotice("远端编辑状态已变化，本次未执行：\(text)"))
            state = .idle(editVersion: context?.editVersion ?? 0)
            effects.append(.requestContextRefresh(reason: "stale"))
        case .rejectedUnsupported:
            effects.append(.showNotice("该输入控件不接受此提交方式，已切换为降级输入"))
            state = .idle(editVersion: context?.editVersion ?? 0)
        case .rejectedNoFocus:
            effects.append(.showNotice("目标输入框未聚焦"))
            state = .idle(editVersion: context?.editVersion ?? 0)
        case .unknown:
            state = .pendingUnknown(commitSeq: seq, text: text, since: pendingCommitAt ?? 0)
            effects.append(.showNotice("上一条输入结果未确认，正在重新同步远端状态"))
        }
    }

    /// 提交超时：转入 `pendingUnknown`，**不自动重试**。
    public func tick(now: TimeInterval) {
        guard case .committing(let seq, let text) = state, let started = pendingCommitAt else { return }
        if now - started >= commitTimeout {
            pendingCommitAt = nil
            state = .pendingUnknown(commitSeq: seq, text: text, since: now)
            effects.append(.showNotice("上一条输入结果未确认，正在重新同步远端状态"))
        }
    }

    /// 按键去向判断的对外入口。
    public func routeKey(keycode: UInt16, flags: ModifierFlags, imeConsumed: Bool) -> KeyRoute {
        if case .pendingUnknown = state {
            // 结果不明期间不向远端发送任何输入
            return .consumedLocally(reason: "输入结果未确认，已暂停向远端发送")
        }
        return gate.route(keycode: keycode, flags: flags,
                          isComposing: state.isComposing, imeConsumed: imeConsumed)
    }

    // MARK: 辅助

    private func drainQueueIfIdle() {
        guard case .idle = state, !queuedText.isEmpty else { return }
        let next = queuedText.removeFirst()
        _ = confirmComposition(next, at: pendingCommitAt ?? 0)
    }

    /// 取出待发送的提交。调用方负责实际发送。
    public func takeOutgoingCommits() -> [TextCommit] {
        let c = outgoing; outgoing.removeAll(); return c
    }

    public func takeEffects() -> [TextBridgeEffect] {
        let e = effects; effects.removeAll(); return e
    }

    public var pendingQueueCount: Int { queuedText.count }
}

// MARK: - Host 侧文本会话

/// 远端编辑状态的提供者。
///
/// **`editVersion` 的所有权在这里，不在 `TextSession`。** 版本必须反映远端应用真实的
/// 编辑状态：如果会话层自己再维护一个计数器，一旦远端状态变化（用户直接在远端打字、
/// 焦点转移、应用重启），两个计数器就会失步，导致合法提交被误判为过期。
public protocol TextContextProvider: AnyObject {
    func currentContext() -> TextContext?
    /// 提交生效后推进权威版本。实现方需要同步更新其上下文的 `editVersion`。
    @discardableResult
    func advanceEditVersion() -> UInt64
}

public extension TextContextProvider {
    /// 默认实现：不持有版本的状态源可以不做任何事。
    @discardableResult
    func advanceEditVersion() -> UInt64 { currentContext()?.editVersion ?? 0 }
}

public protocol TextCommitExecutor: AnyObject {
    /// 执行一次提交。返回实际结果；`editVersion` 不匹配时**必须**返回 `.rejectedStale`。
    func execute(_ commit: TextCommit, context: TextContext) -> TextCommitResult
}

/// Host 侧文本会话：维护权威 `editVersion` 并执行提交。
///
/// 规则：
/// - 版本不匹配 → `.rejectedStale`（不执行、不猜）
/// - 控件不接受 → `.rejectedUnsupported`
/// - 未聚焦 → `.rejectedNoFocus`
/// - 执行成功 → `applied` + 新 `editVersion`
public final class TextSession {
    private let provider: TextContextProvider
    private let executor: TextCommitExecutor
    private var appliedCommitSeqs = Set<UInt32>()

    public init(provider: TextContextProvider, executor: TextCommitExecutor) {
        self.provider = provider
        self.executor = executor
    }

    /// 当前权威版本，直接来自编辑状态的所有者。
    public var currentEditVersion: UInt64 { provider.currentContext()?.editVersion ?? 0 }

    public func handle(_ commit: TextCommit) -> TextCommitResult {
        // 幂等：同一 commitSeq 只执行一次
        if appliedCommitSeqs.contains(commit.commitSeq) {
            return TextCommitResult(commitSeq: commit.commitSeq, status: .applied,
                                    newEditVersion: currentEditVersion,
                                    detail: "重复提交已忽略（幂等）")
        }
        guard let ctx = provider.currentContext() else {
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedNoFocus,
                                    detail: "当前没有聚焦的可编辑控件")
        }
        guard ctx.nodeID == commit.nodeID, ctx.windowUID == commit.windowUID else {
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedStale,
                                    detail: "目标控件已变化")
        }
        guard commit.editVersion == ctx.editVersion else {
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedStale,
                                    detail: "编辑版本不匹配（提交 \(commit.editVersion) / 远端 \(ctx.editVersion)）")
        }
        let result = executor.execute(commit, context: ctx)
        if result.status.isApplied {
            appliedCommitSeqs.insert(commit.commitSeq)
            // 版本由状态所有者推进，这里只读取推进后的值
            let newVersion = provider.advanceEditVersion()
            return TextCommitResult(commitSeq: result.commitSeq, status: result.status,
                                    newEditVersion: newVersion, appliedRange: result.appliedRange,
                                    detail: result.detail)
        }
        return result
    }

    /// 远端编辑状态发生变化（用户直接在远端打字、焦点转移等）时推进版本。
    @discardableResult
    public func bumpEditVersion(reason: String) -> UInt64 {
        _ = reason
        return provider.advanceEditVersion()
    }
}

// MARK: - 测试与演示用实现

/// 记录型提交执行器：用于无 AX 权限环境下的确定性验证。
public final class RecordingTextCommitExecutor: TextCommitExecutor {
    public private(set) var executed: [TextCommit] = []
    /// 模拟远端文本缓冲（不是产品的一部分，仅用于测试断言）。
    public var buffer: String = ""
    public var caret: Int = 0
    public var selectionLength: Int = 0
    public var supportsCommit = true
    public var focused = true
    public var remoteMarked = false

    public init() {}

    public func execute(_ commit: TextCommit, context: TextContext) -> TextCommitResult {
        guard focused else {
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedNoFocus)
        }
        guard supportsCommit else {
            return TextCommitResult(commitSeq: commit.commitSeq, status: .rejectedUnsupported,
                                    detail: "控件不支持该写入方式")
        }
        executed.append(commit)
        var chars = Array(buffer)
        var loc = min(caret, chars.count)
        var appliedLength = commit.text.count
        switch commit.intent {
        case .insertText, .newline:
            if let r = commit.replaceRange, r.valid, r.length > 0 {
                let start = min(r.location, chars.count)
                let len = min(r.length, chars.count - start)
                chars.replaceSubrange(start..<(start + len), with: Array(commit.text))
                loc = start
            } else {
                chars.insert(contentsOf: Array(commit.text), at: loc)
            }
            caret = loc + commit.text.count
        case .replaceSelection:
            if let r = commit.replaceRange, r.valid {
                let start = min(r.location, chars.count)
                let len = min(r.length, chars.count - start)
                chars.replaceSubrange(start..<(start + len), with: Array(commit.text))
                loc = start
            } else {
                chars.insert(contentsOf: Array(commit.text), at: loc)
            }
            caret = loc + commit.text.count
        case .deleteBackward:
            guard loc > 0 else { appliedLength = 0; break }
            chars.removeSubrange((loc - 1)..<loc)
            caret = loc - 1
            appliedLength = 0
        case .deleteForward:
            guard loc < chars.count else { appliedLength = 0; break }
            chars.removeSubrange(loc..<(loc + 1))
            appliedLength = 0
        }
        buffer = String(chars)
        return TextCommitResult(commitSeq: commit.commitSeq, status: .applied,
                                appliedRange: SelectionInfo(valid: true, location: loc, length: appliedLength),
                                detail: nil)
    }
}

/// 可变上下文提供者，测试可驱动。
public final class MutableTextContextProvider: TextContextProvider {
    public var context: TextContext?
    public init(context: TextContext? = nil) { self.context = context }
    public func currentContext() -> TextContext? { context }

    @discardableResult
    public func advanceEditVersion() -> UInt64 {
        guard var c = context else { return 0 }
        c.editVersion &+= 1
        context = c
        return c.editVersion
    }
}

// MARK: - AppKit 层按键去向决策

/// 本地客户端 `keyDown` 的按键处理路径。
///
/// 这里必须区分清楚，否则很容易写出"非组合态的回车被 IME 吞掉"或
/// "组合态的回车直接发往远端"这类错误：
///
/// - `shortcutToRemote`：明确的快捷键，绕过输入法直接发往远端
/// - `interpretByIME`：先交给本地输入法；输入法不消费时经 `doCommand(by:)`
///   再由应用层映射为远端按键。**非组合态的回车/方向/编辑键走这条路**
/// - `imeOnly`：组合期间，只允许本地输入法处理；即使它意外不消费也不外发
public enum KeyHandlingPath: Equatable, Sendable {
    case shortcutToRemote
    case interpretByIME
    case imeOnly

    /// 最终是否会作用到远端（无论经由哪条路径）。
    public var reachesRemote: Bool {
        // interpretByIME 在输入法不消费时会经 doCommand 到达远端
        true
    }
}

public enum IMEKeyDecision {

    /// 判定按键的处理路径。
    public static func path(keycode: UInt16, flags: ModifierFlags,
                            isComposing: Bool) -> KeyHandlingPath {
        // 组合期间一律留在本地输入法。
        // 组合中的 Enter 是"确认选词"，绝不能直接变成远端的发送动作。
        if isComposing { return .imeOnly }
        if flags.hasCommandLikeModifier { return .shortcutToRemote }
        return .interpretByIME
    }

    /// 便捷判断：是否绕过输入法直接发往远端。
    public static func sendsDirectlyToRemote(keycode: UInt16, flags: ModifierFlags,
                                             isComposing: Bool) -> Bool {
        path(keycode: keycode, flags: flags, isComposing: isComposing) == .shortcutToRemote
    }
}
