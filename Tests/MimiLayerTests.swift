//
//  MimiLayerTests.swift
//  MLXAudioTests
//
//  Sortie 17 of OPERATION ECHO DRAGNET — Mimi codec layer-level unit tests.
//
//  This file exercises five Mimi building blocks:
//    1. Conv1d (causal) — shape test
//    2. SeanetResnetBlock — shape test
//    3. Transformer — shape test
//    4. ResidualVectorQuantization — shape test
//    5. ResidualVectorQuantization — numeric-parity assertion (mimi_rvq fixture)
//
//  Shape tests use random-init weights (no fixture) and assert output
//  dimensions only — not values. The parity assertion loads the Sortie 1
//  fixture from Tests/media/parity/mimi_rvq/ and asserts
//  MLX.allClose(swift_out, expected, atol: 1e-4, rtol: 1e-4).
//
//  CI-safe: no model downloads. Wired into the CLAUDE.md -only-testing list.
//
//  Production-code-scope discipline: zero modifications to Sources/ files.
//  All Swift entry points are accessed via their public init / callAsFunction.
//

import Foundation
import MLX
import MLXNN
import MLXLMCommon
import Testing

@testable import MLXAudioCodecs

// MARK: - MimiLayerTests

@Suite("MimiLayerTests")
struct MimiLayerTests {

    /// Tolerance used by the numeric-parity assertion.
    /// Matches the project-wide parity contract (EXECUTION_PLAN.md C1).
    static let parityATol: Double = 1e-4
    static let parityRTol: Double = 1e-4

    // MARK: - Conv1d shape test
    //
    // Target: Sources/MLXAudioCodecs/Mimi/Conv.swift — public final class Conv1d
    // Input  [N=1, C_in=4, L=16] (NCL)
    // Output [N=1, C_out=8, L=16] (NCL, causal padding keeps L intact for stride=1)

    @Test func conv1dOutputShape() throws {
        let inC = 4
        let outC = 8
        let ksize = 3
        let padding = 1  // (ksize-1)/2 for stride=1, preserves length

        let conv = Conv1d(
            inChannels: inC,
            outChannels: outC,
            ksize: ksize,
            stride: 1,
            padding: padding,
            groups: 1,
            dilation: 1,
            bias: true
        )

        // NCL input: batch=1, channels=4, length=16
        let input = MLXRandom.normal([1, inC, 16])
        let output = conv(input)

        #expect(output.shape[0] == 1,  "batch dim should be 1")
        #expect(output.shape[1] == outC, "channel dim should be \(outC)")
        #expect(output.shape[2] == 16, "length should be preserved for padding=\(padding), stride=1")
    }

    // MARK: - SeanetResnetBlock shape test
    //
    // Target: Sources/MLXAudioCodecs/Mimi/Seanet.swift — public final class SeanetResnetBlock
    // Uses StreamableConv1d internally (causal, constant padding).
    // Input  [N=1, C=16, L=32] (NCL)
    // Output [N=1, C=16, L>=1] (length may vary due to causal extra-padding logic)

    @Test func seanetResnetBlockOutputShape() throws {
        let dim = 16
        let cfg = SeanetConfig(
            dimension: dim,
            channels: 1,
            causal: true,
            nfilters: dim,
            nresidualLayers: 1,
            ratios: [1],
            ksize: 3,
            residualKsize: 3,
            lastKsize: 3,
            dilationBase: 2,
            padMode: .constant,
            trueSkip: true,   // no shortcut conv — pure residual add
            compress: 2
        )

        let block = SeanetResnetBlock(
            cfg: cfg,
            dim: dim,
            ksizesAndDilations: [(3, 1), (1, 1)]
        )

        // NCL input: batch=1, channels=16, length=32
        let input = MLXRandom.normal([1, dim, 32])
        let output = block(input)

        #expect(output.shape[0] == 1,   "batch dim should be 1")
        #expect(output.shape[1] == dim, "channel dim should be \(dim)")
        #expect(output.shape[2] >= 1,   "output length should be non-zero")
    }

    // MARK: - Transformer block shape test
    //
    // Target: Sources/MLXAudioCodecs/Mimi/Transformer.swift — public final class Transformer
    //
    // TransformerLayer.callAsFunction has force-casts that require:
    //   - gating: false    → module stored as MlpNoGating (not MlpGating)
    //   - norm: "layer_norm" → norm2 stored as LayerNorm (not RMSNorm)
    //   - layerScale != nil → layer_scale_1/2 stored as LayerScale (not Id)
    //   - useConvBlock: false, crossAttention: false (preconditions in init)
    //
    // Input  [B=1, T=8, D=16]  (batch, time, model-dim) — convLayout=false
    // Output [B=1, T=8, D=16]

