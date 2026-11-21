import Foundation

/// 修飾キー（AppKit に依存しないように独自に持つ）。
public struct KeyModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    /// `NSEvent.ModifierFlags` の rawValue から作る（AppKit に依存しないよう、ビットの値で受け取る）。
    /// ⌘⌃⌥⇧ だけを見る（Caps Lock、fn、テンキーなどの印は無視する）。
    public init(modifierFlagsRawValue raw: UInt) {
        var m: KeyModifiers = []
        if raw & Self.nsShift != 0 { m.insert(.shift) }
        if raw & Self.nsControl != 0 { m.insert(.control) }
        if raw & Self.nsOption != 0 { m.insert(.option) }
        if raw & Self.nsCommand != 0 { m.insert(.command) }
        self = m
    }

    // NSEvent.ModifierFlags の値（AppKit の定数と一致することをテストで確かめている）
    static let nsShift: UInt = 1 << 17
    static let nsControl: UInt = 1 << 18
    static let nsOption: UInt = 1 << 19
    static let nsCommand: UInt = 1 << 20
}

/// 1回の打鍵。
public struct KeyStroke: Equatable {
    /// キー番号（Carbon の kVK_*）
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// `NSEvent.characters`
    public var characters: String?
    /// 打鍵の時点のクライアントの `selectedRange()`。取得できなければ nil（直接モードの打鍵バッファで使う）。
    public var selectedRange: NSRange?

    public init(keyCode: UInt16, modifiers: KeyModifiers = [], characters: String?, selectedRange: NSRange? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
        self.selectedRange = selectedRange
    }

    public enum Code {
        public static let tab: UInt16 = 48
        public static let returnKey: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let deleteBackward: UInt16 = 51
        public static let escape: UInt16 = 53
        public static let space: UInt16 = 49
        /// カーソルを動かすキー: ← → ↓ ↑ Home End PageUp PageDown
        public static let cursorMoving: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
    }
}
