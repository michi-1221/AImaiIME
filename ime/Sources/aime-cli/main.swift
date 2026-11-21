import AIMECore
import AIMELlama
import Foundation

// 実推論の確認とレイテンシ測定用の CLI。
//
//   aime-cli convert --model <gguf> [--context <左文脈>] <入力>
//   aime-cli bench   --model <gguf> [--chars 200] [--runs 5] [--input <入力>] [--force-tokens <n>] [--beam <候補数>]
//
// convert は IME と同じ Converter（プロンプト組み立て + 後処理の既定設定）を通す。

func usage() -> Never {
    fputs("""
    使い方:
      aime-cli convert --model <gguf> [--context <左文脈>] <入力>
      aime-cli bench   --model <gguf> [--chars 200] [--runs 5] [--input <入力>] [--force-tokens <n>] [--beam <候補数>]
        --force-tokens: </s> で止めずに必ず n トークン生成する（出力長を固定してレイテンシを測る）
        --beam: 貪欲法の代わりに、Tab の候補送りと同じビームサーチ（ビーム幅 max(8, 候補数)）の時間を測る。
                --force-tokens と併用すると </s> で止めずに n ステップ進める
    共通: --gpu-layers <n>（Metal に載せる層数。既定 -1 = 全層、0 = CPU のみ）

    """, stderr)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

var options: [String: String] = [:]
var positional: [String] = []
var i = 0
while i < args.count {
    let a = args[i]
    if a.hasPrefix("--"), i + 1 < args.count {
        options[String(a.dropFirst(2))] = args[i + 1]
        i += 2
    } else {
        positional.append(a)
        i += 1
    }
}

guard let modelPath = options["model"].map({ ($0 as NSString).expandingTildeInPath }) else { usage() }

func elapsed(_ f: () throws -> Void) rethrows -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    try f()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9
}

func run() throws {
    var generator: LlamaGenerator!
    let loadSec = try elapsed {
        generator = try LlamaGenerator(modelPath: modelPath, gpuLayers: Int32(options["gpu-layers"] ?? "-1") ?? -1)
    }
    print(String(format: "モデル読み込み: %.3f 秒 (コンテキスト長 %d, 終了トークン id=%d)",
                 loadSec, generator.contextSize, generator.stopToken))
    let converter = Converter(generator: generator)

    switch command {
    case "convert":
        guard let input = positional.first else { usage() }
        var out = ""
        let sec = try elapsed {
            out = try converter.convert(input: input, leftContext: options["context"], options: .init())
        }
        let st = generator.lastStats
        print("入力: \(input)")
        print("出力: \(out)")
        print(String(format: "時間: %.3f 秒 (プロンプト %d トークン, 生成 %d トークン, </s> で終了: %@)",
                     sec, st.promptTokens, st.generatedTokens, st.hitStopToken ? "はい" : "いいえ"))

    case "bench":
        let chars = Int(options["chars"] ?? "200") ?? 200
        let runs = Int(options["runs"] ?? "5") ?? 5
        let input: String
        if let given = options["input"] {
            input = given
        } else {
            // 既定の測定用入力: カタカナの文を繰り返して指定文字数にする
            let unit = "ライシュウノカイギデツカウシリョウヲキョウユウシテクダサイマエノヒマデニメヲトオシテオキマス"
            input = String(String(repeating: unit, count: chars / unit.count + 1).prefix(chars))
        }
        print("入力 (\(input.count) 文字): \(input)")
        let force = options["force-tokens"].flatMap { Int($0) }
        if let beamCount = options["beam"].flatMap({ Int($0) }) {
            let prompt = PromptBuilder.build(input: input, leftContext: nil)
            let width = Converter.beamWidth(forCount: beamCount)
            let onceBeam: () throws -> [ScoredGeneration] = {
                try generator.beamSearch(prompt: prompt, maxNewTokens: force ?? Converter.maxNewTokens(forInput: input),
                                         beamWidth: width, topN: beamCount, ignoreStopToken: force != nil)
            }
            _ = try onceBeam() // ウォームアップ
            var times: [Double] = []
            var result: [ScoredGeneration] = []
            for _ in 0..<runs {
                times.append(try elapsed { result = try onceBeam() })
            }
            let st = generator.lastBeamStats
            print("ビームサーチ: ビーム幅 \(width), 候補数 \(beamCount), プロンプト \(st.promptTokens) トークン, \(st.steps) ステップ, </s> で止まった候補 \(st.finishedCandidates)")
            for (k, g) in result.prefix(beamCount * 2).enumerated() {
                print(String(format: "  %d. %@ (対数尤度 %.3f, </s> で終了: %@)", k + 1, g.text, g.logProb, g.hitStopToken ? "はい" : "いいえ"))
            }
            let sorted = times.sorted()
            print(String(format: "レイテンシ (%d 回): 平均 %.3f 秒, 中央値 %.3f 秒, 最小 %.3f 秒, 最大 %.3f 秒",
                         runs, times.reduce(0, +) / Double(runs), sorted[sorted.count / 2], sorted.first!, sorted.last!))
            return
        }
        let once: () throws -> String = {
            if let force {
                // 出力長を固定: Converter と同じプロンプトで、</s> を無視して force 個生成する
                let prompt = PromptBuilder.build(input: input, leftContext: nil)
                return try generator.generate(prompt: prompt, maxNewTokens: force, ignoreStopToken: true).text
            }
            return try converter.convert(input: input, leftContext: nil, options: .init())
        }
        // ウォームアップ（Metal のパイプライン作成などを除くため）
        _ = try once()
        var times: [Double] = []
        var out = ""
        for _ in 0..<runs {
            times.append(try elapsed { out = try once() })
        }
        let st = generator.lastStats
        print("出力 (\(out.count) 文字): \(out)")
        print("プロンプト \(st.promptTokens) トークン, 生成 \(st.generatedTokens) トークン, </s> で終了: \(st.hitStopToken ? "はい" : "いいえ")")
        let sorted = times.sorted()
        print(String(format: "レイテンシ (%d 回): 平均 %.3f 秒, 中央値 %.3f 秒, 最小 %.3f 秒, 最大 %.3f 秒, %.1f トークン/秒",
                     runs, times.reduce(0, +) / Double(runs), sorted[sorted.count / 2], sorted.first!, sorted.last!,
                     Double(st.generatedTokens) / sorted[sorted.count / 2]))

    default:
        usage()
    }
}

// generator は run() を抜けるときに解放される（解放しないまま終了すると ggml-metal の後始末で assert が落ちる）
do {
    try run()
} catch {
    fputs("エラー: \(error)\n", stderr)
    exit(1)
}
