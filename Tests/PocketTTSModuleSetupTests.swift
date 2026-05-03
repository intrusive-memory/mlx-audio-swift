//
//  PocketTTSModuleSetupTests.swift
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

// MARK: - PocketTTS Module Setup Tests (CI-safe, no model downloads)

@Suite("PocketTTSModuleSetupTests")
struct PocketTTSModuleSetupTests {

    // MARK: - Task 2a: FlowLM config decodes from JSON fixture

    /// Assert that PocketTTSFlowLMConfig decodes correctly from the upstream-representative
    /// fixture at Tests/media/configs/pockettts_flowlm.json.
    @Test func flowLMConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "pockettts_flowlm",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "pockettts_flowlm.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(PocketTTSFlowLMConfig.self, from: data)

        #expect(config.flow.dim == 512)
        #expect(config.flow.depth == 4)
        #expect(config.transformer.dModel == 1024)
        #expect(config.transformer.numHeads == 16)
        #expect(config.transformer.numLayers == 16)
        #expect(config.transformer.hiddenScale == 4)
        #expect(config.transformer.maxPeriod == 10000.0)
        #expect(config.lookupTable.dim == 512)
        #expect(config.lookupTable.nBins == 32064)
        #expect(config.lookupTable.tokenizer == "sentencepiece")
        #expect(config.dtype == "bfloat16")
        #expect(config.weightsPath == "flow_lm.safetensors")
    }

    /// Assert that PocketTTSFlowLMConfig decodes from a minimal inline JSON and
    /// that optional fields default to nil.
    @Test func flowLMConfigDecodesFromMinimalJSON() throws {
        let json = """
        {
            "flow": { "dim": 256, "depth": 2 },
            "transformer": {
                "hidden_scale": 4,
                "max_period": 10000.0,
                "d_model": 512,
                "num_heads": 8,
                "num_layers": 8
            },
            "lookup_table": {
                "dim": 256,
                "n_bins": 1000,
                "tokenizer": "sentencepiece",
                "tokenizer_path": "tok.model"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(PocketTTSFlowLMConfig.self, from: data)

        #expect(config.flow.dim == 256)
        #expect(config.transformer.numLayers == 8)
        #expect(config.dtype == nil)
        #expect(config.weightsPath == nil)
    }

    // MARK: - Task 2b: Conditioners (LookupTable) config decodes from JSON fixture

    /// Assert that PocketTTSLookupTableConfig decodes correctly from the
    /// fixture at Tests/media/configs/pockettts_conditioners.json.
    @Test func conditionersConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "pockettts_conditioners",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "pockettts_conditioners.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(PocketTTSLookupTableConfig.self, from: data)

        #expect(config.dim == 512)
        #expect(config.nBins == 32064)
        #expect(config.tokenizer == "sentencepiece")
        #expect(config.tokenizerPath == "tokenizer.model")
    }

    // MARK: - Task 2c: MimiAdapter config decodes from JSON fixture

    /// Assert that PocketTTSMimiConfig decodes correctly from the
    /// fixture at Tests/media/configs/pockettts_mimi_adapter.json.
    @Test func mimiAdapterConfigDecodesFromJSON() throws {
        let url = Bundle.module.url(
            forResource: "pockettts_mimi_adapter",
            withExtension: "json",
            subdirectory: "media/configs"
        )
        #expect(url != nil, "pockettts_mimi_adapter.json fixture not found in bundle")
        let data = try Data(contentsOf: url!)
        let config = try JSONDecoder().decode(PocketTTSMimiConfig.self, from: data)

        #expect(config.sampleRate == 24000)
        #expect(config.channels == 1)
        #expect(config.frameRate == 12.5)
        #expect(config.seanet.dimension == 512)
        #expect(config.seanet.nFilters == 64)
        #expect(config.seanet.ratios == [8, 6, 5, 4])
        #expect(config.seanet.kernelSize == 7)
        #expect(config.seanet.padMode == "constant")
        #expect(config.transformer.dModel == 512)
        #expect(config.transformer.numHeads == 8)
        #expect(config.transformer.numLayers == 8)
        #expect(config.transformer.layerScale == 0.01)
        #expect(config.transformer.context == 250)
        #expect(config.quantizer.dimension == 256)
        #expect(config.quantizer.outputDimension == 1024)
        #expect(config.dtype == "bfloat16")
        #expect(config.weightsPath == "mimi.safetensors")
    }

    /// Assert that PocketTTSMimiConfig decodes from minimal inline JSON (no optional fields).
    @Test func mimiAdapterConfigDecodesFromMinimalJSON() throws {
        let json = """
        {
            "sample_rate": 24000,
            "channels": 1,
            "frame_rate": 12.5,
            "seanet": {
                "dimension": 256,
                "channels": 1,
                "n_filters": 32,
                "n_residual_layers": 1,
                "ratios": [4, 4],
                "kernel_size": 7,
                "residual_kernel_size": 3,
                "last_kernel_size": 3,
                "dilation_base": 2,
                "pad_mode": "constant",
                "compress": 2
            },
            "transformer": {
                "d_model": 256,
                "input_dimension": 256,
                "output_dimensions": [256],
                "num_heads": 4,
                "num_layers": 4,
                "layer_scale": 0.01,
                "context": 100,
                "dim_feedforward": 1024,
                "max_period": 10000.0
            },
            "quantizer": {
                "dimension": 128,
                "output_dimension": 512
            }
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(PocketTTSMimiConfig.self, from: data)

        #expect(config.sampleRate == 24000)
        #expect(config.transformer.numLayers == 4)
        #expect(config.dtype == nil)
        #expect(config.weightsPath == nil)
    }

    // MARK: - Task 3: sanitize strips expected keys

    /// Assert that sanitize(weights:) removes the computed-buffer keys (freqs) that
    /// would appear in a raw PyTorch checkpoint but have no Swift module parameter counterpart.
    @Test func sanitizeDropsTimeEmbedFreqsKeys() {
        let model = makeTinyModel()

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            // Legitimate learnable weights that must survive
            "flow_lm.transformer.layers.0.self_attn.in_proj.weight": someArray,
            "flow_lm.transformer.layers.0.norm1.weight": someArray,
            "flow_lm.input_linear.weight": someArray,
            "flow_lm.out_eos.weight": someArray,
            "flow_lm.emb_std": someArray,
            "flow_lm.emb_mean": someArray,
            "speaker_proj_weight": someArray,
            // Computed buffer keys that must be filtered out
            "flow_lm.flow_net.time_embed.0.freqs": someArray,
            "flow_lm.flow_net.time_embed.1.freqs": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // Buffer keys must be gone
        let freqsKeys = sanitized.keys.filter { $0.contains(".time_embed.") && $0.hasSuffix(".freqs") }
        #expect(freqsKeys.isEmpty,
                "Expected all time_embed.*.freqs keys to be removed; found: \(freqsKeys)")

        // Learnable keys must survive
        #expect(sanitized["flow_lm.transformer.layers.0.self_attn.in_proj.weight"] != nil)
        #expect(sanitized["flow_lm.input_linear.weight"] != nil)
        #expect(sanitized["flow_lm.emb_std"] != nil)
        #expect(sanitized["flow_lm.emb_mean"] != nil)
        #expect(sanitized["speaker_proj_weight"] != nil)
    }

    /// Assert that sanitize(weights:) strips leading underscores from path segments
    /// that might appear in raw upstream (non-MLX-converted) checkpoints.
    @Test func sanitizeStripsUnderscorePrefixes() {
        let model = makeTinyModel()

        let someArray = MLXArray.zeros([4])
        let rawWeights: [String: MLXArray] = [
            // Raw upstream keys with underscore-prefixed private-attr convention
            "_flow_lm._transformer._layers.0._self_attn._in_proj.weight": someArray,
            "flow_lm.input_linear.weight": someArray,
        ]

        let sanitized = model.sanitize(weights: rawWeights)

        // Underscore-stripped key must appear
        #expect(sanitized["flow_lm.transformer.layers.0.self_attn.in_proj.weight"] != nil,
                "Expected underscore-stripped key to exist after sanitize")

        // Clean key must pass through unchanged
        #expect(sanitized["flow_lm.input_linear.weight"] != nil)

        // Original underscore-prefixed key must not be present
        #expect(sanitized["_flow_lm._transformer._layers.0._self_attn._in_proj.weight"] == nil,
                "Expected raw underscore-prefixed key to be gone after sanitize")
    }

    // MARK: - Task 4: makeCache returns expected shape

    /// Assert that FlowLMModel.makeCache() returns one KVCacheSimple per transformer layer.
    @Test func flowLMTransformerMakeCacheReturnsExpectedCount() {
        let flowLMConfig = makeTinyFlowLMConfig()

        let transformer = PocketStreamingTransformer(
            dModel: flowLMConfig.transformer.dModel,
            numHeads: flowLMConfig.transformer.numHeads,
            numLayers: flowLMConfig.transformer.numLayers,
            dimFeedforward: flowLMConfig.transformer.hiddenScale * flowLMConfig.transformer.dModel,
            maxPeriod: flowLMConfig.transformer.maxPeriod,
            layerScale: nil
        )

        let cache = transformer.makeCache()

        // Count must match num_layers from config
        #expect(cache.count == flowLMConfig.transformer.numLayers,
                "Expected cache.count == \(flowLMConfig.transformer.numLayers), got \(cache.count)")
    }

    /// Assert that MimiAdapter caches are initialised with the correct layer count
    /// from the transformer config (encoder and decoder transformers share the same depth).
    @Test func mimiAdapterCacheCountMatchesTransformerLayers() {
        let mimiConfig = makeTinyMimiConfig()
        let mimi = MimiAdapter.fromConfig(mimiConfig)

        #expect(mimi.encoderCache.count == mimiConfig.transformer.numLayers,
                "encoderCache.count \(mimi.encoderCache.count) != transformer.numLayers \(mimiConfig.transformer.numLayers)")
        #expect(mimi.decoderCache.count == mimiConfig.transformer.numLayers,
                "decoderCache.count \(mimi.decoderCache.count) != transformer.numLayers \(mimiConfig.transformer.numLayers)")
    }

    /// Assert that PocketTTSModel.initState() returns a flow cache with one entry per
    /// FlowLM transformer layer — verifying end-to-end makeCache wiring.
    @Test func pocketTTSModelInitStateFlowCacheCount() {
        let model = makeTinyModel()
        let flowLMConfig = makeTinyFlowLMConfig()

        let state = model.initState()

        #expect(state.flowCache.count == flowLMConfig.transformer.numLayers,
                "Expected flowCache.count == \(flowLMConfig.transformer.numLayers), got \(state.flowCache.count)")
    }

    // MARK: - Helpers

    /// Return a tiny but valid FlowLM config for model construction without weight loading.
    /// Dimensions are chosen to satisfy divisibility constraints (dModel / numHeads must be even).
    private func makeTinyFlowLMConfig() -> PocketTTSFlowLMConfig {
        PocketTTSFlowLMConfig(
            dtype: nil,
            flow: PocketTTSFlowConfig(dim: 16, depth: 1),
            transformer: PocketTTSFlowLMTransformerConfig(
                hiddenScale: 2,
                maxPeriod: 10000.0,
                dModel: 16,
                numHeads: 2,
                numLayers: 2
            ),
            lookupTable: PocketTTSLookupTableConfig(
                dim: 16,
                nBins: 64,
                tokenizer: "sentencepiece",
                tokenizerPath: "tokenizer.model"
            ),
            weightsPath: nil
        )
    }

    /// Return a tiny but valid Mimi config for model construction without weight loading.
    private func makeTinyMimiConfig() -> PocketTTSMimiConfig {
        PocketTTSMimiConfig(
            dtype: nil,
            sampleRate: 24000,
            channels: 1,
            frameRate: 12.5,
            seanet: PocketTTSSeanetConfig(
                dimension: 16,
                channels: 1,
                nFilters: 4,
                nResidualLayers: 1,
                ratios: [2, 2],
                kernelSize: 7,
                residualKernelSize: 3,
                lastKernelSize: 3,
                dilationBase: 2,
                padMode: "constant",
                compress: 2
            ),
            transformer: PocketTTSMimiTransformerConfig(
                dModel: 16,
                inputDimension: 16,
                outputDimensions: [16],
                numHeads: 2,
                numLayers: 2,
                layerScale: 0.01,
                context: 8,
                dimFeedforward: 32,
                maxPeriod: 10000.0
            ),
            quantizer: PocketTTSQuantizerConfig(dimension: 8, outputDimension: 16),
            weightsPath: nil
        )
    }

    /// Construct a PocketTTSModel with tiny synthetic weights, bypassing all file I/O.
    /// Uses the testing-only internal init that accepts pre-built sub-models.
    private func makeTinyModel() -> PocketTTSModel {
        let flowLMConfig = makeTinyFlowLMConfig()
        let mimiConfig = makeTinyMimiConfig()

        let dModel = flowLMConfig.transformer.dModel
        let ldim = mimiConfig.quantizer.dimension

        // Use the testing-only internal init on LUTConditioner — no tokenizer file required.
        let conditioner = LUTConditioner(
            nBins: flowLMConfig.lookupTable.nBins,
            dim: flowLMConfig.lookupTable.dim,
            outputDim: dModel
        )

        let flowNet = SimpleMLPAdaLN(
            inChannels: ldim,
            modelChannels: flowLMConfig.flow.dim,
            outChannels: ldim,
            condChannels: dModel,
            numResBlocks: flowLMConfig.flow.depth,
            numTimeConds: 2
        )

        let transformer = PocketStreamingTransformer(
            dModel: dModel,
            numHeads: flowLMConfig.transformer.numHeads,
            numLayers: flowLMConfig.transformer.numLayers,
            dimFeedforward: flowLMConfig.transformer.hiddenScale * dModel,
            maxPeriod: flowLMConfig.transformer.maxPeriod,
            layerScale: nil
        )

        let flowLM = FlowLMModel(
            conditioner: conditioner,
            flowNet: flowNet,
            transformer: transformer,
            dim: dModel,
            ldim: ldim
        )

        let mimi = MimiAdapter.fromConfig(mimiConfig)

        let modelConfig = PocketTTSModelConfig(
            modelType: "pocket_tts",
            flowLM: flowLMConfig,
            mimi: mimiConfig,
            weightsPath: nil,
            weightsPathWithoutVoiceCloning: nil,
            modelPath: nil
        )

        // Uses the testing-only internal init — no modelFolder / file I/O required.
        return PocketTTSModel(config: modelConfig, flowLM: flowLM, mimi: mimi)
    }
}
