import Foundation
import AppKit
import M2MCore

// m2mdemo —— 被代理的目标应用（独立进程）
//
// 职责：
//   1. 持有窗口模型与文本状态（扮演"远端应用"）
//   2. 在私有 UDS 上提供服务，供 Host 查询窗口 / 改尺寸 / 投递输入
//   3. 把模型渲染成真实 AppKit 窗口，让目标应用"看得见"
//
// 隔离：进程独立、套接字位于私有运行目录（0600）、不监听任何网络端口。

struct DemoOptions {
    var socketPath: String = ""
    var headless = false
    var bundleID = "dev.m2m.demoapp"
    var displayName = "M2M Demo App"
    var caretRectValid = true
    var windowSize = Size(560, 380)
    var stateFile: String?
    var controlFile: String?
}

func parseDemoOptions() -> DemoOptions {
    var o = DemoOptions()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--socket": o.socketPath = it.next() ?? ""
        case "--headless": o.headless = true
        case "--bundle-id": o.bundleID = it.next() ?? o.bundleID
        case "--name": o.displayName = it.next() ?? o.displayName
        case "--no-caret-rect": o.caretRectValid = false
        case "--size":
            if let s = it.next() {
                let p = s.split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { o.windowSize = Size(p[0], p[1]) }
            }
        case "--state-file": o.stateFile = it.next()
        case "--control-file": o.controlFile = it.next()
        case "--help", "-h":
            print("""
            m2mdemo —— 被代理的目标应用

            用法: m2mdemo --socket <path> [选项]

              --socket <path>      提供服务用的 UDS 路径（必填）
              --headless           不显示窗口（仅提供服务）
              --bundle-id <id>     应用标识
              --name <name>        应用显示名
              --no-caret-rect      模拟"无法提供插入点位置"的降级场景
              --size WxH           主窗口内容尺寸
              --state-file <path>  周期性写出状态快照（供外部断言）
              --control-file <path> 轮询控制文件以执行外部指令（打开窗口、设置文本等）
            """)
            exit(0)
        default: break
        }
    }
    return o
}

func logDemo(_ message: String) {
    FileHandle.standardError.write(Data("[demo] \(message)\n".utf8))
}

let demoOptions = parseDemoOptions()
guard !demoOptions.socketPath.isEmpty else {
    FileHandle.standardError.write(Data("m2mdemo: 缺少 --socket\n".utf8))
    exit(2)
}

let demoModel = SyntheticAppModel(bundleID: demoOptions.bundleID,
                                  displayName: demoOptions.displayName,
                                  appLaunchID: "demo-\(UUID().uuidString.prefix(6))",
                                  pid: getpid(), contentScale: 2.0,
                                  caretRectValid: demoOptions.caretRectValid)
if let mainUID = demoModel.focusedWindowUID {
    demoModel.setSize(mainUID, demoOptions.windowSize)
    demoModel.setTitle(mainUID, demoOptions.displayName)
}

let demoService = DemoAppService(model: demoModel)
let demoListener: IPCListener
do {
    demoListener = try demoService.serve(socketPath: demoOptions.socketPath)
} catch {
    FileHandle.standardError.write(Data("m2mdemo: 启动服务失败 \(error)\n".utf8))
    exit(1)
}

logDemo("就绪 pid=\(getpid()) socket=\(demoOptions.socketPath) 窗口=\(demoModel.allWindows.count) 插入点能力=\(demoOptions.caretRectValid)")

// 外部控制：轮询控制文件执行指令，避免引入额外连接与网络暴露面
let demoControl = demoOptions.controlFile.map { ControlFile(url: URL(fileURLWithPath: $0)) }
var demoControlTimer: DispatchSourceTimer?
if let demoControl {
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "m2m.demo.control"))
    t.schedule(deadline: .now(), repeating: .milliseconds(60), leeway: .milliseconds(10))
    t.setEventHandler {
        guard let batch = demoControl.readIfChanged(DemoControl.self) else { return }
        for req in batch.requests {
            let resp = demoService.handle(req)
            logDemo("控制指令 \(req.kind.rawValue) -> ok=\(resp.ok) \(resp.error ?? "")")
        }
    }
    t.resume()
    demoControlTimer = t
}

