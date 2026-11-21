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

    public struct Result: Equatable {
        /// 変換対象のローマ字列（末尾から連続する ASCII 印字可能文字、空白を除く）。
        public var romaji: String
        /// ローマ字列の直前にある既存テキスト（最大 `maxLeftContextLength` スカラー）。空のこともある。
        public var leftContext: String
        /// ローマ字列の UTF-16 長。クライアント上の置換範囲の計算に使う。
        public var romajiUTF16Length: Int { romaji.utf16.count }

        public init(romaji: String, leftContext: String) {
            self.romaji = romaji
            self.leftContext = leftContext
        }
    }

    /// 直接モード用: `textBeforeCursor`（カーソル直前までのテキスト）から、末尾のローマ字列と左文脈を切り出す。
    /// ローマ字列が空なら nil を返す。
    public static func extract(from textBeforeCursor: String) -> Result? {
        let scalars = textBeforeCursor.unicodeScalars
        var start = scalars.endIndex
        while start > scalars.startIndex {
            let prev = scalars.index(before: start)
            guard isRomajiScalar(scalars[prev]) else { break }
            start = prev
        }
        if start == scalars.endIndex { return nil }
        let romaji = String(scalars[start...])
        let before = String(scalars[..<start])
        return Result(romaji: romaji, leftContext: leftContextSuffix(before))
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
