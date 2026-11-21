import XCTest
@testable import AIMECore

// 直接モード（inputMode = direct）の部品のテスト:
// ローマ字列の切り出し、打鍵バッファ、置き換え範囲の決定、候補送りの判定、入力欄ごとの方式、変換キー。

final class RomajiExtractorTests: XCTestCase {
    func testWholeTextIsRomaji() throws {
        let r = RomajiExtractor.extract(from: "raishuunokaigide")
        XCTAssertEqual(r?.romaji, "raishuunokaigide")
        XCTAssertEqual(r?.leftContext, "")
    }

    func testStopsAtJapanese() throws {
        let r = RomajiExtractor.extract(from: "来週の会議でshiryouwo")
        XCTAssertEqual(r?.romaji, "shiryouwo")
        XCTAssertEqual(r?.leftContext, "来週の会議で")
    }

    func testStopsAtSpaceAndNewline() throws {
        XCTAssertEqual(RomajiExtractor.extract(from: "foo bar-baz")?.romaji, "bar-baz")
        XCTAssertEqual(RomajiExtractor.extract(from: "foo bar-baz")?.leftContext, "foo ")
        XCTAssertEqual(RomajiExtractor.extract(from: "一行目\nnigyoume")?.romaji, "nigyoume")
        XCTAssertEqual(RomajiExtractor.extract(from: "一行目\nnigyoume")?.leftContext, "一行目\n")
        XCTAssertEqual(RomajiExtractor.extract(from: "a\tb")?.romaji, "b")
    }

    func testIncludesSymbolsAndDigits() throws {
        let r = RomajiExtractor.extract(from: "は、v2.0no{api}wo!?")
        XCTAssertEqual(r?.romaji, "v2.0no{api}wo!?")
        XCTAssertEqual(r?.leftContext, "は、")
    }

    func testEmptyRomajiReturnsNil() throws {
        XCTAssertNil(RomajiExtractor.extract(from: ""))
        XCTAssertNil(RomajiExtractor.extract(from: "日本語"))
        XCTAssertNil(RomajiExtractor.extract(from: "abc "))
        XCTAssertNil(RomajiExtractor.extract(from: "abc\n"))
        XCTAssertNil(RomajiExtractor.extract(from: "ａｂｃ")) // 全角英字は ASCII ではない
    }

    func testLeftContextIsLimitedTo40Scalars() throws {
        let ctx = String(repeating: "あ", count: 30) + String(repeating: "い", count: 30)
        let r = RomajiExtractor.extract(from: ctx + "ka")
        XCTAssertEqual(r?.leftContext, String(repeating: "あ", count: 10) + String(repeating: "い", count: 30))
        let s = "👍🏽" + "か\u{3099}" + String(repeating: "ん", count: 38)
        XCTAssertEqual(RomajiExtractor.extract(from: s + "ka")?.leftContext, "か\u{3099}" + String(repeating: "ん", count: 38))
    }

    func testUTF16Length() throws {
        let r = RomajiExtractor.extract(from: "😀abc")
        XCTAssertEqual(r?.romajiUTF16Length, 3)
        XCTAssertEqual(r?.leftContext, "😀")
    }
}

final class TypingBufferTests: XCTestCase {
    func testAppendAndDeleteTrackLocation() throws {
        var b = TypingBuffer(capacity: 10)
        b.sync(cursorLocation: 5)
        b.append("abc", cursorLocation: 5)
        XCTAssertEqual(b.expectedLocation, 8)
        b.sync(cursorLocation: 8)
        b.deleteBackward(cursorLocation: 8)
        XCTAssertEqual(b.text, "ab")
        XCTAssertEqual(b.expectedLocation, 7)
        b.append("😀", cursorLocation: 7) // サロゲートペアは UTF-16 で2
        XCTAssertEqual(b.expectedLocation, 9)
        b.deleteBackward(cursorLocation: 9)
        XCTAssertEqual(b.text, "ab")
        XCTAssertEqual(b.expectedLocation, 7)
    }

