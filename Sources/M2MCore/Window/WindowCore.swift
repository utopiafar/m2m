import Foundation

/// 远端窗口注册表（Host 侧）。
///
/// 职责边界（规格 §3）：只维护窗口身份、角色、几何、父子与模态、尺寸约束；
/// **不解析应用内部控件**——那是 AX 增强层的事。
public final class WindowRegistry {
    public private(set) var layoutVersion: UInt64 = 0
    public private(set) var epoch: UInt64
    private var windows: [String: WindowInfo] = [:]
    private var order: [String] = []
    private var lastSizes: [String: Size] = [:]

    public init(epoch: UInt64) { self.epoch = epoch }

    public var allWindows: [WindowInfo] { order.compactMap { windows[$0] } }
    public var count: Int { windows.count }

    public func window(_ uid: String) -> WindowInfo? { windows[uid] }

    /// 应用重启或会话重建时调用：`window_uid` 不得跨应用重启复用（规格 §1.2 规则 5）。
    public func reset(epoch: UInt64) {
        self.epoch = epoch
        windows.removeAll(); order.removeAll(); lastSizes.removeAll()
        layoutVersion = 0
    }

    @discardableResult
    public func upsert(_ info: WindowInfo) -> Bool {
        let changed = windows[info.windowUID] != info
        if changed {
            windows[info.windowUID] = info
            if !order.contains(info.windowUID) { order.append(info.windowUID) }
            bumpLayoutVersion()
        }
        return changed
    }

    @discardableResult
    public func remove(_ uid: String) -> Bool {
        guard windows.removeValue(forKey: uid) != nil else { return false }
        order.removeAll { $0 == uid }
        lastSizes.removeValue(forKey: uid)
        bumpLayoutVersion()
        return true
    }

    private func bumpLayoutVersion() { layoutVersion &+= 1 }

    public func snapshot() -> WindowSnapshot {
        WindowSnapshot(epoch: epoch, layoutVersion: layoutVersion, windows: allWindows)
    }

    /// 应用一次尺寸请求并读回**实际生效**的尺寸。
    ///
    /// `applySize` 由远端适配器提供（真实实现走 AX `AXSize` 写入后重新读取）。
    /// 规格 §1.2 规则 2：读回的是事实，不是承诺。
    public func applyResize(uid: String, requested: Size,
                            applySize: (WindowInfo, Size) -> (Size, SizeConstraint)) -> WindowResizeResult? {
        guard var info = windows[uid] else { return nil }
        let clamped = info.constraints.clamp(requested)
        let (actual, constrainedBy) = applySize(info, clamped.size)
        info.contentRect = Rect(origin: info.contentRect.origin, size: actual)
        if windows[uid] != info {
            windows[uid] = info
            bumpLayoutVersion()
        }
        lastSizes[uid] = actual
        return WindowResizeResult(requestSeq: 0, actualContentSize: actual,
                                  layoutVersion: layoutVersion, constrainedBy: constrainedBy)
    }

    public func clampForApp(_ uid: String, requested: Size) -> (Size, SizeConstraint) {
        guard let info = windows[uid] else { return (requested, .none) }
        return info.constraints.clamp(requested)
    }

    /// 远端窗口消失时必须通知本地关闭对应壳，避免"僵尸窗口"接收输入（规格 §5.2）。
    public func vanishedUIDs(comparedTo localUIDs: Set<String>) -> [String] {
        Array(localUIDs.subtracting(windows.keys)).sorted()
    }
}

/// 尺寸请求合并器：约 10 Hz，只保留最新（规格 §1.2 规则 3）。
///
/// 拖动缩放时若每个鼠标事件都发一次请求，会产生请求风暴并引发双侧抖动。
public final class ResizeCoalescer {
    public let interval: TimeInterval
    private var pending: [String: (size: Size, seq: UInt32, at: TimeInterval)] = [:]
    private var lastEmit: [String: TimeInterval] = [:]
    private var nextSeq: UInt32 = 0

    public init(interval: TimeInterval = 0.1) { self.interval = interval }

    /// 返回本次应当立即发出的请求（若未到间隔，则暂存并返回 nil）。
    public func submit(uid: String, size: Size, now: TimeInterval) -> (size: Size, seq: UInt32)? {
        nextSeq &+= 1
        pending[uid] = (size, nextSeq, now)
        let last = lastEmit[uid] ?? -(.infinity)
        guard now - last >= interval else { return nil }
        lastEmit[uid] = now
        let p = pending[uid]!
        pending[uid] = nil
        return (p.size, p.seq)
    }

