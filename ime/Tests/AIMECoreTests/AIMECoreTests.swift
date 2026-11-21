import XCTest
@testable import AIMECore

final class RomajiAndLeftContextTests: XCTestCase {
    func testRomajiScalars() throws {
        for c in "az09-.{}!?~" { XCTAssertTrue(RomajiExtractor.isRomajiScalar(try XCTUnwrap(c.unicodeScalars.first)), String(c)) }
        for c in [" ", "\t", "\n", "あ", "ａ", "\u{7F}"] {
            XCTAssertFalse(RomajiExtractor.isRomajiScalar(try XCTUnwrap(c.unicodeScalars.first)), c)
        }
    }

    func testLeftContextSuffixCountsUnicodeScalars() throws {
        let ctx = String(repeating: "あ", count: 30) + String(repeating: "い", count: 30)
        XCTAssertEqual(RomajiExtractor.leftContextSuffix(ctx), String(repeating: "あ", count: 10) + String(repeating: "い", count: 30))
        // 👍🏽 は1書記素だが2スカラー。"が"（か + 濁点の結合文字）も2スカラー。学習時と同じくスカラーで数える
        let s = "👍🏽" + "か\u{3099}" + String(repeating: "ん", count: 38)
        XCTAssertEqual(RomajiExtractor.leftContextSuffix(s), "か\u{3099}" + String(repeating: "ん", count: 38))
    }

    /// 確定済みテキスト + 未確定文字の文書を模したもの
    private struct Doc {
        var committed: NSString
        var marked: String
        var canFetch = true
        var markedRange: NSRange { NSRange(location: committed.length, length: (marked as NSString).length) }
        var selectedRange: NSRange { NSRange(location: NSMaxRange(markedRange), length: 0) }
        func fetch(_ r: NSRange) -> String? {
            let all = committed.appending(marked) as NSString
            guard canFetch, r.location >= 0, NSMaxRange(r) <= all.length else { return nil }
            return all.substring(with: r)
        }
    }

    func testLeftContextFromCommittedTextBeforeMarked() throws {
        let d = Doc(committed: "😀来週の会議で", marked: "shiryou")
        XCTAssertEqual(LeftContext.get(markedRange: d.markedRange, selectedRange: d.selectedRange, fetch: d.fetch),
                       "😀来週の会議で")
        // 40 スカラーまで
        let long = Doc(committed: (String(repeating: "あ", count: 50) + "い") as NSString, marked: "ka")
        XCTAssertEqual(LeftContext.get(markedRange: long.markedRange, selectedRange: long.selectedRange, fetch: long.fetch),
                       String(repeating: "あ", count: 39) + "い")
    }

    func testLeftContextIsEmptyWhenUnavailable() throws {
        // 取れないアプリ（ターミナルなど）: 空にする（エラーにしない）
        var d = Doc(committed: "本番では", marked: "ka")
        d.canFetch = false
        XCTAssertEqual(LeftContext.get(markedRange: d.markedRange, selectedRange: d.selectedRange, fetch: d.fetch), "")
        // 先頭
        let top = Doc(committed: "", marked: "ka")
        XCTAssertEqual(LeftContext.get(markedRange: top.markedRange, selectedRange: top.selectedRange, fetch: top.fetch), "")
        // 位置がわからない
        let nf = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(LeftContext.get(markedRange: nf, selectedRange: nf, fetch: { _ in "x" }), "")
    }

    func testLeftContextFallsBackToSelectedRange() throws {
        // markedRange を返さないアプリでは selectedRange の位置から取る
        let nf = NSRange(location: NSNotFound, length: 0)
        let text = "今日は" as NSString
        XCTAssertEqual(LeftContext.get(markedRange: nf, selectedRange: NSRange(location: 3, length: 0)) { r in
            text.substring(with: r)
        }, "今日は")
    }
}

final class CandidateCycleTests: XCTestCase {
    func testCyclesThroughCandidatesThenRomajiThenFirst() throws {
        var c = CandidateCycle(romaji: "kyouha", leftContext: "", first: "今日は")
        XCTAssertEqual(c.currentText, "今日は")
        c.setCandidates(["今日は", "京は", "強は"])
        XCTAssertEqual((0..<5).map { _ in c.advance() }, ["京は", "強は", "kyouha", "今日は", "京は"])
    }

