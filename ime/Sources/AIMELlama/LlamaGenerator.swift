import AIMECore
import Foundation
import llama

public enum LlamaGeneratorError: Error, CustomStringConvertible {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case contextInitFailed
    case stopTokenNotFound(String)
    case tokenizeFailed
    case promptTooLong(promptTokens: Int, contextSize: Int)
    case decodeFailed(Int32)

    public var description: String {
        switch self {
        case .modelNotFound(let p): return "モデルファイルが見つかりません: \(p)"
        case .modelLoadFailed(let p): return "モデルを読み込めませんでした: \(p)"
        case .contextInitFailed: return "llama.cpp のコンテキストを作れませんでした"
        case .stopTokenNotFound(let t): return "語彙に終了トークン \(t) がありません"
        case .tokenizeFailed: return "トークン化に失敗しました"
        case .promptTooLong(let n, let c): return "プロンプトが長すぎます（\(n) トークン / コンテキスト \(c)）"
        case .decodeFailed(let r): return "llama_decode が失敗しました (\(r))"
        }
    }
}

/// llama.cpp（Metal）で GGUF モデルを読み込み、貪欲デコードで生成する `TextGenerator`。
///
/// - トークナイザーは GGUF に入っている語彙（GPT-2 バイトレベル BPE）をそのまま使う。
///   語彙の中身に依存する処理はハードコードしない（空白トークン `Ġ` が追加されても
///   llama.cpp のデトークナイズで半角スペースになる）。
/// - 終了トークンは語彙から文字列 `</s>` を探して決める（GGUF / config.json の eos id は使わない）。
/// - スレッドセーフ（内部でロックする）。
public final class LlamaGenerator: TextGenerator {
    public let modelPath: String
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let nVocab: Int32
    public let stopToken: llama_token
    public let contextSize: Int
    private let lock = NSLock()
    /// ビームサーチ用のコンテキスト（初めて使うときに作る。複数シーケンスで KV キャッシュを共有する）
    private var beamContext: OpaquePointer?
    private var beamContextSeqMax = 0
    private let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))

    /// 直近のビームサーチの統計（測定用）。
    public private(set) var lastBeamStats = BeamStats()

    /// ビーム幅の上限（シーケンスを 2 × ビーム幅 本使い、llama.cpp の上限は 256 本）。
    public static let maxBeamWidth = 128

    public struct BeamStats {
        public var promptTokens = 0
        public var steps = 0
        /// `</s>` で止まった候補の数（重複する文字列はまとめた数）
        public var finishedCandidates = 0
        /// 各ステップで KV キャッシュに中身があったシーケンスの最大数（ビーム幅以下のはず。テスト用）
        public var maxLiveSequences = 0
        public var seconds: Double = 0
    }

    /// 直近の生成の統計（測定用）。
    public private(set) var lastStats = Stats()

    public struct Stats {
        public var promptTokens = 0
        public var generatedTokens = 0
        public var hitStopToken = false
        public var seconds: Double = 0
    }

    private static let backendInit: Void = {
        llama_log_set({ level, text, _ in
            // 既定では警告以上だけ標準エラーへ（IME では Console.app で見える）
            guard let text, level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue,
                  level != GGML_LOG_LEVEL_CONT else { return }
            if ProcessInfo.processInfo.environment["AIME_LLAMA_LOG"] != nil || level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue {
                fputs(String(cString: text), stderr)
            }
        }, nil)
        llama_backend_init()
    }()

    /// - Parameters:
    ///   - modelPath: GGUF ファイルのパス。
    ///   - contextSize: コンテキスト長。0 ならモデルの学習時の長さ。
    ///   - gpuLayers: GPU（Metal）に載せる層の数。負なら全層。
    public init(modelPath: String, contextSize: Int = 0, gpuLayers: Int32 = -1) throws {
        _ = Self.backendInit
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaGeneratorError.modelNotFound(modelPath)
        }
        self.modelPath = modelPath

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = gpuLayers < 0 ? 999 : gpuLayers

        // 上流の llama.cpp が知らない前処理（pre-tokenizer）名を、同じ動作の名前に読み替える
        var overrides: [llama_model_kv_override] = []
        if let pre = Self.stringMetadata(path: modelPath, key: Self.preTokenizerKey),
           let alias = Self.preTokenizerAliases[pre] {
            overrides.append(Self.stringOverride(key: Self.preTokenizerKey, value: alias))
        }
        overrides.append(llama_model_kv_override()) // 終端（key が空）
        let loaded: OpaquePointer? = overrides.withUnsafeBufferPointer { buf in
            mparams.kv_overrides = buf.count > 1 ? buf.baseAddress : nil
            return llama_model_load_from_file(modelPath, mparams)
        }
        guard let model = loaded else {
            throw LlamaGeneratorError.modelLoadFailed(modelPath)
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw LlamaGeneratorError.modelLoadFailed(modelPath)
        }
        let nVocab = llama_vocab_n_tokens(vocab)

        // 終了トークン `</s>` を語彙から探す
        let vocabTexts = (0..<nVocab).lazy.map { id -> String in
            llama_vocab_get_text(vocab, id).map { String(cString: $0) } ?? ""
        }
        guard let stopId = StopToken.find(in: vocabTexts) else {
            llama_model_free(model)
            throw LlamaGeneratorError.stopTokenNotFound(StopToken.text)
        }
        let stop = llama_token(stopId)

        let trainCtx = Int(llama_model_n_ctx_train(model))
        let nCtx = contextSize > 0 ? min(contextSize, trainCtx) : trainCtx
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(nCtx)
        cparams.n_batch = UInt32(nCtx)
        cparams.n_ubatch = UInt32(nCtx)
        let threads = self.threads
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        cparams.no_perf = true
        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LlamaGeneratorError.contextInitFailed
        }

        self.model = model
        self.context = ctx
        self.vocab = vocab
        self.nVocab = nVocab
        self.stopToken = stop
        self.contextSize = Int(llama_n_ctx(ctx))
    }

    static let preTokenizerKey = "tokenizer.ggml.pre"

    /// GGUF に書かれた pre-tokenizer 名 → 上流 llama.cpp で同じ動作をする名前。
    /// zenz（ku-nlp/gpt2-small-japanese-char 由来）の GGUF は "gpt2-small-japanese-char" と書かれているが、
    /// これは azooKey 版 llama.cpp 独自の名前で、上流は読み込みを拒否する。元の HF トークナイザーは
    /// GPT2Tokenizer（GPT-2 の正規表現で前処理するバイトレベル BPE）なので、上流の "gpt-2" と同じ動作になる。
    static let preTokenizerAliases: [String: String] = ["gpt2-small-japanese-char": "gpt-2"]

    /// GGUF のメタデータ（文字列）を読む。テンソルは読み込まない。
    static func stringMetadata(path: String, key: String) -> String? {
        let params = gguf_init_params(no_alloc: true, ctx: nil)
        guard let ctx = gguf_init_from_file(path, params) else { return nil }
        defer { gguf_free(ctx) }
        let id = gguf_find_key(ctx, key)
        guard id >= 0, gguf_get_kv_type(ctx, id) == GGUF_TYPE_STRING,
              let v = gguf_get_val_str(ctx, id) else { return nil }
        return String(cString: v)
    }

    static func stringOverride(key: String, value: String) -> llama_model_kv_override {
        var o = llama_model_kv_override()
        o.tag = LLAMA_KV_OVERRIDE_TYPE_STR
        withUnsafeMutableBytes(of: &o.key) { raw in
            let b = Array(key.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: b)
        }
        withUnsafeMutableBytes(of: &o.val_str) { raw in
            let b = Array(value.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: b)
        }
        return o
    }

    deinit {
        if let beamContext { llama_free(beamContext) }
        llama_free(context)
        llama_model_free(model)
    }

    /// テキストをトークン列にする（特殊トークンの解釈・BOS の付加はしない）。
    public func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        var n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, false)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, false)
        }
        guard n >= 0 else { throw LlamaGeneratorError.tokenizeFailed }
        return Array(tokens.prefix(Int(n)))
    }

    /// トークンのバイト列（llama.cpp のデトークナイズ。GPT-2 のバイト表現は元のバイトに戻る）。
    public func pieceBytes(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    public func generate(prompt: String, maxNewTokens: Int) throws -> GenerationResult {
        try generate(prompt: prompt, maxNewTokens: maxNewTokens, ignoreStopToken: false)
    }

    /// - Parameter ignoreStopToken: true なら `</s>` でも止めず、必ず `maxNewTokens` 個生成する（レイテンシ測定用）。
    public func generate(prompt: String, maxNewTokens: Int, ignoreStopToken: Bool) throws -> GenerationResult {
        lock.lock(); defer { lock.unlock() }
        let start = Date()
        var stats = Stats()
        defer {
            stats.seconds = Date().timeIntervalSince(start)
            lastStats = stats
        }

        var promptTokens = try tokenize(prompt)
        stats.promptTokens = promptTokens.count
        guard !promptTokens.isEmpty, promptTokens.count < contextSize else {
            throw LlamaGeneratorError.promptTooLong(promptTokens: promptTokens.count, contextSize: contextSize)
        }
        let limit = min(maxNewTokens, contextSize - promptTokens.count)

        llama_memory_clear(llama_get_memory(context), true)

        let r = promptTokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard r == 0 else { throw LlamaGeneratorError.decodeFailed(r) }

        var bytes: [UInt8] = []
        for _ in 0..<limit {
            guard let logits = llama_get_logits_ith(context, -1) else { break }
            var best: llama_token = 0
            var bestValue = logits[0]
            for i in 1..<Int(nVocab) where logits[i] > bestValue {
                bestValue = logits[i]
                best = llama_token(i)
            }
            if best == stopToken, !ignoreStopToken {
                stats.hitStopToken = true
                break
            }
            stats.generatedTokens += 1
            bytes += pieceBytes(best)
            var next = best
            let rr = llama_decode(context, llama_batch_get_one(&next, 1))
            guard rr == 0 else { throw LlamaGeneratorError.decodeFailed(rr) }
        }
        return GenerationResult(text: String(decoding: bytes, as: UTF8.self), hitStopToken: stats.hitStopToken)
    }

    // MARK: - ビームサーチ

    public func beamSearch(prompt: String, maxNewTokens: Int, beamWidth: Int, topN: Int) throws -> [ScoredGeneration] {
        try beamSearch(prompt: prompt, maxNewTokens: maxNewTokens, beamWidth: beamWidth, topN: topN, ignoreStopToken: false)
    }

    /// ビームサーチ用のコンテキストを用意する（lock を持った状態で呼ぶ）。
    /// シーケンスを `seqMax` 本持ち、KV キャッシュは全シーケンスで共有（unified）する。
    /// プロンプト部分は `llama_memory_seq_cp` で共有されるので、セル数は「プロンプト + ビーム幅 × 生成長」で足りる。
    /// 位置（position）は1シーケンスあたりモデルの学習時の長さ（contextSize）までに収める。
    private func ensureBeamContext(seqMax: Int) throws -> OpaquePointer {
        if let beamContext, beamContextSeqMax >= seqMax { return beamContext }
        if let beamContext { llama_free(beamContext) }
        beamContext = nil
        guard let ctx = makeBeamContext(seqMax: seqMax) else { throw LlamaGeneratorError.contextInitFailed }
        beamContext = ctx
        beamContextSeqMax = seqMax
        return ctx
    }

    /// ビームサーチ用のコンテキストを先に作っておく（モデルの読み込みのあと、裏のスレッドから呼ぶ）。
    /// 初めて候補を求めるときに作る待ち時間をなくすため。作るのはロックの外で行い（その間も変換は止めない）、
    /// 入れるときだけロックを取る。すでに同じか大きいものがあれば何もしない。
    /// - Parameter beamWidth: 使う予定のビーム幅（シーケンスは 2 × ビーム幅 本）。
    public func prepareBeamContext(beamWidth: Int) {
        let seqMax = 2 * min(max(1, beamWidth), Self.maxBeamWidth)
        lock.lock()
        let has = beamContext != nil && beamContextSeqMax >= seqMax
        lock.unlock()
        if has { return }
        guard let ctx = makeBeamContext(seqMax: seqMax) else { return }
        lock.lock()
        var unused: OpaquePointer? = ctx
        if beamContext == nil || beamContextSeqMax < seqMax {
            if let old = beamContext { llama_free(old) }
            beamContext = ctx
            beamContextSeqMax = seqMax
            unused = nil
        }
        lock.unlock()
        if let unused { llama_free(unused) } // 先にほかで作られていた
    }

    /// ビームサーチがすでに使えるコンテキストを持っているか（テスト用）。
    public func hasBeamContext(beamWidth: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return beamContext != nil && beamContextSeqMax >= 2 * min(max(1, beamWidth), Self.maxBeamWidth)
    }

    private func makeBeamContext(seqMax: Int) -> OpaquePointer? {
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextSize * 4)
        cparams.n_batch = UInt32(contextSize)
        cparams.n_ubatch = UInt32(contextSize)
        cparams.n_seq_max = UInt32(seqMax)
        cparams.kv_unified = true
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        cparams.no_perf = true
        return llama_init_from_model(model, cparams)
    }

    /// 対数ソフトマックスの上位 k 件（値の大きい順）。
    private func logSoftmaxTopK(_ logits: UnsafePointer<Float>, k: Int) -> [(Float, llama_token)] {
        let n = Int(nVocab)
        var maxv = logits[0]
        for i in 1..<n where logits[i] > maxv { maxv = logits[i] }
        var sum: Float = 0
        for i in 0..<n { sum += expf(logits[i] - maxv) }
        let lse = maxv + logf(sum)
        var top: [(Float, llama_token)] = []
        top.reserveCapacity(k + 1)
        for i in 0..<n {
            let v = logits[i]
            if top.count == k, let last = top.last, v <= last.0 + lse { continue }
            let item = (v - lse, llama_token(i))
            let pos = top.firstIndex { $0.0 < item.0 } ?? top.count
            top.insert(item, at: pos)
            if top.count > k { top.removeLast() }
        }
        return top
    }

    /// - Parameter ignoreStopToken: true なら `</s>` でも止めず、`maxNewTokens` ステップ進める（レイテンシ測定用）。
    public func beamSearch(prompt: String, maxNewTokens: Int, beamWidth: Int, topN: Int,
                           ignoreStopToken: Bool) throws -> [ScoredGeneration] {
        lock.lock(); defer { lock.unlock() }
        let start = Date()
        var stats = BeamStats()
        defer {
            stats.seconds = Date().timeIntervalSince(start)
            lastBeamStats = stats
        }
        // シーケンスを 2 × ビーム幅 本使うので、上限（LLAMA_MAX_SEQ = 256）を超えないようにする
        let width = min(max(1, beamWidth), Self.maxBeamWidth)

        var promptTokens = try tokenize(prompt)
        stats.promptTokens = promptTokens.count
        let p = promptTokens.count
        guard p > 0, p < contextSize else {
            throw LlamaGeneratorError.promptTooLong(promptTokens: p, contextSize: contextSize)
        }
        // 1シーケンスの位置がモデルの学習時の長さを超えないようにする
        let limit = min(maxNewTokens, contextSize - p - 1)

        // シーケンスを2組（width 本ずつ）使い、ステップごとに入れ替える
        let ctx = try ensureBeamContext(seqMax: 2 * width)
        let mem = llama_get_memory(ctx)
        llama_memory_clear(mem, true)

        // プロンプトをシーケンス 0 に入れる
        let r = promptTokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard r == 0 else { throw LlamaGeneratorError.decodeFailed(r) }
        guard let first = llama_get_logits_ith(ctx, -1) else { throw LlamaGeneratorError.decodeFailed(-1) }

        struct Beam {
            var tokens: [llama_token]
            var score: Double
            /// 最後のトークンを除いた部分の KV キャッシュを持つシーケンス
            var parent: llama_seq_id
        }
        var beams = logSoftmaxTopK(first, k: width).map { Beam(tokens: [$0.1], score: Double($0.0), parent: 0) }
        var finished: [Beam] = []
        var finishedTexts = Set<String>()
        func text(of tokens: [llama_token]) -> String {
            String(decoding: tokens.flatMap { pieceBytes($0) }, as: UTF8.self)
        }
        /// `</s>` で終わったビームを finished に移し、生きているビームだけを返す
        func moveFinished(_ list: [Beam]) -> [Beam] {
            if ignoreStopToken { return list }
            var alive: [Beam] = []
            for b in list {
                if b.tokens.last == stopToken {
                    finished.append(b)
                    finishedTexts.insert(text(of: Array(b.tokens.dropLast())))
                } else {
                    alive.append(b)
                }
            }
            return alive
        }
        beams = moveFinished(beams)
        var bankA = (0..<width).map { llama_seq_id($0) }
        var bankB = (width..<(2 * width)).map { llama_seq_id($0) }

        var batch = llama_batch_init(Int32(width), 0, 1)
        defer { llama_batch_free(batch) }

        for step in 0..<max(0, limit) {
            // 打ち切り: 生きているビームがない、または </s> で止まった候補（重複を除いた文字列の数）が topN の2倍になった
            if beams.isEmpty || finishedTexts.count >= topN * 2 { break }
            let alive = beams
            stats.steps = step + 1

            // 各ビームに専用のシーケンスを割り当て、親の KV キャッシュを複製する（unified なのでセルは共有される）
            for (i, b) in alive.enumerated() {
                llama_memory_seq_rm(mem, bankB[i], -1, -1)
                llama_memory_seq_cp(mem, b.parent, bankB[i], -1, -1)
            }
            // 古い組を消す（消さないと、捨てたビームの KV キャッシュが残り続ける）
            for seq in bankA { llama_memory_seq_rm(mem, seq, -1, -1) }
            let live = (0..<(2 * width)).filter { llama_memory_seq_pos_max(mem, llama_seq_id($0)) >= 0 }.count
            stats.maxLiveSequences = max(stats.maxLiveSequences, live)

            batch.n_tokens = Int32(alive.count)
            for (i, b) in alive.enumerated() {
                batch.token[i] = b.tokens.last!
                batch.pos[i] = llama_pos(p + step)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = bankB[i]
                batch.logits[i] = 1
            }
            let rr = llama_decode(ctx, batch)
            guard rr == 0 else { throw LlamaGeneratorError.decodeFailed(rr) }

            var cand: [(score: Double, beam: Int, token: llama_token)] = []
            for i in 0..<alive.count {
                guard let logits = llama_get_logits_ith(ctx, Int32(i)) else { throw LlamaGeneratorError.decodeFailed(-1) }
                for (v, t) in logSoftmaxTopK(logits, k: width) {
                    cand.append((alive[i].score + Double(v), i, t))
                }
            }
            cand.sort { $0.score > $1.score }
            beams = moveFinished(cand.prefix(width).map {
                Beam(tokens: alive[$0.beam].tokens + [$0.token], score: $0.score, parent: bankB[$0.beam])
            })
            swap(&bankA, &bankB)
        }
        stats.finishedCandidates = finishedTexts.count
        // `</s>` で止まらなかったもの（beams に残っているもの）も、区別できるようにして返す
        let unfinished = beams

        var seen = Set<String>()
        var out: [ScoredGeneration] = []
        let all = finished.map { ($0, true) } + unfinished.map { ($0, false) }
        for (b, done) in all.sorted(by: { $0.0.score > $1.0.score }) {
            let t = text(of: done ? Array(b.tokens.dropLast()) : b.tokens)
            let key = "\(done ? 1 : 0)\u{0}\(t)"
            if seen.insert(key).inserted {
                out.append(ScoredGeneration(text: t, hitStopToken: done, logProb: b.score))
            }
        }
        llama_memory_clear(mem, true)
        return out
    }
}
