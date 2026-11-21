import Foundation

/// IME の設定。UserDefaults（IME のバンドル ID のドメイン）から読む。
/// `defaults write <bundle id> <key> <value>` で変更でき、次の変換から反映される。
public struct Settings: Equatable {
    public enum Key {
        /// GGUF モデルファイルのパス（文字列）。`~` は展開する。
        public static let modelPath = "modelPath"
        /// 全角数字にするか（真偽値、既定 false = 半角）。真偽値でない値（文字列など）は既定値として扱い、警告に入れる。
        public static let fullWidthDigits = "fullWidthDigits"
        /// 変換キーを続けて押したときの候補数（整数、既定 5、1〜32 に丸める。1位を含む。元のローマ字列は含まない）。
        /// 数値でない値は既定値として扱い、警告に入れる。
        public static let candidateCount = "candidateCount"
        /// 入力の方式: "marked"（既定、どこでも未確定文字）/ "direct"（直接モード）。
        public static let inputMode = "inputMode"
        /// 変換キー（両モード共通。書式は `ConvertKey`、既定 "space"）。
        public static let convertKey = "convertKey"
        /// 以前の設定名（直接モードの変換キー）。`convertKey` が未設定でこれがあれば、その値を使う（読み込み時の移行）。
        public static let legacyDirectConvertKey = "directConvertKey"
    }

    public static let defaultModelPath = "~/Library/Application Support/AImaiIME/model.gguf"

    public var modelPath: String
    public var postProcess: PostProcessOptions
    /// 入力の方式
    public var inputMode: InputMode = .marked
    /// 変換キー（両モード共通。不正な値・未設定なら Space）
    public var convertKey: ConvertKey = .defaultKey
    /// 不正な値だったため既定値に戻した設定の説明（警告としてログに残すため）
    public var invalidValues: [String] = []
    public static let defaultCandidateCount = 5
    /// 候補数の範囲（範囲外の値は丸めて使う）。
    public static let candidateCountRange = 1...32
    /// 変換キーを続けて押したときの候補数（`candidateCountRange` の範囲）。
    public var candidateCount = Settings.defaultCandidateCount

    public init(modelPath: String = Settings.defaultModelPath, postProcess: PostProcessOptions = .init()) {
        self.modelPath = modelPath
        self.postProcess = postProcess
    }

    /// `~` を展開した絶対パス。
    public var expandedModelPath: String {
        (modelPath as NSString).expandingTildeInPath
    }

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        var s = Settings()
        if let p = string(defaults, Key.modelPath, &s.invalidValues, defaultText: defaultModelPath), !p.isEmpty {
            s.modelPath = p
        }
        s.postProcess.fullWidthDigits = bool(defaults, Key.fullWidthDigits, &s.invalidValues) ?? false
        if let raw = string(defaults, Key.inputMode, &s.invalidValues, defaultText: InputMode.marked.rawValue) {
            if let mode = InputMode(rawValue: raw.lowercased()) {
                s.inputMode = mode
            } else {
                s.invalidValues.append("\(Key.inputMode) = \"\(raw)\" は不正なため \(InputMode.marked.rawValue) を使います")
            }
        }
        // 変換キー: convertKey が未設定なら、以前の directConvertKey を使う
        let keyName = defaults.object(forKey: Key.convertKey) != nil ? Key.convertKey
            : (defaults.object(forKey: Key.legacyDirectConvertKey) != nil ? Key.legacyDirectConvertKey : nil)
        if let keyName {
            let raw = defaults.object(forKey: keyName)
            if let text = raw as? String, let key = ConvertKey.parse(text) {
                s.convertKey = key
            } else {
                s.invalidValues.append("\(keyName) = \"\(raw.map { "\($0)" } ?? "")\" は不正（または打鍵と区別できない）ため \(ConvertKey.defaultKey) を使います")
            }
        }
        if let n = integer(defaults, Key.candidateCount, &s.invalidValues, defaultText: "\(defaultCandidateCount)") {
            s.candidateCount = min(max(n, candidateCountRange.lowerBound), candidateCountRange.upperBound)
        }
        return s
    }

    // 型を確かめて読む。未設定なら nil。型が合わない値なら警告に入れて nil（呼び出し側が既定値を使う）。

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// 真偽値（`defaults write … -bool`）。数値・文字列は型が合わない。
    private static func bool(_ defaults: UserDefaults, _ key: String, _ invalid: inout [String]) -> Bool? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let n = raw as? NSNumber, isBoolean(n) { return n.boolValue }
        invalid.append("\(key) = \"\(raw)\" は型が合わない（真偽値でない。-bool で書いてください）ため false を使います")
        return nil
    }

    /// 整数（`defaults write … -int`）。真偽値・小数・文字列は型が合わない。
    private static func integer(_ defaults: UserDefaults, _ key: String, _ invalid: inout [String], defaultText: String) -> Int? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let n = raw as? NSNumber, !isBoolean(n), !CFNumberIsFloatType(n) { return n.intValue }
        invalid.append("\(key) = \"\(raw)\" は型が合わない（整数でない。-int で書いてください）ため \(defaultText) を使います")
        return nil
    }

    /// 文字列。数値・真偽値などは型が合わない。
    private static func string(_ defaults: UserDefaults, _ key: String, _ invalid: inout [String], defaultText: String) -> String? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let text = raw as? String { return text }
        invalid.append("\(key) = \"\(raw)\" は型が合わない（文字列でない）ため \(defaultText) を使います")
        return nil
    }
}

/// 入力の方式（設定 `inputMode`）。
public enum InputMode: String, Equatable {
    /// どこでも未確定文字: 打ったローマ字は未確定文字になり、Tab で変換する（既定）。
    case marked
    /// 直接モード: 打鍵はすぐ確定し、変換キーでカーソル直前のローマ字列を置き換える。
    /// 置き換えに対応していない入力欄では、自動的に未確定文字の方式で動く。
    case direct
}
