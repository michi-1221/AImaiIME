import AIMECore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 設定ウィンドウ（入力メニューの「AImai IME の設定…」から開く）。
///
/// - 変更はその場で UserDefaults（IME と同じドメイン・キー）に保存する。IME は次の打鍵で読み直すので、そこから反映される。
/// - 開くたびに UserDefaults から読み直す（`defaults write` で外から変えた値も表示に反映する）。
/// - この IME 自身の変換が働かないように、テキストを入力する欄は作らない（キーの記録は独自のビューで行い、
///   テキスト入力のクライアントにはならない）。
/// - IME のプロセスは `LSUIElement`（Dock に出ないアクセサリー）なので、`setActivationPolicy` は変えずに
///   `NSApp.activate()`（macOS 14 の API）で前面に出す。閉じたら、開く前に前面にあったアプリを前面に戻す。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let model = SettingsViewModel()
    /// 開く前に前面にあったアプリ（閉じたら前面に戻す）
    private var previousApp: NSRunningApplication?

    func show() {
        model.reload()
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "AImai IME の設定"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
            model.window = w
        }
        // すでに開いていて前面にあるときは、前面のアプリは自分なので覚え直さない
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        // 開く前に前面にあったアプリを前面に戻す（macOS 14 の協調アクティベーション: 先に譲ってから相手を前面にする）
        if let previousApp {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        previousApp = nil
    }
}

/// 設定ウィンドウの表示内容。読み書きは AIMECore の `Settings.load` / `SettingsEditor`。
final class SettingsViewModel: ObservableObject {
    @Published var inputMode: InputMode = .marked
    @Published var convertKey: ConvertKey = .defaultKey
    @Published var fullWidthDigits = false
    @Published var candidateCount = Settings.defaultCandidateCount
    @Published var modelPath = Settings.defaultModelPath
    /// 不正な値を既定値として表示しているときなどの警告
    @Published var warnings: [String] = []
    @Published var modelWarning: String?
    /// キーの記録の結果（受け付けなかった理由など）
    @Published var recordMessage: String?
    @Published var isRecording = false

    weak var window: NSWindow?
    private let defaults = UserDefaults.standard
    /// モデルファイルの確認の世代（古い確認の結果で上書きしないため）
    private var modelCheckGeneration = 0

    func reload() {
        let s = Settings.load(from: defaults)
        inputMode = s.inputMode
        convertKey = s.convertKey
        fullWidthDigits = s.postProcess.fullWidthDigits
        candidateCount = s.candidateCount
        modelPath = s.modelPath
        warnings = s.invalidValues
        checkModelFile(s)
    }

    /// モデルファイルの存在確認は、メインスレッドで行わず裏で行い、結果だけ反映する。
    private func checkModelFile(_ settings: AIMECore.Settings) {
        modelCheckGeneration += 1
        let generation = modelCheckGeneration
        DispatchQueue.global(qos: .utility).async {
            let warning = SettingsEditor.modelPathWarning(settings)
            DispatchQueue.main.async {
                guard generation == self.modelCheckGeneration else { return }
                self.modelWarning = warning
            }
        }
    }

    func setInputMode(_ mode: InputMode) {
        SettingsEditor.setInputMode(mode, in: defaults)
        reload()
    }

    func startRecording() {
        isRecording = true
        recordMessage = nil
    }

    /// 記録中に押されたキー。受け付けたら保存して記録を終える。受け付けなければ理由を出して記録中のままにする。
    /// - Returns: 記録を終えたか。
    func record(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        switch SettingsEditor.recordConvertKey(keyCode: keyCode, modifiers: modifiers, in: defaults) {
        case .success(let key):
            isRecording = false
            reload()
            recordMessage = "\(key.displayString) を変換キーにしました。"
            return true
        case .failure(let reason):
            recordMessage = "保存しませんでした: \(reason)"
            return false
        }
    }

    /// 記録を取り消す（Esc 単独・枠の外をクリック）。
    func cancelRecording() {
        isRecording = false
        recordMessage = nil
    }

    func resetConvertKey() {
        SettingsEditor.resetConvertKey(in: defaults)
        reload()
        recordMessage = "既定（Space）に戻しました。"
    }

    func setFullWidthDigits(_ on: Bool) {
        SettingsEditor.setFullWidthDigits(on, in: defaults)
        reload()
    }

    func setCandidateCount(_ n: Int) {
        SettingsEditor.setCandidateCount(n, in: defaults)
        reload()
    }