    @Test func transformerOutputShape() throws {
        let dModel = 16
        let numHeads = 2
        let numLayers = 1

        let cfg = TransformerConfig(
            dModel: dModel,
            numHeads: numHeads,
            numLayers: numLayers,
            causal: true,
            normFirst: true,
            biasFF: false,
            biasAttn: false,
            layerScale: 1.0,       // non-nil → LayerScale modules (required by force-cast)
            positionalEmbedding: "rope",
            useConvBlock: false,   // precondition in TransformerLayer.init
            crossAttention: false, // precondition in TransformerLayer.init
            convKernelSize: 3,
            useConvBias: true,
            gating: false,         // → MlpNoGating (required by force-cast)
            norm: "layer_norm",    // → LayerNorm (required by force-cast)
            context: 250,
            maxPeriod: 10_000,
            maxSeqLen: 1_024,
            kvRepeat: 1,
            dimFeedforward: dModel * 4,
            convLayout: false      // input is [B,T,D] (NLC), not [B,D,T] (NCL)
        )

        let transformer = Transformer(cfg: cfg)
        let cache = transformer.makeCache()

        // [B=1, T=8, D=16]
        let input = MLXRandom.normal([1, 8, dModel])
        let output = transformer(input, cache: cache)

        #expect(output.shape[0] == 1,      "batch dim should be 1")
        #expect(output.shape[1] == 8,      "time dim should be 8")
        #expect(output.shape[2] == dModel, "model dim should be \(dModel)")
    }

    // MARK: - ResidualVectorQuantization shape test
    //
    // Target: Sources/MLXAudioCodecs/Mimi/Quantization.swift
    //         — public final class ResidualVectorQuantization
    //
    // Input  [1, 8, 12] (NCL)
    // encode → indices [nq=2, 1, 12]
    // decode(indices) → quantized [1, 8, 12]

    @Test func rvqOutputShape() throws {
        let dim = 8
        let nq = 2
        let codebookSize = 16

        let rvq = ResidualVectorQuantization(
            nq: nq,
            dim: dim,
            codebookSize: codebookSize,
            codebookDim: nil  // codebookDim == dim → no project_in/out
        )

        let input = MLXRandom.normal([1, dim, 12])
        let indices = rvq.encode(input)

        // encode returns stacked([nq, B, T]) so shape is [nq, 1, 12]
        #expect(indices.shape[0] == nq, "first dim of indices should be nq=\(nq)")
        #expect(indices.shape[1] == 1,  "batch dim should be 1")
        #expect(indices.shape[2] == 12, "time dim should be 12")

        let quantized = rvq.decode(indices)

        #expect(quantized.shape[0] == 1,   "batch dim should be 1")
        #expect(quantized.shape[1] == dim, "channel dim should be \(dim)")
        #expect(quantized.shape[2] == 12,  "time dim should be 12")
    }

    // MARK: - RVQ numeric-parity assertion
    //
    // Target: Sources/MLXAudioCodecs/Mimi/Quantization.swift
    //         — public final class ResidualVectorQuantization
    //
    // Uses the Sortie 1 fixture from Tests/media/parity/mimi_rvq/:
    //   input.safetensors  — key "x"         shape [1, 8, 12] (NCL)
    //   weights.safetensors — keys "layers.0.codebook", "layers.1.codebook"
    //                         each shape [16, 8]  (codebook_size × dim)
    //   expected.safetensors — key "quantized" shape [1, 8, 12]
    //                          key "indices"   shape [1, 2, 12] (float32)
    //
    // NOTE: The Sortie 1 agent flagged that this fixture uses a basic 2-layer
    // residual stack rather than Mimi's full SplitResidualVectorQuantizer.
    // The split-residual (semantic + acoustic) structure is out of scope for
    // Sortie 17 per the plan.
    //
    // Weight loading:
    //   Python stores a plain codebook parameter; Swift's EuclideanCodebook
    //   computes _embedding from (embedding_sum / max(cluster_usage, ε)).
    //   To reproduce the Python result we set embedding_sum = codebook,
    //   cluster_usage = ones, then call updateInPlace() which recomputes
    //   _embedding = embedding_sum / 1 = codebook.
    //   Both embedding_sum and cluster_usage are public var, so this requires
    //   zero modifications to production code.

