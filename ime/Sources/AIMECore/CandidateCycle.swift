import Foundation

/// 変換キーを続けて押したときの候補送りの状態。
///
/// 並び: 1位（1回目の結果）→ 2位 → … → 最後の候補 → 元のローマ字列 → 1位 → …（循環）
/// 候補（2位以降）は2回目の変換キーのときに求めて `setCandidates` で入れる。それまでは1位だけを持つ。
public struct CandidateCycle: Equatable {
    public let romaji: String
    /// 1回目の変換で使った左文脈（2位以降を求めるときも同じものを使う）。
    public let leftContext: String
    /// 候補（後処理済み）。先頭は1回目の結果。
    public private(set) var candidates: [String]
    /// 2位以降を求めたか。
    public private(set) var hasComputedCandidates = false
    /// 今出しているものの位置（`options` の添字）。
    public private(set) var index = 0

    public init(romaji: String, leftContext: String, first: String) {
        self.romaji = romaji
        self.leftContext = leftContext
        self.candidates = [first]
    }

    /// 循環する並び（候補 + 元のローマ字列）。元のローマ字列と同じ候補があれば、その位置でまとめる。
    public var options: [String] { candidates.contains(romaji) ? candidates : candidates + [romaji] }
    /// 今出しているテキスト。
    public var currentText: String { options[index] }

    /// 2位以降を入れる。先頭は1回目の結果のままにする（`list` の先頭が違っても1回目の結果を先頭に置く）。
    public mutating func setCandidates(_ list: [String]) {
        var c = [candidates[0]]
        for s in list where !c.contains(s) { c.append(s) }
        candidates = c
        hasComputedCandidates = true
    }

    /// 次へ進める。新しく出すテキストを返す。
    public mutating func advance() -> String {
        index = (index + 1) % options.count
        return currentText
    }
}
