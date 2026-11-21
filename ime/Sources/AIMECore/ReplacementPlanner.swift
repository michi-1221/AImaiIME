import Foundation

/// 直接モードで変換キーが押されたときに「何をどこで置き換えるか」を決める（クライアントに依存しない純粋な処理）。
/// 置き換えないときは、変換キーをそのままアプリへ通す。
public enum ReplacementPlanner {
    /// カーソル直前から取得する最大長（UTF-16 単位）。200 字程度の入力と左文脈が十分に入る長さ。
    public static let fetchLength = 2048

    public struct Plan: Equatable {
        public var romaji: String
        public var leftContext: String
        /// クライアント上でローマ字列が占める範囲（UTF-16 単位）。
        public var replacementRange: NSRange
        /// 打鍵バッファで代替したか。
        public var usedBuffer: Bool
        /// ローマ字列より前のテキスト（取得できた範囲）。置き換え後にバッファを合わせるのに使う。
        public var textBeforeRomaji: String
    }

    /// `plan` の結果と、置き換えない理由。
    public enum Outcome: Equatable {
        case plan(Plan)
        /// 変換するものがない（カーソル直前にローマ字列がない・範囲選択中）
        case nothingToConvert
        /// 前のテキストが取れない・確かめられない（この入力欄は置き換えに対応していないとみなせる）
        case textUnavailable
    }

    /// 置き換えるものがあれば `Plan`、なければ nil。
    public static func plan(selectedRange sel: NSRange, buffer: TypingBuffer, fetch: (NSRange) -> String?) -> Plan? {
        if case .plan(let p) = outcome(selectedRange: sel, buffer: buffer, fetch: fetch) { return p }
        return nil
    }

    /// - Parameters:
    ///   - selectedRange: クライアントの `selectedRange()`。
    ///   - buffer: 打鍵バッファ。
    ///   - fetch: 範囲のテキストをクライアントから取る。取れない・要求と違う長さのときは nil を返すこと。
    public static func outcome(selectedRange sel: NSRange, buffer: TypingBuffer, fetch: (NSRange) -> String?) -> Outcome {
        // 置換範囲を指定するにはカーソル位置が必要。範囲選択中も変換しない。
        guard sel.location != NSNotFound else { return .textUnavailable }
        guard sel.length == 0 else { return .nothingToConvert }
        let loc = sel.location

        let fetchLen = min(loc, fetchLength)
        var text: String? = fetchLen == 0 ? "" : fetch(NSRange(location: loc - fetchLen, length: fetchLen))
        var usedBuffer = false
        if text == nil {
            // 打鍵バッファで代替する。記録した位置が今のカーソル位置と一致するときだけ。
            guard buffer.expectedLocation == loc else { return .textUnavailable }
            text = buffer.text
            usedBuffer = true
        }

        guard let textBefore = text, let extracted = RomajiExtractor.extract(from: textBefore) else {
            // クライアントのテキストにローマ字列がなければ変換するものがない。
            // バッファで代替していたなら、本当のところはわからない。
            return usedBuffer ? .textUnavailable : .nothingToConvert
        }
        guard extracted.romajiUTF16Length <= loc else { return .textUnavailable }
        let range = NSRange(location: loc - extracted.romajiUTF16Length, length: extracted.romajiUTF16Length)

        // バッファで代替したときは、置き換える範囲の実際のテキストがローマ字列と一致することを確かめる。
        // 確かめられない（取得できない）ときも置き換えない。
        if usedBuffer {
            guard let actual = fetch(range), Array(actual.utf16) == Array(extracted.romaji.utf16) else {
                return .textUnavailable
            }
        }

        let before = String(String.UnicodeScalarView(textBefore.unicodeScalars.dropLast(extracted.romaji.unicodeScalars.count)))

        // バッファの先頭からローマ字列が始まっていて、その前に何があるかわからないとき
        // （クリックや Return のあと途中から打ち始めたとき）は、置き換え範囲の直前1文字を確かめる。
        // それがローマ字列に含まれうる文字なら、ローマ字列の途中だけを変換することになるので置き換えない。
        // 取得できないときも置き換えない。
        if usedBuffer, before.isEmpty, !buffer.knowsPrecedingText, range.location > 0 {
            guard let prev = fetch(NSRange(location: range.location - 1, length: 1)),
                  let scalar = prev.unicodeScalars.last,
                  !RomajiExtractor.isRomajiScalar(scalar) else { return .textUnavailable }
        }
        return .plan(Plan(romaji: extracted.romaji, leftContext: extracted.leftContext, replacementRange: range,
                          usedBuffer: usedBuffer, textBeforeRomaji: before))
    }
}
