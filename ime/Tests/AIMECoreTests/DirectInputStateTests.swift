import XCTest
@testable import AIMECore

/// 直接モードの状態機械（DirectInputState）を、偽のアプリで打鍵列から確かめる。
///
/// - 通常型: 文書全体を返し、打鍵した文字はカーソル位置に入る（テキストエディットなど）。
/// - 隠し欄型（Orca など Electron/xterm.js 系）: 画面裏の隠し入力欄の中身だけを返す。入力のたびに中身は直近の1文字になり、
///   カーソル位置は 1 に戻る。直前1文字は取れるので「置き換え可能」と誤判定されやすい。
final class FakeDirectApp: DirectTextClient {
    enum Kind { case normal, hiddenField }

    let kind: Kind
    var doc: NSMutableString
    var cursor: Int
    let bundleID: String?

    init(_ kind: Kind, text: String = "", bundleID: String) {
        self.kind = kind
        self.doc = NSMutableString(string: text)
        self.cursor = doc.length
        self.bundleID = bundleID
    }

    var selectedRange: NSRange? { NSRange(location: cursor, length: 0) }

    func text(in range: NSRange) -> String? {
        guard range.location >= 0, NSMaxRange(range) <= doc.length else { return nil }
        return doc.substring(with: range)
    }

    /// アプリにそのまま通った文字を受け取る。
    func receive(_ chars: String) {
        switch kind {
        case .normal:
            doc.insert(chars, at: cursor)
            cursor += (chars as NSString).length
        case .hiddenField:
            doc = NSMutableString(string: chars)
            cursor = doc.length
        }
    }
}

final class DirectInputStateTests: XCTestCase {
    private var memory = AppModeMemory()
    private var state = DirectInputState()
    private var composerIsEmpty = true
    /// 未確定文字の方式に渡った文字
    private var markedChars = ""

    private let space = ConvertKey.space

    private func focus(_ app: FakeDirectApp) {
        state.startField(bundleID: app.bundleID, memory: memory)
        state.probe(app)
        composerIsEmpty = true
        markedChars = ""
    }

    /// 1打鍵を処理し、判定を返す（そのまま通る打鍵は記録してアプリに入れる）。
    @discardableResult
    private func press(_ chars: String, keyCode: UInt16 = 0, in app: FakeDirectApp) -> DirectInputState.Decision {
        let stroke = KeyStroke(keyCode: keyCode, characters: chars, selectedRange: app.selectedRange)
        let (decision, _) = state.decide(stroke, convertKey: space, composerIsEmpty: composerIsEmpty, client: app, memory: &memory)
        switch decision {
        case .passThrough:
            state.record(stroke)
            app.receive(chars)
        case .marked:
            if keyCode != KeyStroke.Code.space { markedChars += chars; composerIsEmpty = false }
        case .convert:
            break
        }
        return decision
    }

    private func pressSpace(in app: FakeDirectApp) -> DirectInputState.Decision {
        press(" ", keyCode: KeyStroke.Code.space, in: app)
    }

    func testHiddenFieldAppFallsToMarkedOnSecondKeystroke() {
        let orca = FakeDirectApp(.hiddenField, text: "x", bundleID: "com.example.orca")
        focus(orca)
        XCTAssertEqual(state.field.lastMethod, .replace) // 直前1文字が取れるので、最初は置き換えと誤判定する
        XCTAssertEqual(press("k", in: orca), .passThrough) // 1打鍵目はまだ照合できない（確定したまま入る）
        XCTAssertEqual(press("y", in: orca), .marked)       // 2打鍵目: 位置が戻っている → 食い違い → 未確定文字
        XCTAssertTrue(state.field.lockedToMarked)
        XCTAssertTrue(memory.startsMarked(bundleID: "com.example.orca"))
        XCTAssertEqual(markedChars, "y")
    }

    func testSpacePassesAfterFallingToMarked() {
        let orca = FakeDirectApp(.hiddenField, text: "x", bundleID: "com.example.orca")
        focus(orca)
        press("k", in: orca)
        press("y", in: orca)
        composerIsEmpty = true // 未確定文字を確定したあと
        XCTAssertEqual(pressSpace(in: orca), .passThrough) // 未確定文字がないときの Space はそのまま通る
    }