    func testDriftResets() throws {
        var b = TypingBuffer()
        b.append("abc", cursorLocation: 0)
        b.sync(cursorLocation: 1) // クリック・Undo・ペーストなどで位置がずれた
        XCTAssertEqual(b, TypingBuffer())
        b.append("x", cursorLocation: 1)
        b.sync(cursorLocation: nil) // 位置を取得できない
        XCTAssertEqual(b.text, "")
    }

    func testDeleteOnEmptyResets() throws {
        var b = TypingBuffer()
        b.deleteBackward(cursorLocation: 3)
        XCTAssertEqual(b, TypingBuffer())
    }

    func testCapacityAndSet() throws {
        var b = TypingBuffer(capacity: 4)
        b.append("abcdef", cursorLocation: 0)
        XCTAssertEqual(b.text, "cdef")
        XCTAssertFalse(b.knowsPrecedingText) // 古い側を捨てた
        b.set("前文本番", cursorLocation: 20)
        XCTAssertEqual(b.text, "前文本番")
        XCTAssertEqual(b.expectedLocation, 20)
        XCTAssertTrue(b.knowsPrecedingText)
        b.reset()
        XCTAssertEqual(b, TypingBuffer(capacity: 4))
    }
}

final class KeyRecordingTests: XCTestCase {
    private typealias Code = KeyStroke.Code

    private func type(_ chars: String, at loc: Int, _ mods: KeyModifiers = []) -> KeyStroke {
        KeyStroke(keyCode: 0, modifiers: mods, characters: chars, selectedRange: NSRange(location: loc, length: 0))
    }

    private func key(_ code: UInt16, at loc: Int, _ mods: KeyModifiers = [], chars: String? = nil) -> KeyStroke {
        KeyStroke(keyCode: code, modifiers: mods, characters: chars, selectedRange: NSRange(location: loc, length: 0))
    }

    /// "abc" を位置 10 から打った状態
    private func typedABC() -> TypingBuffer {
        var b = TypingBuffer()
        b.record(type("a", at: 10))
        b.record(type("b", at: 11))
        b.record(type("c", at: 12))
        XCTAssertEqual(b.text, "abc")
        XCTAssertEqual(b.expectedLocation, 13)
        return b
    }

    func testFirstKeystroke() throws {
        var b = TypingBuffer()
        b.record(type("k", at: 10)) // 途中から打ち始めた: 前のテキストはわからない
        XCTAssertEqual(b.text, "k")
        XCTAssertEqual(b.expectedLocation, 11)
        XCTAssertFalse(b.knowsPrecedingText)
        var c = TypingBuffer()
        c.record(type("k", at: 0)) // 文書の先頭から: 前には何もない
        XCTAssertTrue(c.knowsPrecedingText)
    }

    func testDeleteBackward() throws {
        var b = typedABC()
        b.record(key(Code.deleteBackward, at: 13, chars: "\u{7F}"))
        XCTAssertEqual(b.text, "ab")
        XCTAssertEqual(b.expectedLocation, 12)
        b.record(type("x", at: 12))
        XCTAssertEqual(b.text, "abx")
    }

    func testResettingKeys() throws {
        let cases: [KeyStroke] = [
            key(Code.deleteBackward, at: 13, .option, chars: "\u{7F}"), // Option+Delete
            key(Code.returnKey, at: 13, chars: "\r"),
            key(Code.keypadEnter, at: 13, chars: "\u{3}"),
            key(Code.escape, at: 13, chars: "\u{1B}"),
            key(Code.tab, at: 13, chars: "\t"),
            key(Code.tab, at: 13, .shift, chars: "\u{19}"),
            key(123, at: 13, chars: "\u{F702}"), // ←
            type("v", at: 13, .command),
            type("a", at: 13, .control),
            type("\u{1B}", at: 13),
            type("\u{F704}", at: 13), // F1 など
            KeyStroke(keyCode: 0, characters: "", selectedRange: NSRange(location: 13, length: 0)),
            KeyStroke(keyCode: 0, characters: "d", selectedRange: NSRange(location: 13, length: 2)), // 選択範囲あり
            KeyStroke(keyCode: 0, characters: "d", selectedRange: nil),
        ]
        for k in cases {
            var b = typedABC()
            b.record(k)
            XCTAssertEqual(b.text, "", "\(k)")
        }
    }

