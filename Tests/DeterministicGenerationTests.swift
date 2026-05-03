//
//  DeterministicGenerationTests.swift
//  MLXAudioTests
//
//  LOCAL-ONLY: Requires downloading multi-GB model files.
//  DO NOT add to the CI-safe -only-testing list in CLAUDE.md.
//  Runtime validation belongs in the nightly workflow (Sortie 9) and manual
//  local validation.
//
//  This sortie (Sortie 21) follows a compile-only contract:
//   - Fixture JSON files contain placeholder `expected_token_ids: []`.
//   - Each test detects a placeholder fixture and SKIPS the assertion gracefully
//     via `try #require(!fixture.expectedTokenIds.isEmpty, ...)`.
//   - `xcodebuild build-for-testing` must exit 0; no `xcodebuild test` in CI.
//   - Regenerate fixtures locally: run the full test suite with mlx-models-v2 cache
//     and commit the JSON output.
//
//  Run locally (requires mlx-models-v2 cache populated):
//    xcodebuild test \
//      -scheme MLXAudio-Package \
//      -destination 'platform=macOS' \
//      -only-testing:MLXAudioTests/DeterministicGenerationTests \
//      CODE_SIGNING_ALLOWED=NO
//
//  ─────────────────────────────────────────────────────────────────────────────
//  PocketTTS NOTE (PARTIAL implementation):
//  PocketTTS is a flow-matching model that generates continuous latents, NOT
//  an autoregressive model over discrete codec tokens. Its `generateStream`
//  yields only `.audio(MLXArray)` — there are no intermediate token IDs to
//  assert on. Therefore, pockettts_seed42.json records expected audio sample
//  count as a determinism proxy instead. The test is still marked PARTIAL
//  because a continuous-latent flow model's output may not be reproducible
//  across Apple Silicon GPU generations even with a fixed RNG seed.
//  ─────────────────────────────────────────────────────────────────────────────

import Testing
import Foundation
import MLX
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioTTS

// MARK: - Shared fixture types

/// Codable container for deterministic-generation fixture JSON files.
///
/// Fixture format:
/// ```json
/// {
///   "_comment": "...",
///   "expected_token_ids": [101, 202, ...]   // empty array = placeholder
/// }
/// ```
private struct DeterministicFixture: Decodable {
    let expectedTokenIds: [Int]

    enum CodingKeys: String, CodingKey {
        case expectedTokenIds = "expected_token_ids"
    }
}

/// Codable container for the PocketTTS fixture (audio-sample-count proxy).
///
/// PocketTTS is a flow-matching model with no discrete token IDs. The
/// determinism proxy is the audio sample count from generation with seed=42.
private struct PocketTTSFixture: Decodable {
    let expectedTokenIds: [Int]
    let expectedAudioSampleCount: Int

    enum CodingKeys: String, CodingKey {
        case expectedTokenIds         = "expected_token_ids"
        case expectedAudioSampleCount = "expected_audio_sample_count"
    }
}

// MARK: - Helper