    func testFirstIsKeptAtTheHead() throws {
        var c = CandidateCycle(romaji: "kyouha", leftContext: "", first: "今日は")
        c.setCandidates(["京は", "今日は", "強は"])
        XCTAssertEqual(c.candidates, ["今日は", "京は", "強は"])
        XCTAssertTrue(c.hasComputedCandidates)
    }

    func testSingleCandidateGoesBackToRomaji() throws {
        var c = CandidateCycle(romaji: "kyouha", leftContext: "", first: "今日は")
        c.setCandidates(["今日は"])
        XCTAssertEqual(c.advance(), "kyouha")
        XCTAssertEqual(c.advance(), "今日は")
    }

    func testCandidateEqualToRomajiIsMerged() throws {
        var c = CandidateCycle(romaji: "API", leftContext: "", first: "エーピーアイ")
        c.setCandidates(["エーピーアイ", "API", "api"])
        XCTAssertEqual(c.options, ["エーピーアイ", "API", "api"])
        XCTAssertEqual((0..<4).map { _ in c.advance() }, ["API", "api", "エーピーアイ", "API"])
        var d = CandidateCycle(romaji: "API", leftContext: "", first: "API")
        d.setCandidates(["API"])
        XCTAssertEqual(d.options, ["API"])
    }
}

final class PromptBuilderTests: XCTestCase {
    func testWithoutContext() throws {
        XCTAssertEqual(PromptBuilder.build(input: "kyou", leftContext: nil), "\u{EE00}kyou\u{EE01}")
        XCTAssertEqual(PromptBuilder.build(input: "kyou", leftContext: ""), "\u{EE00}kyou\u{EE01}")
    }

    func testWithContext() throws {
        XCTAssertEqual(PromptBuilder.build(input: "tenki", leftContext: "今日は"),
                       "\u{EE02}今日は\u{EE00}tenki\u{EE01}")
    }

    func testContextIsTruncatedToLast40Scalars() throws {
        let ctx = String(repeating: "x", count: 10) + String(repeating: "y", count: 40)
        XCTAssertEqual(PromptBuilder.build(input: "a", leftContext: ctx),
                       "\u{EE02}" + String(repeating: "y", count: 40) + "\u{EE00}a\u{EE01}")
        let emoji = "😀" + String(repeating: "y", count: 39)
        XCTAssertEqual(PromptBuilder.build(input: "a", leftContext: "z" + emoji),
                       "\u{EE02}" + emoji + "\u{EE00}a\u{EE01}")
    }

    func testMarkerUTF8IsThreeBytes() throws {
        for m in [PromptBuilder.inputMarker, PromptBuilder.outputMarker, PromptBuilder.contextMarker] {
            XCTAssertEqual(m.utf8.count, 3)
        }
    }
}

final class StopTokenTests: XCTestCase {
    func testFindsStopTokenAtId3() throws {
        XCTAssertEqual(StopToken.find(in: ["[UNK]", "[PAD]", "<s>", "</s>", "!"]), 3)
    }

    func testFindsStopTokenAtOtherPositions() throws {
        XCTAssertEqual(StopToken.find(in: ["</s>", "<s>", "a"]), 0)
        XCTAssertEqual(StopToken.find(in: ["<s>", "a", "Ġ", "b", "c", "</s>"]), 5)
        // 似た文字列とは一致しない
        XCTAssertEqual(StopToken.find(in: ["</s", "</s> ", "<s>", "</S>", "</s>"]), 4)
    }

    func testMissingStopToken() throws {
        XCTAssertNil(StopToken.find(in: ["[UNK]", "<s>", "a"]))
        XCTAssertNil(StopToken.find(in: [String]()))
    }
}

final class PostProcessorTests: XCTestCase {
    func testDigitsHalfWidthByDefault() throws {
        XCTAssertEqual(PostProcessor.apply("２０２６年に1０回", options: .init()),
                       "2026年に10回")
    }

    func testDigitsFullWidth() throws {
        XCTAssertEqual(PostProcessor.apply("2026年v1.5", options: .init(fullWidthDigits: true)),
                       "２０２６年v１.５")
    }