    func testDriftIsDetected() throws {
        var b = typedABC()
        b.record(type("d", at: 20))
        XCTAssertEqual(b.text, "d")
        XCTAssertEqual(b.expectedLocation, 21)
        XCTAssertFalse(b.knowsPrecedingText)
    }

    func testShiftAndOptionCharactersAreRecorded() throws {
        var b = typedABC()
        b.record(type("A", at: 13, .shift))
        b.record(type("å", at: 14, .option))
        XCTAssertEqual(b.text, "abcAå")
    }
}

/// クライアントのテキストを NSString で模したもの。
struct FakeClient {
    var text: NSString
    var canFetch = true
    /// 指定した長さ以下の範囲だけ返す（短い範囲しか返さないクライアント）
    var maxFetchLength = Int.max
    /// この位置より前から始まる範囲は返さない
    var minFetchLocation = 0

    init(_ text: String, canFetch: Bool = true, maxFetchLength: Int = .max, minFetchLocation: Int = 0) {
        self.text = text as NSString
        self.canFetch = canFetch
        self.maxFetchLength = maxFetchLength
        self.minFetchLocation = minFetchLocation
    }

    var cursorAtEnd: NSRange { NSRange(location: text.length, length: 0) }

    func fetch(_ r: NSRange) -> String? {
        guard canFetch, r.length <= maxFetchLength, r.location >= minFetchLocation, NSMaxRange(r) <= text.length else { return nil }
        return text.substring(with: r)
    }
}

