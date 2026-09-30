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
            // 尺寸请求交给窗口控制器：真正的窗口尺寸归窗口系统管，
            // 服务层只维护模型，不去改窗口
            if req.kind == .resize, let uid = req.uid,
               let w = req.width, let h = req.height,
               let handler = demoWindowResizeHandler {
                let ok = handler(uid, Size(w, h))
                logDemo("窗口尺寸指令 \(uid) → \(Int(w))x\(Int(h)) ok=\(ok)")
                continue
            }
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
    var snap = demoService.snapshot()
    // 附加"真实 NSTextView 里的文本"：代理路径写模型、AX 路径写真实控件，
    // 两条路径必须收敛到同一份内容，这里把它写出来以便交叉校验。
    var dict: [String: Any] = [:]
    if let data = try? JSONEncoder().encode(snap), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        dict = obj
    }
    if let editorText = realEditorText() {
        dict["real_editor_text"] = editorText
        if var text = dict["text"] as? [String: Any] {
            text["real_buffer"] = editorText
            dict["text"] = text
        }
    }
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateURL, options: .atomic)
    }
    _ = snap
}

/// 由窗口控制器注册，返回真实 NSTextView 的当前文本。
nonisolated(unsafe) var realEditorTextProvider: (() -> String?)?

/// 由窗口控制器注册：真正调整窗口尺寸。
/// 用于隔离"是 AX 路径有问题"还是"应用自身不允许改尺寸"。
nonisolated(unsafe) var demoWindowResizeHandler: ((String, Size) -> Bool)?

func realEditorText() -> String? { realEditorTextProvider?() }

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
    realEditorTextProvider = { [weak delegate] in delegate?.mainEditorText() }
    demoWindowResizeHandler = { [weak delegate] uid, size in
        delegate?.applyWindowSize(uid: uid, size: size) ?? false
    }
    app.delegate = delegate
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "m2m.demo.state"))
    timer.schedule(deadline: .now(), repeating: .milliseconds(150))
    let refreshDisabled = ProcessInfo.processInfo.environment["M2M_DEMO_NO_REFRESH"] == "1"
    timer.setEventHandler {
        writeDemoState()
        if !refreshDisabled { DispatchQueue.main.async { delegate.refresh() } }
    }
    timer.resume()
    app.run()
}

// MARK: - 把模型渲染成真实窗口

final class DemoWindowController: NSObject, NSApplicationDelegate {
    private let service: DemoAppService
    private var views: [String: NSView] = [:]
    private var windows: [String: NSWindow] = [:]
    private var frames: [String: NSRect] = [:]

