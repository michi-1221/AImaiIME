import CoreGraphics
import XCTest
@testable import AIMECore

final class ConversionPreviewTests: XCTestCase {
    func testDelayIsOneSecond() {
        XCTAssertEqual(ConversionPreview.delay, 1.0)
    }

    func testTypingSchedulesTimerAndFiringReturnsRomaji() throws {
        var p = ConversionPreview()
        let a = p.update(typing: "kyou")
        XCTAssertFalse(a.hideWindow)
        let gen = try XCTUnwrap(a.scheduleGeneration)
        XCTAssertEqual(p.timerFired(generation: gen), "kyou")
        XCTAssertNil(p.timerFired(generation: gen)) // 1回だけ
    }

    func testNextKeystrokeInvalidatesTimerAndHidesWindow() throws {
        var p = ConversionPreview()
        let g1 = try XCTUnwrap(p.update(typing: "kyou").scheduleGeneration)
        // 1.0 秒たつ前にもう1打鍵 → 前のタイマーは無効
        let a2 = p.update(typing: "kyouh")
        let g2 = try XCTUnwrap(a2.scheduleGeneration)
        XCTAssertNotEqual(g1, g2)
        XCTAssertNil(p.timerFired(generation: g1))
        XCTAssertEqual(p.timerFired(generation: g2), "kyouh")
        // 結果が出て窓を出したあとの打鍵（Backspace を含む）で、窓をすぐ消し、新しい見通しを予約する
        XCTAssertTrue(p.finish(generation: g2, romaji: "kyouh", leftContext: "", text: "今日は"))
        XCTAssertTrue(p.isWindowVisible)
        let a3 = p.update(typing: "kyou")
        XCTAssertTrue(a3.hideWindow)
        XCTAssertNotNil(a3.scheduleGeneration)
        XCTAssertFalse(p.isWindowVisible)
        XCTAssertNil(p.result)
    }

    func testResultIsDroppedIfKeystrokeArrivedWhileConverting() throws {
        var p = ConversionPreview()
        let g1 = try XCTUnwrap(p.update(typing: "kyou").scheduleGeneration)
        XCTAssertEqual(p.timerFired(generation: g1), "kyou")
        // 変換中（裏）に打鍵
        _ = p.update(typing: "kyouh")
        XCTAssertFalse(p.finish(generation: g1, romaji: "kyou", leftContext: "", text: "今日"))
        XCTAssertFalse(p.isWindowVisible)
        XCTAssertNil(p.result)
    }

    func testHideOnCommitConvertEscapeAndEmpty() throws {
        func shown() throws -> ConversionPreview {
            var p = ConversionPreview()
            let g = try XCTUnwrap(p.update(typing: "kyou").scheduleGeneration)
            _ = p.timerFired(generation: g)
            XCTAssertTrue(p.finish(generation: g, romaji: "kyou", leftContext: "", text: "今日"))
            return p
        }
        // 確定・変換キーでの変換・フォーカスの切り替え・Esc で未確定文字の状態が変わる: 変換結果の表示中は nil
        for next: String? in [nil, ""] {
            var p = try shown()
            let a = p.update(typing: next)
            XCTAssertTrue(a.hideWindow)
            XCTAssertNil(a.scheduleGeneration) // 空・変換済みでは予約しない
        }
        // 変更がなければ何もしない
        var p = try shown()
        XCTAssertEqual(p.update(typing: "kyou"), ConversionPreview.Action())
        XCTAssertTrue(p.isWindowVisible)
    }

    func testFailureShowsNothing() throws {
        var p = ConversionPreview()
        let g = try XCTUnwrap(p.update(typing: "kyou").scheduleGeneration)
        _ = p.timerFired(generation: g)
        XCTAssertFalse(p.finish(generation: g, romaji: "kyou", leftContext: "", text: nil))
        XCTAssertFalse(p.isWindowVisible)
        var q = ConversionPreview()
        let g2 = try XCTUnwrap(q.update(typing: "kyou").scheduleGeneration)
        _ = q.timerFired(generation: g2)
        XCTAssertFalse(q.finish(generation: g2, romaji: "kyou", leftContext: "", text: ""))
        XCTAssertNil(q.result)
    }

