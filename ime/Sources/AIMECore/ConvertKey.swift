import Foundation

/// 変換キー（設定 `convertKey`。未確定文字モードと直接モードで共通。既定は `space`）。
///
/// 書式: 修飾キーとキーを `+` でつなぐ（大文字・小文字は区別しない、空白は無視）。例: `space`、`tab`、`option+space`、`ctrl+j`、`f13`。
/// - 修飾キー: `cmd`（`command`）、`ctrl`（`control`）、`opt`（`option`、`alt`）、`shift`
/// - キー: `space`、`tab`、`return`（`enter`）、`esc`（`escape`）、`f1`〜`f20`、`a`〜`z`、`0`〜`9`
/// - 打鍵と区別できないものは受け付けない:
///   - `a`〜`z`・`0`〜`9` は、`cmd`・`ctrl`・`opt` のどれかが必要（修飾キーなしや `shift` だけでは文字の入力になる）
///   - `return`・`esc` は、修飾キーが必要（そのままでは改行・確定・取り消しの操作と区別できない）
///   - `space`・`tab` は修飾キーなしでも使える（変換できないときはそのままアプリに通す）
/// - キー番号は US 配列（ANSI）のもの。
public struct ConvertKey: Equatable, CustomStringConvertible {
    public let keyCode: UInt16
    public let modifiers: KeyModifiers
    /// 正規化した書式（例: "ctrl+j"）
    public let description: String

    public static let tab = ConvertKey(keyCode: KeyStroke.Code.tab, modifiers: [], description: "tab")
    public static let space = ConvertKey(keyCode: KeyStroke.Code.space, modifiers: [], description: "space")
    /// 既定の変換キー
    public static let defaultKey = ConvertKey.space

