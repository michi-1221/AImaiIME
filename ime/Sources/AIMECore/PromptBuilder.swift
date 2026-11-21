import Foundation

/// モデルへのプロンプト文字列を組み立てる。
///
/// 形式（この順に連結）:
///   [左文脈があれば] U+EE02 + 左文脈（末尾100文字。Unicode スカラー単位）
///   U+EE00 + 入力（ローマ字）
///   U+EE01
/// 特殊文字はトークナイザー（GPT-2 バイトレベル BPE）によって UTF-8 の3バイトトークンに分かれる。
/// 語彙に依存した処理はここでは一切しない（文字列を作るだけ）。
public enum PromptBuilder {
    public static let inputMarker = "\u{EE00}"
    public static let outputMarker = "\u{EE01}"
    public static let contextMarker = "\u{EE02}"

    public static func build(input: String, leftContext: String?) -> String {
        var s = ""
        if let ctx = leftContext, !ctx.isEmpty {
            s += contextMarker + RomajiExtractor.leftContextSuffix(ctx)
        }
        s += inputMarker + input + outputMarker
        return s
    }
}
