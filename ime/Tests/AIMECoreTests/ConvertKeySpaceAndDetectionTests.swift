import AppKit
import Carbon.HIToolbox
import XCTest
@testable import AIMECore

// 変換キー Space の動作、Orca 対策（打鍵バッファとの照合・アプリ単位の記憶）、キー番号・修飾キーの照合のテスト。

final class SpaceConvertKeyTests: XCTestCase {
    private let space = KeyStroke(keyCode: 49, characters: " ")
    private let tab = KeyStroke(keyCode: 48, characters: "\t")
    private let letter = KeyStroke(keyCode: 40, characters: "k")

    private var converted: [String] = []
    private func convert(_ r: String) -> (text: String, leftContext: String)? {
        converted.append(r)
        return ("<\(r)>", "")
    }
    private func candidates(_ r: String, _ c: String, _ first: String) -> [String]? { [first, "2位"] }
    private func press(_ c: inout MarkedComposer, _ k: KeyStroke, _ key: ConvertKey) -> ComposerOutput {
        c.handle(ComposerKey.classify(k, convertKey: key), convert: convert, candidates: candidates)
    }

    func testClassifyWithSpaceConvertKey() {
        XCTAssertEqual(ComposerKey.classify(space, convertKey: .space), .convert)
        XCTAssertEqual(ComposerKey.classify(tab, convertKey: .space), .other)
        // 変換キーが space 以外なら、空白はこれまでどおり .space
        XCTAssertEqual(ComposerKey.classify(space, convertKey: .tab), .space)
        XCTAssertEqual(ComposerKey.classify(tab, convertKey: .tab), .convert)
    }

    func testMarkedModeWithSpace() {
        var c = MarkedComposer()
        // 未確定文字がないときの Space・Tab はそのまま通す
        XCTAssertEqual(press(&c, space, .space), .pass)
        XCTAssertEqual(press(&c, tab, .space), .pass)
        // 未確定文字があれば Space で変換、続けて Space で候補送り
        _ = press(&c, letter, .space)
        XCTAssertEqual(press(&c, space, .space), ComposerOutput(marked: "<k>"))
        XCTAssertEqual(press(&c, space, .space), ComposerOutput(marked: "2位"))
        XCTAssertEqual(press(&c, space, .space), ComposerOutput(marked: "k"))
        // Tab は確定してから通す
        XCTAssertEqual(press(&c, tab, .space), ComposerOutput(commit: "k", passKey: true))
        // 確定した直後の Space はそのまま通す
        XCTAssertEqual(press(&c, space, .space), .pass)
        // ローマ字入力中の Tab も、確定してから通す
        _ = press(&c, letter, .space)
        XCTAssertEqual(press(&c, tab, .space), ComposerOutput(commit: "k", passKey: true))
    }

    func testMarkedModeWithTabKeepsSpaceCommit() {
        // 変換キーが tab のときは、空白はこれまでどおり「確定して空白を通す」
        var c = MarkedComposer()
        _ = press(&c, letter, .tab)
        XCTAssertEqual(press(&c, space, .tab), ComposerOutput(commit: "k", passKey: true))
    }

    func testDirectModeRouteWithSpace() {
        func route(_ k: KeyStroke, empty: Bool = true, method: FieldMethod) -> DirectKeyRoute {
            DirectKeyRoute.route(k, convertKey: .space, composerIsEmpty: empty) { method }
        }
        // 置き換えの欄: Space は変換キー（ローマ字列がなければ、変換の処理の中でそのまま通す）
        XCTAssertEqual(route(space, method: .replace), .convert)
        XCTAssertEqual(route(tab, method: .replace), .passThrough)
        // 未確定文字の方式の欄で未確定文字がないとき: Space はそのまま通す
        XCTAssertEqual(route(space, method: .marked), .passThrough)
    }

    func testDirectModeSpaceWithoutRomajiPasses() {
        // 直前が日本語・空白・行頭なら変換するものがない → Space はそのまま通す（.nothingToConvert）
        for text in ["今日は", "foo ", ""] {
            let c = FakeClient(text)
            XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: c.cursorAtEnd, buffer: TypingBuffer(), fetch: c.fetch),
                           .nothingToConvert, text)
        }
    }
}