private func loadFixture<T: Decodable>(_ filename: String, as type: T.Type) throws -> T {
    guard let url = Bundle.module.url(
        forResource: filename,
        withExtension: "json",
        subdirectory: "media/deterministic"
    ) else {
        throw DeterministicTestError.fixtureNotFound(filename)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}

private enum DeterministicTestError: Error, LocalizedError {
    case fixtureNotFound(String)

    var errorDescription: String? {
        switch self {
        case .fixtureNotFound(let name):
            return "Fixture '\(name).json' not found in media/deterministic bundle."
        }
    }
}

// MARK: - Suite

@Suite("DeterministicGenerationTests")
struct DeterministicGenerationTests {

    // MARK: Qwen3TTS

    /// Deterministic token-sequence test for Qwen3TTS.
    ///
    /// Seeds MLX RNG to 42, generates up to 64 codec tokens from a fixed prompt
    /// at temperature=0.6 / top-p=0.8, then asserts the collected token IDs
    /// match the checked-in expected sequence.
    ///
    /// Fixture: `Tests/media/deterministic/qwen3tts_seed42.json`
    /// If the fixture is a placeholder (empty array), the assertion is SKIPPED
    /// gracefully via `try #require`. Regenerate by running this test locally
    /// with mlx-models-v2 cache and committing the updated JSON.
    @Test func qwen3TTSDeterministic() async throws {
        let fixture = try loadFixture("qwen3tts_seed42", as: DeterministicFixture.self)
        try #require(
            !fixture.expectedTokenIds.isEmpty,
            "Placeholder fixture for Qwen3TTS — regenerate via local nightly run. Commit token IDs to Tests/media/deterministic/qwen3tts_seed42.json."
        )

        // Set deterministic seed before any MLX sampling.
        MLXRandom.seed(42)

        // Load model (requires mlx-models-v2 cache).
        let model = try await Qwen3TTSModel.fromPretrained(
            "mlx-community/Qwen3-TTS-12Hz-1.7B-bf16"
        )

        let parameters = GenerateParameters(
            maxTokens: 64,
            temperature: 0.6,
            topP: 0.8,
            repetitionPenalty: 1.05
        )

        // Collect token IDs from the stream.
        var collectedTokenIds: [Int] = []
        for try await event in model.generateStream(
            text: "Hello, this is a deterministic seed test.",
            voice: nil,
            refAudio: nil,
            refText: nil,
            language: "en",
            instruct: nil,
            generationParameters: parameters
        ) {
            if case .token(let id) = event {
                collectedTokenIds.append(id)
            }
        }

        #expect(
            collectedTokenIds == fixture.expectedTokenIds,
            "Qwen3TTS token sequence with seed=42 diverged from expected. If this is intentional (model update), regenerate the fixture."
        )
    }

    // MARK: LlamaTTS

    /// Deterministic token-sequence test for LlamaTTS (Orpheus).
    ///
    /// Seeds MLX RNG to 42, generates up to 64 tokens from a fixed prompt
    /// at temperature=0.6 / top-p=0.8 with voice="tara", then asserts the
    /// collected token IDs match the checked-in expected sequence.
    ///
    /// Fixture: `Tests/media/deterministic/llama_seed42.json`
    /// If the fixture is a placeholder, the assertion is SKIPPED gracefully.
    @Test func llamaTTSDeterministic() async throws {
        let fixture = try loadFixture("llama_seed42", as: DeterministicFixture.self)
        try #require(
            !fixture.expectedTokenIds.isEmpty,
            "Placeholder fixture for LlamaTTS — regenerate via local nightly run. Commit token IDs to Tests/media/deterministic/llama_seed42.json."
        )

        // Set deterministic seed before any MLX sampling.
        MLXRandom.seed(42)

        // Load model (requires mlx-models-v2 cache).
        let model = try await LlamaTTSModel.fromPretrained(
            "mlx-community/orpheus-3b-0.1-ft-bf16"
        )

        let parameters = GenerateParameters(
            maxTokens: 64,
            temperature: 0.6,
            topP: 0.8,
            repetitionPenalty: 1.3,
            repetitionContextSize: 20
        )

        // Collect token IDs from the stream.
        var collectedTokenIds: [Int] = []
        for try await event in model.generateStream(
            text: "Hello, this is a deterministic seed test.",
            voice: "tara",
            parameters: parameters
        ) {
            if case .token(let id) = event {
                collectedTokenIds.append(id)
            }
        }

        #expect(
            collectedTokenIds == fixture.expectedTokenIds,
            "LlamaTTS token sequence with seed=42 diverged from expected. If this is intentional (model update), regenerate the fixture."
        )
    }

    // MARK: SopranoTTS

    /// Deterministic token-sequence test for SopranoTTS.
    ///
    /// Seeds MLX RNG to 42, generates up to 64 tokens from a fixed prompt
    /// at temperature=0.6 / top-p=0.8, then asserts the collected token IDs
    /// match the checked-in expected sequence.
    ///
    /// Fixture: `Tests/media/deterministic/soprano_seed42.json`
    /// If the fixture is a placeholder, the assertion is SKIPPED gracefully.
    @Test func sopranoTTSDeterministic() async throws {
        let fixture = try loadFixture("soprano_seed42", as: DeterministicFixture.self)
        try #require(
            !fixture.expectedTokenIds.isEmpty,
            "Placeholder fixture for SopranoTTS — regenerate via local nightly run. Commit token IDs to Tests/media/deterministic/soprano_seed42.json."
        )

        // Set deterministic seed before any MLX sampling.
        MLXRandom.seed(42)

        // Load model (requires mlx-models-v2 cache).
        let model = try await SopranoModel.fromPretrained(
            "mlx-community/Soprano-80M-bf16"
        )

        let parameters = GenerateParameters(
            maxTokens: 64,
            temperature: 0.6,
            topP: 0.8,
            repetitionPenalty: 1.5,
            repetitionContextSize: 30
        )

        // Collect token IDs from the stream.
        var collectedTokenIds: [Int] = []
        for try await event in model.generateStream(
            text: "Hello, this is a deterministic seed test.",
            parameters: parameters
        ) {
            if case .token(let id) = event {
                collectedTokenIds.append(id)
            }
        }

        #expect(
            collectedTokenIds == fixture.expectedTokenIds,
            "SopranoTTS token sequence with seed=42 diverged from expected. If this is intentional (model update), regenerate the fixture."
        )
    }

    // MARK: PocketTTS (PARTIAL)

    /// Deterministic generation test for PocketTTS — PARTIAL IMPLEMENTATION.
    ///
    /// PocketTTS is a flow-matching model (continuous latent diffusion), NOT an
    /// autoregressive model over discrete codec tokens. Its `generateStream`
    /// yields only `.audio(MLXArray)` — there are no individual token IDs to
    /// assert on.
    ///
    /// Determinism proxy: assert that the generated audio sample count matches
    /// the expected count from the fixture. This guards against regressions that
    /// change audio length (e.g., EOS threshold changes, conditioning changes).
    ///
    /// NOTE: Even with a fixed RNG seed, continuous-latent flow models may not
    /// produce bit-identical output across Apple Silicon GPU generations. If
    /// nightly runs diverge across runners, downgrade to an existence check
    /// (audio.shape[0] > 0) and document the change here.
    ///
    /// Fixture: `Tests/media/deterministic/pockettts_seed42.json`
    /// If the fixture is a placeholder (expected_audio_sample_count == 0), the
    /// assertion is SKIPPED gracefully.
    @Test func pocketTTSDeterministic() async throws {
        let fixture = try loadFixture("pockettts_seed42", as: PocketTTSFixture.self)
        guard fixture.expectedAudioSampleCount > 0 else {
            // Graceful skip when fixture is a placeholder.
            // Regenerate: run this test locally with mlx-models-v2 cache, observe
            // audio.shape[0], and commit the value to pockettts_seed42.json
            // (field: expected_audio_sample_count).
            // Note: PocketTTS is a flow-matching model with no discrete token IDs.
            return
        }

        // Set deterministic seed before any MLX sampling.
        MLXRandom.seed(42)

        // Load model (requires mlx-models-v2 cache).
        let model = try await PocketTTSModel.fromPretrained(
            "mlx-community/pocket-tts"
        )

        let parameters = GenerateParameters(
            temperature: 0.6,
            topP: 0.8
        )

        // Collect audio from the stream.
        var audioSampleCount: Int = 0
        for try await event in model.generateStream(
            text: "Hello, this is a deterministic seed test.",
            voice: "alba",
            refAudio: nil,
            refText: nil,
            language: nil,
            instruct: nil,
            generationParameters: parameters
        ) {
            if case .audio(let audio) = event {
                audioSampleCount = audio.shape[0]
            }
        }

        #expect(
            audioSampleCount == fixture.expectedAudioSampleCount,
            "PocketTTS audio sample count with seed=42 diverged from expected \(fixture.expectedAudioSampleCount). Got \(audioSampleCount) samples. Flow-matching models may vary across GPU generations; see file header comment."
        )
    }
}