    /// 拖动结束后提交最终尺寸，忽略节流。
    public func flush(uid: String, size: Size) -> (size: Size, seq: UInt32) {
        nextSeq &+= 1
        pending[uid] = nil
        return (size, nextSeq)
    }

    public func isNewest(seq: UInt32) -> Bool { seq == nextSeq }

    public var pendingCount: Int { pending.count }
}

/// 本地窗口表（Viewer 侧）：远端窗口 ↔ 本地窗口壳的映射。
///
/// 承载规格 §1.3 的映射规则与 §5.2 的重连一致性要求。
public final class RemoteWindowTable {
    public struct Shell: Equatable {
        public var windowUID: String
        public var role: WindowRole
        public var title: String
        public var parentUID: String?
        public var modal: Bool
        public var remoteContentSize: Size
        public var localContentSize: Size
        public var layoutVersion: UInt64
        /// 缩放拖动中：允许临时缩放旧画面（规格 §5.2）。
        public var isLiveResizing: Bool
        public var degradedReason: String?

        public var isDegraded: Bool { degradedReason != nil }
    }

    private var shells: [String: Shell] = [:]
    /// 记录已"看到过"的远端窗口 UID，用于重连时发现消失的窗口。
    public private(set) var lastKnownRemoteUIDs: Set<String> = []

    public init() {}

    public var allShells: [Shell] { Array(shells.values) }
    public var count: Int { shells.count }
    public func shell(_ uid: String) -> Shell? { shells[uid] }

    /// 应用一次窗口快照。返回需要关闭的本地壳（远端已消失）。
    public func apply(snapshot: WindowSnapshot) -> [String] {
        let incoming = Set(snapshot.windows.map(\.windowUID))
        let toClose = Array(lastKnownRemoteUIDs.subtracting(incoming)).sorted()
        for uid in toClose { shells.removeValue(forKey: uid) }

        for w in snapshot.windows {
            // 子窗口默认不单独建壳（随主窗口画面显示）
            guard w.role.requiresLocalShell else { continue }
            var shell = shells[w.windowUID] ?? Shell(
                windowUID: w.windowUID, role: w.role, title: w.title,
                parentUID: w.parentUID, modal: w.modal,
                remoteContentSize: w.contentSize, localContentSize: w.contentSize,
                layoutVersion: snapshot.layoutVersion, isLiveResizing: false,
                degradedReason: w.role == .unknown ? WindowRole.unknown.localizedDescription : nil
            )
            shell.role = w.role
            shell.title = w.title
            shell.parentUID = w.parentUID
            shell.modal = w.modal
            shell.remoteContentSize = w.contentSize
            shell.layoutVersion = snapshot.layoutVersion
            if !shell.isLiveResizing {
                // 非拖动期间直接采用远端尺寸，保证画面不被拉伸
                shell.localContentSize = w.contentSize
            }
            shells[w.windowUID] = shell
        }
        lastKnownRemoteUIDs = incoming
        return toClose
    }

    public func beginLiveResize(uid: String, localSize: Size) {
        guard var s = shells[uid] else { return }
        s.isLiveResizing = true
        s.localContentSize = localSize
        shells[uid] = s
    }

    /// 缩放结束：以远端读回的实际尺寸为准（规格 §5.2 判据）。
    public func endLiveResize(uid: String, actual: Size, layoutVersion: UInt64) {
        guard var s = shells[uid] else { return }
        s.isLiveResizing = false
        s.remoteContentSize = actual
        s.localContentSize = actual
        s.layoutVersion = layoutVersion
        shells[uid] = s
    }

    public func setDegraded(uid: String, reason: String?) {
        guard var s = shells[uid] else { return }
        s.degradedReason = reason
        shells[uid] = s
    }

    /// 会话重连：清空表但保留"需要关闭"的语义由下次快照处理。
    public func resetForReconnect() {
        shells.removeAll()
    }

    /// 一致性校验：本地壳数量是否与远端窗口一一对应（T-REC-10）。
    public func isConsistent(with snapshot: WindowSnapshot) -> Bool {
        let expected = Set(snapshot.windows.filter { $0.role.requiresLocalShell }.map(\.windowUID))
        return expected == Set(shells.keys)
    }
}
