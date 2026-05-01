//
//  MarvisTTSTests.swift
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

// MARK: - Marvis TTS Module Setup Tests (CI-safe, no model downloads)

@Suite("MarvisTTSModuleSetupTests")
struct MarvisTTSModuleSetupTests {

    // MARK: - Task 2: CSMModelArgs config decodes from JSON fixture

    /// Assert that CSMModelArgs decodes correctly from the upstream-representative
    /// config fixture at Tests/media/configs/marvis_csm.json.
    @Test func marvisCSMConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "marvis_csm",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "marvis_csm.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(CSMModelArgs.self, from: data)

        #expect(config.modelType == "csm")
        #expect(config.backboneFlavor == "llama-1B")
        #expect(config.decoderFlavor == "llama-100M")
        #expect(config.textVocabSize == 128256)
        #expect(config.audioVocabSize == 2051)
        #expect(config.audioNumCodebooks == 32)
        #expect(config.attentionBias == false)
        #expect(config.numHiddenLayers == 16)
        #expect(config.numAttentionHeads == 32)
        #expect(config.numKeyValueHeads == 8)
        #expect(config.hiddenSize == 2048)
        #expect(config.intermediateSize == 8192)
        #expect(config.rmsNormEps == 1e-5)
        #expect(config.ropeTheta == 500000)
        #expect(config.tieWordEmbeddings == true)
        #expect(config.tieCodebooksEmbeddings == false)
        #expect(config.useCache == true)
        #expect(config.vocabSize == 128256)

        // depth_decoder_config must decode nested struct
        #expect(config.depthDecoderConfig != nil, "Expected depth_decoder_config to be present")
        if let depth = config.depthDecoderConfig {
            #expect(depth.hiddenSize == 1024)
            #expect(depth.numHiddenLayers == 4)
            #expect(depth.numAttentionHeads == 8)
            #expect(depth.numKeyValueHeads == 2)
            #expect(depth.vocabSize == 2051)
            #expect(depth.numCodebooks == 32)
        }