let stateURL = demoOptions.stateFile.map { URL(fileURLWithPath: $0) }
func writeDemoState() {
    guard let stateURL else { return }
    if let data = try? JSONEncoder().encode(demoService.snapshot()) {
        try? data.write(to: stateURL, options: .atomic)
    }
}

signal(SIGTERM) { _ in demoListener.stop(); exit(0) }
signal(SIGINT) { _ in demoListener.stop(); exit(0) }

if demoOptions.headless {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "m2m.demo.state"))
    timer.schedule(deadline: .now(), repeating: .milliseconds(200))
    timer.setEventHandler { writeDemoState() }
    timer.resume()
    dispatchMain()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = DemoWindowController(service: demoService)
    app.delegate = delegate
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "m2m.demo.state"))
    timer.schedule(deadline: .now(), repeating: .milliseconds(150))
    timer.setEventHandler {
        writeDemoState()
        DispatchQueue.main.async { delegate.refresh() }
    }
    timer.resume()
    app.run()
}

// MARK: - 把模型渲染成真实窗口

final class DemoWindowController: NSObject, NSApplicationDelegate {
    private let service: DemoAppService
    private var views: [String: DemoWindowView] = [:]
    private var frames: [String: NSRect] = [:]

    init(service: DemoAppService) { self.service = service }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保证置顶显示，便于观察"远端应用"的实际状态
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 依据模型同步窗口：新增/删除/尺寸/标题/内容
    func refresh() {
        let snapshot = service.snapshot()
        var alive = Set<String>()
        for w in snapshot.windows where w.role != "child" {
            alive.insert(w.uid)
            let size = NSSize(width: w.width, height: w.height)
            if let view = views[w.uid] {
                if view.frame.size != size {
                    view.setFrameSize(size)
                    view.window?.setContentSize(size)
                }
                view.window?.title = w.title
                view.render(text: snapshot.text, badge: w.role == "main" ? nil : w.role)
                if w.minimized {
                    view.window?.miniaturize(nil)
                }
            } else {
                let controller = NSWindowController(window: makeWindow(for: w))
                frames[w.uid] = NSRect(origin: NSPoint(x: 60 + CGFloat(views.count) * 40,
                                                       y: 120 + CGFloat(views.count) * 30),
                                       size: size)
                controller.window?.setFrame(frames[w.uid]!, display: true)
                controller.window?.title = w.title
                controller.showWindow(nil)
                views[w.uid] = controller.window?.contentView as? DemoWindowView
                (controller.window?.contentView as? DemoWindowView)?
                    .render(text: snapshot.text, badge: w.role == "main" ? nil : w.role)
                retainControllers.append(controller)
            }
        }
        for (uid, view) in views where !alive.contains(uid) {
            view.window?.close()
            views.removeValue(forKey: uid)
        }
    }

    private var retainControllers: [NSWindowController] = []

    private func makeWindow(for w: DemoSnapshot.Win) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: w.width, height: w.height)
        let style: NSWindow.StyleMask = w.resizable
            ? [.titled, .closable, .resizable, .miniaturizable]
            : [.titled, .closable, .miniaturizable]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = DemoWindowView(service: service)
        if w.minWidth > 0 {
            window.contentMinSize = NSSize(width: w.minWidth, height: w.minHeight)
        }
        return window
    }
}

/// 目标应用的内容视图：用与合成采集相同的渲染器，保证"看到的就是被采集的"。
final class DemoWindowView: NSView {
    private let service: DemoAppService
    private var latestText: String = ""
    private var badge: String?

    init(service: DemoAppService) {
        self.service = service
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(text: DemoSnapshot.TextState, badge: String?) {
        self.latestText = text.buffer
        self.badge = badge
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let content = SyntheticWindowContent(
            title: service.snapshot().displayName,
            textContent: latestText,
            caretOffset: service.snapshot().text.caret,
            selectionLength: service.snapshot().text.selection,
            scrollOffset: 0,
            badge: badge,
            theme: .light)
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0 else { return }
        let pixels = SyntheticRenderer.render(content, size: Size(Double(w), Double(h)))
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        ctx.draw(image, in: bounds)
        // 叠加一层文字说明，便于人工核对
        let label = "目标应用（demo 进程, pid \(service.snapshot().pid)）\n输入内容: \(latestText)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.85),
        ]
        (label as NSString).draw(in: NSRect(x: 6, y: 6, width: bounds.width - 12, height: 44), withAttributes: attrs)
    }
}
