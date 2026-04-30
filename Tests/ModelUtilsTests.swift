//
//  ModelUtilsTests.swift
//  MLXAudioTests
//
//  CI-safe: no model downloads. Tests the shared weight-dict transforms
//  exposed by Sources/MLXAudioCore/ModelUtils.swift.
//
//  Covered transformations (all pre-existing in production before this sortie):
//
//    1. DTypeConfiguration.convertBFloat16ToFloat16 — default path
//         (Sources/MLXAudioCore/ModelUtils.swift:37-61)
//         bfloat16 tensors are converted to float16; other dtypes pass through.
//
//    2. DTypeConfiguration.convertBFloat16ToFloat16 — non-bf16 passthrough
//         (Sources/MLXAudioCore/ModelUtils.swift:37-61)
//         float32, float16, and integer tensors are left untouched even when
//         conversion is enabled.
//
//    3. DTypeConfiguration.convertBFloat16ToFloat16 — force flag overrides
//         disabled global setting  (Sources/MLXAudioCore/ModelUtils.swift:41)
//         When preferFloat16 == false but force == true, bf16 tensors are
//         still converted.
//
//    4. DTypeConfiguration.convertBFloat16ToFloat16 — no-op when disabled
//         (Sources/MLXAudioCore/ModelUtils.swift:41)
//         When preferFloat16 == false and force == false, the original dict is
//         returned untouched (no dtype changes at all).
//

import Testing
import MLX
import Foundation

@testable import MLXAudioCore

// MARK: - ModelUtils weight-transform tests (CI-safe, no model downloads)

// Serialize execution: DTypeConfiguration.preferFloat16 is a process-wide mutable
// variable. Running tests in parallel would create race conditions between tests
// that toggle the flag. Serialized ensures each test sees a stable value.
@Suite("ModelUtilsTests", .serialized)
struct ModelUtilsTests {

    // MARK: - Transformation 1: bfloat16 → float16 (default/enabled path)

