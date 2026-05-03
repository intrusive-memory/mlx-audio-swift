//
//  WeightRoundTripTests.swift
//  MLXAudioTests
//
//  LOCAL-ONLY: Requires downloading multi-GB model files.
//  DO NOT add to the CI-safe -only-testing list in CLAUDE.md.
//  Runtime validation belongs in the nightly workflow and manual local validation.
//
//  This sortie (Sortie 23) follows the compile-only contract established in
//  Sortie 21 (DeterministicGenerationTests.swift) and Sortie 22 (KVCacheCorrectnessTests.swift):
//   - Model loading is guarded behind `MLXAUDIO_NIGHTLY_RUN` env-var + `try #require` stubs
//     that skip gracefully when the guard is not satisfied.
//   - `xcodebuild build-for-testing` must exit 0; no `xcodebuild test` in CI.
//   - Runtime validation deferred to nightly workflow + manual local runs.
//
//  CI-safe promotion: DEFERRED.
//  A synthetic small-config round-trip (random-init weights, small dim) could potentially
//  run in <10 min, but neither LlamaTTS nor Qwen3ASR has a public initializer that accepts
//  an arbitrary config + random weights without touching the file system. Promotion would
//  require adding a `init(config:)` public entry point that skips Acervo downloads, then
//  benchmarking the full build-for-testing + test run. Deferred to follow-up.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHAT THIS SUITE TESTS
//
//  Weight-loading round-trip: For a given instantiated model, extract all parameter
//  MLXArrays via `module.parameters().flattened()`, serialize to a scratch `.safetensors`
//  file via `MLX.save(arrays:url:)`, reload via `MLX.loadArrays(url:)`, then assert
//  byte-exact equality (`MLX.allClose(atol: 0)`) for every key.
//
//  This guards against:
//    - Silent precision loss during save/reload (e.g., float32 vs bfloat16 coercion)
//    - Key naming changes in the parameter tree that would break reload
//    - Incomplete parameter extraction (missing keys after round-trip)
//
//  ─────────────────────────────────────────────────────────────────────────────
//  API GAP FINDINGS (Sortie 23 investigation, 2026-04-30)
//
//  LlamaTTS — PUBLIC API COMPLETE FOR ROUND-TRIP:
//    • `LlamaTTSModel` inherits `parameters() -> ModuleParameters` from MLXNN `Module`.
//    • `module.parameters().flattened()` returns `[(String, MLXArray)]` — flat key/value pairs.
//    • `MLX.save(arrays: [String: MLXArray], url: URL)` is public (saves safetensors).
//    • `MLX.loadArrays(url: URL)` is public (loads safetensors).
//    • `MLX.allClose(a, b, atol: 0)` is public.
//    • Full round-trip is expressible via public API after `fromPretrained` loads the model.
//
//  Qwen3ASR — PUBLIC API COMPLETE FOR ROUND-TRIP:
//    • Same as LlamaTTS — `Qwen3ASRModel` inherits `parameters()` from `Module`.
//    • No additional private API needed for weight serialization.
//    • Note: `mergeAudioFeatures` is still private (Sortie 22 gap), but weight round-trip
//      does NOT require it — only parameter extraction and save/reload.
//
//  SYNTHESIS: No new API gaps found for the weight round-trip use case. Both models expose
//  sufficient public API via MLXNN `Module.parameters()`. The only limitation is that
//  CI-safe promotion requires a synthetic-config path (instantiate without downloads),
//  which is deferred as noted above.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  Run locally (requires mlx-models-v2 cache populated):
//    MLXAUDIO_NIGHTLY_RUN=1 xcodebuild test \
//      -scheme MLXAudio-Package \
//      -destination 'platform=macOS' \
//      -only-testing:MLXAudioTests/WeightRoundTripTests \
//      CODE_SIGNING_ALLOWED=NO

import Testing
import Foundation
import MLX
import MLXNN

@testable import MLXAudioCore
@testable import MLXAudioTTS
@testable import MLXAudioSTT

// MARK: - Suite

@Suite("WeightRoundTripTests")
struct WeightRoundTripTests {

    // MARK: LlamaTTS Weight Round-Trip

