//
//  GLMASRModelTests.swift
//  MLXAudioTests
//
//  CI-safe: no model downloads. Tests config decoding, weight sanitization,
//  and makeCache() shape — all exercised with synthetic data and JSON fixtures.
//
//  DISTINCT from GLMASRModuleSetupTests.swift, which tests higher-level module
//  registration. This file covers:
//    - GLMASRModelConfig / LlamaConfig JSON decoding
//    - GLMASRModel.sanitize(weights:) key remapping
//    - GLMASRModel.makeCache() / GLMASRLanguageModel.kvHeads shape
//

import Testing
import MLX
import MLXNN
import MLXLMCommon
import Foundation

@testable import MLXAudioCore
@testable import MLXAudioSTT

// MARK: - GLMASRModel Tests (CI-safe, no model downloads)

@Suite("GLMASRModelTests")
struct GLMASRModelTests {

    // MARK: - Task 2: GLMASRLanguageModel config decodes from JSON fixture

    /// Assert that GLMASRModelConfig (and its nested LlamaConfig) decodes correctly
    /// from the upstream-representative fixture at Tests/media/configs/glm_asr.json.
    @Test func glmASRConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "glm_asr",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "glm_asr.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(GLMASRModelConfig.self, from: data)

        // Top-level fields
        #expect(config.modelType == "glmasr")
        #expect(config.adapterType == "mlp")
        #expect(config.mergeFactor == 4)
        #expect(config.mlpAdapterAct == "gelu")
        #expect(config.useRope == true)
        #expect(config.maxWhisperLength == 1500)
        #expect(config.maxLength == 65536)

        // Nested whisper config
        #expect(config.whisperConfig.dModel == 1280)
        #expect(config.whisperConfig.encoderAttentionHeads == 20)
        #expect(config.whisperConfig.encoderFfnDim == 5120)
        #expect(config.whisperConfig.encoderLayers == 32)
        #expect(config.whisperConfig.numMelBins == 128)
        #expect(config.whisperConfig.maxSourcePositions == 1500)
        #expect(config.whisperConfig.ropeTraditional == true)

