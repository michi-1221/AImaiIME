import AIMECore
import Cocoa
import InputMethodKit

/// 入力コントローラー。ローマ字を未確定文字（setMarkedText、下線付き）として持ち、変換キー（設定 `convertKey`、既定 Space）で
/// 変換して差し替える。状態遷移は AIMECore の `MarkedComposer`。
/// 未確定文字がないときの変換キー・Tab は必ずアプリに通す。
///
/// 変換キーが修飾キーの単独押し（`rightcmd` など）のときは、flagsChanged で見分ける（AIMECore の `ModifierTap`）。
@objc(AIMEInputController)
final class AIMEInputController: IMKInputController {
    /// 未確定文字の状態
    private var composer = MarkedComposer()
    /// 変換キーが修飾キーの単独押しのとき、その押して離す操作の判定
    private var modifierTap = ModifierTap()

    private typealias Client = IMKTextInput & NSObjectProtocol

    override func recognizedEvents(_ sender: Any!) -> Int {
        // マウスクリックは未確定文字の確定に使う。flagsChanged は、変換キーを修飾キーの単独押しにしたときの判定に使う
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return Int(mask.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // フォーカスが来た。残っている未確定文字は捨てずに確定する（deactivateServer を挟まずに来ることがあるため。
        // client が取れないときは未確定文字の状態を残す）
        commitMarked(client: sender as? Client)
        modifierTap.cancel()
    }

    override func deactivateServer(_ sender: Any!) {
        commitMarked(client: sender as? Client)
        modifierTap.cancel()
        super.deactivateServer(sender)
    }

    /// 入力メニュー（メニューバーの入力ソースのメニュー）に足す項目。
    override func menu() -> NSMenu! {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AImai IME の設定…", action: #selector(showSettings(_:)), keyEquivalent: ""))
        return menu
    }

    /// 設定ウィンドウを開く（すでに開いていれば前面に出す）。開く前に未確定文字を確定する
    /// （ウィンドウが前面に出るとアプリのフォーカスが外れるので、入力中の状態を残さない）。
    @objc func showSettings(_ sender: Any?) {
        commitMarked(client: client())
        SettingsWindowController.shared.show()
    }

    /// 入力ソースの切り替え・フォーカスが外れたときなどに呼ばれる。表示中の未確定文字を確定する。
    override func commitComposition(_ sender: Any!) {
        commitMarked(client: sender as? Client)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let client = sender as? Client
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // クリック: 未確定文字を確定する
            commitMarked(client: client)
            modifierTap.cancel()
            return false
        case .flagsChanged:
            return handleFlagsChanged(event, client: client)
        case .keyDown:
            break
        default:
            return false
        }
        modifierTap.keyDown()
        guard let client else { return false }

        let mods = KeyModifiers(modifierFlagsRawValue: event.modifierFlags.rawValue)
        let stroke = KeyStroke(keyCode: event.keyCode, modifiers: mods, characters: event.characters)
        let settings = Settings.load()
        SettingsWarning.report(settings.invalidValues)
        return handleMarked(stroke, convertKey: settings.convertKey, settings: settings, client: client)
    }

    /// 修飾キーの変化。変換キーが修飾キーの単独押しのときだけ見る（単独で押して離したら、変換キーが押されたものとして処理する）。
    private func handleFlagsChanged(_ event: NSEvent, client: Client?) -> Bool {
        let settings = Settings.load()
        guard let target = settings.convertKey.modifierKey else {
            modifierTap.cancel()
            return false
        }
        if modifierTap.target != target { modifierTap = ModifierTap(target: target) }
        let times = SystemInputTimes.current()
        guard modifierTap.flagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue,
                                       timestamp: event.timestamp, lastKeyDownAt: times.lastKeyDownAt,
                                       lastMouseDownAt: times.lastMouseDownAt, lastScrollAt: times.lastScrollAt) != nil,
              let client else { return false }
        // 変換キーが押されたものとして処理する（擬似的な打鍵。通す先がないので結果は使わない）
        let stroke = KeyStroke(keyCode: target.keyCode, modifiers: [], characters: nil)
        _ = handleMarked(stroke, convertKey: settings.convertKey, settings: settings, client: client)
        return false // 修飾キーの離しはそのままアプリに通す
    }

    /// 範囲のテキストをクライアントから取る。取れない・要求と違う長さのときは nil。
    private func fetcher(_ client: Client) -> (NSRange) -> String? {
        { range in
            guard let attr = client.attributedSubstring(from: range), attr.length == range.length else { return nil }
            return attr.string
        }
    }

    // MARK: - 未確定文字

    /// キーを処理する。キーを消費したら true。
    private func handleMarked(_ stroke: KeyStroke, convertKey: ConvertKey, settings: Settings, client: Client) -> Bool {
        let key = ComposerKey.classify(stroke, convertKey: convertKey)
        let output = composer.handle(key, convert: { romaji in
            guard let converter = EngineHolder.shared.converter(settings: settings) else {
                log.info("変換エンジンが使えないため、ローマ字のまま残します")
                return nil
            }
            let context = self.leftContext(client: client)
            do {
                let text = try converter.convert(input: romaji, leftContext: context, options: settings.postProcess)
                return (text, context)
            } catch {
                log.error("変換結果を使えないため、ローマ字のまま残します: \(String(describing: error), privacy: .public)")
                return nil
            }
        }, candidates: { romaji, context, first in
            guard let converter = EngineHolder.shared.converter(settings: settings) else { return nil }
            do {
                return try converter.candidates(input: romaji, leftContext: context, first: first,
                                                count: settings.candidateCount, options: settings.postProcess)
            } catch {
                log.error("候補を求められません: \(String(describing: error), privacy: .public)")
                return nil
            }
        })
        apply(output, client: client)
        return !output.passKey
    }

    private func apply(_ output: ComposerOutput, client: Client) {
        if let text = output.commit {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if let marked = output.marked {
            let attributed = NSAttributedString(string: marked, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            client.setMarkedText(attributed, selectionRange: NSRange(location: (marked as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// 表示中の未確定文字を確定する。client が取れないときは、未確定文字の状態を残す（失わない）。
    private func commitMarked(client: Client?) {
        guard let client, let text = composer.commitAll() else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 未確定文字の直前の確定済みテキスト（最大 40 スカラー）。取れないアプリでは空（エラーにしない）。
    private func leftContext(client: Client) -> String {
        LeftContext.get(markedRange: client.markedRange(), selectedRange: client.selectedRange(), fetch: fetcher(client))
    }
}
