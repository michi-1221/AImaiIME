import AIMECore
import Cocoa
import InputMethodKit

/// 入力コントローラー。設定 `inputMode` で2つの方式を切り替える。
///
/// 変換キーは両モード共通の設定 `convertKey`（既定 Space）。
/// - `marked`（既定）: どこでも未確定文字。ローマ字を未確定文字（setMarkedText）として持ち、変換キーで変換して差し替える
///   （状態遷移は AIMECore の `MarkedComposer`）。未確定文字がないときの変換キー・Tab は必ずアプリに通す。
/// - `direct`: 直接モード。打鍵はすぐ確定し、変換キーでカーソル直前のローマ字列を置き換える。
///   置き換えに対応していない入力欄（判定は AIMECore の `FieldModeState`、`BufferConsistency`、`AppModeMemory`）では、
///   未確定文字の方式で動かす（変換キーは同じ）。
///   クライアントがカーソル直前のテキストを返せないときに備えて、打鍵を `TypingBuffer` に記録する。
@objc(AIMEInputController)
final class AIMEInputController: IMKInputController {
    /// 未確定文字の状態（両方のモードで使う）
    private var composer = MarkedComposer()
    /// 直接モード: 打鍵バッファ・入力欄の方式・照合の状態（判定は AIMECore の `DirectInputState`）
    private var direct = DirectInputState()
    /// 直接モード: 変換キーを続けて押したときの候補送りの状態
    private var cycler = CandidateCycler()
    /// 直接モード: 置き換え・判定で失敗したアプリ（IME のプロセスが動いている間、全コントローラーで共有）
    private static var appMemory = AppModeMemory()

    private typealias Client = IMKTextInput & NSObjectProtocol

    override func recognizedEvents(_ sender: Any!) -> Int {
        // マウスクリックは、未確定文字の確定と、カーソル位置が変わった合図（打鍵バッファを空にする）に使う
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return Int(mask.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // フォーカスが来た: 新しい入力欄として扱い、直接モードならこの時点で方式を試す。
        // 残っている未確定文字は捨てずに確定する（deactivateServer を挟まずに来ることがあるため。
        // client が取れないときは未確定文字の状態を残す）
        let client = sender as? Client
        commitMarked(client: client)
        startField(client: client)
        cycler.end()
        if Settings.load().inputMode == .direct, let client {
            let method = direct.probe(IMKDirectClient(client))
            log.debug("入力欄の方式: \(String(describing: method), privacy: .public)")
        }
    }

    override func deactivateServer(_ sender: Any!) {
        commitMarked(client: sender as? Client)
        direct.buffer.reset()
        cycler.end()
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
        direct.buffer.reset()
        cycler.end()
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
            // クリック: 未確定文字を確定する。別の欄に移ったかもしれないので、方式の固定も解く
            commitMarked(client: client)
            cycler.end()
            startField(client: client)
            return false
        case .keyDown:
            break
        default:
            return false
        }
        guard let client else { return false }

        let mods = KeyModifiers(modifierFlagsRawValue: event.modifierFlags.rawValue)
        let stroke = KeyStroke(keyCode: event.keyCode, modifiers: mods, characters: event.characters,
                               selectedRange: client.selectedRange())
        let settings = Settings.load()
        SettingsWarning.report(settings.invalidValues)

        switch settings.inputMode {
        case .marked:
            // どこでも未確定文字。未確定文字がないときは、変換キー・Tab を含めてアプリに通す
            return handleMarked(stroke, convertKey: settings.convertKey, settings: settings, client: client)
        case .direct:
            return handleDirect(stroke, settings: settings, client: client)
        }
    }

    // MARK: - 直接モード

    /// 新しい入力欄として方式の判定をやり直す。そのアプリで前に失敗していたら、最初から未確定文字の方式にする。
    private func startField(client: Client?) {
        direct.startField(bundleID: client?.bundleIdentifier(), memory: Self.appMemory)
    }

    /// この入力欄（とアプリ）を、置き換えに対応していないとして未確定文字の方式にする。確定済みの文字は書き換えない。
    private func markFieldUnsupported(client: Client, reason: String) {
        log.info("\(reason, privacy: .public)。この入力欄（とアプリ）は未確定文字の方式にします")
        direct.markUnsupported(bundleID: client.bundleIdentifier(), memory: &Self.appMemory)
        cycler.end()
    }

    private func handleDirect(_ stroke: KeyStroke, settings: Settings, client: Client) -> Bool {
        let convertKey = settings.convertKey
        // 照合 → 振り分け → 照合済みでない欄では置き換えない（AIMECore の DirectInputState.decide）
        let (decision, detectedMismatch) = direct.decide(stroke, convertKey: convertKey, composerIsEmpty: composer.isEmpty,
                                                         client: IMKDirectClient(client), memory: &Self.appMemory)
        if detectedMismatch {
            log.info("打鍵バッファとクライアントのテキストが食い違いました。この入力欄（とアプリ）は未確定文字の方式にします")
            cycler.end()
        }
        switch decision {
        case .marked:
            cycler.end()
            return handleMarked(stroke, convertKey: convertKey, settings: settings, client: client)
        case .convert:
            if handleConvertKey(client: client, settings: settings) { return true }
        case .passThrough:
            break
        }
        // 変換キー以外の打鍵（または通した変換キー）で候補送りは終わる（その時点の内容で確定）。
        // 変換キーが Tab 以外のときの Tab や、ローマ字列がないときの Space（変換キーが space のとき）、
        // 照合済みでない欄での変換キーも、ここでそのままアプリに通る
        cycler.end()

        // アプリへそのまま通す打鍵を打鍵バッファに記録する（分類と更新は AIMECore の TypingBuffer.record）
        direct.record(stroke)
        return false
    }

