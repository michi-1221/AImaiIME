import Foundation

/// 生成の結果。
public struct GenerationResult: Equatable {
    /// 生成したテキスト（終了トークン自体は含めない）。
    public var text: String
    /// 終了トークン（`</s>`）で止まったか。false なら上限で打ち切られた（途中で切れている）。
    public var hitStopToken: Bool

    public init(text: String, hitStopToken: Bool) {
        self.text = text
        self.hitStopToken = hitStopToken
    }
}

/// ビームサーチの1候補。
public struct ScoredGeneration: Equatable {
    /// 生成したテキスト（終了トークン自体は含めない）。
    public var text: String
    /// 終了トークン（`</s>`）で止まったか。
    public var hitStopToken: Bool
    /// 対数尤度（終了トークンを含む、生成したトークンの対数確率の和）。
    public var logProb: Double

    public init(text: String, hitStopToken: Bool, logProb: Double) {
        self.text = text
        self.hitStopToken = hitStopToken
        self.logProb = logProb
    }
}

/// プロンプトから続きを生成するエンジンの抽象。
/// 実装: `LlamaGenerator`（AIMELlama モジュール、llama.cpp + Metal）、`MockGenerator`（テスト用）。
public protocol TextGenerator: AnyObject {
    /// `prompt` に続くテキストを貪欲デコードで生成する。
    /// 終了トークン（`</s>`）が出たら止める。
    /// - Parameter maxNewTokens: 生成するトークン数の上限。
    func generate(prompt: String, maxNewTokens: Int) throws -> GenerationResult

    /// `prompt` に続くテキストをビームサーチで求める。
    /// 対数尤度の高い順に返す。`</s>` で止まらなかった候補が含まれることもある（`hitStopToken` で区別する）。
    /// - Parameters:
    ///   - beamWidth: ビーム幅。
    ///   - topN: 求める候補数（`</s>` で止まった候補がこの数の2倍になったら探索を打ち切る）。
    func beamSearch(prompt: String, maxNewTokens: Int, beamWidth: Int, topN: Int) throws -> [ScoredGeneration]
}

/// 終了トークンの決め方。語彙の中から文字列 `</s>` を探す（GGUF / config.json の eos id は使わない）。
public enum StopToken {
    public static let text = "</s>"

    /// 語彙（id 順のトークン文字列の並び）から `</s>` の id を探す。なければ nil。
    public static func find<C: Collection>(in vocabulary: C) -> Int? where C.Element == String {
        for (id, token) in vocabulary.enumerated() where token == text {
            return id
        }
        return nil
    }
}

/// テスト・モデル未完成時用のモック。
/// 受け取ったプロンプトを記録し、`respond` の戻り値を返す。
public final class MockGenerator: TextGenerator {
    public private(set) var prompts: [String] = []
    public private(set) var requestedMaxNewTokens: [Int] = []
    public var respond: (String) throws -> GenerationResult
    /// ビームサーチの応答（既定は空）。
    public var respondBeam: (String) throws -> [ScoredGeneration] = { _ in [] }
    public private(set) var beamPrompts: [String] = []

    public init(respond: @escaping (String) throws -> GenerationResult = { _ in GenerationResult(text: "", hitStopToken: true) }) {
        self.respond = respond
    }

    /// 固定の出力を返すモック（既定では `</s>` で止まった扱い）。
    public convenience init(fixed output: String, hitStopToken: Bool = true) {
        self.init(respond: { _ in GenerationResult(text: output, hitStopToken: hitStopToken) })
    }

    public func generate(prompt: String, maxNewTokens: Int) throws -> GenerationResult {
        prompts.append(prompt)
        requestedMaxNewTokens.append(maxNewTokens)
        return try respond(prompt)
    }

    public func beamSearch(prompt: String, maxNewTokens: Int, beamWidth: Int, topN: Int) throws -> [ScoredGeneration] {
        beamPrompts.append(prompt)
        return try respondBeam(prompt)
    }
}
