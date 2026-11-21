import XCTest
import AIMECore
@testable import AIMELlama

/// 実推論の確認。ime/models/zenz-v3.1-small-Q5_K_M.gguf（scripts/fetch-deps.sh --with-test-model）
/// または環境変数 AIME_TEST_MODEL のモデルがないときはスキップする。
/// zenz-v3.1 は本番モデルと同じアーキテクチャ・トークナイザーで、入力はカタカナ。
final class LlamaGeneratorTests: XCTestCase {
    static var shared: LlamaGenerator?

    // プロセス終了前に解放しておく（解放しないと終了時に ggml-metal の後始末で assert が落ちる）
    override class func tearDown() {
        shared = nil
        super.tearDown()
    }

    func generator() throws -> LlamaGenerator {
        if let g = Self.shared { return g }
        let path = ProcessInfo.processInfo.environment["AIME_TEST_MODEL"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("models/zenz-v3.1-small-Q5_K_M.gguf").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("テスト用モデルがありません: \(path)")
        }
        let g = try LlamaGenerator(modelPath: path)
        Self.shared = g
        return g
    }

    func testStopTokenIsLookedUpFromVocab() throws {
        let g = try generator()
        // zenz の語彙では </s> は id=3（config.json の eos_token_id=2 ではない）
        XCTAssertEqual(g.stopToken, 3)
    }

    func testSpecialMarkersAreSplitIntoThreeByteTokens() throws {
        let g = try generator()
        for m in [PromptBuilder.inputMarker, PromptBuilder.outputMarker, PromptBuilder.contextMarker] {
            let toks = try g.tokenize(m)
            XCTAssertEqual(toks.count, 3, "\(m.unicodeScalars.map { String($0.value, radix: 16) }) のトークン数")
            XCTAssertEqual(toks.flatMap { g.pieceBytes($0) }, Array(m.utf8))
        }
    }

    func testKatakanaToKanjiConversion() throws {
        let g = try generator()
        let conv = Converter(generator: g)
        let out = try conv.convert(input: "ライシュウノカイギデシリョウヲキョウユウシテクダサイ",
                                   leftContext: nil, options: .init())
        print("変換結果: \(out) / \(g.lastStats)")
        XCTAssertEqual(out, "来週の会議で資料を共有してください")
        XCTAssertTrue(g.lastStats.hitStopToken)
    }

    func testRawPromptMatchesSpecExample() throws {
        let g = try generator()
        let out = try g.generate(
            prompt: "\u{EE00}ライシュウノカイギデシリョウヲキョウユウシテクダサイ\u{EE01}",
            maxNewTokens: 100)
        XCTAssertEqual(out.text, "来週の会議で資料を共有してください")
        XCTAssertTrue(out.hitStopToken)
    }

    func testWithLeftContext() throws {
        let g = try generator()
        let conv = Converter(generator: g)
        let out = try conv.convert(input: "シリョウヲキョウユウシテクダサイ", leftContext: "来週の会議で", options: .init())
        print("左文脈つき変換結果: \(out)")
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(g.lastStats.hitStopToken)
    }

    func testMaxNewTokensIsRespected() throws {
        let g = try generator()
        let r = try g.generate(prompt: PromptBuilder.build(input: "ライシュウノカイギデ", leftContext: nil), maxNewTokens: 2)
        XCTAssertLessThanOrEqual(g.lastStats.generatedTokens, 2)
        XCTAssertFalse(r.hitStopToken) // 途中で切れたことがわかる
    }

    func testPromptLongerThanContextThrows() throws {
        let g = try generator()
        let input = String(repeating: "ア", count: g.contextSize + 10)
        XCTAssertThrowsError(try g.generate(prompt: PromptBuilder.build(input: input, leftContext: nil), maxNewTokens: 10))
    }

    // MARK: - ビームサーチ

    private let example = "ライシュウノカイギデシリョウヲキョウユウシテクダサイ"

    func testBeamTopMatchesGreedyAndHasNoDuplicates() throws {
        let g = try generator()
        let prompt = PromptBuilder.build(input: example, leftContext: nil)
        let greedy = try g.generate(prompt: prompt, maxNewTokens: Converter.maxNewTokens(forInput: example))
        let beam = try g.beamSearch(prompt: prompt, maxNewTokens: Converter.maxNewTokens(forInput: example),
                                    beamWidth: 8, topN: 5)
        let terminated = beam.filter(\.hitStopToken)
        print("ビームサーチ上位: \(terminated.prefix(5).map(\.text))")
        XCTAssertGreaterThanOrEqual(terminated.count, 2)
        // 1位が貪欲法の結果と一致する
        XCTAssertEqual(terminated.first?.text, greedy.text)
        // 上位候補が重複しない
        XCTAssertEqual(Set(terminated.map(\.text)).count, terminated.count)
        // 対数尤度の高い順
        XCTAssertEqual(beam.map(\.logProb), beam.map(\.logProb).sorted(by: >))
    }