final class ReplacementPlannerTests: XCTestCase {
    func testClientText() throws {
        let c = FakeClient("本番では2dainosa-ba-")
        let p = try XCTUnwrap(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: TypingBuffer(), fetch: c.fetch))
        XCTAssertEqual(p.romaji, "2dainosa-ba-")
        XCTAssertEqual(p.leftContext, "本番では")
        XCTAssertEqual(p.replacementRange, NSRange(location: 4, length: 12))
        XCTAssertFalse(p.usedBuffer)
        XCTAssertEqual(p.textBeforeRomaji, "本番では")
    }

    func testEmojiAndSurrogatePairsOnTheLeft() throws {
        let c = FakeClient("😀👍🏽テストdesu")
        let p = try XCTUnwrap(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: TypingBuffer(), fetch: c.fetch))
        XCTAssertEqual(p.romaji, "desu")
        XCTAssertEqual(p.replacementRange, NSRange(location: 2 + 4 + 3, length: 4))
        XCTAssertEqual(c.fetch(p.replacementRange), "desu")
        XCTAssertEqual(p.leftContext, "😀👍🏽テスト")
    }

    func testCursorInTheMiddle() throws {
        let c = FakeClient("あいうkakiku えお")
        let p = try XCTUnwrap(ReplacementPlanner.plan(selectedRange: NSRange(location: 9, length: 0), buffer: TypingBuffer(), fetch: c.fetch))
        XCTAssertEqual(p.romaji, "kakiku")
        XCTAssertEqual(p.replacementRange, NSRange(location: 3, length: 6))
    }

    func testOutcomeReasons() throws {
        let none = FakeClient("日本語 ")
        XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: none.cursorAtEnd, buffer: TypingBuffer(), fetch: none.fetch), .nothingToConvert)
        let d = FakeClient("abc")
        XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: NSRange(location: 1, length: 2), buffer: TypingBuffer(), fetch: d.fetch), .nothingToConvert)
        XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: NSRange(location: 0, length: 0), buffer: TypingBuffer(), fetch: d.fetch), .nothingToConvert)
        XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: NSRange(location: NSNotFound, length: 0), buffer: TypingBuffer(), fetch: d.fetch), .textUnavailable)
        let blind = FakeClient("kyou", canFetch: false)
        XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: blind.cursorAtEnd, buffer: TypingBuffer(), fetch: blind.fetch), .textUnavailable)
    }

    func testBufferUsedWhenLongRangeCannotBeFetched() throws {
        let c = FakeClient("前置きkyouha", maxFetchLength: 6)
        var b = TypingBuffer()
        b.append("前置きkyouha", cursorLocation: 0)
        let p = try XCTUnwrap(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: b, fetch: c.fetch))
        XCTAssertTrue(p.usedBuffer)
        XCTAssertEqual(p.romaji, "kyouha")
        XCTAssertEqual(p.leftContext, "前置き")
        XCTAssertEqual(p.replacementRange, NSRange(location: 3, length: 6))
    }

    func testBufferContentIsComparedByUTF16() throws {
        // ケルビン記号（U+212A）は K と正規化で等しく、String の == では一致してしまう
        XCTAssertTrue("\u{212A}you" == "Kyou")
        var b = TypingBuffer()
        b.append("前Kyou", cursorLocation: 0)
        // 長い範囲は返さず、置き換え範囲（4）は返すクライアント。実テキストは「前\u{212A}you」
        let c = FakeClient("前\u{212A}you", maxFetchLength: 4)
        XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: c.cursorAtEnd, buffer: b, fetch: c.fetch), .textUnavailable)
        // 対照: 実テキストが同じ並びなら使う
        let ok = FakeClient("前Kyou", maxFetchLength: 4)
        XCTAssertEqual(ReplacementPlanner.plan(selectedRange: ok.cursorAtEnd, buffer: b, fetch: ok.fetch)?.romaji, "Kyou")
    }

    func testBufferNotUsedWhenItCannotBeVerified() throws {
        let c = FakeClient("kyouha", canFetch: false)
        var b = TypingBuffer()
        b.append("kyouha", cursorLocation: 0)
        XCTAssertEqual(ReplacementPlanner.outcome(selectedRange: c.cursorAtEnd, buffer: b, fetch: c.fetch), .textUnavailable)
    }

    func testDriftedBufferByLocationIsNotUsed() throws {
        let c = FakeClient("xxkyouha", maxFetchLength: 6)
        var b = TypingBuffer()
        b.append("kyouha", cursorLocation: 0) // 位置 6 を期待しているが、実際のカーソルは 8
        XCTAssertNil(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: b, fetch: c.fetch))
    }

    func testDriftedBufferByContentIsNotUsed() throws {
        // 位置は一致し、置き換え範囲（7）も取得できるが、中身が違う
        let c = FakeClient("あいbcdefgh", maxFetchLength: 7)
        var b = TypingBuffer()
        b.append("あいzzzefgh", cursorLocation: 0)
        XCTAssertEqual(c.fetch(NSRange(location: 2, length: 7)), "bcdefgh")
        XCTAssertNil(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: b, fetch: c.fetch))
        let ok = FakeClient("あいzzzefgh", maxFetchLength: 7)
        XCTAssertEqual(ReplacementPlanner.plan(selectedRange: ok.cursorAtEnd, buffer: b, fetch: ok.fetch)?.romaji, "zzzefgh")
    }

    private func bufferStartedMidway(_ typed: String, at location: Int) -> TypingBuffer {
        var b = TypingBuffer()
        b.append(typed, cursorLocation: location)
        XCTAssertFalse(b.knowsPrecedingText)
        return b
    }

    func testBufferWithUnknownPrecedingRomajiIsNotUsed() throws {
        // example.com/ の直後をクリックして kyou と打った: ローマ字列は本当は example.com/kyou
        let c = FakeClient("example.com/kyou", maxFetchLength: 4)
        XCTAssertNil(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: bufferStartedMidway("kyou", at: 12), fetch: c.fetch))
    }

    func testBufferWithUnknownPrecedingNonRomajiIsUsed() throws {
        for prefix in ["今日は", "foo "] {
            let c = FakeClient(prefix + "kyou", maxFetchLength: 4)
            let b = bufferStartedMidway("kyou", at: (prefix as NSString).length)
            let p = try XCTUnwrap(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: b, fetch: c.fetch), prefix)
            XCTAssertEqual(p.replacementRange, NSRange(location: (prefix as NSString).length, length: 4))
        }
        let e = FakeClient("😀kyou", maxFetchLength: 4)
        XCTAssertNotNil(ReplacementPlanner.plan(selectedRange: e.cursorAtEnd, buffer: bufferStartedMidway("kyou", at: 2), fetch: e.fetch))
    }

    func testBufferWithUnknownPrecedingThatCannotBeFetchedIsNotUsed() throws {
        let c = FakeClient("今日はkyou", maxFetchLength: 4, minFetchLocation: 3)
        XCTAssertNil(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: bufferStartedMidway("kyou", at: 3), fetch: c.fetch))
    }

    func testBufferWithKnownPrecedingTextSkipsTheCheck() throws {
        let c = FakeClient("今日はkyou", maxFetchLength: 4, minFetchLocation: 3)
        var b = TypingBuffer()
        b.set("", cursorLocation: 3)
        b.append("kyou", cursorLocation: 3)
        XCTAssertEqual(ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: b, fetch: c.fetch)?.romaji, "kyou")
    }

    func testFetchLengthIsCapped() throws {
        let c = FakeClient(String(repeating: "あ", count: 3000) + "kana")
        var requested: [NSRange] = []
        let p = ReplacementPlanner.plan(selectedRange: c.cursorAtEnd, buffer: TypingBuffer()) { r in
            requested.append(r)
            return c.fetch(r)
        }
        XCTAssertEqual(requested.first?.length, ReplacementPlanner.fetchLength)
        XCTAssertEqual(p?.replacementRange, NSRange(location: 3000, length: 4))
    }
}

