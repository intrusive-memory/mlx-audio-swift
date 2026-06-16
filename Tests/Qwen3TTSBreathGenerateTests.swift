//
//  Qwen3TTSBreathGenerateTests.swift
//  MLXAudioTests
//
//  LOCAL-ONLY: Requires downloading multi-GB model files.
//  DO NOT add to the CI-safe -only-testing list in CLAUDE.md.
//  Runtime validation belongs in the nightly workflow and manual local runs.
//
//  This sortie (Sortie 5) follows the compile-only contract established in
//  Sortie 21 (DeterministicGenerationTests.swift):
//   - Model loading is gated by `MLXAUDIO_NIGHTLY_RUN=1`. Tests skip gracefully
//     when the env var is unset (no models loaded, no hard failure).
//   - `xcodebuild build-for-testing` must exit 0; no `xcodebuild test` in CI.
//   - Runtime validation deferred to nightly workflow + manual local runs.
//   - Does NOT rely on the App Group being configured.
//
//  Run locally (requires mlx-models-v2 cache populated):
//    xcodebuild test \
//      -scheme MLXAudio-Package \
//      -destination 'platform=macOS' \
//      -only-testing:MLXAudioTests/Qwen3TTSBreathGenerateTests \
//      CODE_SIGNING_ALLOWED=NO
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHAT THIS SUITE TESTS
//
//  FR3 (breathOffsets seam test):
//
//  Test A (sampleCountSum): Verifies that calling generate(..., breathOffsets:)
//  with a non-empty offset list produces a waveform whose total sample count
//  equals the sum of the per-chunk sample counts obtained by splitting the same
//  text manually via splitTextAtBreaths and generating each segment independently.
//  Tolerance: exact (direct concatenation via concatenateChunks is lossless —
//  no crossfade is applied; breathSeamCrossfadeEnabled is false by default).
//  If the crossfade scaffold is ever enabled, update this tolerance to
//  ±(fadeSamples * numSeams) and document here.
//
//  Test B (emptyBreathOffsets): Verifies that passing empty breathOffsets is
//  byte-identical to calling the overload WITHOUT the parameter.  Both calls
//  use MLXRandom.seed(42) + greedy decoding (temperature 0) to ensure
//  the generation is fully deterministic across both paths.
//  ─────────────────────────────────────────────────────────────────────────────

import Testing
import Foundation
import MLX
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioTTS

// MARK: - Suite

@Suite("Qwen3TTSBreathGenerateTests")
struct Qwen3TTSBreathGenerateTests {

    /// Model repository for the VoiceDesign variant (same as DeterministicGenerationTests).
    private static let modelRepo = "mlx-community/Qwen3-TTS-12Hz-1.7B-bf16"

    /// Short fixed prompt used across all tests to minimise wall time.
    private static let testText = "Hello world. This is a breath test."

    /// Offset that splits testText into two chunks ("Hello world. " | "This is a breath test.").
    /// Unicode-scalar index 13 falls between the space after the period and "T".
    private static let breathOffset = 13

    // MARK: Test A — sample count sum

