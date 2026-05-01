//
//  SNACVQTests.swift
//  MLXAudioTests
//
//  Sortie 19 of OPERATION ECHO DRAGNET — SNAC VQ numeric-parity assertion.
//
//  This file contains a single CI-safe parity test for the SNAC VectorQuantize
//  layer. The test loads the Sortie 1 fixture from Tests/media/parity/snac_vq/,
//  injects fixture weights into a Swift VectorQuantize instance, runs forward,
//  and asserts MLX.allClose(swift_out, expected, atol: 1e-4, rtol: 1e-4).
//
//  CI-safe: no model downloads. Uses fixture weights only (random init, seeded).
//  Wired into the CLAUDE.md -only-testing list.
//
//  Production-code-scope discipline: zero modifications to Sources/ files.
//  All Swift entry points accessed via their public init / callAsFunction.
//
//  Fixture: Tests/media/parity/snac_vq/
//    input.safetensors    — key "x"               shape [1, 8, 12]  (B, D_in, T) — NCT
//    weights.safetensors  — keys:
//        "in_proj.weight"  [4, 8, 1]   (out, in, k=1)   — plain Conv1d format
//        "in_proj.bias"    [4]
//        "out_proj.weight" [8, 4, 1]   (out, in, k=1)   — plain Conv1d format
//        "out_proj.bias"   [8]
//        "codebook.weight" [16, 4]     (codebook_size, codebook_dim)
//    expected.safetensors — key "y"               shape [1, 8, 12]  (B, D_in, T) — NCT
//                           key "indices"          shape [1, 12]    (B, T) — float32
//
//  Layout note: Python SNACVectorQuantizer uses NCT [B, C, T].
//  Swift VectorQuantize.callAsFunction also expects NCT [B, C, T] (NCL ≡ NCT).
//  No input/output transposition needed.
//
//  Weight injection note:
//    Python in_proj/out_proj use plain nn.Conv1d; weight shape is [out, in, k].
//    Swift WNConv1d uses weight normalization: weight_v/weight_g shape is [out, k, in].
//    For kernel_size=1: [out, in, 1] ↔ [out, 1, in] — different axis order.
//    Strategy: set weight_v = w.swappedAxes(1,2), weight_g = per-out-channel norm.
//    Then composed weight = weight_g * weight_v / norm(weight_v) = w (transposed back).
//    For k=1 this gives the same result regardless of axis order, but we match
//    the exact WNConv1d formula for correctness.
//
//    Python codebook uses nn.Embedding; weight shape [codebook_size, codebook_dim].
//    Swift uses MLXNN.Embedding; inject via update(parameters: ["codebook.weight": ...]).
//
//  Key remapping (Python fixture key → Swift module path):
//    "in_proj.weight"  → "in_proj.weight_v" (transposed), "in_proj.weight_g"
//    "in_proj.bias"    → "in_proj.bias"
//    "out_proj.weight" → "out_proj.weight_v" (transposed), "out_proj.weight_g"
//    "out_proj.bias"   → "out_proj.bias"
//    "codebook.weight" → "codebook.weight"

import Foundation
import MLX
import MLXNN
import Testing

@testable import MLXAudioCodecs

// MARK: - SNACVQTests

@Suite("SNACVQTests")
struct SNACVQTests {

    /// Tolerance used by the numeric-parity assertion.
    static let parityATol: Double = 1e-4
    static let parityRTol: Double = 1e-4

    // MARK: - SNAC VQ numeric-parity assertion