final class DirectCandidateCycleTests: XCTestCase {
    /// クライアントの文書を模したもの（insertText を反映する）
    private final class Doc {
        var text: NSMutableString
        var cursor: Int
        var canFetch = true
        init(_ s: String) { text = NSMutableString(string: s); cursor = text.length }
        var sel: NSRange { NSRange(location: cursor, length: 0) }
        func fetch(_ r: NSRange) -> String? {
            guard canFetch, r.location >= 0, NSMaxRange(r) <= text.length else { return nil }
            return text.substring(with: r)
        }
        func insert(_ s: String, replacing r: NSRange) {
            text.replaceCharacters(in: r, with: s)
            cursor = r.location + (s as NSString).length
        }
    }

    /// "😀前文" + romaji を1回目の変換キーで first に置き換えた状態
    private func converted(first: String = "今日は") -> (Doc, CandidateCycler) {
        let doc = Doc("😀前文kyouha")
        let start = ("😀前文" as NSString).length
        doc.insert(first, replacing: NSRange(location: start, length: 6))
        var cycler = CandidateCycler()
        cycler.start(CandidateCycle(romaji: "kyouha", leftContext: "😀前文", textBeforeRomaji: "😀前文", start: start, first: first))
        return (doc, cycler)
    }

    private func press(_ doc: Doc, _ cycler: inout CandidateCycler, candidates: [String]) -> CandidateCycle.Decision {
        let d = cycler.tab(selectedRange: doc.sel, fetch: doc.fetch)
        if d == .advance {
            if cycler.cycle?.hasComputedCandidates == false { cycler.setCandidates(candidates) }
            guard let next = cycler.advance() else {
                XCTFail("候補送り中なのに advance が nil")
                return d
            }
            doc.insert(next.text, replacing: next.range)
        }
        return d
    }

