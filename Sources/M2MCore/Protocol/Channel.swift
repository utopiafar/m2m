import Foundation

/// 四条逻辑通道 + 控制优先级。
/// 参考 docs/03-protocol.md §0：通道是逻辑概念，由独立队列与优先级区分。
public enum Channel: UInt8, Sendable, CaseIterable {
    /// P0：撤销控制、会话状态、修饰键释放。不排队。
    case control = 1
    /// P1：输入事件、文本提交。可靠有序，不丢弃。
    case input = 2
    /// P2：窗口状态、几何、文本上下文。可靠；同类消息可合并。
    case state = 3
    /// P3：媒体画面。可丢弃过期帧。
    case media = 4
    /// P4：文件分块。限速，使用剩余带宽。
    case file = 5

    /// 数值越小优先级越高。
    public var priority: Int {
        switch self {
        case .control: return 0
        case .input: return 1
        case .state: return 2
        case .media: return 3
        case .file: return 4
        }
    }

    /// 该通道上的消息是否允许被丢弃（过期帧策略）。
    public var isDroppable: Bool {
        switch self {
        case .media: return true
        // 窗口状态允许"合并"而非丢弃：合并后仍表达最新状态。
        case .state: return false
        case .control, .input, .file: return false
        }
    }

    /// 该通道是否要求可靠有序投递。
    public var isReliableOrdered: Bool {
        switch self {
        case .control, .input, .state, .file: return true
        case .media: return false
        }
    }
}
