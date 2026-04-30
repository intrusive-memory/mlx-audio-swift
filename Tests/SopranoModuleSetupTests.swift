//
//  SopranoModuleSetupTests.swift
//  MLXAudioTests
//
//  CI-safe: no model downloads. Tests config decoding, weight sanitization,
//  and SopranoDecoder output shape — all exercised with synthetic data and JSON fixtures.
//

import Testing
import MLX
import MLXNN
import Foundation

@testable import MLXAudioCore
@testable import MLXAudioTTS

// MARK: - Soprano Module Setup Tests (CI-safe, no model downloads)

@Suite("SopranoModuleSetupTests")
struct SopranoModuleSetupTests {

    // MARK: - Task 2: Config decodes from JSON fixture

    /// Assert that SopranoConfiguration decodes correctly from the upstream-representative
    /// config fixture at Tests/media/configs/soprano.json.
    @Test func sopranoConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "soprano",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "soprano.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(SopranoConfiguration.self, from: data)

        #expect(config.hiddenSize == 896)
        #expect(config.hiddenLayers == 24)
        #expect(config.intermediateSize == 4864)
        #expect(config.attentionHeads == 14)
        #expect(config.kvHeads == 2)
        #expect(config.headDim == 64)
        #expect(config.vocabularySize == 151936)
        #expect(config.maxPositionEmbeddings == 32768)
        #expect(config.rmsNormEps == 1e-6)
        #expect(config.ropeTheta == 1000000.0)
        #expect(config.tieWordEmbeddings == false)
        #expect(config.bosTokenId == 151643)
        #expect(config.eosTokenId == 151645)
        #expect(config.padTokenId == 151643)
        #expect(config.sampleRate == 32000)
        #expect(config.decoderNumLayers == 8)
        #expect(config.decoderDim == 512)
        #expect(config.decoderIntermediateDim == 1536)
        #expect(config.hopLength == 512)
        #expect(config.nFft == 2048)
        #expect(config.upscale == 4)
        #expect(config.dwKernel == 3)
        #expect(config.tokenSize == 2048)
        #expect(config.receptiveField == 4)
    }

    /// Assert that SopranoConfiguration decodes from a minimal inline JSON and
    /// that defaults are applied correctly.
    @Test func sopranoConfigDecodesFromMinimalJSON() throws {
        let json = """
        {
            "hidden_size": 512,
            "num_hidden_layers": 8,
            "intermediate_size": 2048,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 64,
            "vocab_size": 32000
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(SopranoConfiguration.self, from: data)

        #expect(config.hiddenSize == 512)
        #expect(config.hiddenLayers == 8)
        #expect(config.kvHeads == 2)
        #expect(config.headDim == 64)
        // Defaults
        #expect(config.maxPositionEmbeddings == 512)
        #expect(config.rmsNormEps == 1e-6)
        #expect(config.ropeTheta == 10000)
        #expect(config.tieWordEmbeddings == false)
        #expect(config.sampleRate == 32000)
        #expect(config.decoderNumLayers == 8)
        #expect(config.decoderDim == 512)
        #expect(config.hopLength == 512)
        #expect(config.nFft == 2048)
        #expect(config.upscale == 4)
    }

    // MARK: - Task 3: sanitize one-way transformation test

    /// Assert that sanitize(weights:) correctly remaps language_model.* keys and
    /// preserves decoder keys from upstream-style checkpoints.
    ///
    /// The production sanitize applies two transformations in sequence:
    ///   1. Strip leading "model." prefix (if present).
    ///   2. Remap "language_model." prefix → "model." (or strip for lm_head path).
    ///
    /// So "language_model.model.embed_tokens.weight" →
    ///   step 1: unchanged (does not start with "model.")
    ///   step 2: "language_model." → "model." → "model.model.embed_tokens.weight"
    @Test func sanitizeRemapsLanguageModelKeys() {
        let config = makeTinyConfig()
        let model = SopranoModel(config)

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            // Upstream key pattern: language_model.* prefix for transformer weights.
            // After sanitize: "language_model." replaced with "model." → "model.model.*"
            "language_model.model.embed_tokens.weight": someArray,
            "language_model.model.layers.0.self_attn.q_proj.weight": someArray,
            "language_model.model.norm.weight": someArray,
            // lm_head under language_model → strip "language_model." → "lm_head.weight"
            "language_model.lm_head.weight": someArray,
            // Decoder weights: key unchanged, value cast to float32
            "decoder.head.out.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // "language_model.model.*" → strip "language_model." → prepend "model." → "model.model.*"
        #expect(sanitized["model.model.embed_tokens.weight"] != nil,
                "Expected language_model.model.embed_tokens.weight → model.model.embed_tokens.weight")
        #expect(sanitized["model.model.layers.0.self_attn.q_proj.weight"] != nil,
                "Expected language_model.model.layers.0... → model.model.layers.0...")
        #expect(sanitized["model.model.norm.weight"] != nil,
                "Expected language_model.model.norm.weight → model.model.norm.weight")

        // Original language_model.* keys must be gone
        #expect(sanitized["language_model.model.embed_tokens.weight"] == nil,
                "Expected language_model.model.embed_tokens.weight to be remapped away")

        // "language_model.lm_head.weight" → strip "language_model." → "lm_head.weight"
        // (tieWordEmbeddings == false on tiny config, so lm_head survives)
        #expect(sanitized["lm_head.weight"] != nil,
                "Expected language_model.lm_head.weight → lm_head.weight")

        // Decoder weights should survive with key unchanged
        #expect(sanitized["decoder.head.out.weight"] != nil,
                "Expected decoder.head.out.weight to survive sanitize")
    }

    /// Assert that sanitize(weights:) removes lm_head.weight when tieWordEmbeddings == true.
    ///
    /// Note: the sanitize step-1 strips a leading "model." prefix, so a key
    /// "model.embed_tokens.weight" becomes "embed_tokens.weight" in the output.
    @Test func sanitizeRemovesLmHeadWhenEmbeddingsTied() {
        var config = makeTinyConfig()
        config.tieWordEmbeddings = true
        let model = SopranoModel(config)

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            "lm_head.weight": someArray,
            // This key starts with "model." → sanitize strips it → "embed_tokens.weight"
            "model.embed_tokens.weight": someArray,
            // This key has no "model." prefix → passes through unchanged
            "embed_tokens.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // lm_head.weight must be gone when tieWordEmbeddings == true
        #expect(sanitized["lm_head.weight"] == nil,
                "Expected lm_head.weight to be removed when tieWordEmbeddings == true")

        // "embed_tokens.weight" (already clean key) must survive
        #expect(sanitized["embed_tokens.weight"] != nil,
                "Expected embed_tokens.weight to survive sanitize")
    }

    /// Assert that sanitize(weights:) preserves lm_head.weight when tieWordEmbeddings == false.
    @Test func sanitizePreservesLmHeadWhenNotTied() {
        var config = makeTinyConfig()
        config.tieWordEmbeddings = false
        let model = SopranoModel(config)

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            "lm_head.weight": someArray,
            "model.embed_tokens.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // lm_head.weight must survive when tieWordEmbeddings == false
        #expect(sanitized["lm_head.weight"] != nil,
                "Expected lm_head.weight to survive when tieWordEmbeddings == false")
    }

    // MARK: - Task 4: SopranoDecoder output-shape test

    /// Assert that SopranoDecoder (random-init, no weight loading) produces the correct
    /// audio output shape for a fixed small input.
    ///
    /// Input: (B=1, L=5, C=numInputChannels)
    /// Expected output shape: [1, audioSamples] where:
    ///   targetSize = upscale * (L - 1) + 1 = 4 * 4 + 1 = 17 frames (numFrames=17)
    ///   outputLength = (numFrames - 1) * hopLength + nFft = 16 * 512 + 2048 = 10240
    ///   trimmed: [nFft/2 : outputLength - nFft/2] = [1024 : 9216] → 8192 samples
    @Test func sopranoDecoderOutputShape() {
        MLXRandom.seed(42)

        // Small decoder dimensions to keep the test fast.
        let numInputChannels = 32
        let decoderDim = 16
        let numLayers = 2
        let nFft = 32
        let hopLength = 8
        let upscale = 2

        let decoder = SopranoDecoder(
            numInputChannels: numInputChannels,
            decoderNumLayers: numLayers,
            decoderDim: decoderDim,
            decoderIntermediateDim: decoderDim * 3,
            hopLength: hopLength,
            nFft: nFft,
            upscale: upscale,
            dwKernel: 3
        )

        // Fixed input: (B=1, L=5, C=numInputChannels)
        let batchSize = 1
        let seqLen = 5
        let input = MLXRandom.uniform(low: -1, high: 1, [batchSize, seqLen, numInputChannels])

        let output = decoder(input)
        eval(output)

        // targetSize = upscale * (seqLen - 1) + 1 = 2 * 4 + 1 = 9 frames
        // outputLength = (9 - 1) * hopLength + nFft = 8 * 8 + 32 = 96
        // trimStart = nFft / 2 = 16, trimEnd = 96 - 16 = 80
        // trimmedLength = 80 - 16 = 64
        let numFrames = upscale * (seqLen - 1) + 1
        let outputLength = (numFrames - 1) * hopLength + nFft
        let trimStart = nFft / 2
        let trimEnd = outputLength - nFft / 2
        let expectedAudioSamples = trimEnd - trimStart

        #expect(output.ndim == 2,
                "Expected 2D output (batch, samples), got ndim=\(output.ndim)")
        #expect(output.shape[0] == batchSize,
                "Expected batch dimension \(batchSize), got \(output.shape[0])")
        #expect(output.shape[1] == expectedAudioSamples,
                "Expected \(expectedAudioSamples) audio samples, got \(output.shape[1])")
    }

    // MARK: - Task 4b: SopranoModel structure tests (no weights, no downloads)

    /// Assert that makeCache() returns one KVCache per hidden layer.
    @Test func sopranoMakeCacheReturnsExpectedCount() {
        let config = makeTinyConfig()
        let model = SopranoModel(config)

        let cache = model.makeCache()

        #expect(cache.count == config.hiddenLayers,
                "Expected cache.count == \(config.hiddenLayers), got \(cache.count)")
    }

    /// Assert that numLayers is consistent with hiddenLayers in config.
    @Test func sopranoNumLayersMatchesConfig() {
        let config = makeTinyConfig()
        let model = SopranoModel(config)
        #expect(model.numLayers == config.hiddenLayers)
    }

    /// Assert that vocabularySize matches the config.
    @Test func sopranoVocabSizeMatchesConfig() {
        let config = makeTinyConfig()
        let model = SopranoModel(config)
        #expect(model.vocabularySize == config.vocabularySize)
    }

    /// Assert that kvHeads array has one entry per layer, each equal to config.kvHeads.
    @Test func sopranoKvHeadsMatchesConfig() {
        let config = makeTinyConfig()
        let model = SopranoModel(config)
        #expect(model.kvHeads.count == config.hiddenLayers)
        for kv in model.kvHeads {
            #expect(kv == config.kvHeads)
        }
    }

    // MARK: - Helpers

    /// Return a tiny but valid SopranoConfiguration — small enough that
    /// instantiating the model (no weights) completes in milliseconds.
    ///
    /// headDim must satisfy: headDim = hiddenSize / attentionHeads when Qwen3-style
    /// (here: 32 / 4 = 8 headDim).
    private func makeTinyConfig() -> SopranoConfiguration {
        // Use the minimal Decoder init with all required fields.
        // SopranoConfiguration.init(from:) requires hidden_size, num_hidden_layers,
        // intermediate_size, num_attention_heads, num_key_value_heads, head_dim, vocab_size.
        // We construct via JSON decoding to avoid a memberwise init dependency.
        let json = """
        {
            "hidden_size": 32,
            "num_hidden_layers": 2,
            "intermediate_size": 64,
            "num_attention_heads": 4,
            "num_key_value_heads": 2,
            "head_dim": 8,
            "vocab_size": 256,
            "sample_rate": 32000,
            "decoder_num_layers": 2,
            "decoder_dim": 16,
            "decoder_intermediate_dim": 48,
            "hop_length": 8,
            "n_fft": 32,
            "upscale": 2,
            "dw_kernel": 3,
            "token_size": 32,
            "receptive_field": 2
        }
        """
        return try! JSONDecoder().decode(SopranoConfiguration.self, from: json.data(using: .utf8)!)
    }
}