    func testResultIsReusableOnlyWhileUnchanged() throws {
        var p = ConversionPreview()
        let g = try XCTUnwrap(p.update(typing: "kyou").scheduleGeneration)
        XCTAssertNil(p.reusable(for: "kyou")) // 結果がまだない
        _ = p.timerFired(generation: g)
        XCTAssertTrue(p.finish(generation: g, romaji: "kyou", leftContext: "前の文", text: "今日"))
        let r = try XCTUnwrap(p.reusable(for: "kyou"))
        XCTAssertEqual(r.text, "今日")
        XCTAssertEqual(r.leftContext, "前の文") // 候補送りでも同じ左文脈を使う
        XCTAssertNil(p.reusable(for: "kyouh"))  // 別の文字列には使わない
        _ = p.update(typing: "kyouh")
        XCTAssertNil(p.reusable(for: "kyou"))
        XCTAssertNil(p.reusable(for: "kyouh"))
    }

    func testStaleFinishWithWrongRomajiIsRejected() throws {
        var p = ConversionPreview()
        let g = try XCTUnwrap(p.update(typing: "kyou").scheduleGeneration)
        _ = p.timerFired(generation: g)
        XCTAssertFalse(p.finish(generation: g, romaji: "other", leftContext: "", text: "x"))
    }
}

final class PreviewPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 300, height: 60)

    func testPlacedBelowTheLine() {
        let f = PreviewPlacement.frame(size: size, lineRect: CGRect(x: 100, y: 400, width: 2, height: 20), screen: screen)
        XCTAssertEqual(f, CGRect(x: 100, y: 400 - 2 - 60, width: 300, height: 60))
    }

    func testClampedAtRightEdge() {
        let f = PreviewPlacement.frame(size: size, lineRect: CGRect(x: 900, y: 400, width: 2, height: 20), screen: screen)
        XCTAssertEqual(f.maxX, 1000)
        XCTAssertEqual(f.minX, 700)
    }

    func testClampedAtLeftEdge() {
        let f = PreviewPlacement.frame(size: size, lineRect: CGRect(x: -50, y: 400, width: 2, height: 20), screen: screen)
        XCTAssertEqual(f.minX, 0)
    }

    func testFlipsAboveWhenNoRoomBelow() {
        let f = PreviewPlacement.frame(size: size, lineRect: CGRect(x: 100, y: 30, width: 2, height: 20), screen: screen)
        XCTAssertEqual(f.minY, 52) // 行の上（maxY + gap）
        XCTAssertGreaterThanOrEqual(f.minY, screen.minY)
    }

    func testStaysInsideWhenNeitherFits() {
        let tall = CGSize(width: 300, height: 700)
        let f = PreviewPlacement.frame(size: tall, lineRect: CGRect(x: 100, y: 350, width: 2, height: 20), screen: screen)
        XCTAssertGreaterThanOrEqual(f.minY, 0)
        XCTAssertLessThanOrEqual(f.maxY, 800)
    }

    func testLargerThanScreenIsShrunk() {
        let f = PreviewPlacement.frame(size: CGSize(width: 2000, height: 2000), lineRect: CGRect(x: 100, y: 400, width: 2, height: 20),
                                       screen: screen)
        XCTAssertEqual(f.size, CGSize(width: 1000, height: 800))
        XCTAssertTrue(screen.contains(f))
    }
}

final class ConversionPreviewMoreTests: XCTestCase {
    func testRepeatedUpdateWithSameInputDoesNotScheduleTwice() throws {
        var p = ConversionPreview()
        XCTAssertNotNil(p.update(typing: "kyou").scheduleGeneration)
        XCTAssertEqual(p.update(typing: "kyou"), ConversionPreview.Action()) // タイマーを二重に予約しない
        XCTAssertEqual(p.update(typing: "kyou"), ConversionPreview.Action())
        let gen = p.generation
        XCTAssertEqual(p.timerFired(generation: gen), "kyou")
        XCTAssertEqual(p.update(typing: "kyou"), ConversionPreview.Action()) // 変換中も同じ
    }

    func testReusableIsNilRightAfterConversion() throws {
        var p = ConversionPreview()
        let g = try XCTUnwrap(p.update(typing: "kyou").scheduleGeneration)
        _ = p.timerFired(generation: g)
        XCTAssertTrue(p.finish(generation: g, romaji: "kyou", leftContext: "", text: "今日"))
        XCTAssertNotNil(p.reusable(for: "kyou"))
        // 変換キーでの変換のあと（変換結果の表示中: typing = nil）
        _ = p.update(typing: nil)
        XCTAssertNil(p.typing)
        XCTAssertNil(p.reusable(for: "kyou"))
    }

