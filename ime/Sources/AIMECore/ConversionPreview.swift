import CoreGraphics
import Foundation

/// 変換の見通し（手が止まったら、未確定文字を変換した結果を小さな窓に出す）の状態。
///
/// タイマー・世代・窓の出し消しの判定だけを持つ（時間の待ち、変換の実行、窓の描画は呼び出し側）。
/// - 未確定文字（ローマ字、変換前）が変わるたびに `update` を呼ぶ。変わったら世代を進め、前の結果と窓を捨てる。
///   ローマ字があれば、`delay` 秒後に `timerFired` を呼ぶ予約を返す。
/// - `timerFired` で、そのときも世代が同じなら、変換するローマ字を返す。変換は main スレッドの外で行う。
/// - 変換が終わったら `finish` を呼ぶ。その間に打鍵（世代の変化）があれば、結果は捨てる。
/// - 変換キーが押されたとき、`reusable` で見通しの結果を使える（モデルをもう一度動かさない）。
public struct ConversionPreview: Equatable {
    /// 最後の打鍵から、見通しの変換を始めるまでの時間（秒。固定）
    public static let delay: TimeInterval = 1.0

    /// 見通しの結果
    public struct Result: Equatable {
        public var romaji: String
        /// 変換に使った左文脈（候補送りでも同じものを使う）
        public var leftContext: String
        public var text: String
    }

    /// `update` の結果として、呼び出し側がすること
    public struct Action: Equatable {
        /// 窓を消す
        public var hideWindow = false
        /// この世代で `delay` 秒後に `timerFired` を呼ぶ予約をする（nil なら予約しない・前の予約は取り消してよい）
        public var scheduleGeneration: Int?
    }

    public private(set) var generation = 0
    /// 今の、変換前の未確定文字（なければ nil。変換結果を表示中のときも nil）
    public private(set) var typing: String?
    public private(set) var result: Result?
    public private(set) var isWindowVisible = false
    private var timerPending = false
    private var running = false

    public init() {}

    /// 未確定文字が変わったかもしれないときに呼ぶ（打鍵のあと・確定・フォーカスの切り替えなど）。
    /// - Parameter typing: 変換前のローマ字の未確定文字。空・変換結果の表示中・未確定文字なしは nil。
    public mutating func update(typing newTyping: String?) -> Action {
        let normalized = (newTyping?.isEmpty ?? true) ? nil : newTyping
        guard normalized != typing else { return Action() }
        generation += 1
        typing = normalized
        result = nil
        timerPending = false
        running = false
        var action = Action(hideWindow: isWindowVisible)
        isWindowVisible = false
        if normalized != nil {
            timerPending = true
            action.scheduleGeneration = generation
        }
        return action
    }

    /// タイマーが鳴った。世代が変わっていなければ、変換するローマ字を返す（nil なら何もしない）。
    public mutating func timerFired(generation g: Int) -> String? {
        guard g == generation, timerPending, let typing else { return nil }
        timerPending = false
        running = true
        return typing
    }

    /// 変換を始めてよいか（世代と未確定文字が、タイマーが鳴ったときのままで、変換の結果を待っているか）。
    public func isCurrent(generation g: Int, romaji: String) -> Bool {
        g == generation && running && typing == romaji
    }

    /// 変換が終わった。結果を使うなら（窓を出すなら）true。
    /// 変換の間に打鍵（世代の変化）があった・変換に失敗した（`text` が nil か空）ときは false（窓を出さない）。
    public mutating func finish(generation g: Int, romaji: String, leftContext: String, text: String?) -> Bool {
        guard g == generation, running, typing == romaji else { return false }
        running = false
        guard let text, !text.isEmpty else { return false }
        result = Result(romaji: romaji, leftContext: leftContext, text: text)
        isWindowVisible = true
        return true
    }

    /// 変換キーが押されたとき、未確定文字が見通しを出した時点から変わっていなければ、その結果。
    public func reusable(for romaji: String) -> Result? {
        guard let result, result.romaji == romaji, typing == romaji else { return nil }
        return result
    }
}

/// 見通しの窓の置き場所（画面の端からはみ出さない）。座標は AppKit（左下が原点）。
public enum PreviewPlacement {
    /// - Parameters:
    ///   - size: 窓の大きさ。
    ///   - lineRect: カーソルのある行の矩形（画面座標）。
    ///   - screen: 窓を置く画面の表示領域（`visibleFrame`）。
    ///   - gap: 行と窓のすき間。
    /// - Returns: 行の下が基本。下に入らなければ上。幅・高さが画面より大きければ画面に収める。
    public static func frame(size: CGSize, lineRect: CGRect, screen: CGRect, gap: CGFloat = 2) -> CGRect {
        let w = min(size.width, screen.width)
        let h = min(size.height, screen.height)
        var x = lineRect.minX
        x = max(screen.minX, min(x, screen.maxX - w))
        var y = lineRect.minY - gap - h
        if y < screen.minY {
            let above = lineRect.maxY + gap
            y = above + h <= screen.maxY ? above : max(screen.minY, min(y, screen.maxY - h))
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension Settings {
    /// 変換結果に影響する設定（モデルと後処理）を表す文字列。見通しの結果を変換キーの変換で使い回してよいかの照合に使う。
    public var conversionSignature: String {
        "\(modelPath)|digits=\(postProcess.fullWidthDigits)"
    }
}

/// 見通しの変換（裏のスレッド）と変換キーの変換（main スレッド）が、同じ入力を二重に変換しないようにする。
///
/// 変換は lock の中で行い、結果（入力・左文脈・設定が分かる `Key` つき）を、lock を手放す前に置いておく。
/// あとから lock を取ったほうは、モデルを呼ぶ前に置き場を見て、`Key` が一致すればその結果を使う。
/// つまり、裏の変換が終わるのを待っていた main は、待ったあとに同じ変換をやり直さない。
public final class SharedConversion {
    public struct Key: Equatable {
        public var romaji: String
        public var leftContext: String
        public var settings: String

        public init(romaji: String, leftContext: String, settings: String) {
            self.romaji = romaji
            self.leftContext = leftContext
            self.settings = settings
        }
    }

    private let lock = NSLock()
    private var stored: (key: Key, text: String)?

    public init() {}

    /// `key` の変換結果を返す。置き場に同じ `key` の結果があればそれを使い、なければ `work` で変換して置く。
    /// `work` が投げたときは何も置かず、投げ直す。
    public func run(key: Key, work: () throws -> String) rethrows -> String {
        lock.lock(); defer { lock.unlock() }
        if let stored, stored.key == key { return stored.text }
        let text = try work()
        stored = (key, text)
        return text
    }
}
