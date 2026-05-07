import Foundation
@preconcurrency import MLX
import MLXNN
import MLXAudioCore
public struct TokenizedText {
    public let tokens: MLXArray
}

public final class SentencePieceTokenizer {
    public let tokenizer: UnigramTokenizer

    public init(nBins: Int, modelFolder: URL) async throws {
        let tokenizerJSON = modelFolder.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizerJSON.path),
              let data = try? Data(contentsOf: tokenizerJSON) else {
            throw NSError(
                domain: "PocketTTSConditioners",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing tokenizer.json in \(modelFolder.path)"]
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        self.tokenizer = try UnigramTokenizer(tokenizerJSON: json)
        Telemetry.trackLifecycle(self, className: "PocketTTS.Tokenizer")
    }

    /// Testing-only init: constructs a SentencePieceTokenizer with a minimal single-entry
    /// vocabulary. No file I/O occurs. Intended for CI-safe unit tests only.
    internal init(__testStub nBins: Int) {
        // Build a minimal tokenizer JSON with one vocab entry so UnigramTokenizer inits without error.
        let stubJSON: [String: Any] = [
            "model": [
                "unk_id": 0,
                "vocab": [["<unk>", -100.0]]
            ]
        ]
        // Force-try: the hardcoded JSON above is always valid.
        self.tokenizer = try! UnigramTokenizer(tokenizerJSON: stubJSON)
        Telemetry.trackLifecycle(self, className: "PocketTTS.Tokenizer")
    }

    /// Synchronous variant — no actual async work; used inside `loadWithAcervoStrict` closure.
    public init(nBins: Int, modelFolderSync modelFolder: URL) throws {
        let tokenizerJSON = modelFolder.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizerJSON.path),
              let data = try? Data(contentsOf: tokenizerJSON) else {
            throw NSError(
                domain: "PocketTTSConditioners",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing tokenizer.json in \(modelFolder.path)"]
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        self.tokenizer = try UnigramTokenizer(tokenizerJSON: json)
        Telemetry.trackLifecycle(self, className: "PocketTTS.Tokenizer")
    }

    deinit {
        Telemetry.trackLifecycleEnd(className: "PocketTTS.Tokenizer")
    }

    public func callAsFunction(_ text: String) -> TokenizedText {
        let ids = tokenizer.encodeWithByteFallback(text)
        let arr = MLXArray(ids).expandedDimensions(axis: 0)
        return TokenizedText(tokens: arr)
    }

    public func encode(_ text: String) -> [Int] {
        tokenizer.encodeWithByteFallback(text)
    }

    public func decode(_ ids: [Int]) -> String {
        tokenizer.decode(ids)
    }
}

public final class LUTConditioner: Module {
    public let tokenizer: SentencePieceTokenizer
    public let dim: Int
    public let outputDim: Int

    @ModuleInfo(key: "embed") public var embed: Embedding
    @ModuleInfo(key: "output_proj") public var output_proj: Linear?

    /// Testing-only init: constructs a LUTConditioner backed by a stub tokenizer.
    /// No file I/O occurs. Intended for CI-safe unit tests only.
    internal init(nBins: Int, dim: Int, outputDim: Int) {
        self.tokenizer = SentencePieceTokenizer(__testStub: nBins)
        self.dim = dim
        self.outputDim = outputDim
        self._embed = ModuleInfo(wrappedValue: Embedding(embeddingCount: nBins + 1, dimensions: dim))
        if dim == outputDim {
            self._output_proj = ModuleInfo(wrappedValue: nil)
        } else {
            self._output_proj = ModuleInfo(wrappedValue: Linear(dim, outputDim, bias: false))
        }
        super.init()
    }

    public init(nBins: Int, modelFolder: URL, dim: Int, outputDim: Int) async throws {
        self.tokenizer = try await SentencePieceTokenizer(nBins: nBins, modelFolder: modelFolder)
        self.dim = dim
        self.outputDim = outputDim
        self._embed = ModuleInfo(wrappedValue: Embedding(embeddingCount: nBins + 1, dimensions: dim))
        if dim == outputDim {
            self._output_proj = ModuleInfo(wrappedValue: nil)
        } else {
            self._output_proj = ModuleInfo(wrappedValue: Linear(dim, outputDim, bias: false))
        }
        super.init()
    }

    /// Synchronous variant — no actual async work; used inside `loadWithAcervoStrict` closure.
    public init(nBins: Int, modelFolderSync modelFolder: URL, dim: Int, outputDim: Int) throws {
        self.tokenizer = try SentencePieceTokenizer(nBins: nBins, modelFolderSync: modelFolder)
        self.dim = dim
        self.outputDim = outputDim
        self._embed = ModuleInfo(wrappedValue: Embedding(embeddingCount: nBins + 1, dimensions: dim))
        if dim == outputDim {
            self._output_proj = ModuleInfo(wrappedValue: nil)
        } else {
            self._output_proj = ModuleInfo(wrappedValue: Linear(dim, outputDim, bias: false))
        }
        super.init()
    }

    public func prepare(_ text: String) -> TokenizedText {
        tokenizer(text)
    }

    public func callAsFunction(_ inputs: TokenizedText) -> MLXArray {
        var embeds = embed(inputs.tokens)
        if let proj = output_proj {
            embeds = proj(embeds)
        }
        return embeds
    }
}
