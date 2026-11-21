import Foundation

/// 変換キーを続けて押したときの候補送りの状態。
///
/// 並び: 1位（1回目の結果）→ 2位 → … → 最後の候補 → 元のローマ字列 → 1位 → …（循環）
/// 候補（2位以降）は2回目の変換キーのときに求めて `setCandidates` で入れる。それまでは1位だけを持つ。
/// 直接モード（置き換え）と未確定文字の両方で使う（未確定文字では `start` と `textBeforeRomaji` は使わない）。
public struct CandidateCycle: Equatable {
    public let romaji: String
    /// 1回目の変換で使った左文脈（2位以降を求めるときも同じものを使う）。
    public let leftContext: String
    /// 直接モード: ローマ字列より前のテキスト（打鍵バッファを合わせるのに使う）。
    public let textBeforeRomaji: String
    /// 直接モード: 置き換えた範囲の先頭（UTF-16 単位）。
    public let start: Int
    /// 候補（後処理済み）。先頭は1回目の結果。
    public private(set) var candidates: [String]
    /// 2位以降を求めたか。
    public private(set) var hasComputedCandidates = false
    /// 今出しているものの位置（`options` の添字）。
    public private(set) var index = 0

    public init(romaji: String, leftContext: String, textBeforeRomaji: String = "", start: Int = 0, first: String) {
        self.romaji = romaji
        self.leftContext = leftContext
        self.textBeforeRomaji = textBeforeRomaji
        self.start = start
        self.candidates = [first]
    }

    /// 循環する並び（候補 + 元のローマ字列）。元のローマ字列と同じ候補があれば、その位置でまとめる。
    public var options: [String] { candidates.contains(romaji) ? candidates : candidates + [romaji] }
    /// 今出しているテキスト。
    public var currentText: String { options[index] }
    /// 直接モード: 今出しているテキストがクライアント上で占める範囲。
    public var currentRange: NSRange { NSRange(location: start, length: currentText.utf16.count) }

    /// 2位以降を入れる。先頭は1回目の結果のままにする（`list` の先頭が違っても1回目の結果を先頭に置く）。
    public mutating func setCandidates(_ list: [String]) {
        var c = [candidates[0]]
        for s in list where !c.contains(s) { c.append(s) }
        candidates = c
        hasComputedCandidates = true
    }

    /// 次へ進める。置き換える範囲（進める前に出していたものの範囲）と、新しく出すテキストを返す。
    public mutating func advance() -> (range: NSRange, text: String) {
        let range = currentRange
        index = (index + 1) % options.count
        return (range, currentText)
    }

    public enum Decision: Equatable {
        /// 候補送りを続ける（次の候補に置き換える）
        case advance
        /// 候補送りを終え、置き換えずに変換キーをそのまま通す（実テキストを確かめられない）
        case passThrough
        /// 候補送りを終え、通常の新規変換として扱う（位置や内容が崩れた）
        case newConversion
    }

    /// 直接モード: 変換キーが押されたときに、候補送りを続けられるかを決める。
    /// - Parameters:
    ///   - selectedRange: クライアントの `selectedRange()`。
    ///   - fetch: 範囲のテキストをクライアントから取る。取れない・要求と違う長さのときは nil。
    public func decide(selectedRange sel: NSRange, fetch: (NSRange) -> String?) -> Decision {
        let range = currentRange
        // カーソルが置き換え直後（置き換えた範囲の末尾）のままか
        guard sel.location != NSNotFound, sel.length == 0, sel.location == NSMaxRange(range) else {
            return .newConversion
        }
        guard let actual = fetch(range) else { return .passThrough }
        // String の == は正規化して比べる（「が」と「か + 濁点」が等しくなる）ので、UTF-16 の並びで比べる
        return Array(actual.utf16) == Array(currentText.utf16) ? .advance : .newConversion
    }
}

/// 直接モードの候補送りの状態を持ち、打鍵や変換キーに応じて進める・終える。
public struct CandidateCycler: Equatable {
    public private(set) var cycle: CandidateCycle?

    public init() {}

    /// 新規変換で置き換えたあとに呼ぶ。
    public mutating func start(_ cycle: CandidateCycle) {
        self.cycle = cycle
    }

    /// 変換キー以外の打鍵・クリック・入力ソースの切り替えなど。候補送りを終える（その時点の内容で確定）。
    public mutating func end() {
        cycle = nil
    }

    /// 変換キーが押された。`.advance` 以外なら候補送りを終える。
    public mutating func tab(selectedRange: NSRange, fetch: (NSRange) -> String?) -> CandidateCycle.Decision {
        guard let cycle else { return .newConversion }
        let d = cycle.decide(selectedRange: selectedRange, fetch: fetch)
        if d != .advance { self.cycle = nil }
        return d
    }

    public mutating func setCandidates(_ list: [String]) {
        cycle?.setCandidates(list)
    }

    /// 次へ進める。候補送り中でなければ nil。
    public mutating func advance() -> (range: NSRange, text: String)? {
        cycle?.advance()
    }
}