    func testCyclesThroughCandidatesThenRomajiThenFirst() throws {
        var (doc, cycler) = converted()
        var seen: [String] = []
        for _ in 0..<5 {
            XCTAssertEqual(press(doc, &cycler, candidates: ["今日は", "京は", "強は"]), .advance)
            seen.append(doc.text as String)
        }
        XCTAssertEqual(seen, ["😀前文京は", "😀前文強は", "😀前文kyouha", "😀前文今日は", "😀前文京は"])
    }

    func testOtherKeyEndsCycle() throws {
        var (doc, cycler) = converted()
        _ = press(doc, &cycler, candidates: ["今日は", "京は"])
        cycler.end()
        XCTAssertEqual(press(doc, &cycler, candidates: []), .newConversion)
        XCTAssertEqual(doc.text, "😀前文京は")
    }

    func testCursorMovedEndsCycle() throws {
        var (doc, cycler) = converted()
        doc.cursor -= 1
        XCTAssertEqual(press(doc, &cycler, candidates: ["今日は", "京は"]), .newConversion)
        XCTAssertNil(cycler.cycle)
        XCTAssertEqual(doc.text, "😀前文今日は")
    }

    func testTextMismatchEndsCycle() throws {
        var (doc, cycler) = converted()
        doc.text.replaceCharacters(in: NSRange(location: 4, length: 1), with: "昨")
        XCTAssertEqual(press(doc, &cycler, candidates: ["今日は", "京は"]), .newConversion)
        XCTAssertEqual(doc.text, "😀前文昨日は")
    }

    func testUnverifiableTextPassesKey() throws {
        var (doc, cycler) = converted()
        doc.canFetch = false
        XCTAssertEqual(press(doc, &cycler, candidates: ["今日は", "京は"]), .passThrough)
        XCTAssertNil(cycler.cycle)
    }

    func testTextIsComparedByUTF16() throws {
        XCTAssertTrue("\u{00C5}" == "\u{212B}") // String の == では一致してしまう
        let c = CandidateCycle(romaji: "a", leftContext: "", first: "\u{00C5}")
        let sel = NSRange(location: 1, length: 0)
        XCTAssertEqual(c.decide(selectedRange: sel, fetch: { _ in "\u{212B}" }), .newConversion)
        XCTAssertEqual(c.decide(selectedRange: sel, fetch: { _ in "\u{00C5}" }), .advance)
    }

    func testRangesUseUTF16Lengths() throws {
        var (doc, cycler) = converted(first: "𠮷野家")
        XCTAssertEqual(cycler.cycle?.currentRange, NSRange(location: 4, length: 4))
        XCTAssertEqual(press(doc, &cycler, candidates: ["𠮷野家", "吉野家"]), .advance)
        XCTAssertEqual(doc.text, "😀前文吉野家")
        XCTAssertEqual(press(doc, &cycler, candidates: []), .advance)
        XCTAssertEqual(doc.text, "😀前文kyouha")
    }
}

final class FieldModeTests: XCTestCase {
    func testProbe() throws {
        let c = FakeClient("abc")
        XCTAssertEqual(ClientCapability.probe(selectedRange: c.cursorAtEnd, fetch: c.fetch), .supported)
        XCTAssertEqual(ClientCapability.probe(selectedRange: NSRange(location: 0, length: 0), fetch: c.fetch), .unknown)
        XCTAssertEqual(ClientCapability.probe(selectedRange: nil, fetch: c.fetch), .unsupported)
        let blind = FakeClient("abc", canFetch: false)
        XCTAssertEqual(ClientCapability.probe(selectedRange: blind.cursorAtEnd, fetch: blind.fetch), .unsupported)
    }

