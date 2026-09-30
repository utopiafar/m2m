import Foundation

/// 延迟样本记录器。
///
/// 性能验收要求给出分位数与较差情况，而不是一个平均值——单机验证里也一样：
/// 平均延迟正常但 p95 很差，体验就是"偶尔卡半秒"。
public final class LatencyRecorder {
    private var samples: [Double] = []
    private let lock = NSLock()
    public let capacity: Int
    public let name: String

    public init(name: String, capacity: Int = 4096) {
        self.name = name
        self.capacity = capacity
    }

    public func record(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.lock()
        samples.append(seconds)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        lock.unlock()
    }

    public func measure<T>(_ body: () -> T) -> T {
        let t0 = Date().timeIntervalSinceReferenceDate
        let result = body()
        record(Date().timeIntervalSinceReferenceDate - t0)
        return result
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return Statistics(name: name, count: 0) }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[idx]
        }
        return Statistics(name: name, count: sorted.count,
                          p50: percentile(0.5), p95: percentile(0.95),
                          max: sorted.last ?? 0, min: sorted.first ?? 0,
                          mean: sorted.reduce(0, +) / Double(sorted.count))
    }

    public func reset() {
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    public struct Statistics: Sendable, Equatable {
        public var name: String
        public var count: Int
        public var p50: Double = 0
        public var p95: Double = 0
        public var max: Double = 0
        public var min: Double = 0
        public var mean: Double = 0

        public var milliseconds: (p50: Double, p95: Double, max: Double) {
            (p50 * 1000, p95 * 1000, max * 1000)
        }

        public var oneLine: String {
            guard count > 0 else { return "\(name)：无样本" }
            let (a, b, c) = milliseconds
            return String(format: "%@：n=%d  p50=%.2fms  p95=%.2fms  max=%.2fms", name, count, a, b, c)
        }

        public var asJSON: [String: Any] {
            ["name": name, "count": count, "p50_ms": p50 * 1000, "p95_ms": p95 * 1000,
             "max_ms": max * 1000, "min_ms": min * 1000, "mean_ms": mean * 1000]
        }
    }
}

/// 运行时全套延迟指标。名称对应 docs/05-media-performance.md §9 的验收项。
public final class LatencyMetrics {
    /// 本地交互：窗口尺寸在本地生效的耗时（**必须与网络无关**）
    public let localResizeApply = LatencyRecorder(name: "本地窗口尺寸生效")
    /// 本地交互：组合文本更新耗时（**必须与网络无关**）
    public let localCompositionUpdate = LatencyRecorder(name: "本地组合更新")
    /// 端到端：一次文本提交从发出到拿到结果
    public let commitRoundTrip = LatencyRecorder(name: "文本提交往返")
    /// 端到端：一帧画面从主机发出到本地解码完成
    public let frameLatency = LatencyRecorder(name: "画面帧延迟")
    /// 端到端：一次窗口尺寸请求从发出到远端尺寸读回
    public let resizeRoundTrip = LatencyRecorder(name: "尺寸请求往返")

    public init() {}

    public var all: [LatencyRecorder] {
        [localResizeApply, localCompositionUpdate, commitRoundTrip, frameLatency, resizeRoundTrip]
    }

    public var summaries: [LatencyRecorder.Statistics] { all.map { $0.statistics } }
    public var asJSON: [[String: Any]] { summaries.map { $0.asJSON } }

    public func reset() { all.forEach { $0.reset() } }

    /// 面向验收的判定：本地交互必须与网络无关，因此用绝对阈值。
    /// 端到端指标不做阈值判定，只报告实测值（阈值取决于真实线路，见 G3）。
    public func localInteractionWithinBudget(p95Milliseconds: Double = 30) -> (ok: Bool, detail: String) {
        let r = localResizeApply.statistics
        let c = localCompositionUpdate.statistics
        let worst = Swift.max(r.p95, c.p95) * 1000
        let hasSamples = r.count > 0 || c.count > 0
        return (hasSamples && worst <= p95Milliseconds,
                String(format: "本地交互 p95=%.3fms（预算 %.0fms）", worst, p95Milliseconds))
    }
}