final class BufferConsistencyTests: XCTestCase {
    private func buffer(_ text: String, at start: Int) -> TypingBuffer {
        var b = TypingBuffer()
        var loc = start
        for ch in text {
            b.append(String(ch), cursorLocation: loc)
            loc += String(ch).utf16.count
        }
        return b
    }

    func testConsistentWhenClientReturnsTypedText() {
        let b = buffer("kyouha", at: 3)
        let c = FakeClient("今日はkyouha")
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: c.cursorAtEnd, fetch: c.fetch), .consistent)
    }

    func testMismatchWhenClientReturnsHiddenFieldContents() {
        // Orca のように、隠し入力欄の中身（直近の1文字だけなど）を返す
        let b = buffer("kyouha", at: 0)
        let hidden = FakeClient("xxxxxa") // 位置は合っているが中身が違う
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: hidden.cursorAtEnd, fetch: hidden.fetch), .mismatch)
    }

    func testMismatchWhenLocationDoesNotAdvance() {
        // 入力のたびに隠し入力欄が空になり、位置が戻る
        let b = buffer("ky", at: 0)
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: NSRange(location: 1, length: 0), fetch: { _ in "y" }), .mismatch)
    }

    func testMismatchWhenRangeCannotBeFetched() {
        let b = buffer("kyou", at: 0)
        let c = FakeClient("kyou", maxFetchLength: 1)
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: c.cursorAtEnd, fetch: c.fetch), .mismatch)
    }

    func testNotApplicable() {
        let c = FakeClient("abc")
        XCTAssertEqual(BufferConsistency.check(buffer: TypingBuffer(), selectedRange: c.cursorAtEnd, fetch: c.fetch), .notApplicable)
        let b = buffer("abc", at: 0)
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: nil, fetch: c.fetch), .notApplicable)
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: NSRange(location: 1, length: 2), fetch: c.fetch), .notApplicable)
    }

    func testComparesOnlyTheTailAndKeepsSurrogatePairs() {
        // 長いバッファは末尾（最大 16 UTF-16 単位）だけ比べる。サロゲートペアは割らない
        let typed = String(repeating: "a", count: 30) + "😀" + String(repeating: "b", count: 15)
        let b = buffer(typed, at: 0)
        let c = FakeClient(typed)
        var asked: [NSRange] = []
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: c.cursorAtEnd) { r in asked.append(r); return c.fetch(r) }, .consistent)
        XCTAssertEqual(asked.first?.length, 15) // 😀（2）を足すと 17 になるので、b の 15 個だけ
    }
}

final class AppModeMemoryTests: XCTestCase {
    func testRemembersFailedApps() {
        var m = AppModeMemory()
        XCTAssertFalse(m.startsMarked(bundleID: "com.example.orca"))
        m.markUnsupported(bundleID: "com.example.orca")
        XCTAssertTrue(m.startsMarked(bundleID: "com.example.orca"))
        XCTAssertFalse(m.startsMarked(bundleID: "com.apple.TextEdit"))
        // bundle ID が取れないときは覚えない・効かない
        m.markUnsupported(bundleID: nil)
        m.markUnsupported(bundleID: "")
        XCTAssertEqual(m.unsupportedApps, ["com.example.orca"])
        XCTAssertFalse(m.startsMarked(bundleID: nil))
    }

    func testMemoryAppliesToTheNextField() {
        var memory = AppModeMemory()
        var field = FieldModeState()
        // 1回目: Orca にフォーカス。直前1文字は取れるので置き換えと誤判定する
        field.reset(lockedToMarked: memory.startsMarked(bundleID: "com.example.orca"))
        XCTAssertEqual(field.method { .supported }, .replace)
        // 打鍵バッファとの食い違いを検出 → 欄もアプリも未確定文字へ
        field.markUnsupported()
        memory.markUnsupported(bundleID: "com.example.orca")
        XCTAssertEqual(field.method { .supported }, .marked)
        // 別のアプリに移る（記憶がないので置き換え）
        field.reset(lockedToMarked: memory.startsMarked(bundleID: "com.apple.TextEdit"))
        XCTAssertEqual(field.method { .supported }, .replace)
        // Orca に戻ってくる: 最初から未確定文字
        field.reset(lockedToMarked: memory.startsMarked(bundleID: "com.example.orca"))
        XCTAssertTrue(field.lockedToMarked)
        XCTAssertEqual(field.lastMethod, .marked)
        XCTAssertEqual(field.method { .supported }, .marked)
    }
}