    func testMethodFollowsTheCurrentField() throws {
        var m = FieldModeState()
        XCTAssertEqual(m.method { .supported }, .replace)
        XCTAssertEqual(m.method { .unsupported }, .marked) // 同じアプリの中で、対応しない欄に移った
        XCTAssertEqual(m.method { .unknown }, .marked)     // 先頭にいて試せない
        XCTAssertEqual(m.method { .supported }, .replace)
    }

    func testFailureLocksToMarkedUntilFieldChanges() throws {
        var m = FieldModeState()
        m.markUnsupported()
        XCTAssertEqual(m.method { .supported }, .marked)
        m.reset()
        XCTAssertEqual(m.method { .supported }, .replace)
    }
}

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

final class DirectKeyRouteTests: XCTestCase {
    private let tab = KeyStroke(keyCode: 48, characters: "\t")
    private let optSpace = KeyStroke(keyCode: 49, modifiers: .option, characters: "\u{A0}")
    private let letter = KeyStroke(keyCode: 0, characters: "a")

    private func route(_ k: KeyStroke, _ convertKey: ConvertKey, empty: Bool = true, method: FieldMethod) -> DirectKeyRoute {
        DirectKeyRoute.route(k, convertKey: convertKey, composerIsEmpty: empty) { method }
    }

    func testTabPassesWhenConvertKeyIsNotTab() throws {
        let ck = try ck("option+space")
        XCTAssertEqual(route(tab, ck, method: .replace), .passThrough)
        XCTAssertEqual(route(tab, ck, method: .marked), .passThrough)
        XCTAssertEqual(route(optSpace, ck, method: .replace), .convert)
    }

    func testTabIsConvertKeyByDefault() throws {
        XCTAssertEqual(route(tab, .tab, method: .replace), .convert)
        XCTAssertEqual(route(optSpace, .tab, method: .replace), .passThrough)
    }

    func testUnsupportedFieldUsesMarked() throws {
        // 置き換えに対応していない欄: 文字は未確定文字に、未確定文字がないときの変換キーは通す
        XCTAssertEqual(route(letter, .tab, method: .marked), .marked)
        XCTAssertEqual(route(tab, .tab, method: .marked), .passThrough)
        // 対応している欄: 文字はそのまま通す（確定）
        XCTAssertEqual(route(letter, .tab, method: .replace), .passThrough)
    }

    func testWhileComposingEverythingGoesToMarked() throws {
        let ck = try ck("ctrl+j")
        for k in [tab, optSpace, letter, KeyStroke(keyCode: 38, modifiers: .control, characters: "\n")] {
            XCTAssertEqual(route(k, ck, empty: false, method: .replace), .marked)
        }
    }

    func testMarkedFieldWithCustomConvertKey() throws {
        // 直接モードの未確定文字でも変換キーは directConvertKey。Tab は確定して通す
        let ck = try ck("ctrl+j")
        let ctrlJ = KeyStroke(keyCode: 38, modifiers: .control, characters: "\n")
        var c = MarkedComposer()
        let noop: MarkedComposer.Convert = { r in ("<\(r)>", "") }
        _ = c.handle(ComposerKey.classify(letter, convertKey: ck), convert: noop, candidates: { _, _, _ in nil })
        XCTAssertEqual(c.handle(ComposerKey.classify(ctrlJ, convertKey: ck), convert: noop, candidates: { _, _, _ in nil }),
                       ComposerOutput(marked: "<a>"))
        XCTAssertEqual(c.handle(ComposerKey.classify(tab, convertKey: ck), convert: noop, candidates: { _, _, _ in nil }),
                       ComposerOutput(commit: "<a>", passKey: true))
        // 未確定文字がないときの Tab は通る
        XCTAssertEqual(c.handle(ComposerKey.classify(tab, convertKey: ck), convert: noop, candidates: { _, _, _ in nil }), .pass)
    }
}