    init(service: DemoAppService) { self.service = service }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保证置顶显示，便于观察"远端应用"的实际状态
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        // 把焦点放进真实文本视图：AX 只有焦点在可编辑控件上才能读到插入点，
        // 这也是一个真实应用被打开时的正常状态。
        focusEditor()
    }

    /// 真正调整窗口尺寸（应用侧的"响应尺寸变化"入口）。
    ///
    /// 与"外部通过辅助功能改尺寸"的区别：这里走应用自己的 API。
    /// 两种方式都会让窗口成为尺寸的事实来源，模型随后跟随。
    @discardableResult
    func applyWindowSize(uid: String, size: Size) -> Bool {
        guard let win = windows[uid] else { return false }
        win.setContentSize(NSSize(width: size.width, height: size.height))
        syncSizeToModel(uid: uid)
        return true
    }

    /// 把窗口的真实内容尺寸读回模型（窗口是尺寸的事实来源）。
    func syncSizeToModel(uid: String) {
        guard let win = windows[uid], let content = win.contentView else { return }
        let size = content.bounds.size
        guard size.width >= 20, size.height >= 20 else { return }
        guard let mw = service.model.windows[uid] else { return }
        let newSize = Size(Double(size.width), Double(size.height))
        guard mw.contentSize != newSize else { return }
        // 用公开入口设置尺寸（模型的窗口字典对外只读）
        service.model.setSize(uid, newSize)
    }


    /// 主窗口真实文本视图的当前文本。
    func mainEditorText() -> String? {
        for (_, view) in views {
            if let editor = view as? DemoRealTextEditorView { return editor.currentText }
        }
        return nil
    }

    /// 把第一响应者交给主窗口的真实文本视图。
    func focusEditor() {
        for (_, view) in views {
            if let editor = view as? DemoRealTextEditorView {
                view.window?.makeKeyAndOrderFront(nil)
                view.window?.makeFirstResponder(editor.textView)
                return
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 依据模型同步窗口：新增/删除/尺寸/标题/内容
    func refresh() {
        let snapshot = service.snapshot()
        var alive = Set<String>()
        for w in snapshot.windows where w.role != "child" {
            alive.insert(w.uid)
            if let view = views[w.uid] {
                // 绝不把模型尺寸推给窗口。
                //
                // 窗口尺寸的事实来源是**窗口本身**（用户拖拽、辅助功能写入都作用在窗口上），
                // 模型只是跟随。如果每次刷新都用模型尺寸调 setContentSize，就等于每 150ms
                // 把外部改尺寸顶回去——实测表现是"AXSize 写入返回成功，但窗口纹丝不动"，
                // 而且这个现象看起来像操作系统的限制，极难定位。
                // 正确方向是反过来：把窗口的真实尺寸读回模型（见 syncSizeToModel）。
                if let win = view.window, windows[w.uid] == nil { windows[w.uid] = win }
                syncSizeToModel(uid: w.uid)
                view.window?.title = w.title
                if let editor = view as? DemoRealTextEditorView {
                    editor.syncFromModel()
                } else if let plain = view as? DemoWindowView {
                    plain.render(text: snapshot.text, badge: w.role == "main" ? nil : w.role)
                }
                if w.minimized {
                    view.window?.miniaturize(nil)
                }
            } else {
                let controller = NSWindowController(window: makeWindow(for: w))
                let initialSize = NSSize(width: w.width, height: w.height)
                frames[w.uid] = NSRect(origin: NSPoint(x: 60 + CGFloat(views.count) * 40,
                                                       y: 120 + CGFloat(views.count) * 30),
                                       size: initialSize)
                controller.window?.setFrame(frames[w.uid]!, display: true)
                controller.window?.title = w.title
                controller.showWindow(nil)
                if let editor = controller.window?.contentView as? DemoRealTextEditorView {
                    editor.syncFromModel()
                } else if let plain = controller.window?.contentView as? DemoWindowView {
                    plain.render(text: snapshot.text, badge: w.role == "main" ? nil : w.role)
                }
                views[w.uid] = controller.window?.contentView
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
        // 主窗口使用**真实 NSTextView**：这样辅助功能（AX）能读到真实的编辑控件、
        // 插入点与选区，真实采集也能拿到真实渲染的文字。它让"真实目标应用"这一侧
        // 成为可自动验证的确定性对象，而不是只能靠人工在第三方应用上试。
        if w.role == "main" {
            window.contentView = DemoRealTextEditorView(service: service)
        } else {
            window.contentView = DemoWindowView(service: service)
        }
        if w.minWidth > 0 {
            window.contentMinSize = NSSize(width: w.minWidth, height: w.minHeight)
        }
        return window
    }
}

/// 主窗口内容：真实的 `NSTextView` + 状态行。
///
/// 它同时承担两个角色：
///   1. 作为"被代理应用"的真实编辑控件，供 AX 路径读写（插入点、选区、文本）
///   2. 与 `SyntheticAppModel` 双向同步，供代理路径读写
/// 两条路径指向同一个控件，因此可以互相校验（AX 读到的是不是模型里的那一份）。
final class DemoRealTextEditorView: NSView, NSTextViewDelegate {
    private let service: DemoAppService
    private let scrollView = NSScrollView()
    let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var syncingFromModel = false

    init(service: DemoAppService) {
        self.service = service
        super.init(frame: .zero)
        wantsLayer = true

        // 用 autoresizing 而不是 Auto Layout：内容视图若用约束完全决定自身尺寸，
        // AppKit 会把窗口尺寸锁定在"适配尺寸"上，外部（含辅助功能）改尺寸会返回成功
        // 但窗口纹丝不动。这里刻意保持布局简单，让窗口尺寸完全由窗口系统决定。
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true              // 撤销链必须真实可用
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.delegate = self
        textView.string = service.model.textBuffer
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.autoresizingMask = [.width]

        statusLabel.frame = NSRect(x: 10, y: 6, width: max(10, bounds.width - 20), height: 16)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        addSubview(scrollView)
        addSubview(statusLabel)
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 底部 24pt 给状态行，其余给文本区
        scrollView.frame = NSRect(x: 8, y: 26, width: max(10, bounds.width - 16),
                                 height: max(10, bounds.height - 34))
    }

    /// 真实控件 → 模型（用户或 AX 改动了文本）
    func textDidChange(_ notification: Notification) {
        guard !syncingFromModel else { return }
        service.model.textBuffer = textView.string
        service.model.caretOffset = textView.selectedRange().location
        service.model.selectionLength = textView.selectedRange().length
        updateStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !syncingFromModel else { return }
        service.model.caretOffset = textView.selectedRange().location
        service.model.selectionLength = textView.selectedRange().length
    }

    /// 模型 → 真实控件（代理路径写入了文本）
    func syncFromModel() {
        guard textView.string != service.model.textBuffer else {
            updateStatus()
            return
        }
        syncingFromModel = true
        let sel = textView.selectedRange()
        textView.string = service.model.textBuffer
        let loc = min(service.model.caretOffset, (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        _ = sel
        syncingFromModel = false
        updateStatus()
    }

    /// 真实控件当前文本（供交叉校验：AX 读到的应与它一致）。
    var currentText: String { textView.string }

    private func updateStatus() {
        let sel = textView.selectedRange()
        statusLabel.stringValue = "真实 NSTextView ｜ 长度 \(textView.string.count) ｜ "
            + "光标 \(sel.location) ｜ 选区 \(sel.length) ｜ 撤销可用=\(textView.undoManager?.canUndo ?? false)"
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