    func testDigitsDoNotTouchOtherCharacters() throws {
        XCTAssertEqual(PostProcessor.convertDigits("ＡＰＩ①一", fullWidth: false), "ＡＰＩ①一")
    }
}

final class ConverterTests: XCTestCase {
    func testConverterBuildsPromptAndPostProcesses() throws {
        let mock = MockGenerator(fixed: "２台のサーバー")
        let conv = Converter(generator: mock)
        let out = try conv.convert(input: "2dainosa-ba-", leftContext: "本番では", options: .init())
        XCTAssertEqual(out, "2台のサーバー")
        XCTAssertEqual(mock.prompts, ["\u{EE02}本番では\u{EE00}2dainosa-ba-\u{EE01}"])
        XCTAssertEqual(mock.maxNewTokensHistory, [Converter.maxNewTokens(forInput: "2dainosa-ba-")])
    }

    func testEndToEndWithComposer() throws {
        let romaji = "raishuunokaigideshiryouwokyouyuushitekudasai"
        let mock = MockGenerator { prompt in
            GenerationResult(
                text: prompt == "\u{EE00}\(romaji)\u{EE01}" ? "来週の会議で資料を共有してください" : "?",
                hitStopToken: true)
        }
        let conv = Converter(generator: mock)
        var c = MarkedComposer()
        for ch in romaji { _ = c.handle(.char(String(ch)), convert: { _ in nil }, candidates: { _, _, _ in nil }) }
        let out = c.handle(.convert, convert: { r in
            (try? conv.convert(input: r, leftContext: "", options: .init())).map { ($0, "") }
        }, candidates: { _, _, _ in nil })
        XCTAssertEqual(out, ComposerOutput(marked: "来週の会議で資料を共有してください"))
        XCTAssertFalse(mock.prompts[0].contains("\u{EE02}")) // 左文脈が空ならマーカーも付けない
    }

    func testTruncatedOutputIsRejected() throws {
        let conv = Converter(generator: MockGenerator(fixed: "来週の会議", hitStopToken: false))
        XCTAssertThrowsError(try conv.convert(input: "raishuunokaigi", leftContext: nil, options: .init())) {
            XCTAssertEqual($0 as? ConversionError, .notTerminated)
        }
    }

    func testReplacementCharacterIsRejected() throws {
        let conv = Converter(generator: MockGenerator(fixed: "本番\u{FFFD}"))
        XCTAssertThrowsError(try conv.convert(input: "honban", leftContext: nil, options: .init())) {
            XCTAssertEqual($0 as? ConversionError, .invalidCharacters)
        }
    }

    func testEmptyOutputIsRejected() throws {
        let conv = Converter(generator: MockGenerator(fixed: ""))
        XCTAssertThrowsError(try conv.convert(input: "honban", leftContext: nil, options: .init())) {
            XCTAssertEqual($0 as? ConversionError, .empty)
        }
    }

    func testInputLongerThanLimitIsNotConverted() throws {
        let mock = MockGenerator(fixed: "x")
        mock.respondBeam = { _ in XCTFail("ビームサーチを走らせてはいけない"); return [] }
        let conv = Converter(generator: mock)
        let long = String(repeating: "a", count: Converter.maxInputLength + 1)
        XCTAssertThrowsError(try conv.convert(input: long, leftContext: nil, options: .init())) {
            XCTAssertEqual($0 as? ConversionError, .inputTooLong)
        }
        XCTAssertThrowsError(try conv.candidates(input: long, leftContext: nil, first: "x", count: 5, options: .init())) {
            XCTAssertEqual($0 as? ConversionError, .inputTooLong)
        }
        XCTAssertTrue(mock.prompts.isEmpty) // 生成もしない
        // ちょうど上限なら変換する
        XCTAssertEqual(try conv.convert(input: String(repeating: "a", count: Converter.maxInputLength), leftContext: nil, options: .init()), "x")
    }

