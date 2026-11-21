import CoreGraphics
import Foundation

/// システム全体の、最後の keyDown・マウスダウン・スクロールの絶対時刻（`NSEvent.timestamp` と同じ、起動からの秒）。
/// `ModifierTap` が、IME に届かなかったショートカット・クリック・スクロールを見分けるのに使う。
struct SystemInputTimes {
    var lastKeyDownAt: TimeInterval
    var lastMouseDownAt: TimeInterval
    var lastScrollAt: TimeInterval

    static func current() -> SystemInputTimes {
        let now = ProcessInfo.processInfo.systemUptime
        func at(_ type: CGEventType) -> TimeInterval {
            now - CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
        }
        return SystemInputTimes(
            lastKeyDownAt: at(.keyDown),
            lastMouseDownAt: max(at(.leftMouseDown), at(.rightMouseDown), at(.otherMouseDown)),
            lastScrollAt: at(.scrollWheel))
    }
}
