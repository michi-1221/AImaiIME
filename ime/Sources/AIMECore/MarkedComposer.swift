import Foundation

/// キーの種類（未確定文字の処理用）。
public enum ComposerKey: Equatable {
    /// 空白以外の ASCII 印字可能文字（ローマ字・数字・記号）
    case char(String)
    case space
    case backspace
    /// 変換キー（未確定文字モードでは Tab。直接モードの未確定文字では `directConvertKey`）
    case convert
    case enter
    case escape
    /// それ以外（矢印、⌘/⌃ との組み合わせ、変換キーでない Tab、Option+Delete、ASCII 以外の文字など）
    case other

    /// 打鍵を分類する。
    /// - Parameter convertKey: 変換キー（既定は Tab）。これに一致する打鍵は `.convert`。変換キーが Tab でないとき、Tab は `.other`。
    public static func classify(_ key: KeyStroke, convertKey: ConvertKey = .tab) -> ComposerKey {
        if convertKey.matches(key) { return .convert }
        if key.modifiers.contains(.command) || key.modifiers.contains(.control) { return .other }
        switch key.keyCode {
        case KeyStroke.Code.tab:
            return .other
        case KeyStroke.Code.returnKey, KeyStroke.Code.keypadEnter:
            return .enter
        case KeyStroke.Code.escape:
            return .escape
        case KeyStroke.Code.deleteBackward:
            return key.modifiers.contains(.option) ? .other : .backspace
        case let k where KeyStroke.Code.cursorMoving.contains(k):
            return .other
        default:
            break
        }
        guard let chars = key.characters, !chars.isEmpty else { return .other }
        if chars == " " { return .space }
        if chars.unicodeScalars.allSatisfy(RomajiExtractor.isRomajiScalar) { return .char(chars) }
        return .other
    }
}

/// 1回のキー処理の結果（クライアントへの操作）。
public struct ComposerOutput: Equatable {
    /// 先に確定する文字列（insertText）。nil なら確定しない。
    public var commit: String?
    /// 新しく表示する未確定文字（setMarkedText）。nil なら変えない。空文字列なら未確定文字を消す。
    public var marked: String?
    /// キーをアプリへ通すか（false なら IME が消費する）。
    public var passKey: Bool

    public init(commit: String? = nil, marked: String? = nil, passKey: Bool = false) {
        self.commit = commit
        self.marked = marked
        self.passKey = passKey
    }

    public static let pass = ComposerOutput(passKey: true)
    public static let consume = ComposerOutput()
}

/// 未確定文字の状態遷移（ふつうの日本語 IME と同じ考え方）。
///
/// 未確定文字がないとき（何も打っていない・確定した直後）は、変換キー（Tab など）を含むすべてのキーをアプリに通す。
/// 未確定文字がある間の変換キーは IME が受け取る。
///
/// 状態:
/// - 空: 未確定文字なし
/// - 入力中: ローマ字を未確定文字として持つ
/// - 変換済み: 変換結果（または候補送り中の候補）を未確定文字として表示している
public struct MarkedComposer: Equatable {
    /// 入力中のローマ字（空なら未確定文字なし）
    public private(set) var romaji = ""
    /// 変換済みなら候補送りの状態（表示中は `cycle.currentText`）
    public private(set) var cycle: CandidateCycle?

    public init() {}

    public var isEmpty: Bool { romaji.isEmpty }

    /// 表示中の未確定文字
    public var displayText: String { cycle?.currentText ?? romaji }

    /// 変換する。失敗したら nil。成功したら（変換結果, 使った左文脈）。
    public typealias Convert = (_ romaji: String) -> (text: String, leftContext: String)?
    /// 候補（先頭は1回目の結果）を求める。失敗したら nil。
    public typealias Candidates = (_ romaji: String, _ leftContext: String, _ first: String) -> [String]?

    public mutating func handle(_ key: ComposerKey, convert: Convert, candidates: Candidates) -> ComposerOutput {
        if romaji.isEmpty {
            // 空: 文字だけを未確定文字として持ち始める。それ以外（変換キー・Backspace を含む）はアプリに通す
            if case .char(let c) = key {
                romaji = c
                return ComposerOutput(marked: romaji)
            }
            return .pass
        }
        if let cycle {
            return handleConverted(key, cycle: cycle, candidates: candidates)
        }
        return handleTyping(key, convert: convert)
    }

    private mutating func handleTyping(_ key: ComposerKey, convert: Convert) -> ComposerOutput {
        switch key {
        case .char(let c):
            romaji += c
            return ComposerOutput(marked: romaji)
        case .backspace:
            romaji.removeLast()
            return ComposerOutput(marked: romaji)
        case .convert:
            guard let result = convert(romaji), !result.text.isEmpty else {
                // 失敗: ローマ字のまま残し、変換キーは消費する
                return .consume
            }
            cycle = CandidateCycle(romaji: romaji, leftContext: result.leftContext, first: result.text)
            return ComposerOutput(marked: result.text)
        case .enter:
            // 確定するだけ。Enter はアプリに送らない
            return ComposerOutput(commit: takeAll(), passKey: false)
        case .space, .escape, .other:
            // 確定してからキーを通す（変換前のローマ字なら Esc もそのまま確定して通す）
            return ComposerOutput(commit: takeAll(), passKey: true)
        }
    }

    private mutating func handleConverted(_ key: ComposerKey, cycle current: CandidateCycle,
                                          candidates: Candidates) -> ComposerOutput {
        switch key {
        case .convert:
            var c = current
            if !c.hasComputedCandidates {
                guard let list = candidates(c.romaji, c.leftContext, c.candidates[0]) else {
                    return .consume // 候補を求められない: 表示はそのまま、変換キーは消費する
                }
                c.setCandidates(list)
            }
            let next = c.advance().text
            cycle = c
            return ComposerOutput(marked: next)
        case .escape:
            // 変換結果を表示中なら、元のローマ字（未確定）に戻す
            cycle = nil
            return ComposerOutput(marked: romaji)
        case .enter:
            return ComposerOutput(commit: takeAll(), passKey: false)
        case .char(let ch):
            // 確定して、この文字から新しい未確定文字を始める
            let committed = takeAll()
            romaji = ch
            return ComposerOutput(commit: committed, marked: romaji)
        case .space, .backspace, .other:
            return ComposerOutput(commit: takeAll(), passKey: true)
        }
    }

    /// 表示中の未確定文字を確定する（入力ソースの切り替え・フォーカスが外れたとき・クリックなど）。
    /// 確定する文字列を返す（未確定文字がなければ nil）。
    public mutating func commitAll() -> String? {
        romaji.isEmpty ? nil : takeAll()
    }

    private mutating func takeAll() -> String {
        let text = displayText
        romaji = ""
        cycle = nil
        return text
    }
}
