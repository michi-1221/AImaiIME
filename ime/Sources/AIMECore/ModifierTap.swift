import Foundation

/// 単独で1回押して使える修飾キー（左右を区別する）。
public enum ModifierKey: CaseIterable, Equatable {
    case rightCommand, leftCommand, rightOption, leftOption, rightControl, leftControl, rightShift, leftShift

    /// キー番号（kVK_*）
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightControl: return 62
        case .leftControl: return 59
        case .rightShift: return 60
        case .leftShift: return 56
        }
    }

    /// `NSEvent.modifierFlags` の下位ビット（デバイス依存。NX_DEVICE*KEYMASK）
    var deviceBit: UInt {
        switch self {
        case .leftControl: return 0x1
        case .leftShift: return 0x2
        case .rightShift: return 0x4
        case .leftCommand: return 0x8
        case .rightCommand: return 0x10
        case .leftOption: return 0x20
        case .rightOption: return 0x40
        case .rightControl: return 0x2000
        }
    }

    static let allDeviceBits: UInt = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000

    /// 修飾キーの種類ごとのフラグ（左右共通）
    var familyFlag: UInt {
        switch self {
        case .rightCommand, .leftCommand: return KeyModifiers.nsCommand
        case .rightOption, .leftOption: return KeyModifiers.nsOption
        case .rightControl, .leftControl: return KeyModifiers.nsControl
        case .rightShift, .leftShift: return KeyModifiers.nsShift
        }
    }

    static let allFamilyFlags: UInt = KeyModifiers.nsCommand | KeyModifiers.nsOption | KeyModifiers.nsControl | KeyModifiers.nsShift

    /// 正規の書式（`defaults write … convertKey rightcmd` など）
    public var name: String {
        switch self {
        case .rightCommand: return "rightcmd"
        case .leftCommand: return "leftcmd"
        case .rightOption: return "rightoption"
        case .leftOption: return "leftoption"
        case .rightControl: return "rightctrl"
        case .leftControl: return "leftctrl"
        case .rightShift: return "rightshift"
        case .leftShift: return "leftshift"
        }
    }

    /// 表示用（例: "右⌘"）
    public var displayName: String {
        switch self {
        case .rightCommand: return "右⌘"
        case .leftCommand: return "左⌘"
        case .rightOption: return "右⌥"
        case .leftOption: return "左⌥"
        case .rightControl: return "右⌃"
        case .leftControl: return "左⌃"
        case .rightShift: return "右⇧"
        case .leftShift: return "左⇧"
        }
    }

    public init?(keyCode: UInt16) {
        guard let k = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = k
    }

    /// 書式から。別名も受け付ける（`rightcommand`、`rightopt`、`rightalt`、`rightcontrol`）。
    public init?(name: String) {
        let n = name.lowercased()
        let side: String
        let rest: String
        if n.hasPrefix("right") { side = "right"; rest = String(n.dropFirst(5)) }
        else if n.hasPrefix("left") { side = "left"; rest = String(n.dropFirst(4)) }
        else { return nil }
        let right = side == "right"
        switch rest {
        case "cmd", "command": self = right ? .rightCommand : .leftCommand
        case "option", "opt", "alt": self = right ? .rightOption : .leftOption
        case "ctrl", "control": self = right ? .rightControl : .leftControl
        case "shift": self = right ? .rightShift : .leftShift
        default: return nil
        }
    }
}

/// 修飾キーを「単独で1回押して離した」ことを見分ける。
///
/// 数えるのは、押して離すまでの間にほかのキー・クリック・スクロール・ほかの修飾キーがなく、0.5 秒以内に離したときだけ。
/// 時刻はすべて、イベントの時刻（`NSEvent.timestamp`。起動からの秒）で測る。IME の main スレッドが詰まって
/// 押したイベントと離したイベントが続けて処理されても、実際に押していた時間で判定するため。
/// IME に届かなかったキー（アプリが先に処理したメニューのショートカットなど）・クリック・スクロールは、
/// システム全体の最後の keyDown・マウスダウン・スクロールの時刻（絶対時刻）が押した時刻より後かで見分ける。
public struct ModifierTap: Equatable {
    /// 押している時間の上限（秒）。これより長く押していたら数えない。
    public static let maxHold: TimeInterval = 0.5

    /// 見る修飾キー。nil なら、どの修飾キーでもよい（変換キーの記録用）。
    public let target: ModifierKey?
    /// 今、単独で押している修飾キー
    public private(set) var armedKey: ModifierKey?
    private var pressedAt: TimeInterval = 0

    public init(target: ModifierKey? = nil) {
        self.target = target
    }

    public var armed: Bool { armedKey != nil }

    /// 修飾キーの変化（flagsChanged）。単独で押して離したとき、そのキーを返す。
    /// - Parameters:
    ///   - timestamp: このイベントの時刻（`NSEvent.timestamp`）。
    ///   - lastKeyDownAt: システム全体で最後の keyDown の時刻（`systemUptime - secondsSinceLastEventType`）。
    ///   - lastMouseDownAt: 同じく最後のマウスダウン。
    ///   - lastScrollAt: 同じく最後のスクロール（⌃+スクロールのズーム、⇧+スクロールの横スクロールなど）。
    ///   どれかが押した時刻より後なら、押している間にあったとみなして数えない。
    public mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt, timestamp: TimeInterval,
                                      lastKeyDownAt: TimeInterval = -.infinity,
                                      lastMouseDownAt: TimeInterval = -.infinity,
                                      lastScrollAt: TimeInterval = -.infinity) -> ModifierKey? {
        guard let key = ModifierKey(keyCode: keyCode), target == nil || target == key else {
            armedKey = nil // ほかの修飾キーが動いた
            return nil
        }
        // デバイスごとのビットが取れるときはそれで押した・離したを見分ける（左右の区別もできる）
        let hasDeviceInfo = rawFlags & 0xFFFF != 0
        let pressed = hasDeviceInfo ? rawFlags & key.deviceBit != 0 : rawFlags & key.familyFlag != 0
        if pressed {
            let others = (ModifierKey.allDeviceBits & ~key.deviceBit) | (ModifierKey.allFamilyFlags & ~key.familyFlag)
            armedKey = rawFlags & others == 0 ? key : nil
            pressedAt = timestamp
            return nil
        }
        guard armedKey == key else {
            armedKey = nil
            return nil
        }
        armedKey = nil
        guard timestamp - pressedAt <= Self.maxHold,
              lastKeyDownAt <= pressedAt, lastMouseDownAt <= pressedAt, lastScrollAt <= pressedAt else { return nil }
        return key
    }

    /// ほかのキーが押された（⌘C など）。
    public mutating func keyDown() { armedKey = nil }

    /// マウスのクリック・フォーカスの切り替えなど。
    public mutating func cancel() { armedKey = nil }
}
