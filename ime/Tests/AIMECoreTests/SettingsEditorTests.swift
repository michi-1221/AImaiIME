import XCTest
@testable import AIMECore

// 設定ウィンドウの裏側（純粋な関数）のテスト: 変換キーの検証・表示、設定の書き込みと読み込み。

final class ConvertKeyValidationTests: XCTestCase {
    func testValidateAcceptsSameRulesAsParse() throws {
        let cases: [(UInt16, KeyModifiers, String, String)] = [
            (48, [], "tab", "Tab"),
            (49, .option, "option+space", "⌥Space"),
            (49, .shift, "shift+space", "⇧Space"),
            (38, .control, "ctrl+j", "⌃J"),
            (49, .control, "ctrl+space", "⌃Space"),
            (105, [], "f13", "F13"),
            (36, .shift, "shift+return", "⇧Return"),
            (53, .control, "ctrl+esc", "⌃Esc"),
            (40, [.command, .shift], "cmd+shift+k", "⇧⌘K"),
            (18, [.control, .option], "ctrl+option+1", "⌃⌥1"),
        ]
        for (code, mods, desc, display) in cases {
            let key = try ConvertKey.validate(keyCode: code, modifiers: mods).get()
            XCTAssertEqual(key.description, desc)
            XCTAssertEqual(key.displayString, display)
            // 保存する書式と解析が往復できる
            XCTAssertEqual(ConvertKey.parse(key.description), key, desc)
        }
        XCTAssertEqual(ConvertKey.tab.displayString, "Tab")
    }

    func testValidateRejectsWithReasons() throws {
        XCTAssertEqual(ConvertKey.validate(keyCode: 0, modifiers: []), .failure(.needsCommandControlOption("A")))
        XCTAssertEqual(ConvertKey.validate(keyCode: 0, modifiers: .shift), .failure(.needsCommandControlOption("A")))
        XCTAssertEqual(ConvertKey.validate(keyCode: 18, modifiers: []), .failure(.needsCommandControlOption("1")))
        XCTAssertEqual(ConvertKey.validate(keyCode: 49, modifiers: []), .success(.space)) // space は修飾キーなしで可
        XCTAssertEqual(ConvertKey.validate(keyCode: 36, modifiers: []), .failure(.needsModifier("Return")))
        XCTAssertEqual(ConvertKey.validate(keyCode: 53, modifiers: []), .failure(.needsModifier("Esc")))
        XCTAssertEqual(ConvertKey.validate(keyCode: 27, modifiers: .control), .failure(.unsupportedKey)) // "-"
        XCTAssertEqual(ConvertKey.validate(keyCode: 123, modifiers: .control), .failure(.unsupportedKey)) // ←
        // 理由の文は表示できる日本語
        if case .failure(let r) = ConvertKey.validate(keyCode: 0, modifiers: []) {
            XCTAssertTrue(r.description.contains("⌘・⌃・⌥"))
        }
    }

    func testConflictNotes() throws {
        XCTAssertTrue(try XCTUnwrap(try ck("ctrl+space").conflictNote).contains("入力ソース"))
        XCTAssertTrue(try XCTUnwrap(try ck("shift+return").conflictNote).contains("改行"))
        XCTAssertNotNil(try ck("shift+space").conflictNote)
        XCTAssertNotNil(ConvertKey.tab.conflictNote)
        XCTAssertNotNil(try ck("cmd+j").conflictNote)
        XCTAssertNotNil(try ck("ctrl+a").conflictNote)
        XCTAssertNil(try ck("option+space").conflictNote)
        XCTAssertNil(try ck("f13").conflictNote)
        XCTAssertNil(try ck("ctrl+j").conflictNote)
    }
}

final class SettingsEditorTests: XCTestCase {
    private var suite = ""
    private var d: UserDefaults!

    override func setUpWithError() throws {
        suite = "aime-test-\(UUID())"
        d = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        d.removePersistentDomain(forName: suite)
    }

    func testWritesAreReadBySettingsLoad() throws {
        SettingsEditor.setInputMode(.direct, in: d)
        SettingsEditor.setFullWidthDigits(true, in: d)
        SettingsEditor.setModelPath("/tmp/m.gguf", in: d)
        XCTAssertEqual(SettingsEditor.setCandidateCount(7, in: d), 7)
        let s = Settings.load(from: d)
        XCTAssertEqual(s.inputMode, .direct)
        XCTAssertTrue(s.postProcess.fullWidthDigits)
        XCTAssertEqual(s.modelPath, "/tmp/m.gguf")
        XCTAssertEqual(s.candidateCount, 7)
        XCTAssertEqual(s.invalidValues, [])
        // defaults write と同じキー・書式
        XCTAssertEqual(d.string(forKey: "inputMode"), "direct")
        SettingsEditor.setInputMode(.marked, in: d)
        XCTAssertEqual(d.string(forKey: "inputMode"), "marked")
    }

    func testCandidateCountIsClamped() throws {
        XCTAssertEqual(SettingsEditor.setCandidateCount(0, in: d), 1)
        XCTAssertEqual(d.integer(forKey: "candidateCount"), 1)
        XCTAssertEqual(SettingsEditor.setCandidateCount(100, in: d), 32)
        XCTAssertEqual(Settings.load(from: d).candidateCount, 32)
    }

    func testRecordConvertKey() throws {
        // 受け付けるもの: 保存する
        XCTAssertEqual(try SettingsEditor.recordConvertKey(keyCode: 38, modifiers: .control, in: d).get().description, "ctrl+j")
        XCTAssertEqual(d.string(forKey: "convertKey"), "ctrl+j")
        XCTAssertEqual(Settings.load(from: d).convertKey, ConvertKey.parse("ctrl+j"))
        // 受け付けないもの: 保存しない（前の値のまま）
        XCTAssertEqual(SettingsEditor.recordConvertKey(keyCode: 0, modifiers: [], in: d), .failure(.needsCommandControlOption("A")))
        XCTAssertEqual(d.string(forKey: "convertKey"), "ctrl+j")
        // 既定に戻す
        // space（修飾キーなし）も記録できる
        XCTAssertEqual(try SettingsEditor.recordConvertKey(keyCode: 49, modifiers: [], in: d).get(), .space)
        // 既定に戻す（以前の directConvertKey も消す）
        d.set("ctrl+j", forKey: "directConvertKey")
        SettingsEditor.resetConvertKey(in: d)
        XCTAssertNil(d.object(forKey: "convertKey"))
        XCTAssertNil(d.object(forKey: "directConvertKey"))
        XCTAssertEqual(Settings.load(from: d).convertKey, .space)
    }

    func testExternalInvalidValuesShowDefaultsWithWarnings() throws {
        // defaults write で不正な値が入っている
        d.set("dirct", forKey: "inputMode")
        d.set("ctl+j", forKey: "convertKey")
        let s = Settings.load(from: d)
        XCTAssertEqual(s.inputMode, .marked)
        XCTAssertEqual(s.convertKey, .space)
        XCTAssertEqual(s.invalidValues.count, 2)
    }

    func testModelPathWarning() throws {
        var s = Settings()
        s.modelPath = "/nonexistent/model.gguf"
        XCTAssertNotNil(SettingsEditor.modelPathWarning(s))
        let dir = FileManager.default.temporaryDirectory
        s.modelPath = dir.path
        XCTAssertTrue(try XCTUnwrap(SettingsEditor.modelPathWarning(s)).contains("フォルダー"))
        let file = dir.appendingPathComponent("aime-\(UUID()).gguf")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        s.modelPath = file.path
        XCTAssertNil(SettingsEditor.modelPathWarning(s))
    }
}