    /// Weight-loading round-trip test for LlamaTTS (Orpheus).
    ///
    /// Loads the model, extracts all parameter MLXArrays via `parameters().flattened()`,
    /// serializes them to a scratch safetensors file in `FileManager.default.temporaryDirectory`,
    /// reloads via `MLX.loadArrays(url:)`, then asserts `MLX.allClose(atol: 0)` (byte-exact)
    /// for every key. Cleans up the scratch file via `defer`.
    ///
    /// LOCAL-ONLY: requires `mlx-community/orpheus-3b-0.1-ft-bf16` in mlx-models-v2 cache.
    /// The `try #require` guard skips gracefully when `MLXAUDIO_NIGHTLY_RUN` is not set.
    ///
    /// CI-safe promotion path: Add a public `LlamaTTSModel.init(config:)` that initialises
    /// with random weights (no downloads), benchmark that it runs in <10 min, then remove
    /// the nightly guard and add to the CI-safe list in CLAUDE.md.
    @Test func llamaTTSWeightRoundTrip() async throws {
        // Guard: compile-only contract — skip at runtime unless MLXAUDIO_NIGHTLY_RUN is set.
        // This mirrors the pattern used in KVCacheCorrectnessTests (Sortie 22).
        try #require(
            Bool(ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] != nil),
            "LlamaTTS weight round-trip test is LOCAL-ONLY. Set MLXAUDIO_NIGHTLY_RUN=1 to run. Requires mlx-community/orpheus-3b-0.1-ft-bf16 in mlx-models-v2 cache."
        )

        // Scratch file path — cleaned up via defer regardless of test outcome.
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).safetensors")
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        // Load model (requires mlx-models-v2 cache).
        let model = try await LlamaTTSModel.fromPretrained(
            "mlx-community/orpheus-3b-0.1-ft-bf16"
        )

        // Extract all parameters as a flat [String: MLXArray] dictionary.
        // Module.parameters() returns a NestedDictionary<String, MLXArray>;
        // .flattened() collapses the tree into [(String, MLXArray)] with dot-separated keys.
        let originalParams: [String: MLXArray] = Dictionary(
            uniqueKeysWithValues: model.parameters().flattened()
        )

        #expect(
            !originalParams.isEmpty,
            "LlamaTTS model.parameters().flattened() returned an empty dictionary — weight extraction failed."
        )

        // Evaluate all arrays before saving (ensures lazy MLX ops are materialised).
        eval(model.parameters())

        // Save parameters to scratch safetensors file.
        // MLX.save(arrays:url:) requires url.pathExtension == "safetensors".
        try MLX.save(arrays: originalParams, url: scratchURL)

        // Reload from the scratch file.
        let reloadedParams = try MLX.loadArrays(url: scratchURL)

        // Verify all keys round-tripped.
        #expect(
            reloadedParams.count == originalParams.count,
            "Key count mismatch after round-trip: original \(originalParams.count), reloaded \(reloadedParams.count)."
        )

        // Assert byte-exact equality for every parameter array.
        var failedKeys: [String] = []
        for (key, original) in originalParams.sorted(by: { $0.key < $1.key }) {
            guard let reloaded = reloadedParams[key] else {
                failedKeys.append("\(key): missing after reload")
                continue
            }
            let match = MLX.allClose(original, reloaded, rtol: 0, atol: 0).item(Bool.self)
            if !match {
                failedKeys.append("\(key): values differ")
            }
        }

        #expect(
            failedKeys.isEmpty,
            "LlamaTTS weight round-trip FAILED for \(failedKeys.count) key(s):\n\(failedKeys.prefix(10).joined(separator: "\n"))"
        )

        Memory.clearCache()
    }

    // MARK: Qwen3ASR Weight Round-Trip

    /// Weight-loading round-trip test for Qwen3ASR.
    ///
    /// Loads the model, extracts all parameter MLXArrays via `parameters().flattened()`,
    /// serializes them to a scratch safetensors file, reloads, then asserts byte-exact equality.
    ///
    /// NOTE on Qwen3ASR vs Sortie 22 API gap:
    ///   `mergeAudioFeatures` is still private (documented in KVCacheCorrectnessTests).
    ///   However, weight round-trip does NOT require that method — it only needs
    ///   `Module.parameters()` (public) and the MLX save/load APIs (public).
    ///   This test is therefore FULL (no partial stub needed).
    ///
    /// LOCAL-ONLY: requires `mlx-community/Qwen3-ASR` in mlx-models-v2 cache.
    /// The `try #require` guard skips gracefully when `MLXAUDIO_NIGHTLY_RUN` is not set.
    @Test func qwen3ASRWeightRoundTrip() async throws {
        // Guard: compile-only contract — skip at runtime unless MLXAUDIO_NIGHTLY_RUN is set.
        try #require(
            Bool(ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] != nil),
            "Qwen3ASR weight round-trip test is LOCAL-ONLY. Set MLXAUDIO_NIGHTLY_RUN=1 to run. Requires mlx-community/Qwen3-ASR in mlx-models-v2 cache."
        )

        // Scratch file path — cleaned up via defer regardless of test outcome.
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).safetensors")
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        // Load model (requires mlx-models-v2 cache).
        let model = try await Qwen3ASRModel.fromPretrained(
            "mlx-community/Qwen3-ASR"
        )

        // Extract all parameters as a flat [String: MLXArray] dictionary.
        let originalParams: [String: MLXArray] = Dictionary(
            uniqueKeysWithValues: model.parameters().flattened()
        )

        #expect(
            !originalParams.isEmpty,
            "Qwen3ASR model.parameters().flattened() returned an empty dictionary — weight extraction failed."
        )

        // Evaluate all arrays before saving (ensures lazy MLX ops are materialised).
        eval(model.parameters())

        // Save parameters to scratch safetensors file.
        try MLX.save(arrays: originalParams, url: scratchURL)

        // Reload from the scratch file.
        let reloadedParams = try MLX.loadArrays(url: scratchURL)

        // Verify all keys round-tripped.
        #expect(
            reloadedParams.count == originalParams.count,
            "Key count mismatch after round-trip: original \(originalParams.count), reloaded \(reloadedParams.count)."
        )

        // Assert byte-exact equality for every parameter array.
        var failedKeys: [String] = []
        for (key, original) in originalParams.sorted(by: { $0.key < $1.key }) {
            guard let reloaded = reloadedParams[key] else {
                failedKeys.append("\(key): missing after reload")
                continue
            }
            let match = MLX.allClose(original, reloaded, rtol: 0, atol: 0).item(Bool.self)
            if !match {
                failedKeys.append("\(key): values differ")
            }
        }

        #expect(
            failedKeys.isEmpty,
            "Qwen3ASR weight round-trip FAILED for \(failedKeys.count) key(s):\n\(failedKeys.prefix(10).joined(separator: "\n"))"
        )

        Memory.clearCache()
    }
}