    func testStaleFinishIsRejectedWhenRomajiComesBackAfterBackspace() throws {
        var p = ConversionPreview()
        let g1 = try XCTUnwrap(p.update(typing: "ab").scheduleGeneration)
        XCTAssertEqual(p.timerFired(generation: g1), "ab")
        _ = p.update(typing: "abc")   // 変換中に打鍵
        let g3 = try XCTUnwrap(p.update(typing: "ab").scheduleGeneration) // Backspace で同じローマ字に戻る
        XCTAssertNotEqual(g1, g3)
        XCTAssertFalse(p.finish(generation: g1, romaji: "ab", leftContext: "", text: "古い"))
        XCTAssertNil(p.result)
        XCTAssertFalse(p.isCurrent(generation: g1, romaji: "ab"))
        // 新しい世代のタイマーと結果は使える
        XCTAssertEqual(p.timerFired(generation: g3), "ab")
        XCTAssertTrue(p.isCurrent(generation: g3, romaji: "ab"))
        XCTAssertTrue(p.finish(generation: g3, romaji: "ab", leftContext: "", text: "新しい"))
    }
}

final class SharedConversionTests: XCTestCase {
    private func key(_ r: String, context: String = "", settings: String = "s") -> SharedConversion.Key {
        .init(romaji: r, leftContext: context, settings: settings)
    }

    func testSameKeyIsConvertedOnce() throws {
        let shared = SharedConversion()
        var calls = 0
        let a = try shared.run(key: key("kyou")) { calls += 1; return "今日" }
        let b = try shared.run(key: key("kyou")) { calls += 1; return "違う" }
        XCTAssertEqual(a, "今日")
        XCTAssertEqual(b, "今日")
        XCTAssertEqual(calls, 1)
    }

    func testDifferentRomajiContextOrSettingsAreConvertedAgain() throws {
        let shared = SharedConversion()
        var calls = 0
        func run(_ k: SharedConversion.Key) throws -> String { try shared.run(key: k) { calls += 1; return "x\(calls)" } }
        _ = try run(key("kyou"))
        _ = try run(key("kyouha"))
        _ = try run(key("kyouha", context: "前"))
        _ = try run(key("kyouha", context: "前", settings: "t"))
        XCTAssertEqual(calls, 4)
    }

    func testFailureIsNotStored() {
        struct E: Error {}
        let shared = SharedConversion()
        XCTAssertThrowsError(try shared.run(key: key("a")) { throw E() })
        XCTAssertEqual(try shared.run(key: key("a")) { "ok" }, "ok")
    }

    /// 裏の変換が lock を持っている間に、main が同じ入力で変換を求める: main は待ち、待ったあとに同じ変換をやり直さない。
    func testWaitingCallerReusesResultOfRunningConversion() {
        let shared = SharedConversion()
        let lock = NSLock()
        var calls = 0
        let started = DispatchSemaphore(value: 0)
        let done = expectation(description: "both finished")
        done.expectedFulfillmentCount = 2
        var results: [String] = []
        let work: () throws -> String = {
            lock.lock(); calls += 1; lock.unlock()
            started.signal()
            Thread.sleep(forTimeInterval: 0.3)
            return "今日"
        }
        DispatchQueue.global().async {
            let r = try? shared.run(key: self.key("kyou"), work: work)
            lock.lock(); results.append(r ?? "nil"); lock.unlock()
            done.fulfill()
        }
        started.wait() // 裏の変換が始まった（lock を持っている）
        DispatchQueue.global().async {
            let r = try? shared.run(key: self.key("kyou"), work: work) // 待たされる
            lock.lock(); results.append(r ?? "nil"); lock.unlock()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(results, ["今日", "今日"])
    }

    func testConversionSignatureChangesWithSettings() {
        var a = Settings()
        let base = a.conversionSignature
        a.postProcess.fullWidthDigits = true
        XCTAssertNotEqual(a.conversionSignature, base)
        var b = Settings()
        b.modelPath = "/other.gguf"
        XCTAssertNotEqual(b.conversionSignature, base)
    }
}
