import Foundation

/// 直接モードで、クライアントがカーソル直前のテキストを返せないときの代替として、
/// IME が見た打鍵からカーソル直前のテキストを推定するバッファ。
///
/// - 打鍵のたびにカーソル位置（`selectedRange().location`、UTF-16 単位）を記録し、
///   次の打鍵のときに位置が「前の位置 + 変化した UTF-16 長」になっていなければ空にする
///   （クリック・Undo・ペースト・単語単位の削除・欄の切り替えなどをまとめて検出する）。
/// - 印字可能な文字の入力は末尾に足す。Delete（後退）は末尾を1文字消す。
/// - そのほかカーソル位置や直前のテキストがわからなくなる操作では空にする（`record(_:)` を参照）。
/// - 空にしたあと途中から打ち始めた場合、バッファの先頭より前に何があるかはわからない。
///   それを `knowsPrecedingText` で表す。
public struct TypingBuffer: Equatable {
    /// 保持する最大文字数。古い側から捨てる。
    public let capacity: Int
    public private(set) var text: String = ""
    /// 次の打鍵のときにあるはずのカーソル位置。nil は「記録なし」（`text` は空）。
    public private(set) var expectedLocation: Int?
    /// バッファの先頭より前のテキストとの境目がわかっているか。
    /// 文書の先頭（位置 0）から打ち始めたとき・変換で置き換えたあとは true。
    /// 空にしたあと途中から打ち始めたとき・古い側を捨てたときは false。
    public private(set) var knowsPrecedingText = false

    public init(capacity: Int = 1024) {
        self.capacity = capacity
    }

    /// 打鍵を記録する前に呼ぶ。カーソル位置が記録と違えば（または取得できなければ）空にする。
    public mutating func sync(cursorLocation: Int?) {
        guard let loc = cursorLocation else {
            reset()
            return
        }
        if let expected = expectedLocation, expected != loc {
            reset()
        }
    }

    /// `cursorLocation`（入力前のカーソル位置）に `s` が入力された。
    public mutating func append(_ s: String, cursorLocation: Int) {
        if expectedLocation == nil {
            // 記録なしからの打ち始め: 文書の先頭なら前には何もない
            knowsPrecedingText = cursorLocation == 0
        }
        text += s
        if text.count > capacity {
            text = String(text.suffix(capacity))
            knowsPrecedingText = false
        }
        expectedLocation = cursorLocation + s.utf16.count
    }

    /// `cursorLocation`（削除前のカーソル位置）で後退削除された。
    public mutating func deleteBackward(cursorLocation: Int) {
        guard let last = text.last else {
            reset() // 何が消えたかわからない
            return
        }
        text.removeLast()
        expectedLocation = cursorLocation - String(last).utf16.count
    }

    /// 変換で置き換えたあとの状態にする（境目は変換時に確かめているので、わかっているものとする）。
    public mutating func set(_ newText: String, cursorLocation: Int) {
        text = String(newText.suffix(capacity))
        knowsPrecedingText = text.count == newText.count
        expectedLocation = cursorLocation
    }

    public mutating func reset() {
        text = ""
        expectedLocation = nil
        knowsPrecedingText = false
    }
}

extension TypingBuffer {
    /// アプリへそのまま通す打鍵を記録する（打鍵の分類とバッファの更新）。
    public mutating func record(_ key: KeyStroke) {
        // 前の打鍵から位置がずれていれば（クリック・Undo・ペースト・欄の切り替えなど）空にする。
        // 範囲選択中・位置を取得できないときも空にする。
        var location: Int?
        if let sel = key.selectedRange, sel.location != NSNotFound, sel.length == 0 {
            location = sel.location
        }
        sync(cursorLocation: location)
        guard let location else { return } // sync で空になっている

        if key.modifiers.contains(.command) || key.modifiers.contains(.control) {
            reset() // ⌘/⌃ のショートカットは何が起きるかわからない
            return
        }
        switch key.keyCode {
        case KeyStroke.Code.deleteBackward:
            if key.modifiers.contains(.option) {
                reset() // 単語単位の削除
            } else {
                deleteBackward(cursorLocation: location)
            }
            return
        case KeyStroke.Code.returnKey, KeyStroke.Code.keypadEnter, KeyStroke.Code.escape, KeyStroke.Code.tab:
            // 改行・確定・フォーカス移動などアプリごとに結果が違うので空にする
            reset()
            return
        case let k where KeyStroke.Code.cursorMoving.contains(k):
            reset()
            return
        default:
            break
        }
        guard let chars = key.characters, !chars.isEmpty else {
            reset()
            return
        }
        // 制御文字やファンクションキー（U+F700〜U+F8FF）は記録しない（何が起きるかわからないので空にする）
        let printable = chars.unicodeScalars.allSatisfy { s in
            s.value >= 0x20 && s.value != 0x7F && !(0xF700...0xF8FF).contains(s.value)
        }
        if printable {
            append(chars, cursorLocation: location)
        } else {
            reset()
        }
    }
}
