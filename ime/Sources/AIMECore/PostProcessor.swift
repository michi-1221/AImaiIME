import Foundation

/// 変換結果の後処理の設定。
public struct PostProcessOptions: Equatable {
    /// true なら数字を全角（０〜９）に、false なら半角（0〜9）にそろえる。既定は半角。
    public var fullWidthDigits: Bool

    public init(fullWidthDigits: Bool = false) {
        self.fullWidthDigits = fullWidthDigits
    }
}

public enum PostProcessor {
    public static func apply(_ text: String, options: PostProcessOptions) -> String {
        convertDigits(text, fullWidth: options.fullWidthDigits)
    }

    /// 数字だけを半角/全角に変換する。ほかの文字は触らない。
    public static func convertDigits(_ text: String, fullWidth: Bool) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if fullWidth, s.value >= 0x30, s.value <= 0x39 {
                out.append(Unicode.Scalar(s.value - 0x30 + 0xFF10)!)
            } else if !fullWidth, s.value >= 0xFF10, s.value <= 0xFF19 {
                out.append(Unicode.Scalar(s.value - 0xFF10 + 0x30)!)
            } else {
                out.append(s)
            }
        }
        return String(out)
    }
}