    func testTooLongInputKeepsMarkedTextAndConsumesTab() throws {
        // 未確定文字モード: 上限を超えたら変換せず、未確定文字のまま Tab を消費する
        let conv = Converter(generator: MockGenerator(fixed: "x"))
        var c = MarkedComposer()
        let long = String(repeating: "a", count: Converter.maxInputLength + 1)
        _ = c.handle(.char(long), convert: { _ in nil }, candidates: { _, _, _ in nil })
        let out = c.handle(.convert, convert: { r in
            (try? conv.convert(input: r, leftContext: "", options: .init())).map { ($0, "") }
        }, candidates: { _, _, _ in nil })
        XCTAssertEqual(out, .consume)
        XCTAssertEqual(c.displayText, long)
    }

    func testMaxNewTokensIsProportional() throws {
        XCTAssertEqual(Converter.maxNewTokens(forInput: ""), 16)
        XCTAssertEqual(Converter.maxNewTokens(forInput: String(repeating: "a", count: 200)), 416)
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultsAndOverrides() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var s = Settings.load(from: d)
        XCTAssertEqual(s.modelPath, Settings.defaultModelPath)
        XCTAssertFalse(s.postProcess.fullWidthDigits)

        d.set("/tmp/m.gguf", forKey: Settings.Key.modelPath)
        d.set(true, forKey: Settings.Key.fullWidthDigits)
        s = Settings.load(from: d)
        XCTAssertEqual(s.expandedModelPath, "/tmp/m.gguf")
        XCTAssertTrue(s.postProcess.fullWidthDigits)
    }

    func testConvertKey() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        // 既定: 変換キーは Space
        XCTAssertEqual(Settings.load(from: d).convertKey, .space)
        d.set("option+space", forKey: Settings.Key.convertKey)
        XCTAssertEqual(Settings.load(from: d).convertKey, ConvertKey.parse("option+space"))
        d.set("tab", forKey: Settings.Key.convertKey)
        XCTAssertEqual(Settings.load(from: d).convertKey, .tab)
        d.set("a", forKey: Settings.Key.convertKey) // 打鍵と区別できない → space
        XCTAssertEqual(Settings.load(from: d).convertKey, .space)
        d.set("nonsense", forKey: Settings.Key.convertKey)
        XCTAssertEqual(Settings.load(from: d).convertKey, .space)
    }

    func testOldInputModeAndDirectConvertKeyAreIgnored() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        // 廃止した設定（直接モード）が残っていても、エラー・警告にせず無視する
        d.set("direct", forKey: "inputMode")
        d.set("bogus", forKey: "inputMode")
        d.set(1, forKey: "inputMode")
        d.set("ctrl+j", forKey: "directConvertKey")
        let s = Settings.load(from: d)
        XCTAssertEqual(s.convertKey, .space)
        XCTAssertEqual(s.invalidValues, [])
    }

    func testInvalidValuesAreReported() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Settings.load(from: d).invalidValues, [])
        d.set("ctrl+j", forKey: Settings.Key.convertKey)
        d.set(true, forKey: Settings.Key.fullWidthDigits)
        d.set(3, forKey: Settings.Key.candidateCount)
        XCTAssertEqual(Settings.load(from: d).invalidValues, [])
        // 打ち間違い
        d.set("ctl+j", forKey: Settings.Key.convertKey)
        let s = Settings.load(from: d)
        XCTAssertEqual(s.convertKey, .space)
        XCTAssertEqual(s.invalidValues.count, 1)
        XCTAssertTrue(s.invalidValues[0].contains("ctl+j"))
    }

    func testMoreWrongTypes() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: Settings.Key.candidateCount)   // 真偽値
        d.set(42, forKey: Settings.Key.modelPath)          // 数値
        d.set(1, forKey: Settings.Key.fullWidthDigits)     // 整数（-bool でない）
        var s = Settings.load(from: d)
        XCTAssertEqual(s.candidateCount, Settings.defaultCandidateCount)
        XCTAssertEqual(s.modelPath, Settings.defaultModelPath)
        XCTAssertFalse(s.postProcess.fullWidthDigits)
        XCTAssertEqual(s.invalidValues.count, 3)
        d.set(3.5, forKey: Settings.Key.candidateCount)    // 小数
        s = Settings.load(from: d)
        XCTAssertEqual(s.candidateCount, Settings.defaultCandidateCount)
        XCTAssertTrue(s.invalidValues.contains { $0.contains("candidateCount") })
        // 正しい型（設定ウィンドウからの書き込み。整数 1 が残っていても真偽値に置き換わる）
        SettingsEditor.setCandidateCount(7, in: d)
        SettingsEditor.setModelPath("/tmp/m.gguf", in: d)
        SettingsEditor.setFullWidthDigits(true, in: d)
        s = Settings.load(from: d)
        XCTAssertEqual(s.candidateCount, 7)
        XCTAssertEqual(s.modelPath, "/tmp/m.gguf")
        XCTAssertTrue(s.postProcess.fullWidthDigits)
        XCTAssertEqual(s.invalidValues, [])
    }

    func testWrongTypesAreDefaultsWithWarnings() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        // defaults write で -bool / -int を付け忘れると文字列になる
        d.set("yes", forKey: Settings.Key.fullWidthDigits)
        d.set("7", forKey: Settings.Key.candidateCount)
        d.set(5, forKey: Settings.Key.convertKey) // 文字列でない
        let s = Settings.load(from: d)
        XCTAssertFalse(s.postProcess.fullWidthDigits)
        XCTAssertEqual(s.candidateCount, Settings.defaultCandidateCount)
        XCTAssertEqual(s.convertKey, .space)
        XCTAssertEqual(s.invalidValues.count, 3)
        for key in ["fullWidthDigits", "candidateCount", "convertKey"] {
            XCTAssertTrue(s.invalidValues.contains { $0.contains(key) }, key)
        }
    }

    func testCandidateCount() throws {
        let suite = "aime-test-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Settings.load(from: d).candidateCount, 5)
        d.set(3, forKey: Settings.Key.candidateCount)
        XCTAssertEqual(Settings.load(from: d).candidateCount, 3)
        // 1〜32 に丸める
        for (given, expected) in [(0, 1), (1, 1), (32, 32), (129, 32), (-5, 1)] {
            d.set(given, forKey: Settings.Key.candidateCount)
            XCTAssertEqual(Settings.load(from: d).candidateCount, expected, "\(given)")
        }
        // ビーム幅はシーケンスの上限（2 × ビーム幅 ≤ 256）に収まる
        XCTAssertLessThanOrEqual(2 * Converter.beamWidth(forCount: Settings.candidateCountRange.upperBound), 256)
    }
}

