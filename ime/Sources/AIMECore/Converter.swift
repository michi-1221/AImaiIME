import Foundation

/// 変換結果を使えない理由。IME はこのとき未確定文字をローマ字のまま残す。
public enum ConversionError: Error, Equatable, CustomStringConvertible {
    /// `</s>` で止まらなかった（上限で打ち切られ、途中で切れている可能性がある）。
    case notTerminated
    /// 出力に U+FFFD（不正な UTF-8 を置き換えた文字）を含む。
    case invalidCharacters
    /// 出力が空。
    case empty
    /// 入力（ローマ字列）が長すぎる（`Converter.maxInputLength` を超える）。
    case inputTooLong

    public var description: String {
        switch self {
        case .notTerminated: return "</s> で止まらなかった（出力が途中で切れている）"
        case .invalidCharacters: return "出力に U+FFFD を含む"
        case .empty: return "出力が空"
        case .inputTooLong: return "入力が長すぎる（\(Converter.maxInputLength) 文字を超える）"
        }
    }
}

/// ローマ字列 + 左文脈 → 変換結果（後処理済み）。
public final class Converter {
    public let generator: TextGenerator

    public init(generator: TextGenerator) {
        self.generator = generator
    }

    /// 変換するローマ字列の長さの上限（Unicode スカラー数）。変換はメインスレッドで同期的に行うので、
    /// 長い入力で IME が長く止まらないようにする。超えたら変換しない（`ConversionError.inputTooLong`）。
    public static let maxInputLength = 400

    /// 生成トークン数の上限。入力の文字数（Unicode スカラー数）に比例させる。
    /// 出力は入力より短くなるのがふつう（ローマ字 2〜3 文字 ≒ かな 1 文字）なので
    /// 入力1文字あたり2トークン + 16 で十分な余裕がある。
    public static func maxNewTokens(forInput input: String) -> Int {
        input.unicodeScalars.count * 2 + 16
    }

    /// 変換する。結果を使えないとき（途中で切れた・不正な文字・空）は `ConversionError` を投げる。
    public func convert(input: String, leftContext: String?, options: PostProcessOptions) throws -> String {
        guard input.unicodeScalars.count <= Self.maxInputLength else { throw ConversionError.inputTooLong }
        let prompt = PromptBuilder.build(input: input, leftContext: leftContext)
        let result = try generator.generate(prompt: prompt, maxNewTokens: Self.maxNewTokens(forInput: input))
        guard result.hitStopToken else { throw ConversionError.notTerminated }
        guard !result.text.unicodeScalars.contains("\u{FFFD}") else { throw ConversionError.invalidCharacters }
        guard !result.text.isEmpty else { throw ConversionError.empty }
        return PostProcessor.apply(result.text, options: options)
    }

    /// ビーム幅（8。候補数がそれより多いときは候補数）。
    public static func beamWidth(forCount count: Int) -> Int { max(8, count) }

    /// Tab を続けて押したときの候補を求める（ビームサーチ）。
    /// - Parameters:
    ///   - first: 1回目の Tab で出した結果（後処理済み）。候補の先頭に置く。
    ///   - count: 候補数の上限（先頭の `first` を含む）。
    /// - Returns: 先頭が `first` の候補列（後処理済み、重複なし）。
    public func candidates(input: String, leftContext: String?, first: String, count: Int,
                           options: PostProcessOptions) throws -> [String] {
        guard input.unicodeScalars.count <= Self.maxInputLength else { throw ConversionError.inputTooLong }
        // 候補数が 1 なら 2位以降は要らないので、ビームサーチは走らせない
        if count <= 1 { return [first] }
        let prompt = PromptBuilder.build(input: input, leftContext: leftContext)
        let beam = try generator.beamSearch(prompt: prompt, maxNewTokens: Self.maxNewTokens(forInput: input),
                                            beamWidth: Self.beamWidth(forCount: count), topN: count)
        return CandidateList.build(first: first, beam: beam, count: count) {
            PostProcessor.apply($0, options: options)
        }
    }
}

/// ビームサーチの結果から候補列を作る。
public enum CandidateList {
    /// - 先頭は `first`（1回目に出した結果）。残りを対数尤度の高い順に並べる。
    /// - `</s>` で止まらなかった候補・U+FFFD を含む候補・空の候補は除く。
    /// - 後処理（`postProcess`）を各候補にかけ、後処理後の文字列が重複するものはまとめる。
    /// - 最大 `count` 件（`count` が 1 以下でも `first` だけは返す）。
    public static func build(first: String, beam: [ScoredGeneration], count: Int,
                             postProcess: (String) -> String) -> [String] {
        var out = [first]
        let usable = beam
            .filter { $0.hitStopToken && !$0.text.isEmpty && !$0.text.unicodeScalars.contains("\u{FFFD}") }
            .sorted { $0.logProb > $1.logProb }
        for g in usable {
            if out.count >= count { break }
            let text = postProcess(g.text)
            if !out.contains(text) { out.append(text) }
        }
        return out
    }
}