    /// キー名 → (キー番号, 種類)
    private enum Kind { case named, needsModifier, character }
    private static let keys: [String: (UInt16, Kind)] = {
        var k: [String: (UInt16, Kind)] = [
            "tab": (48, .named),
            "space": (49, .named),
            "return": (36, .needsModifier), "enter": (36, .needsModifier),
            "esc": (53, .needsModifier), "escape": (53, .needsModifier),
        ]
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fkeys.enumerated() { k["f\(i + 1)"] = (code, .named) }
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        ]
        for (ch, code) in letters { k[String(ch)] = (code, .character) }
        return k
    }()

    private static let modifierNames: [String: KeyModifiers] = [
        "cmd": .command, "command": .command,
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift,
    ]

    /// キー名 → キー番号（テストで Carbon の kVK_* と照合するため。別名も含む）
    public static var keyCodesByName: [String: UInt16] { keys.mapValues(\.0) }

    /// 書式を解析する。不正な値・打鍵と区別できない値なら nil。
    public static func parse(_ text: String?) -> ConvertKey? {
        guard let text else { return nil }
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty, let (code, _) = keys[keyName] else { return nil }
        var mods: KeyModifiers = []
        for name in parts.dropLast() {
            guard let m = modifierNames[name], !mods.contains(m) else { return nil }
            mods.insert(m)
        }
        return try? validate(keyCode: code, modifiers: mods).get()
    }

    /// 受け付けない理由。
    public enum Rejection: Error, Equatable, CustomStringConvertible {
        /// 変換キーにできないキー（記号キー、矢印など）
        case unsupportedKey
        /// return・esc は修飾キーが必要
        case needsModifier(String)
        /// 文字・数字のキーは ⌘・⌃・⌥ のどれかが必要
        case needsCommandControlOption(String)

        public var description: String {
            switch self {
            case .unsupportedKey:
                return "このキーは変換キーにできません（使えるのは Space、Tab、Return、Esc、F1〜F20、A〜Z、0〜9）"
            case .needsModifier(let key):
                return "\(key) だけでは改行・確定・取り消しの操作と区別できません。修飾キー（⌘⌃⌥⇧）と組み合わせてください"
            case .needsCommandControlOption(let key):
                return "\(key) は文字の入力と区別できません。⌘・⌃・⌥ のどれかと組み合わせてください（⇧ だけでは不可）"
            }
        }
    }

    /// キー番号と修飾キーの組み合わせを検証する（`parse` と同じ規則）。設定ウィンドウでのキー記録に使う。
    public static func validate(keyCode: UInt16, modifiers: KeyModifiers) -> Result<ConvertKey, Rejection> {
        guard let (name, kind) = canonicalName[keyCode] else { return .failure(.unsupportedKey) }
        let label = displayKeyName(name)
        switch kind {
        case .named:
            break
        case .needsModifier:
            if modifiers.isEmpty { return .failure(.needsModifier(label)) }
        case .character:
            if modifiers.intersection([.command, .control, .option]).isEmpty {
                return .failure(.needsCommandControlOption(label))
            }
        }
        let order: [(KeyModifiers, String)] = [(.command, "cmd"), (.control, "ctrl"), (.option, "option"), (.shift, "shift")]
        let desc = (order.filter { modifiers.contains($0.0) }.map(\.1) + [name]).joined(separator: "+")
        return .success(ConvertKey(keyCode: keyCode, modifiers: modifiers, description: desc))
    }

    /// キー番号 → 正規の名前（`return`・`esc` など、別名ではないもの）
    private static let canonicalName: [UInt16: (String, Kind)] = {
        var m: [UInt16: (String, Kind)] = [:]
        for (name, value) in keys where name != "enter" && name != "escape" {
            m[value.0] = (name, value.1)
        }
        return m
    }()

    private static func displayKeyName(_ name: String) -> String {
        switch name {
        case "tab": return "Tab"
        case "space": return "Space"
        case "return": return "Return"
        case "esc": return "Esc"
        default: return name.uppercased()
        }
    }

    /// 表示用の文字列（例: "⌃J"、"⌥Space"、"Tab"、"F13"）。修飾キーは macOS の順（⌃⌥⇧⌘）。
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let name = description.split(separator: "+").last.map(String.init) ?? ""
        return s + Self.displayKeyName(name)
    }

    /// アプリや macOS の操作と重なりうるときの注意（なければ nil）。
    public var conflictNote: String? {
        let name = description.split(separator: "+").last.map(String.init) ?? ""
        if modifiers == .control && name == "space" {
            return "⌃Space は macOS の「前の入力ソースを選択」と重なり、IME まで届かないことがあります。"
        }
        if modifiers == .shift && name == "return" {
            return "⇧Return は、チャット欄などの「Shift+Return で改行」と重なります。"
        }
        if modifiers == .shift && name == "space" {
            return "⇧Space は、一部のアプリのスクロールや全角空白の入力と重なることがあります。"
        }
        if modifiers.isEmpty && name == "space" {
            return "space: 英単語を空白で区切って打つと、空白のたびに直前の英字が変換されます。"
        }
        if modifiers.isEmpty && name == "tab" {
            return "Tab: 変換できるとき（直接モードでは英字の直後、未確定文字モードでは未確定文字があるとき）の Tab が変換に使われ、アプリの Tab（補完・字下げ・次の欄への移動）と重なります。"
        }
        if modifiers.contains(.command) {
            return "⌘ との組み合わせは、アプリのメニューのショートカットと重なることがあります。"
        }
        if modifiers == .control && (name == "a" || name == "e" || name == "k" || name == "f" || name == "b" || name == "n" || name == "p") {
            return "⌃\(name.uppercased()) は、テキスト欄やターミナルのカーソル移動・編集のショートカットと重なります。"
        }
        return nil
    }

    /// 書式を解析する。不正な値・未設定なら既定（`space`）。
    public static func parseOrDefault(_ text: String?) -> ConvertKey {
        parse(text) ?? .defaultKey
    }

    /// 打鍵がこの変換キーか（キー番号と修飾キー（⌘⌃⌥⇧）が完全に一致するとき）。
    public func matches(_ key: KeyStroke) -> Bool {
        key.keyCode == keyCode && key.modifiers == modifiers
    }
}