    @Test func snacVQMatchesPythonReference() throws {
        let fixture = try loadParityFixture("snac_vq")

        // --- Load input (Python NCT [B, D_in, T] = [1, 8, 12]) ---
        guard let inputArr = fixture.input["x"] else {
            Issue.record("snac_vq input.safetensors missing key 'x'")
            return
        }
        // Swift VectorQuantize expects NCT [B, C, T] — same format. No transpose needed.

        // --- Load expected ---
        guard let expectedY = fixture.expected["y"] else {
            Issue.record("snac_vq expected.safetensors missing key 'y'")
            return
        }
        // expectedY: [1, 8, 12] in NCT

        // --- Load weights ---
        guard
            let inProjW  = fixture.weights["in_proj.weight"],   // [4, 8, 1]
            let inProjB  = fixture.weights["in_proj.bias"],     // [4]
            let outProjW = fixture.weights["out_proj.weight"],  // [8, 4, 1]
            let outProjB = fixture.weights["out_proj.bias"],    // [8]
            let cbWeight = fixture.weights["codebook.weight"]   // [16, 4]
        else {
            Issue.record("snac_vq weights.safetensors missing one or more expected keys")
            return
        }
        // Derive dims from fixture shapes
        let inputDim    = inProjW.shape[1]   // 8
        let codebookDim = inProjW.shape[0]   // 4
        let codebookSz  = cbWeight.shape[0]  // 16

        // --- Construct VectorQuantize ---
        // VectorQuantize(inputDim: 8, codebookSize: 16, codebookDim: 4, stride: 1)
        let vq = VectorQuantize(
            inputDim: inputDim,
            codebookSize: codebookSz,
            codebookDim: codebookDim,
            stride: 1
        )

        // --- Helper: compute WNConv1d weight_g from transposed weight [out, k, in] ---
        // weight_g = per-output-channel L2 norm = sqrt(sum(w^2, axes=[1,2], keepDims=true))
        func wg(_ w: MLXArray) -> MLXArray {
            MLX.sqrt(MLX.sum(w * w, axes: [1, 2], keepDims: true))
        }

        // --- Helper: transpose Python Conv1d weight [out, in, k] → WNConv1d [out, k, in] ---
        func wv(_ w: MLXArray) -> MLXArray {
            w.swappedAxes(1, 2)
        }

        // Prepare transposed WNConv1d weight_v tensors
        let inProjWv  = wv(inProjW)   // [4, 8, 1] → [4, 1, 8]
        let outProjWv = wv(outProjW)  // [8, 4, 1] → [8, 1, 4]

        // --- Inject weights via update(parameters:) ---
        // WNConv1d module key in VectorQuantize: "in_proj" (ModuleInfo key: "in_proj")
        // WNConv1d properties: weight_g (key "weight_g"), weight_v (key "weight_v"), bias
        // Codebook is a plain `let Embedding` but accessible via Module.update(parameters:)
        // since Embedding.weight is tracked by MLXNN's parameter tree.
        let snacParams: [String: MLXArray] = [
            "in_proj.weight_v":  inProjWv,
            "in_proj.weight_g":  wg(inProjWv),
            "in_proj.bias":      inProjB,
            "out_proj.weight_v": outProjWv,
            "out_proj.weight_g": wg(outProjWv),
            "out_proj.bias":     outProjB,
            "codebook.weight":   cbWeight,
        ]
        vq.update(parameters: ModuleParameters.unflattened(snacParams))
        eval(vq)

        // --- Forward pass ---
        // VectorQuantize.callAsFunction expects NCT [B, C, T].
        let (swiftY, _) = vq(inputArr)
        eval(swiftY)

        // --- Shape assertion ---
        #expect(
            swiftY.shape == expectedY.shape,
            "SNAC VQ output shape mismatch: swift=\(swiftY.shape) expected=\(expectedY.shape)"
        )

        // --- Numeric-parity assertion ---
        let close = MLX.allClose(swiftY, expectedY, rtol: Self.parityRTol, atol: Self.parityATol)
        let isClose = close.item(Bool.self)

        if !isClose {
            let maxAbsErr = abs(swiftY - expectedY).max().item(Float.self)
            Issue.record("SNAC VQ output != Python reference. max_abs_err=\(maxAbsErr) (atol=\(Self.parityATol), rtol=\(Self.parityRTol))")
        }
        #expect(isClose, "snacVQMatchesPythonReference: allClose failed (atol=\(Self.parityATol), rtol=\(Self.parityRTol))")
    }
}
