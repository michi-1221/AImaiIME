import AIMECore
import AIMELlama
import Foundation
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AImaiIME", category: "ime")

/// 変換エンジン（LlamaGenerator）を1つだけ持つ。
///
/// - モデルの読み込みは裏のスレッドで行う。読み込みが終わっていなければ `converter` は nil を返す（待たない）。
/// - 設定のモデルパスが変わったら読み込み直す。
/// - 読み込みに失敗したら、モデルのパスかファイルの更新日時が変わるまで再試行しない。
final class EngineHolder {
    static let shared = EngineHolder()

    /// 読み込みの対象（パスと、そのファイルの更新日時）。
    private struct ModelKey: Equatable {
        var path: String
        var modificationDate: Date?

        init(path: String) {
            self.path = path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            modificationDate = attrs?[.modificationDate] as? Date
        }
    }

    private let lock = NSLock()
    private var generator: LlamaGenerator?
    private var loadedPath: String?
    private var loadingKey: ModelKey?
    private var failedKey: ModelKey?
    private var registeredExitHandler = false

    /// 起動直後に裏でモデルを読み込んでおく。
    func preload() {
        _ = converter(settings: Settings.load())
    }

    /// 使えるエンジンがあれば Converter を返す。なければ（読み込み中・失敗）nil を返し、
    /// 必要なら裏で読み込みを始める。
    func converter(settings: Settings) -> Converter? {
        lock.lock(); defer { lock.unlock() }
        let path = settings.expandedModelPath
        if let generator, loadedPath == path {
            return Converter(generator: generator)
        }
        if let loadingKey, loadingKey.path == path {
            return nil // 読み込み中
        }
        let key = ModelKey(path: path)
        if failedKey == key {
            return nil // 前回失敗し、パスも更新日時も変わっていない
        }
        startLoading(key)
        return nil
    }

    /// lock を持った状態で呼ぶ。
    private func startLoading(_ key: ModelKey) {
        loadingKey = key
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            var result: Result<LlamaGenerator, Error>? = Result { try LlamaGenerator(modelPath: key.path) }
            // ロックの中では入れ替えだけを行う。手放すエンジン（古いもの・捨てる結果）の解放は
            // ロックの外（この裏のスレッド）で行う（解放には時間がかかることがあり、その間 Tab を止めないため）。
            var released: [LlamaGenerator] = []
            self.lock.lock()
            // 読み込み中に別のモデルが指定された場合は、この結果を捨てる
            if self.loadingKey == key {
                self.loadingKey = nil
                switch result! {
                case .success(let g):
                    if let old = self.generator { released.append(old) }
                    self.generator = g
                    self.loadedPath = key.path
                    self.failedKey = nil
                    if !self.registeredExitHandler {
                        // 終了時に解放しておく（解放しないまま exit すると ggml-metal の後始末で assert が落ちる）。
                        // ggml-metal の後始末より先に呼ばれるよう、モデル読み込みのあとで登録する。
                        self.registeredExitHandler = true
                        atexit { EngineHolder.shared.releaseForExit() }
                    }
                    log.info("モデルを読み込みました: \(key.path, privacy: .public) (\(Date().timeIntervalSince(start), privacy: .public) 秒)")
                case .failure(let error):
                    self.failedKey = key
                    log.error("モデルの読み込みに失敗: \(String(describing: error), privacy: .public)")
                }
            }
            var adopted: LlamaGenerator?
            if case .success(let g) = result!, self.generator === g { adopted = g }
            self.lock.unlock()
            // ここで解放する（採用しなかった読み込み結果も、result を手放すと解放される）
            result = nil
            released.removeAll()
            // ビームサーチ用のコンテキストを先に作っておく（初回の候補送りで待たないように）
            if let adopted {
                let start = Date()
                adopted.prepareBeamContext(beamWidth: Converter.beamWidth(forCount: Settings.load().candidateCount))
                log.info("ビームサーチ用のコンテキストを作りました (\(Date().timeIntervalSince(start), privacy: .public) 秒)")
            }
        }
    }

    func releaseForExit() {
        lock.lock()
        let old = generator
        generator = nil
        lock.unlock()
        withExtendedLifetime(old) {} // ロックの外で解放する
    }
}

/// 不正な設定値を既定値に戻したことを、警告としてログに残す（同じ内容は繰り返さない）。
enum SettingsWarning {
    private static var last: [String] = []

    static func report(_ invalid: [String]) {
        guard invalid != last else { return }
        last = invalid
        for message in invalid {
            log.warning("設定: \(message, privacy: .public)")
        }
    }
}