    /// Asserts that the waveform produced by `generate(..., breathOffsets:)` has a
    /// total sample count equal to the sum of the per-chunk sample counts.
    ///
    /// Method:
    ///   1. Split `testText` at `breathOffset` via `splitTextAtBreaths`.
    ///   2. Generate each segment individually with the same deterministic settings.
    ///   3. Sum the per-chunk sample counts.
    ///   4. Generate the full text with `breathOffsets: [breathOffset]`.
    ///   5. Assert `audio.dim(0) == sum`.
    ///
    /// Tolerance: exact (breathSeamCrossfadeEnabled is false; seams are direct
    /// concatenation via concatenateChunks, which is lossless).  If the crossfade
    /// scaffold is ever activated, revise tolerance to ±(fadeSamples * numSeams).
    ///
    /// LOCAL-ONLY: requires mlx-community/Qwen3-TTS-12Hz-1.7B-bf16 in mlx-models-v2 cache.
    /// Skips gracefully when MLXAUDIO_NIGHTLY_RUN is not set.
    @Test func sampleCountSum() async throws {
        // Guard: compile-only contract — skip at runtime unless env var is set.
        try #require(
            Bool(ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] != nil),
            "Qwen3TTSBreathGenerateTests.sampleCountSum is LOCAL-ONLY. Set MLXAUDIO_NIGHTLY_RUN=1 to run. Requires mlx-community/Qwen3-TTS-12Hz-1.7B-bf16 in mlx-models-v2 cache."
        )

        // Load model (requires mlx-models-v2 cache).
        let model = try await Qwen3TTSModel.fromPretrained(Self.modelRepo)

        let parameters = GenerateParameters(
            maxTokens: 256,
            temperature: 0,    // Greedy: fully deterministic, no RNG sampling.
            topP: 1.0
        )

        // Step 1: split text manually and generate each chunk independently.
        let segments = splitTextAtBreaths(Self.testText, offsets: [Self.breathOffset])

        // Verify split produced exactly 2 segments (sanity).
        try #require(
            segments.count == 2,
            "splitTextAtBreaths should produce 2 segments for offset \(Self.breathOffset). Got: \(segments)"
        )

        var perChunkSampleCount = 0
        for segment in segments {
            // Use a fixed seed per segment to keep generation deterministic.
            MLXRandom.seed(42)
            let chunk = try await model.generate(
                text: segment,
                voice: nil,
                language: "en",
                generationParameters: parameters
            )
            perChunkSampleCount += chunk.dim(0)
        }

        // Step 2: generate with breathOffsets in a single call.
        MLXRandom.seed(42)
        let combined = try await model.generate(
            text: Self.testText,
            voice: nil,
            language: "en",
            breathOffsets: [Self.breathOffset],
            generationParameters: parameters
        )

        // Tolerance: exact (direct concatenation; crossfade is default-off).
        // If breathSeamCrossfadeEnabled is ever set to true, replace == with
        // an approximate check and document the crossfade fade-sample count here.
        #expect(
            combined.dim(0) == perChunkSampleCount,
            """
            breathOffsets waveform sample count (\(combined.dim(0))) does not match \
            the sum of per-chunk sample counts (\(perChunkSampleCount)). \
            Direct concatenation is lossless; this indicates an unexpected \
            mismatch in the chunking/concatenation path.
            """
        )
    }

    // MARK: Test B — empty breathOffsets byte-identical to no-parameter overload

    /// Asserts that passing `breathOffsets: []` produces a waveform that is
    /// byte-identical to calling `generate` without the parameter.
    ///
    /// Reproducibility strategy:
    ///   - Set `MLXRandom.seed(42)` immediately before each call.
    ///   - Use greedy decoding (`temperature: 0`), which eliminates all
    ///     sampling randomness and makes output deterministic on a fixed model.
    ///   - Both calls use identical inputs, so both paths must produce the same
    ///     waveform (the `breathOffsets: []` branch falls through to the
    ///     single-shot path in `_generateImpl`).
    ///
    /// Assertion: `MLX.allClose(a, b, atol: 0)` — byte-exact equality.
    ///
    /// LOCAL-ONLY: requires mlx-community/Qwen3-TTS-12Hz-1.7B-bf16 in mlx-models-v2 cache.
    /// Skips gracefully when MLXAUDIO_NIGHTLY_RUN is not set.
    @Test func emptyBreathOffsets() async throws {
        // Guard: compile-only contract — skip at runtime unless env var is set.
        try #require(
            Bool(ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] != nil),
            "Qwen3TTSBreathGenerateTests.emptyBreathOffsets is LOCAL-ONLY. Set MLXAUDIO_NIGHTLY_RUN=1 to run. Requires mlx-community/Qwen3-TTS-12Hz-1.7B-bf16 in mlx-models-v2 cache."
        )

        // Load model (requires mlx-models-v2 cache).
        let model = try await Qwen3TTSModel.fromPretrained(Self.modelRepo)

        let parameters = GenerateParameters(
            maxTokens: 256,
            temperature: 0,    // Greedy: fully deterministic, no RNG sampling.
            topP: 1.0
        )

        // Path A: standard overload without breathOffsets parameter.
        // Seed before each call to reset the MLX RNG state identically.
        MLXRandom.seed(42)
        let audioA = try await model.generate(
            text: Self.testText,
            voice: nil,
            language: "en",
            generationParameters: parameters
        )

        // Path B: new overload with explicit empty breathOffsets.
        MLXRandom.seed(42)
        let audioB = try await model.generate(
            text: Self.testText,
            voice: nil,
            language: "en",
            breathOffsets: [],
            generationParameters: parameters
        )

        // Both paths must have the same shape.
        #expect(
            audioA.shape == audioB.shape,
            "generate (no breathOffsets) and generate(breathOffsets: []) produced different shapes: \(audioA.shape) vs \(audioB.shape)"
        )

        // Byte-exact equality: atol: 0 means no tolerance.
        // Both calls are fully deterministic (seed=42, greedy), so any difference
        // would indicate a code-path divergence in _generateImpl / _generateSingle.
        let equal = MLX.allClose(audioA, audioB, atol: 0).item(Bool.self)
        #expect(
            equal,
            """
            generate(breathOffsets: []) is NOT byte-identical to generate() \
            (without breathOffsets). With seed=42 + greedy decoding, both paths \
            must produce identical waveforms. Check _generateImpl / _generateSingle \
            for unintended state mutation between the two code branches.
            """
        )
    }
}