final class CandidateListTests: XCTestCase {
    private func g(_ t: String, _ lp: Double, stop: Bool = true) -> ScoredGeneration {
        ScoredGeneration(text: t, hitStopToken: stop, logProb: lp)
    }

    func testFirstIsGreedyAndRestAreByLikelihood() throws {
        let beam = [g("C", -3), g("A", -0.1), g("B", -1), g("D", -4)]
        XCTAssertEqual(CandidateList.build(first: "A", beam: beam, count: 5) { $0 }, ["A", "B", "C", "D"])
        // 1回目の結果がビームの1位と違っても先頭に置く
        XCTAssertEqual(CandidateList.build(first: "Z", beam: beam, count: 3) { $0 }, ["Z", "A", "B"])
    }

    func testExcludesUnterminatedReplacementCharAndEmpty() throws {
        let beam = [g("A", -0.1), g("切れ", -0.5, stop: false), g("壊\u{FFFD}", -0.6), g("", -0.7), g("B", -1)]
        XCTAssertEqual(CandidateList.build(first: "A", beam: beam, count: 5) { $0 }, ["A", "B"])
    }

    func testDeduplicatesAfterPostProcessing() throws {
        // 後処理（半角数字）で同じ文字列になるものはまとめる
        let beam = [g("1台", -0.1), g("１台", -0.2), g("一台", -0.3)]
        let out = CandidateList.build(first: "1台", beam: beam, count: 5) {
            PostProcessor.apply($0, options: .init())
        }
        XCTAssertEqual(out, ["1台", "一台"])
    }

    func testCountLimit() throws {
        let beam = (0..<10).map { g("c\($0)", -Double($0)) }
        XCTAssertEqual(CandidateList.build(first: "c0", beam: beam, count: 3) { $0 }, ["c0", "c1", "c2"])
        XCTAssertEqual(CandidateList.build(first: "c0", beam: beam, count: 1) { $0 }, ["c0"])
        XCTAssertEqual(CandidateList.build(first: "x", beam: [], count: 5) { $0 }, ["x"])
    }

