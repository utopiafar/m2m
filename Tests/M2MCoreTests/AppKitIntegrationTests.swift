import XCTest
import AppKit
@testable import M2MCore

/// 真实 AppKit 对象层的验证。
///
/// 这些用例不依赖屏幕录制 / 辅助功能权限，但需要一个图形会话（NSEvent 与 NSPasteboard
/// 在无显示环境下行为不同），因此在不满足条件时明确跳过并在报告里标注，而不是假装通过。
final class AppKitIntegrationTests: XCTestCase {

    private var hasDisplay: Bool { NSScreen.main != nil || NSApp != nil }

    // MARK: 真实 NSEvent 上的按键去向

    /// 构造真实 NSEvent（而不是用字典造一个假事件）。
    private func keyEvent(keycode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0,
                         context: nil,
                         characters: "",
                         charactersIgnoringModifiers: "",
                         isARepeat: false,
                         keyCode: keycode)
    }

    func testRealReturnEventDuringCompositionStaysLocal() throws {
        try XCTSkipUnless(hasDisplay, "无图形会话，跳过真实 NSEvent 用例")
        // T-CN-06：组合期间的回车必须先给本地输入法
        guard let event = keyEvent(keycode: KeyCode.returnKey, flags: []) else {
            return XCTFail("无法构造 NSEvent")
        }
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        XCTAssertEqual(event.keyCode, KeyCode.returnKey)
        XCTAssertEqual(IMEKeyDecision.path(keycode: event.keyCode, flags: flags, isComposing: true),
                       .imeOnly,
                       "组合中的回车被判定为直接发往远端，会让选词变成发送")
    }

    func testRealReturnEventOutsideCompositionGoesThroughIMEToRemote() throws {
        try XCTSkipUnless(hasDisplay, "无图形会话，跳过真实 NSEvent 用例")
        // 非组合态的回车不能绕过输入法（某些输入法会用它确认候选），
        // 但输入法不消费时必须最终到达远端。两条路径都要有断言，
        // 只测其中一条会漏掉"回车被 IME 吞掉"或"回车直接变成发送"这类问题。
        guard let event = keyEvent(keycode: KeyCode.returnKey, flags: []) else {
            return XCTFail("无法构造 NSEvent")
        }
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        let path = IMEKeyDecision.path(keycode: event.keyCode, flags: flags, isComposing: false)
        XCTAssertEqual(path, .interpretByIME, "非组合态的回车应先交给输入法")

        // 输入法未消费 → 经 doCommand(by:) 映射为远端回车
        XCTAssertEqual(RemoteWindowView.keycode(for: #selector(NSResponder.insertNewline(_:))),
                       KeyCode.returnKey, "doCommand 的回车映射必须正确，否则回车到不了远端")
    }

    func testDoCommandSelectorMappingCoversEditingAndNavigation() {
        // 输入法不消费的编辑/导航键必须都能映射到正确的远端键码
        let cases: [(Selector, UInt16)] = [
            (#selector(NSResponder.deleteBackward(_:)), KeyCode.delete),
            (#selector(NSResponder.deleteForward(_:)), KeyCode.forwardDelete),
            (#selector(NSResponder.moveLeft(_:)), KeyCode.leftArrow),
            (#selector(NSResponder.moveRight(_:)), KeyCode.rightArrow),
            (#selector(NSResponder.moveUp(_:)), KeyCode.upArrow),
            (#selector(NSResponder.moveDown(_:)), KeyCode.downArrow),
            (#selector(NSResponder.insertTab(_:)), KeyCode.tab),
            (#selector(NSResponder.cancelOperation(_:)), KeyCode.escape),
            (#selector(NSResponder.pageUp(_:)), KeyCode.pageUp),
            (#selector(NSResponder.pageDown(_:)), KeyCode.pageDown),
        ]
        for (selector, expected) in cases {
            XCTAssertEqual(RemoteWindowView.keycode(for: selector), expected,
                           "\(NSStringFromSelector(selector)) 的映射不正确")
        }
    }

    func testRealDigitEventDuringCompositionStaysLocal() throws {
        try XCTSkipUnless(hasDisplay, "无图形会话，跳过真实 NSEvent 用例")
        // T-CN-07：数字键在组合中用于选词
        for keycode in KeyCode.digits {
            guard let event = keyEvent(keycode: keycode, flags: []) else { continue }
            let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
            XCTAssertEqual(IMEKeyDecision.path(keycode: event.keyCode, flags: flags, isComposing: true),
                           .imeOnly, "组合中的数字键只能由本地输入法处理")
        }
    }

    func testRealCommandShortcutGoesRemoteEvenOutsideComposition() throws {
        try XCTSkipUnless(hasDisplay, "无图形会话，跳过真实 NSEvent 用例")
        guard let event = keyEvent(keycode: 8, flags: [.command]) else {   // Cmd+C
            return XCTFail("无法构造 NSEvent")
        }
        let flags = ModifierFlags(rawValue: UInt32(event.modifierFlags.rawValue))
        XCTAssertTrue(flags.contains(.command), "NSEvent 的修饰键位应与 ModifierFlags 一致")
        XCTAssertEqual(IMEKeyDecision.path(keycode: event.keyCode, flags: flags, isComposing: false),
                       .shortcutToRemote, "带 Command 的按键应绕过输入法直接发往远端")
    }

    func testModifierFlagsRawValuesMatchNSEvent() {
        // 位定义必须与 NSEvent 一致，否则从修饰键到路由判断的桥接会静默出错
        XCTAssertEqual(ModifierFlags.command.rawValue, UInt32(NSEvent.ModifierFlags.command.rawValue))
        XCTAssertEqual(ModifierFlags.shift.rawValue, UInt32(NSEvent.ModifierFlags.shift.rawValue))
        XCTAssertEqual(ModifierFlags.control.rawValue, UInt32(NSEvent.ModifierFlags.control.rawValue))
        XCTAssertEqual(ModifierFlags.option.rawValue, UInt32(NSEvent.ModifierFlags.option.rawValue))
        XCTAssertEqual(ModifierFlags.function.rawValue, UInt32(NSEvent.ModifierFlags.function.rawValue))
    }

    func testKeyCodeConstantsMatchAppKit() {
        // 键码是硬编码常量，必须与 AppKit 的实际值一致，否则方向键会被当成普通字符
        XCTAssertEqual(KeyCode.returnKey, 36)
        XCTAssertEqual(KeyCode.keypadEnter, 76)
        XCTAssertEqual(KeyCode.space, 49)
        XCTAssertEqual(KeyCode.delete, 51)
        XCTAssertEqual(KeyCode.escape, 53)
        XCTAssertEqual(KeyCode.leftArrow, 123)
        XCTAssertEqual(KeyCode.rightArrow, 124)
        XCTAssertEqual(KeyCode.downArrow, 125)
        XCTAssertEqual(KeyCode.upArrow, 126)
        XCTAssertEqual(KeyCode.tab, 48)
    }

    // MARK: 真实系统剪贴板

    func testRealPasteboardRoundTripThroughBridge() throws {
        try XCTSkipUnless(hasDisplay, "无图形会话，跳过真实剪贴板用例")
        // T-CLIP-01/02 的系统层验证：桥接逻辑作用在真实 NSPasteboard 上
        let pasteboard = NSPasteboard.general
        let marker = "m2m-剪贴板-\(UUID().uuidString.prefix(8))"

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(marker, forType: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), marker)

        let bridge = ClipboardBridge()
        // 模拟"从远端复制到本地"：远端内容写入系统剪贴板后，系统会报告一次本地变化
        let fromRemote = ClipboardUpdate(kind: .text, text: marker,
                                         hash: FileBridge.sha256(Data(marker.utf8)),
                                         origin: .host)
        XCTAssertTrue(bridge.receive(fromRemote))
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        // 同一内容必须被识别为回环，不产生回传
        XCTAssertNil(bridge.localChanged(text: marker, origin: .viewer))
        XCTAssertGreaterThan(bridge.suppressedLoops, 0)
    }

    func testRealPasteboardDetectsGenuineLocalChange() throws {
        try XCTSkipUnless(hasDisplay, "无图形会话，跳过真实剪贴板用例")
        let pasteboard = NSPasteboard.general
        let bridge = ClipboardBridge()
        let remote = "远端内容-\(UUID().uuidString.prefix(6))"
        _ = bridge.receive(ClipboardUpdate(kind: .text, text: remote,
                                           hash: FileBridge.sha256(Data(remote.utf8)),
                                           origin: .host))
        let local = "本地新内容-\(UUID().uuidString.prefix(6))"
        pasteboard.clearContents()
        pasteboard.setString(local, forType: .string)
        let out = bridge.localChanged(text: pasteboard.string(forType: .string) ?? "", origin: .viewer)
        XCTAssertNotNil(out, "真实的本地剪贴板内容变化必须产生回传")
        XCTAssertEqual(out?.text, local)
    }
}
