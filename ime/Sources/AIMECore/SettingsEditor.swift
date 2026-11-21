import Foundation

/// 設定ウィンドウからの変更を UserDefaults に書く（`Settings.load` と同じキー・書式）。
/// 書いた値は、IME が次の打鍵で `Settings.load` を読むときに反映される。
public enum SettingsEditor {
    /// 変換キーを保存する（`convertKey`）。
    public static func setConvertKey(_ key: ConvertKey, in defaults: UserDefaults = .standard) {
        replace(key.description, forKey: Settings.Key.convertKey, in: defaults)
    }

    /// 記録したキーを検証し、受け付けられれば保存する。受け付けなければ保存せずに理由を返す。
    @discardableResult
    public static func recordConvertKey(keyCode: UInt16, modifiers: KeyModifiers,
                                        in defaults: UserDefaults = .standard) -> Result<ConvertKey, ConvertKey.Rejection> {
        let result = ConvertKey.validate(keyCode: keyCode, modifiers: modifiers)
        if case .success(let key) = result {
            setConvertKey(key, in: defaults)
        }
        return result
    }

    /// 単独で押した修飾キー（左右を区別）を変換キーとして保存する。
    @discardableResult
    public static func recordModifierKey(_ key: ModifierKey, in defaults: UserDefaults = .standard) -> ConvertKey {
        let convertKey = ConvertKey.modifierOnly(key)
        setConvertKey(convertKey, in: defaults)
        return convertKey
    }

    /// 既定（Space）に戻す。
    public static func resetConvertKey(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Settings.Key.convertKey)
    }


    public static func setFullWidthDigits(_ on: Bool, in defaults: UserDefaults = .standard) {
        replace(on, forKey: Settings.Key.fullWidthDigits, in: defaults)
    }

    /// 前の値を消してから書く。UserDefaults は、前の値と「等しい」（整数 1 と真偽値 true など）と書き込みを省くので、
    /// `defaults write … -int 1` のような型の合わない値が残り続けないようにする。
    private static func replace(_ value: Any, forKey key: String, in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
        defaults.set(value, forKey: key)
    }

    /// 候補数を 1〜32 に丸めて保存し、保存した値を返す。
    @discardableResult
    public static func setCandidateCount(_ n: Int, in defaults: UserDefaults = .standard) -> Int {
        let clamped = min(max(n, Settings.candidateCountRange.lowerBound), Settings.candidateCountRange.upperBound)
        replace(clamped, forKey: Settings.Key.candidateCount, in: defaults)
        return clamped
    }

    public static func setModelPath(_ path: String, in defaults: UserDefaults = .standard) {
        replace(path, forKey: Settings.Key.modelPath, in: defaults)
    }

    /// モデルファイルの警告（ファイルがない・フォルダーである）。問題なければ nil。
    public static func modelPathWarning(_ settings: Settings, fileManager: FileManager = .default) -> String? {
        var isDir: ObjCBool = false
        let path = settings.expandedModelPath
        if !fileManager.fileExists(atPath: path, isDirectory: &isDir) {
            return "モデルファイルがありません: \(path)"
        }
        if isDir.boolValue {
            return "モデルのパスがフォルダーです: \(path)"
        }
        return nil
    }
}