    @Test func mimiRVQMatchesPythonReference() throws {
        let fixture = try loadParityFixture("mimi_rvq")

        // --- Load input ---
        guard let inputArr = fixture.input["x"] else {
            Issue.record("mimi_rvq input.safetensors missing key 'x'")
            return
        }
        // inputArr shape: [1, 8, 12]

        // --- Load expected ---
        guard let expectedQuantized = fixture.expected["quantized"] else {
            Issue.record("mimi_rvq expected.safetensors missing key 'quantized'")
            return
        }
        guard let expectedIndicesF = fixture.expected["indices"] else {
            Issue.record("mimi_rvq expected.safetensors missing key 'indices'")
            return
        }

        // --- Load weights ---
        guard
            let cb0 = fixture.weights["layers.0.codebook"],
            let cb1 = fixture.weights["layers.1.codebook"]
        else {
            Issue.record("mimi_rvq weights.safetensors missing 'layers.0.codebook' or 'layers.1.codebook'")
            return
        }
        // cb0, cb1 each have shape [codebook_size=16, dim=8]

        let dim = cb0.shape[1]
        let codebookSize = cb0.shape[0]
        let nq = 2

        // --- Construct RVQ with matching dims ---
        let rvq = ResidualVectorQuantization(
            nq: nq,
            dim: dim,
            codebookSize: codebookSize,
            codebookDim: nil   // same as dim → no project_in/out
        )

        // --- Inject codebook weights ---
        // Set embedding_sum = codebook, cluster_usage = ones(codebook_size).
        // updateInPlace() recomputes _embedding = embedding_sum / max(usage, ε) = codebook.
        rvq.layers[0].codebook.embedding_sum = cb0
        rvq.layers[0].codebook.cluster_usage = MLXArray.ones([codebookSize])
        rvq.layers[0].codebook.updateInPlace()

        rvq.layers[1].codebook.embedding_sum = cb1
        rvq.layers[1].codebook.cluster_usage = MLXArray.ones([codebookSize])
        rvq.layers[1].codebook.updateInPlace()

        eval(rvq)

        // --- Forward pass ---
        // encode returns [nq, B, T]; decode returns [B, dim, T]
        let indices = rvq.encode(inputArr)
        let swiftQuantized = rvq.decode(indices)

        eval(swiftQuantized)

        // --- Shape assertions ---
        #expect(
            swiftQuantized.shape == expectedQuantized.shape,
            "quantized shape mismatch: swift=\(swiftQuantized.shape) expected=\(expectedQuantized.shape)"
        )

        // --- Numeric-parity assertion ---
        let close = MLX.allClose(
            swiftQuantized,
            expectedQuantized,
            rtol: Self.parityRTol,
            atol: Self.parityATol
        )
        let isClose = close.item(Bool.self)

        if !isClose {
            // Compute max absolute error for the report
            let maxAbsErr = abs(swiftQuantized - expectedQuantized).max().item(Float.self)
            Issue.record("RVQ quantized != Python reference. max_abs_err=\(maxAbsErr) (atol=\(Self.parityATol), rtol=\(Self.parityRTol))")
        }
        #expect(isClose, "mimiRVQMatchesPythonReference: allClose failed (atol=\(Self.parityATol), rtol=\(Self.parityRTol))")

        // --- Indices shape sanity (not a parity assertion — Python stores [B,nq,T], Swift [nq,B,T]) ---
        // The expected indices shape is [1, 2, 12] (Python batch-first).
        // Swift encode returns [2, 1, 12] (nq-first). Both represent the same data.
        // We verify the decode roundtrip covers correctness; indices shape difference
        // is a known layout convention difference, not a bug.
        let expectedIndices = expectedIndicesF.asType(.int32)
        let swiftIndicesTransposed = swappedAxes(indices, 0, 1)  // [nq,B,T] → [B,nq,T]
        let indicesClose = MLX.allClose(
            swiftIndicesTransposed.asType(.float32),
            expectedIndicesF,
            rtol: 0,
            atol: 0
        )
        #expect(indicesClose.item(Bool.self), "RVQ indices != Python reference after layout transpose")
        _ = expectedIndices  // suppress unused-variable warning
    }
}
