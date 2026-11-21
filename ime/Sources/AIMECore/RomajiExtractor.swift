import Foundation

/// ローマ字（変換の対象にする文字）と左文脈の決まり。
public enum RomajiExtractor {
    /// 左文脈としてモデルに渡す最大文字数（Unicode スカラー単位。学習時の左文脈と同じ数え方）。
    public static let maxLeftContextLength = 40

    /// 末尾 `maxLeftContextLength` 個の Unicode スカラー。
    public static func leftContextSuffix(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.suffix(maxLeftContextLength)))
    }

    /// ASCII の印字可能文字（U+0021〜U+007E）。空白 U+0020 は含めない。
    @inlinable
    public static func isRomajiScalar(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0x21 && s.value <= 0x7E
    }
}

/// 未確定文字の直前の確定済みテキストから左文脈を取る。
public enum LeftContext {
    /// - Parameters:
    ///   - markedRange: クライアントの `markedRange()`（未確定文字の範囲。なければ location が NSNotFound）。
    ///   - selectedRange: クライアントの `selectedRange()`（未確定文字の範囲がわからないときに使う）。
    ///   - fetch: 範囲のテキストをクライアントから取る。取れない・要求と違う長さのときは nil。
    /// - Returns: 最大 40 スカラー。取れなければ空文字列（エラーにしない）。
    public static func get(markedRange: NSRange, selectedRange: NSRange, fetch: (NSRange) -> String?) -> String {
        let start = markedRange.location != NSNotFound ? markedRange.location : selectedRange.location
        guard start != NSNotFound, start > 0 else { return "" }
        // 40 スカラー（サロゲートペアなら最大 80 UTF-16 単位）
        let length = min(start, RomajiExtractor.maxLeftContextLength * 2)
        guard let text = fetch(NSRange(location: start - length, length: length)) else { return "" }
        return RomajiExtractor.leftContextSuffix(text)
    }
}
