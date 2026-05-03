//
//  LlamaTTSModuleSetupTests.swift
//  MLXAudioTests
//
//  CI-safe: no model downloads. Tests config decoding, weight sanitization,
//  and makeCache() shape — all exercised with synthetic data and JSON fixtures.
//

import Testing
import MLX
import MLXNN
import MLXLMCommon
import Foundation

@testable import MLXAudioCore
@testable import MLXAudioTTS

// MARK: - LlamaTTS Module Setup Tests (CI-safe, no model downloads)

@Suite("LlamaTTSModuleSetupTests")
struct LlamaTTSModuleSetupTests {

    // MARK: - Task 2: Config decodes from JSON fixture

    /// Assert that LlamaTTSConfiguration decodes correctly from the upstream-representative
    /// config fixture at Tests/media/configs/llama_tts.json.
    @Test func llamaConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "llama_tts",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "llama_tts.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(LlamaTTSConfiguration.self, from: data)

        #expect(config.hiddenSize == 3072)
        #expect(config.hiddenLayers == 28)
        #expect(config.intermediateSize == 8192)
        #expect(config.attentionHeads == 24)
        #expect(config.kvHeads == 8)
        #expect(config.rmsNormEps == 1e-5)
        #expect(config.vocabularySize == 155168)
        #expect(config.maxPositionEmbeddings == 131072)
        #expect(config.ropeTheta == 500000.0)
        #expect(config.tieWordEmbeddings == true)
        #expect(config.attentionBias == false)
        #expect(config.mlpBias == false)
        #expect(config.sampleRate == 24000)

        // rope_scaling should decode correctly
        #expect(config.ropeScaling != nil)
    }

    /// Assert that LlamaTTSConfiguration decodes from a minimal inline JSON
    /// (no rope_scaling) and that defaults are applied correctly.
    @Test func llamaConfigDecodesFromMinimalJSON() throws {
        let json = """
        {
            "hidden_size": 2048,
            "num_hidden_layers": 16,
            "intermediate_size": 5632,
            "num_attention_heads": 16,
            "num_key_value_heads": 8,
            "rms_norm_eps": 1e-5,
            "vocab_size": 32000
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(LlamaTTSConfiguration.self, from: data)

        #expect(config.hiddenSize == 2048)
        #expect(config.hiddenLayers == 16)
        #expect(config.kvHeads == 8)
        // Defaults
        #expect(config.ropeTheta == 10000)
        #expect(config.ropeTraditional == false)
        #expect(config.tieWordEmbeddings == true)
        #expect(config.sampleRate == 24000)
        #expect(config.ropeScaling == nil)
    }

    // MARK: - Task 3: sanitize strips expected prefixes

    /// Assert that sanitize(weights:) removes self_attn.rotary_emb.inv_freq keys
    /// and (when tieWordEmbeddings == true) removes the lm_head.weight key.
    @Test func llamaSanitizeStripsExpectedPrefixes() {
        let config = makeTinyConfig()
        let model = LlamaTTSModel(config)

        // Build synthetic raw weight dict with upstream key names
        let someArray = MLXArray.zeros([4])
        var rawWeights: [String: MLXArray] = [
            "model.layers.0.self_attn.q_proj.weight": someArray,
            "model.layers.0.self_attn.k_proj.weight": someArray,
            "model.layers.0.self_attn.rotary_emb.inv_freq": someArray,   // should be removed
            "model.layers.1.self_attn.rotary_emb.inv_freq": someArray,   // should be removed
            "model.embed_tokens.weight": someArray,
            "lm_head.weight": someArray,  // should be removed when tieWordEmbeddings == true
            "model.norm.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // All inv_freq keys must be gone
        let invFreqKeys = sanitized.keys.filter { $0.contains("rotary_emb.inv_freq") }
        #expect(invFreqKeys.isEmpty, "Expected all rotary_emb.inv_freq keys to be removed; found: \(invFreqKeys)")

        // lm_head.weight must be gone when tieWordEmbeddings == true
        #expect(sanitized["lm_head.weight"] == nil,
                "Expected lm_head.weight to be removed when tieWordEmbeddings == true")

        // Non-sanitized keys must survive
        #expect(sanitized["model.layers.0.self_attn.q_proj.weight"] != nil)
        #expect(sanitized["model.embed_tokens.weight"] != nil)
        #expect(sanitized["model.norm.weight"] != nil)
    }

    /// Assert that sanitize(weights:) preserves lm_head.weight when tieWordEmbeddings == false.
    @Test func llamaSanitizePreservesLmHeadWhenNotTied() {
        var config = makeTinyConfig()
        config.tieWordEmbeddings = false
        let model = LlamaTTSModel(config)

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

    // MARK: - Task 4: makeCache returns expected shape

    /// Assert that makeCache() returns one KVCache per hidden layer.
    @Test func llamaMakeCacheReturnsExpectedShape() {
        let config = makeTinyConfig()
        let model = LlamaTTSModel(config)

        let cache = model.makeCache()

        // Count must match num_hidden_layers from config
        #expect(cache.count == config.hiddenLayers,
                "Expected cache.count == \(config.hiddenLayers), got \(cache.count)")

        // kvHeads array on model must also match
        #expect(model.kvHeads.count == config.hiddenLayers)
        for kv in model.kvHeads {
            #expect(kv == config.kvHeads)
        }
    }

    /// Assert that numLayers is consistent with hiddenLayers.
    @Test func llamaNumLayersMatchesConfig() {
        let config = makeTinyConfig()
        let model = LlamaTTSModel(config)
        #expect(model.numLayers == config.hiddenLayers)
    }

    /// Assert that the model's vocabularySize matches the config.
    @Test func llamaVocabSizeMatchesConfig() {
        let config = makeTinyConfig()
        let model = LlamaTTSModel(config)
        #expect(model.vocabularySize == config.vocabularySize)
    }

    // MARK: - Helpers

    /// Return a tiny but valid LlamaTTSConfiguration — small enough that
    /// instantiating the model (no weights) completes in milliseconds.
    private func makeTinyConfig() -> LlamaTTSConfiguration {
        // hiddenSize must be divisible by attentionHeads (32 / 4 = 8 headDim)
        return LlamaTTSConfiguration(
            hiddenSize: 32,
            hiddenLayers: 2,
            intermediateSize: 64,
            attentionHeads: 4,
            rmsNormEps: 1e-5,
            vocabularySize: 256,
            kvHeads: 2,
            ropeTheta: 10000,
            ropeScaling: [
                "factor": .float(32.0),
                "rope_type": .string("llama3")
            ]
        )
    }
}