        // Nested LM config (GLMASRLanguageModel config)
        #expect(config.lmConfig.vocabSize == 59264)
        #expect(config.lmConfig.hiddenSize == 2048)
        #expect(config.lmConfig.intermediateSize == 6144)
        #expect(config.lmConfig.numHiddenLayers == 28)
        #expect(config.lmConfig.numAttentionHeads == 16)
        #expect(config.lmConfig.numKeyValueHeads == 4)
        #expect(config.lmConfig.rmsNormEps == 1e-5)
        #expect(config.lmConfig.ropeTheta == 10000.0)
        #expect(config.lmConfig.tieWordEmbeddings == false)
        #expect(config.lmConfig.attentionBias == false)
        #expect(config.lmConfig.mlpBias == false)
        #expect(config.lmConfig.padTokenId == 59260)
        #expect(config.lmConfig.eosTokenId == [59246, 59253, 59255])
    }

    /// Assert that GLMASRModelConfig decodes from a minimal inline JSON and
    /// that defaults are applied correctly.
    @Test func glmASRConfigDecodesFromMinimalJSON() throws {
        let json = """
        {
            "whisper_config": {
                "hidden_size": 256,
                "num_attention_heads": 4,
                "intermediate_size": 1024,
                "num_hidden_layers": 4
            },
            "lm_config": {
                "vocab_size": 1024,
                "hidden_size": 128,
                "intermediate_size": 256,
                "num_hidden_layers": 2,
                "num_attention_heads": 4,
                "num_key_value_heads": 2
            }
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(GLMASRModelConfig.self, from: data)

        // Defaults
        #expect(config.modelType == "glmasr")
        #expect(config.adapterType == "mlp")
        #expect(config.mergeFactor == 4)
        #expect(config.useRope == true)
        #expect(config.maxLength == 65536)

        // LM defaults
        #expect(config.lmConfig.rmsNormEps == 1e-5)
        #expect(config.lmConfig.ropeTheta == 10000.0)
        #expect(config.lmConfig.tieWordEmbeddings == false)
    }

    // MARK: - Task 3: GLMASRModel.sanitize one-way key remapping

    /// Assert that sanitize(weights:) remaps "model.*" keys to "language_model.model.*"
    /// and "lm_head.*" keys to "language_model.lm_head.*".
    @Test func sanitizeRemapsModelPrefixToLanguageModel() {
        let model = makeTinyModel()

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            // Upstream key pattern: model.* -> language_model.model.*
            "model.embed_tokens.weight": someArray,
            "model.layers.0.self_attn.q_proj.weight": someArray,
            "model.norm.weight": someArray,
            // Upstream key pattern: lm_head.* -> language_model.lm_head.*
            "lm_head.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // model.* must be remapped to language_model.model.*
        #expect(sanitized["language_model.model.embed_tokens.weight"] != nil,
                "Expected model.embed_tokens.weight → language_model.model.embed_tokens.weight")
        #expect(sanitized["language_model.model.layers.0.self_attn.q_proj.weight"] != nil,
                "Expected model.layers.0... → language_model.model.layers.0...")
        #expect(sanitized["language_model.model.norm.weight"] != nil,
                "Expected model.norm.weight → language_model.model.norm.weight")

        // lm_head.* must be remapped to language_model.lm_head.*
        #expect(sanitized["language_model.lm_head.weight"] != nil,
                "Expected lm_head.weight → language_model.lm_head.weight")

        // Original keys must be gone
        #expect(sanitized["model.embed_tokens.weight"] == nil,
                "Expected raw model.embed_tokens.weight key to be remapped away")
        #expect(sanitized["lm_head.weight"] == nil,
                "Expected raw lm_head.weight key to be remapped away")
    }

    /// Assert that sanitize(weights:) remaps adapting layer index keys:
    ///   audio_encoder.adapting.0.* → audio_encoder.adapting.fc1.*
    ///   audio_encoder.adapting.2.* → audio_encoder.adapting.fc2.*
    @Test func sanitizeRemapsAdaptingLayerIndices() {
        let model = makeTinyModel()

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            // Upstream PyTorch sequential index keys for adapting MLP
            "audio_encoder.adapting.0.weight": someArray,
            "audio_encoder.adapting.0.bias": someArray,
            "audio_encoder.adapting.2.weight": someArray,
            "audio_encoder.adapting.2.bias": someArray,
            // Unrelated audio encoder key that must pass through
            "audio_encoder.layer_norm.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // .0. → .fc1.
        #expect(sanitized["audio_encoder.adapting.fc1.weight"] != nil,
                "Expected adapting.0.weight → adapting.fc1.weight")
        #expect(sanitized["audio_encoder.adapting.fc1.bias"] != nil,
                "Expected adapting.0.bias → adapting.fc1.bias")

        // .2. → .fc2.
        #expect(sanitized["audio_encoder.adapting.fc2.weight"] != nil,
                "Expected adapting.2.weight → adapting.fc2.weight")
        #expect(sanitized["audio_encoder.adapting.fc2.bias"] != nil,
                "Expected adapting.2.bias → adapting.fc2.bias")

        // Original index keys must be gone
        #expect(sanitized["audio_encoder.adapting.0.weight"] == nil,
                "Expected raw .0. key to be remapped away")
        #expect(sanitized["audio_encoder.adapting.2.weight"] == nil,
                "Expected raw .2. key to be remapped away")

        // Unrelated key must pass through unchanged
        #expect(sanitized["audio_encoder.layer_norm.weight"] != nil,
                "Expected audio_encoder.layer_norm.weight to pass through unchanged")
    }

    /// Assert that sanitize(weights:) transposes 3D conv weights when the last
    /// dimension is smaller than the middle dimension (PyTorch → MLX conv layout).
    @Test func sanitizeTransposesConvWeightsWhenNeeded() {
        let model = makeTinyModel()

        // Simulate a PyTorch-layout conv weight (outChannels, inChannels, kernelSize)
        // in MLX-land the conv weight is (outChannels, kernelSize, inChannels)
        // sanitize must transpose when v.shape[2] < v.shape[1] — i.e. kernelSize < inChannels
        let convWeightNeedsTranspose = MLXArray.zeros([8, 16, 3])   // shape[2]=3 < shape[1]=16
        let convWeightAlreadyOK     = MLXArray.zeros([8, 3, 16])    // shape[2]=16 > shape[1]=3

        let rawWeights: [String: MLXArray] = [
            "audio_encoder.whisper.conv1.weight": convWeightNeedsTranspose,
            "audio_encoder.whisper.conv2.weight": convWeightAlreadyOK,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // Transposed weight: original (8,16,3) → transposed(0,2,1) → (8,3,16)
        let transposedShape = sanitized["audio_encoder.whisper.conv1.weight"]?.shape
        #expect(transposedShape == [8, 3, 16],
                "Expected conv1 weight transposed to (8,3,16), got \(String(describing: transposedShape))")

        // Already-OK weight: (8,3,16) → passes through as-is
        let okShape = sanitized["audio_encoder.whisper.conv2.weight"]?.shape
        #expect(okShape == [8, 3, 16],
                "Expected conv2 weight to pass through as (8,3,16), got \(String(describing: okShape))")
    }

    // MARK: - Task 4: makeCache test for GLMASRLanguageModel (via GLMASRModel)

    /// Assert that GLMASRModel.makeCache() returns one KVCache per LM hidden layer.
    /// The plan asks for a makeCache test scoped to GLMASRLanguageModel; the cache
    /// is created by GLMASRModel.makeCache() which uses config.lmConfig.numHiddenLayers.
    @Test func glmASRMakeCacheReturnsExpectedCount() {
        let config = makeTinyModelConfig()
        let model = GLMASRModel(config: config)

        let cache = model.makeCache()

        #expect(cache.count == config.lmConfig.numHiddenLayers,
                "Expected cache.count == \(config.lmConfig.numHiddenLayers), got \(cache.count)")
    }

    /// Assert that GLMASRLanguageModel.kvHeads has one entry per LM hidden layer,
    /// each equal to numKeyValueHeads — confirming KVCacheDimensionProvider correctness.
    @Test func glmASRLanguageModelKvHeadsMatchesConfig() {
        let lmConfig = makeTinyLMConfig()
        let lm = GLMASRLanguageModel(config: lmConfig)

        #expect(lm.kvHeads.count == lmConfig.numHiddenLayers,
                "Expected kvHeads.count == \(lmConfig.numHiddenLayers), got \(lm.kvHeads.count)")
        for kv in lm.kvHeads {
            #expect(kv == lmConfig.numKeyValueHeads,
                    "Expected each kvHeads entry == \(lmConfig.numKeyValueHeads), got \(kv)")
        }
    }

    // MARK: - Helpers

    /// Return a tiny but valid LlamaConfig for GLMASRLanguageModel construction
    /// without any weight loading.
    private func makeTinyLMConfig() -> LlamaConfig {
        // hiddenSize must be divisible by numAttentionHeads
        // headDim = hiddenSize / numAttentionHeads = 32 / 4 = 8
        return LlamaConfig(
            vocabSize: 256,
            hiddenSize: 32,
            intermediateSize: 64,
            numHiddenLayers: 2,
            numAttentionHeads: 4,
            numKeyValueHeads: 2,
            rmsNormEps: 1e-5,
            ropeTheta: 10000.0,
            ropeDim: 8,
            tieWordEmbeddings: false
        )
    }

    /// Return a tiny but valid GLMASRModelConfig for full GLMASRModel construction.
    private func makeTinyModelConfig() -> GLMASRModelConfig {
        let whisperConfig = WhisperConfig(
            dModel: 32,
            encoderAttentionHeads: 4,
            encoderFfnDim: 64,
            encoderLayers: 2,
            numMelBins: 4,
            maxSourcePositions: 16
        )
        let lmConfig = makeTinyLMConfig()
        return GLMASRModelConfig(
            whisperConfig: whisperConfig,
            lmConfig: lmConfig,
            mergeFactor: 2,
            maxWhisperLength: 16,
            maxLength: 64
        )
    }

    /// Construct a GLMASRModel with tiny synthetic config — no weights, no file I/O.
    private func makeTinyModel() -> GLMASRModel {
        return GLMASRModel(config: makeTinyModelConfig())
    }
}