    func testNextFocusStartsMarked() {
        let orca = FakeDirectApp(.hiddenField, text: "x", bundleID: "com.example.orca")
        focus(orca)
        press("k", in: orca)
        press("y", in: orca)
        // 別のアプリへ移る（記憶がないので置き換え）
        let edit = FakeDirectApp(.normal, text: "本文", bundleID: "com.apple.TextEdit")
        focus(edit)
        XCTAssertEqual(state.field.lastMethod, .replace)
        XCTAssertEqual(press("a", in: edit), .passThrough)
        // Orca に戻ると、1打鍵目から未確定文字
        focus(orca)
        XCTAssertEqual(press("k", in: orca), .marked)
    }

    func testUnverifiedFieldDoesNotReplace() {
        // フォーカス直後に打鍵せず変換キー: 隠し欄の古い中身（kyou）を信じて置き換えない
        let orca = FakeDirectApp(.hiddenField, text: "kyou", bundleID: "com.example.orca2")
        focus(orca)
        XCTAssertEqual(state.field.lastMethod, .replace)
        XCTAssertFalse(state.verified)
        XCTAssertEqual(pressSpace(in: orca), .passThrough)
        // 通常型のアプリでも、照合済みになるまでは置き換えない
        let edit = FakeDirectApp(.normal, text: "前の文kyou", bundleID: "com.apple.TextEdit")
        focus(edit)
        XCTAssertEqual(pressSpace(in: edit), .passThrough)
    }

    func testNormalAppIsVerifiedAfterTwoMatchingCharacters() {
        let edit = FakeDirectApp(.normal, text: "本文", bundleID: "com.apple.TextEdit")
        focus(edit)
        press("k", in: edit)
        XCTAssertFalse(state.verified) // 1文字だけでは照合済みにしない
        press("a", in: edit)
        XCTAssertEqual(pressSpace(in: edit), .convert) // "ka" が一致 → 照合済み → 変換
        XCTAssertTrue(state.verified)
        XCTAssertFalse(state.field.lockedToMarked)
        // 1文字だけ打ってすぐ変換キー: まだ照合済みでないので置き換えない
        focus(edit)
        press("k", in: edit)
        XCTAssertEqual(pressSpace(in: edit), .passThrough)
    }

    func testMismatchIsDetectedBeforeRouting() {
        // 照合は振り分けより先: 食い違いを検出した打鍵そのものが未確定文字に回る
        let orca = FakeDirectApp(.hiddenField, text: "x", bundleID: "com.example.orca3")
        focus(orca)
        press("k", in: orca)
        let stroke = KeyStroke(keyCode: 0, characters: "y", selectedRange: orca.selectedRange)
        let (decision, detected) = state.decide(stroke, convertKey: space, composerIsEmpty: true, client: orca, memory: &memory)
        XCTAssertTrue(detected)
        XCTAssertEqual(decision, .marked)
    }

    func testClickResetsVerification() {
        let edit = FakeDirectApp(.normal, text: "本文", bundleID: "com.apple.TextEdit")
        focus(edit)
        press("k", in: edit)
        press("a", in: edit)
        XCTAssertEqual(pressSpace(in: edit), .convert)
        XCTAssertTrue(state.verified)
        // クリック（新しい入力欄として扱う）
        state.startField(bundleID: edit.bundleID, memory: memory)
        XCTAssertFalse(state.verified)
    }
}

final class ConsistencyEdgeTests: XCTestCase {
    func testBufferLongerThanLocationIsNotApplicable() {
        // TypingBuffer.set に、記録した位置より長いテキストを渡した場合（公開 API から到達しうる）
        var b = TypingBuffer()
        b.set("abcdef", cursorLocation: 3)
        let c = FakeClient("abc")
        XCTAssertEqual(BufferConsistency.check(buffer: b, selectedRange: c.cursorAtEnd, fetch: c.fetch), .notApplicable)
    }
}