        // rope_scaling must decode correctly
        #expect(config.ropeScaling != nil, "Expected rope_scaling to be present")
    }

    /// Assert that CSMModelArgs decodes from a minimal inline JSON (no depth_decoder_config).
    @Test func marvisCSMConfigDecodesFromMinimalJSON() throws {
        let json = """
        {
            "model_type": "csm",
            "backbone_flavor": "llama-1B",
            "decoder_flavor": "llama-100M",
            "text_vocab_size": 128256,
            "audio_vocab_size": 2051,
            "audio_num_codebooks": 32,
            "attention_bias": false,
            "attention_dropout": 0.0,
            "audio_eos_token_id": 0,
            "audio_token_id": 128257,
            "bos_token_id": 128000,
            "codebook_eos_token_id": 0,
            "codebook_pad_token_id": 0,
            "head_dim": 64,
            "hidden_act": "silu",
            "hidden_size": 2048,
            "initializer_range": 0.02,
            "intermediate_size": 8192,
            "max_position_embeddings": 2048,
            "mlp_bias": false,
            "num_attention_heads": 32,
            "num_codebooks": 32,
            "num_hidden_layers": 16,
            "num_key_value_heads": 8,
            "pad_token_id": 128004,
            "rms_norm_eps": 1e-5,
            "rope_theta": 500000,
            "tie_codebooks_embeddings": false,
            "tie_word_embeddings": true,
            "use_cache": true,
            "vocab_size": 128256
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(CSMModelArgs.self, from: data)

        #expect(config.modelType == "csm")
        #expect(config.textVocabSize == 128256)
        #expect(config.audioNumCodebooks == 32)
        // No depth_decoder_config provided
        #expect(config.depthDecoderConfig == nil)
        // No rope_scaling provided
        #expect(config.ropeScaling == nil)
        // No quantization provided
        #expect(config.quantization == nil)
    }

    // MARK: - Task 3: CSMLlamaConfiguration config decodes from JSON fixture

    /// Assert that CSMLlamaConfiguration decodes correctly from the upstream-representative
    /// config fixture at Tests/media/configs/marvis_csm_llama.json.
    @Test func marvisCSMLlamaConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "marvis_csm_llama",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "marvis_csm_llama.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(CSMLlamaConfiguration.self, from: data)

        #expect(config.hiddenSize == 2048)
        #expect(config.hiddenLayers == 16)
        #expect(config.intermediateSize == 8192)
        #expect(config.attentionHeads == 32)
        #expect(config.headDimensions == 64)
        #expect(config.kvHeads == 8)
        #expect(config.maxPositionEmbeddings == 2048)
        #expect(config.ropeTheta == 500000.0)
        #expect(config.ropeTraditional == false)
        #expect(config.tieWordEmbeddings == true)
        #expect(config.attentionBias == false)
        #expect(config.mlpBias == false)
        #expect(config.vocabularySize == 128256)
        #expect(config.rmsNormEps == 1e-5)

        // rope_scaling must decode
        #expect(config.ropeScaling != nil, "Expected rope_scaling to be present")
    }

    /// Assert that CSMLlamaConfiguration decodes from minimal inline JSON with defaults applied.
    @Test func marvisCSMLlamaConfigDecodesFromMinimalJSON() throws {
        let json = """
        {
            "hidden_size": 1024,
            "num_hidden_layers": 4,
            "intermediate_size": 4096,
            "num_attention_heads": 8,
            "rms_norm_eps": 1e-5,
            "vocab_size": 128256
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(CSMLlamaConfiguration.self, from: data)

        #expect(config.hiddenSize == 1024)
        #expect(config.hiddenLayers == 4)
        // kvHeads defaults to attentionHeads when omitted
        #expect(config.kvHeads == 8)
        // Defaults
        #expect(config.ropeTheta == 10000)
        #expect(config.ropeTraditional == false)
        #expect(config.tieWordEmbeddings == true)
        #expect(config.attentionBias == false)
        #expect(config.mlpBias == false)
        #expect(config.ropeScaling == nil)
        #expect(config.headDimensions == nil)
    }

    // MARK: - Task 4: sanitize strips expected prefixes (CSMLlamaModel)

    /// Assert that CSMLlamaModel.sanitize(weights:) removes self_attn.rotary_emb.inv_freq keys.
    /// This is the only sanitize method exposed on Marvis production types —
    /// CSMModel's top-level sanitize is private-static on MarvisTTSModel.
    @Test func marvisSanitizeStripsExpectedPrefixes() {
        let config = makeTinyCSMLlamaConfig()
        let model = CSMLlamaModel(config)

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            // Legitimate learnable weights that must survive
            "layers.0.self_attn.q_proj.weight": someArray,
            "layers.0.self_attn.k_proj.weight": someArray,
            "layers.0.self_attn.v_proj.weight": someArray,
            "layers.0.self_attn.o_proj.weight": someArray,
            "norm.weight": someArray,
            // inv_freq is a computed buffer — must be removed
            "layers.0.self_attn.rotary_emb.inv_freq": someArray,
            "layers.1.self_attn.rotary_emb.inv_freq": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // All inv_freq keys must be gone
        let invFreqKeys = sanitized.keys.filter { $0.contains("rotary_emb.inv_freq") }
        #expect(invFreqKeys.isEmpty,
                "Expected all rotary_emb.inv_freq keys to be removed; found: \(invFreqKeys)")

        // Legitimate weight keys must survive
        #expect(sanitized["layers.0.self_attn.q_proj.weight"] != nil,
                "Expected q_proj.weight to survive sanitize")
        #expect(sanitized["layers.0.self_attn.k_proj.weight"] != nil,
                "Expected k_proj.weight to survive sanitize")
        #expect(sanitized["norm.weight"] != nil,
                "Expected norm.weight to survive sanitize")
    }

    /// Assert that CSMLlamaModel.sanitize(weights:) passes through keys that
    /// do not contain rotary_emb.inv_freq unchanged.
    @Test func marvisSanitizePreservesNonInvFreqKeys() {
        let config = makeTinyCSMLlamaConfig()
        let model = CSMLlamaModel(config)

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            "layers.0.self_attn.q_proj.weight": someArray,
            "layers.0.mlp.gate_proj.weight": someArray,
            "layers.0.input_layernorm.weight": someArray,
            "embed_tokens.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // All keys should pass through unchanged — no inv_freq keys to remove
        #expect(sanitized.count == rawWeights.count,
                "Expected sanitize to pass through all non-inv_freq keys; got \(sanitized.count) vs \(rawWeights.count)")
        for key in rawWeights.keys {
            #expect(sanitized[key] != nil, "Expected key \(key) to survive sanitize")
        }
    }

    // MARK: - Task 5: makeCache returns expected shape

    /// Assert that CSMLlamaModel.newCache(parameters:) returns one KVCache per hidden layer.
    /// CSMLlamaModel conforms to KVCacheDimensionProvider, so the cache count is driven by kvHeads.count.
    @Test func marvisMakeCacheReturnsExpectedShape() {
        let config = makeTinyCSMLlamaConfig()
        let model = CSMLlamaModel(config)

        let cache = model.newCache(parameters: nil)

        // Cache count must match the number of transformer layers in config
        #expect(cache.count == config.hiddenLayers,
                "Expected cache.count == \(config.hiddenLayers), got \(cache.count)")

        // kvHeads array must have one entry per layer
        #expect(model.kvHeads.count == config.hiddenLayers,
                "Expected kvHeads.count == \(config.hiddenLayers), got \(model.kvHeads.count)")
        for kv in model.kvHeads {
            #expect(kv == config.kvHeads,
                    "Expected each kvHeads entry == \(config.kvHeads), got \(kv)")
        }
    }

    /// Assert that CSMModel.resetCaches() correctly wires backbone and decoder caches
    /// with counts matching their respective layer configurations.
    @Test func marvisCSMModelResetCachesShape() {
        let args = makeTinyCSMModelArgs()
        let model = CSMModel(config: args)

        // resetCaches() creates backbone and decoder KVCache arrays
        model.resetCaches()

        // Backbone cache: driven by DepthDecoderConfig backbone path —
        // numHiddenLayers comes from args.numHiddenLayers (backbone uses CSMModelArgs fields)
        let backboneCount = model.backboneCache?.count ?? -1
        #expect(backboneCount == args.numHiddenLayers,
                "Expected backboneCache.count == \(args.numHiddenLayers), got \(backboneCount)")

        // Decoder cache: driven by depthDecoderConfig.numHiddenLayers
        let decoderLayerCount = args.depthDecoderConfig!.numHiddenLayers
        let decoderCount = model.decoderCache?.count ?? -1
        #expect(decoderCount == decoderLayerCount,
                "Expected decoderCache.count == \(decoderLayerCount), got \(decoderCount)")

        // cachesEnabled must be true after resetCaches()
        #expect(model.cachesAreEnabled() == true)
    }

    // MARK: - Helpers

    /// Return a tiny but valid CSMLlamaConfiguration — small enough that
    /// instantiating the model (no weights) completes in milliseconds.
    private func makeTinyCSMLlamaConfig() -> CSMLlamaConfiguration {
        // hiddenSize must be divisible by attentionHeads
        // headDim = hiddenSize / attentionHeads = 32 / 4 = 8
        return CSMLlamaConfiguration(
            hiddenSize: 32,
            hiddenLayers: 2,
            intermediateSize: 64,
            attentionHeads: 4,
            headDimensions: 8,
            rmsNormEps: 1e-5,
            vocabularySize: 256,
            kvHeads: 2,
            maxPositionEmbeddings: 64,
            ropeTheta: 500000,
            ropeTraditional: false,
            ropeScaling: [
                "factor": .float(32.0),
                "low_freq_factor": .float(1.0),
                "high_freq_factor": .float(4.0),
                "original_max_position_embeddings": .float(8192.0),
                "rope_type": .string("llama3")
            ],
            tieWordEmbeddings: true,
            attentionBias: false,
            mlpBias: false
        )
    }

    /// Return a tiny but valid DepthDecoderConfig for model construction without weight loading.
    private func makeTinyDepthDecoderConfig(backboneHiddenSize: Int) -> DepthDecoderConfig {
        return DepthDecoderConfig(
            attentionBias: false,
            attentionDropout: 0.0,
            backboneHiddenSize: backboneHiddenSize,
            headDim: 8,
            hiddenAct: "silu",
            hiddenSize: 32,
            initializerRange: 0.02,
            intermediateSize: 64,
            maxPositionEmbeddings: 64,
            mlpBias: false,
            modelType: "csm_depth_decoder",
            numAttentionHeads: 4,
            numCodebooks: 2,
            numHiddenLayers: 2,
            numKeyValueHeads: 2,
            rmsNormEps: 1e-5,
            ropeScaling: nil,
            ropeTheta: 500000,
            useCache: true,
            vocabSize: 64
        )
    }

    /// Return a tiny but valid CSMModelArgs that uses depthDecoderConfig path
    /// (avoids the flavor->hardcoded-config lookup, allowing tiny dimensions).
    private func makeTinyCSMModelArgs() -> CSMModelArgs {
        let backboneHiddenSize = 32
        let depthDecoder = makeTinyDepthDecoderConfig(backboneHiddenSize: backboneHiddenSize)

        return CSMModelArgs(
            modelType: "csm",
            backboneFlavor: "llama-1B",   // not used when depthDecoderConfig is set
            decoderFlavor: "llama-100M",  // not used when depthDecoderConfig is set
            textVocabSize: 64,
            audioVocabSize: 32,
            audioNumCodebooks: 2,
            attentionBias: false,
            attentionDropout: 0.0,
            audioEosTokenId: 0,
            audioTokenId: 65,
            bosTokenId: 1,
            codebookEosTokenId: 0,
            codebookPadTokenId: 0,
            depthDecoderConfig: depthDecoder,
            headDim: 8,
            hiddenAct: "silu",
            hiddenSize: backboneHiddenSize,
            initializerRange: 0.02,
            intermediateSize: 64,
            maxPositionEmbeddings: 64,
            mlpBias: false,
            numAttentionHeads: 4,
            numCodebooks: 2,
            numHiddenLayers: 2,
            numKeyValueHeads: 2,
            padTokenId: 0,
            rmsNormEps: 1e-5,
            ropeScaling: nil,
            ropeTheta: 500000,
            tieCodebooksEmbeddings: false,
            tieWordEmbeddings: true,
            useCache: true,
            vocabSize: 64,
            quantization: nil
        )
    }
}