    /// Verify that bfloat16 weights are converted to float16 when preferFloat16 is
    /// true (the default).
    ///
    /// Input:  { "a": bf16 tensor, "b": bf16 tensor }
    /// Output: { "a": f16 tensor,  "b": f16 tensor  }
    ///
    /// Source: Sources/MLXAudioCore/ModelUtils.swift:37-61
    @Test func convertBFloat16ToFloat16_convertsWhenEnabled() {
        let originalSetting = DTypeConfiguration.preferFloat16
        defer { DTypeConfiguration.preferFloat16 = originalSetting }

        DTypeConfiguration.preferFloat16 = true

        let bf16Weight = MLXArray([1.0 as Float, 2.0 as Float, 3.0 as Float]).asType(.bfloat16)
        let weights: [String: MLXArray] = [
            "encoder.weight": bf16Weight,
            "encoder.bias": bf16Weight,
        ]

        let result = DTypeConfiguration.convertBFloat16ToFloat16(weights: weights)

        #expect(result["encoder.weight"] != nil, "encoder.weight must be present in output")
        #expect(result["encoder.bias"] != nil,   "encoder.bias must be present in output")
        #expect(result["encoder.weight"]!.dtype == .float16,
                "bfloat16 encoder.weight must be converted to float16")
        #expect(result["encoder.bias"]!.dtype == .float16,
                "bfloat16 encoder.bias must be converted to float16")
        #expect(result.count == weights.count, "Key count must be preserved")
    }

    // MARK: - Transformation 2: non-bfloat16 dtypes pass through unchanged

    /// Verify that float32, float16, and int32 tensors are NOT changed by
    /// convertBFloat16ToFloat16, even when conversion is enabled.
    ///
    /// Input:  { "a": f32, "b": f16, "c": i32 }
    /// Output: { "a": f32, "b": f16, "c": i32 }  (identical dtypes)
    ///
    /// Source: Sources/MLXAudioCore/ModelUtils.swift:47-49 (the `else` branch)
    @Test func convertBFloat16ToFloat16_nonBf16PassesThrough() {
        let originalSetting = DTypeConfiguration.preferFloat16
        defer { DTypeConfiguration.preferFloat16 = originalSetting }

        DTypeConfiguration.preferFloat16 = true

        let f32Weight  = MLXArray([1.0 as Float]).asType(.float32)
        let f16Weight  = MLXArray([1.0 as Float]).asType(.float16)
        let i32Weight  = MLXArray([Int32(1)])

        let weights: [String: MLXArray] = [
            "layer.float32_param": f32Weight,
            "layer.float16_param": f16Weight,
            "layer.int32_param":   i32Weight,
        ]

        let result = DTypeConfiguration.convertBFloat16ToFloat16(weights: weights)

        #expect(result["layer.float32_param"]?.dtype == .float32,
                "float32 tensor must pass through unchanged")
        #expect(result["layer.float16_param"]?.dtype == .float16,
                "float16 tensor must pass through unchanged")
        #expect(result["layer.int32_param"]?.dtype == .int32,
                "int32 tensor must pass through unchanged")
        #expect(result.count == weights.count, "Key count must be preserved")
    }

    // MARK: - Transformation 3: force=true overrides disabled global setting

    /// Verify that passing force: true triggers conversion even when
    /// preferFloat16 is set to false globally.
    ///
    /// Input:  { "w": bf16 } with preferFloat16=false, force=true
    /// Output: { "w": f16 }
    ///
    /// Source: Sources/MLXAudioCore/ModelUtils.swift:41 — `guard force || preferFloat16`
    @Test func convertBFloat16ToFloat16_forceFlagOverridesDisabledSetting() {
        let originalSetting = DTypeConfiguration.preferFloat16
        defer { DTypeConfiguration.preferFloat16 = originalSetting }

        DTypeConfiguration.preferFloat16 = false   // globally disabled

        let bf16Weight = MLXArray([1.0 as Float, 2.0 as Float]).asType(.bfloat16)
        let weights: [String: MLXArray] = ["decoder.weight": bf16Weight]

        // force: true must override the disabled global flag
        let result = DTypeConfiguration.convertBFloat16ToFloat16(weights: weights, force: true)

        #expect(result["decoder.weight"] != nil, "decoder.weight must be present in output")
        #expect(result["decoder.weight"]!.dtype == .float16,
                "force=true must convert bf16 to f16 even when preferFloat16=false")
    }

    // MARK: - Transformation 4: no-op when preferFloat16=false and force=false

    /// Verify that when the global flag is disabled and force is not set,
    /// convertBFloat16ToFloat16 returns the original dictionary with all dtypes
    /// intact (no conversion performed).
    ///
    /// Input:  { "w": bf16 } with preferFloat16=false
    /// Output: { "w": bf16 }  (untouched)
    ///
    /// Source: Sources/MLXAudioCore/ModelUtils.swift:41 — early return when disabled
    @Test func convertBFloat16ToFloat16_noOpWhenDisabled() {
        let originalSetting = DTypeConfiguration.preferFloat16
        defer { DTypeConfiguration.preferFloat16 = originalSetting }

        DTypeConfiguration.preferFloat16 = false

        let bf16Weight = MLXArray([1.0 as Float, 2.0 as Float]).asType(.bfloat16)
        let weights: [String: MLXArray] = [
            "model.embed.weight": bf16Weight,
            "model.norm.weight":  bf16Weight,
        ]

        // Default force: false — should be a no-op
        let result = DTypeConfiguration.convertBFloat16ToFloat16(weights: weights)

        #expect(result["model.embed.weight"]?.dtype == .bfloat16,
                "bf16 weight must remain bfloat16 when conversion is disabled")
        #expect(result["model.norm.weight"]?.dtype == .bfloat16,
                "bf16 weight must remain bfloat16 when conversion is disabled")
        #expect(result.count == weights.count, "Key count must be preserved")
    }
}