    /// モデルファイルを選ぶ（runModal を使わず、ウィンドウのシートとして非同期に開く）。
    func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "モデルファイル（.gguf）を選択"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        panel.directoryURL = URL(fileURLWithPath: (Settings.load(from: defaults).expandedModelPath as NSString).deletingLastPathComponent)
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            SettingsEditor.setModelPath(url.path, in: self.defaults)
            self.reload()
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func stopRecording() {
        isRecording = false
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            if !model.warnings.isEmpty {
                Section {
                    ForEach(model.warnings, id: \.self) { w in
                        Label(w + "（既定値で表示しています）", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("入力の方式") {
                Picker("入力の方式", selection: Binding(get: { model.inputMode }, set: { model.setInputMode($0) })) {
                    VStack(alignment: .leading) {
                        Text("未確定文字モード")
                        Text("打ったローマ字は下線付きの未確定文字になり、変換キーで変換、Enter などで確定します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(InputMode.marked)
                    VStack(alignment: .leading) {
                        Text("直接モード")
                        Text("打鍵はすぐ確定し、変換キーでカーソル直前のローマ字を置き換えます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(InputMode.direct)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("変換キー（両モード共通）") {
                HStack {
                    KeyRecorderField(model: model)
                        .frame(width: 180, height: 26)
                    Button("既定に戻す（Space）") { model.resetConvertKey() }
                }
                Text(model.isRecording
                     ? "変換キーにしたい組み合わせを押してください（Esc で取り消し）。"
                     : "枠をクリックしてから、変換キーにしたい組み合わせを押してください（Esc で取り消し）。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.recordMessage {
                    Text(message).font(.caption)
                }
                if let note = model.convertKey.conflictNote {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("変換結果") {
                Toggle("数字を全角にする", isOn: Binding(get: { model.fullWidthDigits }, set: { model.setFullWidthDigits($0) }))
                Stepper(value: Binding(get: { model.candidateCount }, set: { model.setCandidateCount($0) }),
                        in: Settings.candidateCountRange) {
                    Text("候補数: \(model.candidateCount)（続けて変換キーを押したときの候補の数）")
                }
            }

            Section("モデルファイル") {
                Text(model.modelPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Button("選択…") { model.chooseModel() }
                    Spacer()
                }
                if let w = model.modelWarning {
                    Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 変換キーを記録する枠。クリックすると記録を始め、次に押したキーの組み合わせを記録する。
/// - 記録中のキーはほかへ送らない（このビューで受け取って止める）。テキスト入力のクライアントではないので、IME の変換は働かない。
/// - Esc 単独で記録を取り消す。受け付けない組み合わせは、理由を出して記録中のままにする。
/// - 記録が終わったら first responder を外す（キーリピートでビープ音が鳴らないように）。
struct KeyRecorderField: NSViewRepresentable {
    @ObservedObject var model: SettingsViewModel

    func makeNSView(context: Context) -> KeyRecorderView {
        let v = KeyRecorderView()
        v.onRecord = { code, mods in model.record(keyCode: code, modifiers: mods) }
        v.onStart = { model.startRecording() }
        v.onCancel = { model.cancelRecording() }
        return v
    }

    func updateNSView(_ v: KeyRecorderView, context: Context) {
        v.label = model.isRecording ? "キーを押してください…" : model.convertKey.displayString
        v.recording = model.isRecording
        v.needsDisplay = true
    }
}

final class KeyRecorderView: NSView {
    /// 記録中に押されたキー。記録を終えたら true を返す。
    var onRecord: ((UInt16, KeyModifiers) -> Bool)?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var label = ""
    var recording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onStart?()
    }

    override func resignFirstResponder() -> Bool {
        // ほかをクリックするなどして枠から離れたら、記録をやめる
        if recording { onCancel?() }
        return true
    }

    /// 記録中のキーを処理する。
    private func handleRecording(_ event: NSEvent) {
        let mods = KeyModifiers(modifierFlagsRawValue: event.modifierFlags.rawValue)
        if event.keyCode == KeyStroke.Code.escape && mods.isEmpty {
            onCancel?()
            endRecording()
            return
        }
        if onRecord?(event.keyCode, mods) == true {
            endRecording()
        }
        // 受け付けない組み合わせ: 理由はモデルが表示し、記録中のまま
    }

    private func endRecording() {
        // 先にビュー側の記録中の印を下ろす（first responder を外したときの resignFirstResponder で
        // 取り消し（onCancel）が走り、成功メッセージが消えないように）
        recording = false
        // first responder を外す（以後のキーリピートがこのビューに来てビープ音が鳴らないように）
        window?.makeFirstResponder(nil)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        // 記録中はここで受け取って止める（ほかへは送らない）
        handleRecording(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘ との組み合わせはメニューより先にここで受け取る
        guard recording, event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        handleRecording(event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
