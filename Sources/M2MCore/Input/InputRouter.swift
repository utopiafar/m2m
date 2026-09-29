import Foundation

/// 输入路由器（Viewer 侧）。
///
/// 承载三条硬规则：
/// - B5：每条输入消息携带目标窗口，不匹配则丢弃并上报
/// - B6/A8：连接丢失时释放所有按下的修饰键
/// - T7：鼠标移动合并；按键与文本提交**不合并、不丢弃**
public final class InputRouter {
    public private(set) var pressedModifiers: Set<ModifierFlags> = []
    public private(set) var pressedKeys: Set<UInt16> = []
    public private(set) var targetWindowUID: String?
    public private(set) var epoch: UInt64

    /// 鼠标移动合并：只保留最新位置，定时发出。
    public var pointerCoalesceInterval: TimeInterval = 1.0 / 60.0

    private var pendingMove: (position: Point, samples: UInt32)?
    private var lastMoveFlush: TimeInterval = 0

    public private(set) var releasedModifiersOnDisconnect = 0
    public private(set) var droppedWrongWindow = 0
    public private(set) var emitted: [AnyMessage] = []

    /// 用于测试断言的轻量记录类型。
    public enum AnyMessage: Equatable, Sendable {
        case key(KeyEvent)
        case pointer(PointerEvent)
        case commit(TextCommit)
        case windowAction(WindowAction)
    }

    public init(epoch: UInt64) { self.epoch = epoch }

    public func setEpoch(_ e: UInt64, targetWindow: String?) {
        epoch = e
        targetWindowUID = targetWindow
    }

    public func setTargetWindow(_ uid: String?) {
        guard targetWindowUID != uid else { return }
        targetWindowUID = uid
        // 切换窗口时释放按键状态，避免把按住的状态带到新窗口
        _ = releaseAllKeys()
    }

    // MARK: 按键

    public enum KeyDisposition: Equatable, Sendable {
        case sent(KeyEvent)
        case heldForIME
        case consumedLocally(String)
        case rejected(String)
    }

    /// 处理一个物理按键。`route` 由 `TextBridge.routeKey` 给出。
    public func handleKey(keycode: UInt16, kind: KeyKind, flags: ModifierFlags,
                          unicode: String?, route: KeyRoute) -> KeyDisposition {
        // 修饰键状态跟踪先行，保证任何时候状态是最新的
        updateModifierState(keycode: keycode, flags: flags, kind: kind)

        switch route {
        case .localIME:
            return .heldForIME
        case .consumedLocally(let reason):
            return .consumedLocally(reason)
        case .remote(let category):
            guard let target = targetWindowUID else {
                return .rejected("没有目标窗口")
            }
            let event = KeyEvent(epoch: epoch, windowUID: target, kind: kind,
                                 keycode: keycode, flags: flags.rawValue,
                                 unicode: unicode, category: category)
            emitted.append(.key(event))
            return .sent(event)
        }
    }

    private func updateModifierState(keycode: UInt16, flags: ModifierFlags, kind: KeyKind) {
        if kind == .flagsChanged {
            let active = Set(ModifierFlags.allModifiers.filter { flags.contains($0) })
            pressedModifiers = active
        }
        if kind == .keyDown { pressedKeys.insert(keycode) }
        if kind == .keyUp { pressedKeys.remove(keycode) }
    }

    /// 连接丢失：释放所有按下的修饰键与普通键。
    @discardableResult
    public func releaseAllKeys() -> [KeyEvent] {
        guard let target = targetWindowUID else {
            pressedModifiers.removeAll(); pressedKeys.removeAll()
            return []
        }
        var events: [KeyEvent] = []
        for m in pressedModifiers {
            events.append(KeyEvent(epoch: epoch, windowUID: target, kind: .keyUp,
                                   keycode: modifierKeycode(m), flags: 0, unicode: nil, category: .shortcut))
            releasedModifiersOnDisconnect += 1
        }
        for k in pressedKeys {
            events.append(KeyEvent(epoch: epoch, windowUID: target, kind: .keyUp,
                                   keycode: k, flags: 0, unicode: nil, category: .rawKey))
        }
        pressedModifiers.removeAll()
        pressedKeys.removeAll()
        emitted.append(contentsOf: events.map { .key($0) })
        return events
    }

    private func modifierKeycode(_ m: ModifierFlags) -> UInt16 {
        switch m {
        case .command: return 55
        case .shift: return 56
        case .control: return 59
        case .option: return 58
        case .function: return 63
        default: return 0
        }
    }

    // MARK: 鼠标

    public enum PointerDisposition: Equatable, Sendable {
        case sent(PointerEvent)
        case coalesced(pending: Int)
        case rejected(String)
    }

    public func handlePointer(kind: PointerKind, position: Point, button: PointerButton = .none,
                              scrollDX: Double = 0, scrollDY: Double = 0,
                              now: TimeInterval) -> PointerDisposition {
        guard let target = targetWindowUID else { return .rejected("没有目标窗口") }

        if kind == .move {
            let samples = (pendingMove?.samples ?? 0) + 1
            pendingMove = (position, samples)
            if now - lastMoveFlush >= pointerCoalesceInterval {
                return flushPointer(now: now)
            }
            return .coalesced(pending: Int(samples))
        }

        // 非移动事件：先把挂起的移动发出，保证顺序正确
        _ = flushPointer(now: now)
        let event = PointerEvent(epoch: epoch, windowUID: target, kind: kind,
                                 positionInWindow: position, button: button,
                                 scrollDX: scrollDX, scrollDY: scrollDY)
        emitted.append(.pointer(event))
        return .sent(event)
    }

    @discardableResult
    public func flushPointer(now: TimeInterval) -> PointerDisposition {
        guard let target = targetWindowUID, let pending = pendingMove else {
            return .coalesced(pending: 0)
        }
        pendingMove = nil
        lastMoveFlush = now
        // 被合并的移动使用 moveCoalesced，并带上采样数供诊断
        let kind: PointerKind = pending.samples > 1 ? .moveCoalesced : .move
        let event = PointerEvent(epoch: epoch, windowUID: target, kind: kind,
                                 positionInWindow: pending.position,
                                 coalescedSampleCount: pending.samples)
        emitted.append(.pointer(event))
        return .sent(event)
    }

    public var pendingMoveSamples: Int { Int(pendingMove?.samples ?? 0) }

    // MARK: 目标窗口校验

    /// 校验一条输入是否属于当前目标窗口。返回 false 时必须丢弃并上报。
    public func validateTarget(_ windowUID: String) -> Bool {
        guard windowUID == targetWindowUID else {
            droppedWrongWindow += 1
            return false
        }
        return true
    }

    public func resetEmitted() { emitted.removeAll() }
}
