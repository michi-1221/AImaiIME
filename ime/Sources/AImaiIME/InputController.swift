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

    /// 変換の見通し（手が止まったら変換結果を小さな窓に出す）の状態。判定は AIMECore の `ConversionPreview`
    private var preview = ConversionPreview()
    /// 見通しの変換を動かす裏のキュー（直列。モデルの同時実行は LlamaGenerator の lock が直列にする）
    private static let previewQueue = DispatchQueue(label: "dev.aimai.inputmethod.preview", qos: .userInitiated)

    /// 見通しの変換と変換キーの変換の結果の置き場（二重に変換しない）
    private static let sharedConversion = SharedConversion()

    deinit {
        // 窓を出したコントローラーが deactivateServer の前に消えても、窓を残さない
        let id = ObjectIdentifier(self)
        if Thread.isMainThread {
            PreviewPanel.shared.hide(ifOwnedBy: id)
        } else {
            DispatchQueue.main.async { PreviewPanel.shared.hide(ifOwnedBy: id) }
        }
    }


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
        PreviewPanel.shared.hide() // 持ち主にかかわらず、一度消す
        commitMarked(client: sender as? Client)
        modifierTap.cancel()
        updatePreview()
    }

    override func deactivateServer(_ sender: Any!) {
        commitMarked(client: sender as? Client)
        modifierTap.cancel()
        updatePreview()
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
        // JIS キーボードの「英数」（102）と「かな」（104）は、文字として空白を持って届くことがある。
        // 文字を入力するキーではないので、未確定文字があれば確定し、キーはアプリに渡さない（空白が入らないように）
        if event.keyCode == 102 || event.keyCode == 104 {
            commitMarked(client: client)
            return true
        }

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
            // 見通しを出した時点から未確定文字が変わっていなければ、その結果をそのまま使う（もう一度モデルを動かさない）
            if let reused = self.preview.reusable(for: romaji) {
                return (reused.text, reused.leftContext)
            }
            guard let converter = EngineHolder.shared.converter(settings: settings) else {
                log.info("変換エンジンが使えないため、ローマ字のまま残します")
                return nil
            }
            let context = self.leftContext(client: client)
            do {
                // 見通しの変換が裏で動いている最中なら、その終わりを待ち、同じ入力の結果があればそれを使う（二重に変換しない）
                let key = SharedConversion.Key(romaji: romaji, leftContext: context, settings: settings.conversionSignature)
                let text = try Self.sharedConversion.run(key: key) {
                    try converter.convert(input: romaji, leftContext: context, options: settings.postProcess)
                }
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
        updatePreview()
        return !output.passKey
    }

    // MARK: - 変換の見通し

    /// 未確定文字が変わったかもしれないときに呼ぶ。窓を消す・タイマーを予約する判定は `ConversionPreview.update`。
    private func updatePreview() {
        let typing = composer.cycle == nil && !composer.isEmpty ? composer.romaji : nil
        let action = preview.update(typing: typing)
        if action.hideWindow { PreviewPanel.shared.hide() }
        if let generation = action.scheduleGeneration {
            DispatchQueue.main.asyncAfter(deadline: .now() + ConversionPreview.delay) { [weak self] in
                self?.previewTimerFired(generation: generation)
            }
        }
    }

    /// 1.0 秒、未確定文字が変わらなかった: 変換を裏で動かし、結果が出たとき世代が同じなら窓を出す。
    private func previewTimerFired(generation: Int) {
        guard let romaji = preview.timerFired(generation: generation) else { return }
        startPreviewConversion(generation: generation, romaji: romaji, attempts: 0)
    }

    /// エンジンが読み込み中なら、読み込みが終わるまで少し待って（最大 20 秒）、まだ同じ未確定文字なら見通しを出す。
    private func startPreviewConversion(generation: Int, romaji: String, attempts: Int) {
        guard preview.isCurrent(generation: generation, romaji: romaji) else { return }
        guard let client = client() as? Client else {
            log.debug("見通し: クライアントを取れないため出しません")
            return
        }
        let settings = Settings.load()
        guard let converter = EngineHolder.shared.converter(settings: settings) else {
            guard attempts < 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPreviewConversion(generation: generation, romaji: romaji, attempts: attempts + 1)
            }
            return
        }
        let context = leftContext(client: client)
        let key = SharedConversion.Key(romaji: romaji, leftContext: context, settings: settings.conversionSignature)
        Self.previewQueue.async {
            let text = try? Self.sharedConversion.run(key: key) {
                try converter.convert(input: romaji, leftContext: context, options: settings.postProcess)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 変換の間に打鍵があれば（世代が変わっていれば）捨てる。失敗（途中で切れた・空など）も出さない
                guard self.preview.finish(generation: generation, romaji: romaji, leftContext: context, text: text),
                      let text else {
                    log.debug("見通し: 打鍵で古くなったか、変換に失敗したため出しません")
                    return
                }
                guard let client = self.client() as? Client else {
                    log.debug("見通し: 変換後にクライアントを取れないため出しません")
                    return
                }
                self.showPreview(text, client: client, settings: settings)
            }
        }
    }

    private func showPreview(_ text: String, client: Client, settings: Settings) {
        // カーソルの下: 未確定文字の先頭の位置の行の矩形（画面座標）
        let marked = client.markedRange()
        let index = marked.location != NSNotFound ? marked.location : client.selectedRange().location
        let start = index == NSNotFound ? 0 : index
        var lineRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: start, lineHeightRectangle: &lineRect)
        if lineRect == .zero {
            // Electron（Orca など）はこの問い合わせに位置を返さないことがある。候補窓の位置に使う firstRect でも聞く
            var actual = NSRange(location: NSNotFound, length: 0)
            let length = marked.location != NSNotFound ? marked.length : 0
            lineRect = client.firstRect(forCharacterRange: NSRange(location: start, length: length), actualRange: &actual)
        }
        guard lineRect != .zero, lineRect.height > 0 else { // 位置を取れないアプリでは出さない
            log.debug("見通し: カーソルの位置を取れないため出しません（index=\(start, privacy: .public)）")
            return
        }
        PreviewPanel.shared.show(owner: self, text: text, hint: settings.convertKey.displayString + "で変換", lineRect: lineRect)
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
        defer { updatePreview() }
        guard let client, let text = composer.commitAll() else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }


    /// 未確定文字の直前の確定済みテキスト（最大 100 スカラー）。取れないアプリでは空（エラーにしない）。
    private func leftContext(client: Client) -> String {
        LeftContext.get(markedRange: client.markedRange(), selectedRange: client.selectedRange(), fetch: fetcher(client))
    }
}