    /// 範囲のテキストをクライアントから取る。取れない・要求と違う長さのときは nil。
    private func fetcher(_ client: Client) -> (NSRange) -> String? {
        { range in
            guard let attr = client.attributedSubstring(from: range), attr.length == range.length else { return nil }
            return attr.string
        }
    }

    /// 変換キーの処理。置き換えたら true（キーを消費する）。置き換えなかったら false（キーをアプリへ通す）。
    private func handleConvertKey(client: Client, settings: Settings) -> Bool {
        switch cycler.tab(selectedRange: client.selectedRange(), fetch: fetcher(client)) {
        case .advance:
            return advanceCandidate(client: client, settings: settings)
        case .passThrough:
            log.debug("置き換えた範囲を確かめられないため、候補送りをせず変換キーをそのまま通します")
            return false
        case .newConversion:
            return convertBeforeCursor(client: client, settings: settings)
        }
    }

    /// 置き換えた直後に、新しい範囲の実テキストが入れた文字列と一致するかを確かめる。
    /// 一致しない・確かめられないときは、候補送りを終え、打鍵バッファを「前のテキストがわからない」状態（空）にし、
    /// この入力欄は未確定文字の方式にする。文書を直そうとはしない（何もしないのが安全側）。
    private func verifyInserted(_ text: String, at location: Int, client: Client) -> Bool {
        let range = NSRange(location: location, length: text.utf16.count)
        if let actual = fetcher(client)(range), Array(actual.utf16) == Array(text.utf16) {
            return true
        }
        markFieldUnsupported(client: client, reason: "置き換えた結果を確かめられませんでした")
        return false
    }

    /// 候補送り（2回目以降の変換キー）。候補を求められないときは候補送りを終えて変換キーを通す。
    private func advanceCandidate(client: Client, settings: Settings) -> Bool {
        guard let cycle = cycler.cycle else { return false }
        if !cycle.hasComputedCandidates {
            guard let converter = EngineHolder.shared.converter(settings: settings) else {
                log.info("変換エンジンが使えないため変換キーをそのまま通します")
                cycler.end()
                return false
            }
            do {
                let list = try converter.candidates(input: cycle.romaji, leftContext: cycle.leftContext,
                                                    first: cycle.candidates[0], count: settings.candidateCount,
                                                    options: settings.postProcess)
                cycler.setCandidates(list)
            } catch {
                log.error("候補を求められないため変換キーをそのまま通します: \(String(describing: error), privacy: .public)")
                cycler.end()
                return false
            }
        }
        guard let next = cycler.advance(), let current = cycler.cycle else { return false }
        client.insertText(next.text, replacementRange: next.range)
        guard verifyInserted(next.text, at: current.start, client: client) else { return true }
        direct.buffer.set(current.textBeforeRomaji + next.text, cursorLocation: current.start + next.text.utf16.count)
        return true
    }

    /// 新規変換（1回目の変換キー）。
    private func convertBeforeCursor(client: Client, settings: Settings) -> Bool {
        let fetch = fetcher(client)
        let plan: ReplacementPlanner.Plan
        switch ReplacementPlanner.outcome(selectedRange: client.selectedRange(), buffer: direct.buffer, fetch: fetch) {
        case .plan(let p):
            plan = p
        case .nothingToConvert:
            return false
        case .textUnavailable:
            // 前のテキストが取れずローマ字列を切り出せなかった: この入力欄は以後、未確定文字の方式にする。
            // この変換キーはそのまま通す（すでに確定した文字は書き換えない）
            markFieldUnsupported(client: client, reason: "前のテキストを取得できないため変換キーをそのまま通します")
            return false
        }
        if plan.usedBuffer {
            log.debug("クライアントからテキストを取得できないため打鍵バッファを使います")
        }

        guard let converter = EngineHolder.shared.converter(settings: settings) else {
            log.info("変換エンジンが使えない（読み込み中または読み込み失敗）ため変換キーをそのまま通します")
            return false
        }
        let output: String
        do {
            output = try converter.convert(input: plan.romaji, leftContext: plan.leftContext, options: settings.postProcess)
        } catch {
            log.error("変換結果を使えないため変換キーをそのまま通します: \(String(describing: error), privacy: .public)")
            return false
        }

        client.insertText(output, replacementRange: plan.replacementRange)
        guard verifyInserted(output, at: plan.replacementRange.location, client: client) else { return true }
        direct.buffer.set(plan.textBeforeRomaji + output,
                   cursorLocation: plan.replacementRange.location + output.utf16.count)
        cycler.start(CandidateCycle(romaji: plan.romaji, leftContext: plan.leftContext,
                                    textBeforeRomaji: plan.textBeforeRomaji,
                                    start: plan.replacementRange.location, first: output))
        return true
    }

    // MARK: - 未確定文字

    /// 未確定文字の方式でキーを処理する。キーを消費したら true。
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

/// IMK のクライアントを、AIMECore の `DirectTextClient` として使うための包み。
struct IMKDirectClient: DirectTextClient {
    let client: IMKTextInput & NSObjectProtocol

    init(_ client: IMKTextInput & NSObjectProtocol) {
        self.client = client
    }

    var selectedRange: NSRange? {
        let r = client.selectedRange()
        return r.location == NSNotFound ? nil : r
    }

    func text(in range: NSRange) -> String? {
        guard let attr = client.attributedSubstring(from: range), attr.length == range.length else { return nil }
        return attr.string
    }

    var bundleID: String? { client.bundleIdentifier() }
}