    func testConverterCandidatesUsesSamePromptAndPostProcess() throws {
        let mock = MockGenerator(fixed: "２台")
        mock.respondBeam = { _ in [self.g("２台", -0.1), self.g("2代", -1), self.g("二台", -2)] }
        let conv = Converter(generator: mock)
        let first = try conv.convert(input: "2dai", leftContext: "本番は", options: .init())
        let list = try conv.candidates(input: "2dai", leftContext: "本番は", first: first, count: 5, options: .init())
        XCTAssertEqual(list, ["2台", "2代", "二台"])
        XCTAssertEqual(mock.beamPrompts, mock.prompts) // 1回目と同じプロンプト（左文脈を含む）
        XCTAssertEqual(mock.beamPrompts, ["\u{EE02}本番は\u{EE00}2dai\u{EE01}"])
    }

    func testCountOneDoesNotRunBeamSearch() throws {
        let mock = MockGenerator(fixed: "今日")
        mock.respondBeam = { _ in XCTFail("ビームサーチを走らせてはいけない"); return [] }
        let conv = Converter(generator: mock)
        XCTAssertEqual(try conv.candidates(input: "kyou", leftContext: nil, first: "今日", count: 1, options: .init()), ["今日"])
        XCTAssertTrue(mock.beamPrompts.isEmpty)
    }

    func testBeamWidth() throws {
        XCTAssertEqual(Converter.beamWidth(forCount: 5), 8)
        XCTAssertEqual(Converter.beamWidth(forCount: 12), 12)
    }
}

final class ComposerKeyTests: XCTestCase {
    private func k(_ code: UInt16 = 0, _ mods: KeyModifiers = [], _ chars: String?) -> ComposerKey {
        ComposerKey.classify(KeyStroke(keyCode: code, modifiers: mods, characters: chars))
    }

    func testClassify() throws {
        XCTAssertEqual(k(0, [], "a"), .char("a"))
        XCTAssertEqual(k(0, .shift, "A"), .char("A"))
        XCTAssertEqual(k(0, [], "-"), .char("-"))
        XCTAssertEqual(k(0, [], "1"), .char("1"))
        XCTAssertEqual(k(49, [], " "), .space)
        XCTAssertEqual(k(KeyStroke.Code.deleteBackward, [], "\u{7F}"), .backspace)
        XCTAssertEqual(k(KeyStroke.Code.deleteBackward, .option, "\u{7F}"), .other)
        XCTAssertEqual(k(KeyStroke.Code.tab, [], "\t"), .convert)
        XCTAssertEqual(k(KeyStroke.Code.tab, .shift, "\u{19}"), .other)
        XCTAssertEqual(k(KeyStroke.Code.returnKey, [], "\r"), .enter)
        XCTAssertEqual(k(KeyStroke.Code.keypadEnter, [], "\u{3}"), .enter)
        XCTAssertEqual(k(KeyStroke.Code.escape, [], "\u{1B}"), .escape)
        XCTAssertEqual(k(123, [], "\u{F702}"), .other) // ←
        XCTAssertEqual(k(0, .command, "c"), .other)
        XCTAssertEqual(k(0, .control, "a"), .other)
        XCTAssertEqual(k(0, .option, "å"), .other)
        XCTAssertEqual(k(0, [], nil), .other)
    }
}

final class MarkedComposerTests: XCTestCase {
    /// 変換・候補のフェイク
    private var converted: [String] = []
    private var candidateCalls = 0
    private func convert(_ r: String) -> (text: String, leftContext: String)? {
        converted.append(r)
        return r == "fail" ? nil : ("<\(r)>", "文脈")
    }
    private func candidates(_ r: String, _ ctx: String, _ first: String) -> [String]? {
        candidateCalls += 1
        XCTAssertEqual(ctx, "文脈") // 1回目と同じ左文脈
        return [first, "2位", "3位"]
    }
    private func press(_ c: inout MarkedComposer, _ key: ComposerKey) -> ComposerOutput {
        c.handle(key, convert: convert, candidates: candidates)
    }
    private func typed(_ s: String) -> MarkedComposer {
        var c = MarkedComposer()
        for ch in s { _ = press(&c, .char(String(ch))) }
        return c
    }