    func testConverterCandidatesAreUniqueAndTerminated() throws {
        let g = try generator()
        let conv = Converter(generator: g)
        let first = try conv.convert(input: example, leftContext: nil, options: .init())
        let list = try conv.candidates(input: example, leftContext: nil, first: first, count: 5, options: .init())
        print("候補: \(list)")
        XCTAssertEqual(list.first, first)
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(Set(list).count, list.count)
        // 2位以降はすべて </s> で止まった候補から来ている
        let prompt = PromptBuilder.build(input: example, leftContext: nil)
        let terminated = Set(try g.beamSearch(prompt: prompt, maxNewTokens: Converter.maxNewTokens(forInput: example),
                                              beamWidth: 8, topN: 5).filter(\.hitStopToken).map(\.text))
        for c in list.dropFirst() { XCTAssertTrue(terminated.contains(c), c) }
    }

    func testUnterminatedBeamCandidatesAreExcluded() throws {
        let g = try generator()
        let conv = Converter(generator: g)
        // 生成上限が短く、どの候補も </s> まで届かない
        let prompt = PromptBuilder.build(input: example, leftContext: nil)
        let beam = try g.beamSearch(prompt: prompt, maxNewTokens: 5, beamWidth: 8, topN: 5)
        XCTAssertFalse(beam.isEmpty)
        XCTAssertTrue(beam.allSatisfy { !$0.hitStopToken })
        XCTAssertEqual(CandidateList.build(first: "1位", beam: beam, count: 5) { $0 }, ["1位"])
        _ = conv
    }

    func testBeamPromptLongerThanContextThrows() throws {
        let g = try generator()
        let input = String(repeating: "ア", count: g.contextSize + 10)
        XCTAssertThrowsError(try g.beamSearch(prompt: PromptBuilder.build(input: input, leftContext: nil),
                                              maxNewTokens: 10, beamWidth: 8, topN: 5))
    }

    func testGreedyStillWorksAfterBeamSearch() throws {
        let g = try generator()
        let prompt = PromptBuilder.build(input: example, leftContext: nil)
        _ = try g.beamSearch(prompt: prompt, maxNewTokens: 100, beamWidth: 8, topN: 5)
        XCTAssertEqual(try g.generate(prompt: prompt, maxNewTokens: 100).text,
                       "来週の会議で資料を共有してください")
    }

    func testOldSequencesAreRemovedAndRepeatedSearchesAreStable() throws {
        // 長めの入力で、同じジェネレーターでビームサーチを何度も繰り返す。
        // 毎ステップ古い組のシーケンスを消していれば、中身のあるシーケンスはビーム幅以下に保たれ、結果も毎回同じになる。
        let g = try generator()
        let input = "キノウノヨルホンバンカンキョウニシンシイバージョンヲデプロイシタトコロエーピーアイノレスポンスタイムガニバイイジョウニナッタタメイソイデロールバックシタ"
        let prompt = PromptBuilder.build(input: input, leftContext: nil)
        var results: [[ScoredGeneration]] = []
        for _ in 0..<3 {
            results.append(try g.beamSearch(prompt: prompt, maxNewTokens: Converter.maxNewTokens(forInput: input),
                                            beamWidth: 8, topN: 5))
            XCTAssertGreaterThan(g.lastBeamStats.steps, 30)
            XCTAssertLessThanOrEqual(g.lastBeamStats.maxLiveSequences, 8)
        }
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[1], results[2])
        print("長めの入力のビームサーチ 1位: \(results[0].first?.text ?? "")")
    }

    func testFinishedCandidatesAreCountedOnce() throws {
        let g = try generator()
        let prompt = PromptBuilder.build(input: example, leftContext: nil)
        let beam = try g.beamSearch(prompt: prompt, maxNewTokens: 100, beamWidth: 8, topN: 5)
        let terminated = beam.filter(\.hitStopToken)
        // 打ち切りは重複を除いた文字列の数（topN × 2 = 10）で数える
        XCTAssertEqual(g.lastBeamStats.finishedCandidates, terminated.count)
        XCTAssertLessThanOrEqual(terminated.count, 10 + 8)
    }

    func testPrepareBeamContextInAdvance() throws {
        // 別のジェネレーター（ビーム用コンテキストなし）で、先に作っておけることを確かめる
        let path = try generator().modelPath
        let g = try LlamaGenerator(modelPath: path)
        XCTAssertFalse(g.hasBeamContext(beamWidth: 8))
        // 裏のスレッドで作る間も、貪欲デコードは動く
        let done = expectation(description: "prepare")
        DispatchQueue.global().async { g.prepareBeamContext(beamWidth: 8); done.fulfill() }
        let prompt = PromptBuilder.build(input: example, leftContext: nil)
        XCTAssertEqual(try g.generate(prompt: prompt, maxNewTokens: 100).text, "来週の会議で資料を共有してください")
        wait(for: [done], timeout: 30)
        XCTAssertTrue(g.hasBeamContext(beamWidth: 8))
        XCTAssertFalse(g.hasBeamContext(beamWidth: 9)) // それより大きいビーム幅では作り直しが要る
        let beam = try g.beamSearch(prompt: prompt, maxNewTokens: 100, beamWidth: 8, topN: 5)
        XCTAssertEqual(beam.first?.text, "来週の会議で資料を共有してください")
        g.prepareBeamContext(beamWidth: 8) // すでにあれば何もしない
        XCTAssertTrue(g.hasBeamContext(beamWidth: 8))
    }
}
