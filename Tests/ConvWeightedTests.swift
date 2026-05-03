//
//  ConvWeightedTests.swift
//  MLXAudioTests
//
//  Sortie 12 of OPERATION ECHO DRAGNET — ConvWeighted parity vs Conv1d composition.
//
//  Verifies that ConvWeighted produces output numerically identical to a plain
//  MLX.conv1d call whose weight has been manually composed using the same
//  weight-normalization formula that ConvWeighted applies internally.
//
//  Weight-normalization convention (confirmed from Sources/MLXAudioCore/ConvWeighted.swift):
//
//    weightNorm(weightV:weightG:dim:0)
//      axes  = [1, 2]   (all dims except dim 0 = out-channels)
//      normV = sqrt(sum(weightV * weightV, axes:[1,2], keepDims:true))   shape [outC, 1, 1]
//      w     = (weightV / (normV + 1e-7)) * weightG
//
//  This exactly mirrors PyTorch weight_norm(Conv1d(...), dim=0).
//
//  Both ConvWeighted and the reference MLX.conv1d call operate on NLC inputs:
//    [batch=1, time=16, in_channels=4]
//  Weight shape: [out_channels=8, kernel_size=3, in_channels=4]
//  Padding=1 preserves time dimension.
//
//  CI-safe: no model downloads. Wired into the CLAUDE.md -only-testing list.
//
//  Production-code-scope discipline: zero modifications to Sources/ files.
//

import Foundation
import MLX
import MLXNN
import Testing

@testable import MLXAudioCore

// MARK: - ConvWeightedTests

@Suite("ConvWeightedTests")
struct ConvWeightedTests {

    /// Tolerance for parity assertion.
    /// Both paths compute the same arithmetic, so agreement should be at
    /// floating-point round-off (<<1e-5).  We use 1e-5 as stated in the sortie spec.
    static let atol: Float = 1e-5
    static let rtol: Float = 1e-5

    // MARK: - Parity: ConvWeighted vs manually composed Conv1d

    /// Verify that ConvWeighted(weightG, weightV) produces the same output as
    /// MLX.conv1d called with the explicitly composed weight:
    ///
    ///   w = (weightV / (||weightV||_{axes:[1,2]} + 1e-7)) * weightG
    ///
    /// Normalization is over axes [1, 2] (kernel_size and in_channels) with
    /// keepDims=true, reproducing the formula in weightNorm(dim:0).
    ///
    @Test func convWeightedMatchesComposedConv1d() throws {
        // Deterministic seed for reproducibility.
        MLXRandom.seed(42)

        let batchSize  = 1
        let inC        = 4
        let outC       = 8
        let kSize      = 3
        let timeSteps  = 16
        let padding    = 1   // (kSize-1)/2 — preserves time at stride=1

        // ── Random weight_v  [outC, kSize, inC] ──────────────────────────────
        let weightV = MLXRandom.normal([outC, kSize, inC])

        // ── Compose weight_g: per-output-channel scalar, shape [outC, 1, 1] ──
        //
        // PyTorch weight_norm initialises g = ||v||_0 so that the initial
        // effective weight equals v.  We choose arbitrary positive scalars
        // instead to make the test non-trivial (g ≠ 1).
        let weightG = MLXRandom.uniform(low: 0.5, high: 1.5, [outC, 1, 1])

        // ── Fixed input, NLC format [batch, time, in_channels] ───────────────
        let input = MLXRandom.normal([batchSize, timeSteps, inC])

        // ── Reference: manually compose the weight then call MLX.conv1d ──────
        //
        // Replicates weightNorm(weightV:weightG:dim:0) from ConvWeighted.swift:
        //   axes  = [1, 2]
        //   normV = sqrt(sum(v*v, axes:[1,2], keepDims:true))
        //   w     = (v / (normV + 1e-7)) * g
        let normV    = MLX.sqrt(MLX.sum(weightV * weightV, axes: [1, 2], keepDims: true))
        let composed = (weightV / (normV + 1e-7)) * weightG

        let refOut = MLX.conv1d(
            input,
            composed,
            stride:   1,
            padding:  padding,
            dilation: 1,
            groups:   1
        )

        // ── Subject: ConvWeighted with the same weightG, weightV ─────────────
        let convWeighted = ConvWeighted(
            weightG:  weightG,
            weightV:  weightV,
            bias:     nil,
            stride:   1,
            padding:  padding,
            dilation: 1,
            groups:   1
        )

        // ConvWeighted.callAsFunction requires a conv closure matching:
        //   (MLXArray, MLXArray, Int, Int, Int, Int, StreamOrDevice) -> MLXArray
        // MLX.conv1d matches exactly.
        let cwOut = convWeighted(input, conv: MLX.conv1d)

        // ── Evaluate both arrays before comparison ────────────────────────────
        eval(refOut, cwOut)

        // ── Assert allclose ───────────────────────────────────────────────────
        let diff     = MLX.abs(cwOut - refOut)
        let maxDiff  = diff.max().item(Float.self)
        let closeEnough = MLX.all(
            diff .<= (Self.atol + Self.rtol * MLX.abs(refOut))
        ).item(Bool.self)

        #expect(closeEnough, "ConvWeighted output diverges from composed Conv1d: maxAbsDiff=\(maxDiff)")

        // Record margin for the final sortie report.
        // (Passes silently; value surfaced via test output if run with verbose flag.)
        _ = maxDiff
    }

    // MARK: - Output shape

    /// Verify that ConvWeighted produces the expected output shape:
    ///   [batchSize, timeSteps, outC]  (NLC, padding=1 preserves time).
    @Test func convWeightedOutputShape() throws {
        MLXRandom.seed(42)

        let batchSize  = 2
        let inC        = 4
        let outC       = 8
        let kSize      = 3
        let timeSteps  = 16
        let padding    = 1

        let weightV = MLXRandom.normal([outC, kSize, inC])
        let weightG = MLXRandom.uniform(low: 0.5, high: 1.5, [outC, 1, 1])
        let input   = MLXRandom.normal([batchSize, timeSteps, inC])

        let convWeighted = ConvWeighted(
            weightG:  weightG,
            weightV:  weightV,
            bias:     nil,
            stride:   1,
            padding:  padding,
            dilation: 1,
            groups:   1
        )

        let out = convWeighted(input, conv: MLX.conv1d)
        eval(out)

        // NLC output: [batch, time, out_channels]
        #expect(out.shape[0] == batchSize,  "batch dim mismatch: \(out.shape[0]) ≠ \(batchSize)")
        #expect(out.shape[1] == timeSteps,  "time dim mismatch:  \(out.shape[1]) ≠ \(timeSteps)")
        #expect(out.shape[2] == outC,       "out-channel dim mismatch: \(out.shape[2]) ≠ \(outC)")
    }
}