    func testTypingAndBackspace() throws {
        var c = MarkedComposer()
        XCTAssertEqual(press(&c, .char("k")), ComposerOutput(marked: "k"))
        XCTAssertEqual(press(&c, .char("y")), ComposerOutput(marked: "ky"))
        XCTAssertEqual(press(&c, .backspace), ComposerOutput(marked: "k"))
        XCTAssertEqual(press(&c, .backspace), ComposerOutput(marked: ""))
        XCTAssertTrue(c.isEmpty)
        // 未確定文字がないときの Backspace・Tab・Enter などはアプリに通す
        for key: ComposerKey in [.backspace, .convert, .enter, .space, .escape, .other] {
            XCTAssertEqual(press(&c, key), .pass)
        }
    }

    func testTabConvertsAndCyclesThroughCandidates() throws {
        var c = typed("kyou")
        XCTAssertEqual(press(&c, .convert), ComposerOutput(marked: "<kyou>"))
        XCTAssertEqual(converted, ["kyou"])
        XCTAssertEqual(candidateCalls, 0)
        XCTAssertEqual(press(&c, .convert), ComposerOutput(marked: "2位"))
        XCTAssertEqual(press(&c, .convert), ComposerOutput(marked: "3位"))
        XCTAssertEqual(press(&c, .convert), ComposerOutput(marked: "kyou")) // 元のローマ字
        XCTAssertEqual(press(&c, .convert), ComposerOutput(marked: "<kyou>")) // 1位に戻る
        XCTAssertEqual(candidateCalls, 1) // 候補は2回目の Tab で1回だけ求める
    }

    func testConversionFailureKeepsRomajiAndConsumesTab() throws {
        var c = typed("fail")
        XCTAssertEqual(press(&c, .convert), .consume)
        XCTAssertEqual(c.displayText, "fail")
        XCTAssertNil(c.cycle)
        // 失敗したあとも打ち続けられる
        XCTAssertEqual(press(&c, .char("x")), ComposerOutput(marked: "failx"))
    }

    func testEnterCommitsWithoutPassing() throws {
        var c = typed("kyou")
        XCTAssertEqual(press(&c, .enter), ComposerOutput(commit: "kyou", passKey: false))
        XCTAssertTrue(c.isEmpty)
        var d = typed("kyou")
        _ = press(&d, .convert)
        XCTAssertEqual(press(&d, .enter), ComposerOutput(commit: "<kyou>", passKey: false))
        XCTAssertTrue(d.isEmpty)
    }

    func testSpaceOnRomajiCommitsAndPasses() throws {
        var c = typed("ls")
        XCTAssertEqual(press(&c, .space), ComposerOutput(commit: "ls", passKey: true))
        XCTAssertTrue(c.isEmpty)
    }

    func testSpaceAfterConversionCommitsAndPasses() throws {
        var c = typed("kyou")
        _ = press(&c, .convert)
        XCTAssertEqual(press(&c, .space), ComposerOutput(commit: "<kyou>", passKey: true))
    }

    func testEscape() throws {
        // 変換結果を表示中 → 元のローマ字（未確定）に戻す
        var c = typed("kyou")
        _ = press(&c, .convert)
        _ = press(&c, .convert) // 2位
        XCTAssertEqual(press(&c, .escape), ComposerOutput(marked: "kyou"))
        XCTAssertNil(c.cycle)
        XCTAssertEqual(c.romaji, "kyou")
        // 変換前のローマ字 → そのまま確定して Esc を通す
        XCTAssertEqual(press(&c, .escape), ComposerOutput(commit: "kyou", passKey: true))
        XCTAssertTrue(c.isEmpty)
    }