final class KeyCodeAndModifierTests: XCTestCase {
    func testKeyCodesMatchCarbonConstants() throws {
        let carbon: [String: Int] = [
            "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return, "enter": kVK_Return,
            "esc": kVK_Escape, "escape": kVK_Escape,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
            "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13,
            "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        let ours = ConvertKey.keyCodesByName
        XCTAssertEqual(Set(ours.keys), Set(carbon.keys))
        for (name, code) in carbon {
            XCTAssertEqual(Int(try XCTUnwrap(ours[name], name)), code, name)
        }
        // KeyStroke.Code も Carbon と一致する
        XCTAssertEqual(Int(KeyStroke.Code.tab), kVK_Tab)
        XCTAssertEqual(Int(KeyStroke.Code.space), kVK_Space)
        XCTAssertEqual(Int(KeyStroke.Code.returnKey), kVK_Return)
        XCTAssertEqual(Int(KeyStroke.Code.keypadEnter), kVK_ANSI_KeypadEnter)
        XCTAssertEqual(Int(KeyStroke.Code.deleteBackward), kVK_Delete)
        XCTAssertEqual(Int(KeyStroke.Code.escape), kVK_Escape)
        XCTAssertEqual(Set(KeyStroke.Code.cursorMoving.map(Int.init)),
                       [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown])
    }

    func testValidateAndParseRoundTripForAllKeysAndModifiers() throws {
        let modifierNames: [(KeyModifiers, String)] = [(.command, "cmd"), (.control, "ctrl"), (.option, "option"), (.shift, "shift")]
        var accepted = 0
        for (name, code) in ConvertKey.keyCodesByName {
            for bits in 0..<16 {
                var mods: KeyModifiers = []
                var parts: [String] = []
                for (i, (m, n)) in modifierNames.enumerated() where bits & (1 << i) != 0 {
                    mods.insert(m)
                    parts.append(n)
                }
                let text = (parts + [name]).joined(separator: "+")
                let validated = try? ConvertKey.validate(keyCode: code, modifiers: mods).get()
                let parsed = ConvertKey.parse(text)
                // 書式から解析した結果と、キー番号から検証した結果が一致する
                XCTAssertEqual(parsed, validated, text)
                if let key = validated {
                    accepted += 1
                    XCTAssertEqual(key.keyCode, code, text)
                    XCTAssertEqual(key.modifiers, mods, text)
                    // 保存する書式を解析すると同じキーに戻る
                    XCTAssertEqual(ConvertKey.parse(key.description), key, text)
                    XCTAssertTrue(key.matches(KeyStroke(keyCode: code, modifiers: mods, characters: nil)), text)
                }
            }
        }
        XCTAssertGreaterThan(accepted, 0)
    }

    func testModifiersFromNSEventFlags() {
        XCTAssertEqual(KeyModifiers.nsShift, NSEvent.ModifierFlags.shift.rawValue)
        XCTAssertEqual(KeyModifiers.nsControl, NSEvent.ModifierFlags.control.rawValue)
        XCTAssertEqual(KeyModifiers.nsOption, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(KeyModifiers.nsCommand, NSEvent.ModifierFlags.command.rawValue)
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function, .numericPad]
        XCTAssertEqual(KeyModifiers(modifierFlagsRawValue: flags.rawValue), [.command, .shift]) // ⌘⌃⌥⇧ 以外は無視
        XCTAssertEqual(KeyModifiers(modifierFlagsRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue), [.control, .option])
        XCTAssertEqual(KeyModifiers(modifierFlagsRawValue: 0), [])
    }
}
