import XCTest
@testable import AIMECore

// 変換キー（ConvertKey）の書式・検証・一致のテスト。

final class ConvertKeyTests: XCTestCase {
    func testValidValues() throws {
        let cases: [(String, UInt16, KeyModifiers, String)] = [
            ("tab", 48, [], "tab"),
            ("option+space", 49, .option, "option+space"),
            ("Alt + Space", 49, .option, "option+space"),
            ("shift+space", 49, .shift, "shift+space"),
            ("ctrl+j", 38, .control, "ctrl+j"),
            ("control+space", 49, .control, "ctrl+space"),
            ("f13", 105, [], "f13"),
            ("F1", 122, [], "f1"),
            ("shift+tab", 48, .shift, "shift+tab"),
            ("cmd+shift+k", 40, [.command, .shift], "cmd+shift+k"),
            ("opt+1", 18, .option, "option+1"),
            ("ctrl+return", 36, .control, "ctrl+return"),
        ]
        for (text, code, mods, desc) in cases {
            let k = ConvertKey.parse(text)
            XCTAssertEqual(k?.keyCode, code, text)
            XCTAssertEqual(k?.modifiers, mods, text)
            XCTAssertEqual(k?.description, desc, text)
        }
    }

    func testRejectsKeysIndistinguishableFromTyping() throws {
        // 修飾キーなし（または shift だけ）の印字可能文字、修飾キーなしの空白・改行・Esc
        for text in ["a", "1", "-", "j", "shift+a", "return", "enter", "esc"] {
            XCTAssertNil(ConvertKey.parse(text), text)
        }
        // space と tab は修飾キーなしでも受け付ける
        XCTAssertEqual(ConvertKey.parse("space"), .space)
        XCTAssertEqual(ConvertKey.parse("tab"), .tab)
    }

    func testInvalidValuesFallBackToDefaultSpace() throws {
        for text in [nil, "", "foo", "ctrl+", "+j", "ctrl+ctrl+j", "hyper+j", "f21", "ctrl+-", "a"] as [String?] {
            XCTAssertEqual(ConvertKey.parseOrDefault(text), .space, String(describing: text))
        }
    }

    func testMatchesExactModifiers() throws {
        let k = try ck("option+space")
        XCTAssertTrue(k.matches(KeyStroke(keyCode: 49, modifiers: .option, characters: "\u{A0}")))
        XCTAssertFalse(k.matches(KeyStroke(keyCode: 49, modifiers: [.option, .shift], characters: " ")))
        XCTAssertFalse(k.matches(KeyStroke(keyCode: 49, characters: " ")))
        XCTAssertTrue(ConvertKey.tab.matches(KeyStroke(keyCode: 48, characters: "\t")))
        XCTAssertFalse(ConvertKey.tab.matches(KeyStroke(keyCode: 48, modifiers: .shift, characters: "\u{19}")))
    }

    func testClassifyWithConvertKey() throws {
        let optSpace = try ck("option+space")
        let tab = KeyStroke(keyCode: 48, characters: "\t")
        // 変換キーが Tab 以外のとき、Tab は変換キーではない（.other）
        XCTAssertEqual(ComposerKey.classify(tab, convertKey: optSpace), .other)
        XCTAssertEqual(ComposerKey.classify(KeyStroke(keyCode: 49, modifiers: .option, characters: "\u{A0}"), convertKey: optSpace), .convert)
        XCTAssertEqual(ComposerKey.classify(KeyStroke(keyCode: 49, characters: " "), convertKey: optSpace), .space)
        // ctrl+j: ⌃ の組み合わせでも変換キーなら .convert
        XCTAssertEqual(ComposerKey.classify(KeyStroke(keyCode: 38, modifiers: .control, characters: "\n"), convertKey: try ck("ctrl+j")), .convert)
        // 既定（Tab）
        XCTAssertEqual(ComposerKey.classify(tab), .convert)
    }
}