    func testOtherKeysCommitAndPass() throws {
        // 矢印など: 確定してからキーを通す
        var c = typed("kyou")
        XCTAssertEqual(press(&c, .other), ComposerOutput(commit: "kyou", passKey: true))
        var d = typed("kyou")
        _ = press(&d, .convert)
        XCTAssertEqual(press(&d, .other), ComposerOutput(commit: "<kyou>", passKey: true))
        // 変換結果の表示中の Backspace も、確定してから通す
        var e = typed("kyou")
        _ = press(&e, .convert)
        XCTAssertEqual(press(&e, .backspace), ComposerOutput(commit: "<kyou>", passKey: true))
    }

    func testCharAfterConversionCommitsAndStartsNew() throws {
        var c = typed("kyou")
        _ = press(&c, .convert)
        XCTAssertEqual(press(&c, .char("h")), ComposerOutput(commit: "<kyou>", marked: "h"))
        XCTAssertEqual(c.romaji, "h")
        XCTAssertNil(c.cycle)
    }

    func testCommitAll() throws {
        var c = MarkedComposer()
        XCTAssertNil(c.commitAll())
        c = typed("kyou")
        _ = press(&c, .convert)
        XCTAssertEqual(c.commitAll(), "<kyou>")
        XCTAssertTrue(c.isEmpty)
        XCTAssertNil(c.commitAll())
    }

    func testCandidateFailureKeepsDisplayAndConsumesTab() throws {
        var c = typed("kyou")
        _ = press(&c, .convert)
        let out = c.handle(.convert, convert: convert, candidates: { _, _, _ in nil })
        XCTAssertEqual(out, .consume)
        XCTAssertEqual(c.displayText, "<kyou>")
    }

    // MARK: - Tab の扱い（仕様: 未確定文字がないときの Tab は必ずアプリに通す）

    func testTabWithoutMarkedTextPasses() throws {
        var c = MarkedComposer()
        XCTAssertEqual(press(&c, .convert), .pass)
        XCTAssertTrue(converted.isEmpty) // 変換もしない
        // 実際のキーから分類しても同じ
        let tab = ComposerKey.classify(KeyStroke(keyCode: KeyStroke.Code.tab, characters: "\t"))
        XCTAssertEqual(c.handle(tab, convert: convert, candidates: candidates), .pass)
    }

    func testTabRightAfterCommitPasses() throws {
        // Enter で確定した直後
        var c = typed("kyou")
        _ = press(&c, .convert)
        _ = press(&c, .enter)
        XCTAssertEqual(press(&c, .convert), .pass)
        // 空白で確定した直後
        var d = typed("ls")
        _ = press(&d, .space)
        XCTAssertEqual(press(&d, .convert), .pass)
        // Esc で確定した直後
        var e = typed("ls")
        _ = press(&e, .escape)
        XCTAssertEqual(press(&e, .convert), .pass)
        // クリック・フォーカスが外れたなどで確定した直後
        var f = typed("kyou")
        _ = f.commitAll()
        XCTAssertEqual(press(&f, .convert), .pass)
        XCTAssertEqual(converted, ["kyou"])
    }

    func testTabWithMarkedTextIsTakenByIME() throws {
        var c = typed("kyou")
        let out1 = press(&c, .convert)
        XCTAssertFalse(out1.passKey)
        let out2 = press(&c, .convert)
        XCTAssertFalse(out2.passKey)
        // 変換に失敗しても Tab は IME が受け取る（未確定文字が残る）
        var d = typed("fail")
        XCTAssertFalse(press(&d, .convert).passKey)
        XCTAssertEqual(d.displayText, "fail")
    }

    func testModifiedTabCommitsThenPasses() throws {
        // Shift+Tab などは、未確定文字があれば確定してから通す
        let shiftTab = ComposerKey.classify(KeyStroke(keyCode: KeyStroke.Code.tab, modifiers: .shift, characters: "\u{19}"))
        XCTAssertEqual(shiftTab, .other)
        var c = typed("kyou")
        XCTAssertEqual(press(&c, shiftTab), ComposerOutput(commit: "kyou", passKey: true))
        var d = typed("kyou")
        _ = press(&d, .convert)
        XCTAssertEqual(press(&d, shiftTab), ComposerOutput(commit: "<kyou>", passKey: true))
        // 未確定文字がなければそのまま通す
        XCTAssertEqual(press(&d, shiftTab), .pass)
    }
}
