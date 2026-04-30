//
//  MarvisTTSGenerateTests.swift
//  MLXAudioTests
//
//  LOCAL-ONLY: Requires downloading multi-GB Marvis CSM/Sesame model files.
//  DO NOT add to the CI-safe -only-testing list in CLAUDE.md.
//  Runtime validation belongs in the nightly workflow (Sortie 9) and manual
//  local validation; this sortie's contract is compile-only per the local-only
//  convention used by Qwen3TTSTests, LlamaTTSTests, SopranoTTSTests, etc.
//
//  Run locally (requires mlx-models-v2 cache populated):
//    xcodebuild test \
//      -scheme MLXAudio-Package \
//      -destination 'platform=macOS' \
//      -only-testing:MLXAudioTests/MarvisTTSGenerateTests \
//      CODE_SIGNING_ALLOWED=NO
//

import Testing
import MLX
import MLXLMCommon
import Foundation

@testable import MLXAudioCore
@testable import MLXAudioTTS

// MARK: - Marvis TTS Generation Tests (local-only, requires model download)

@Suite("MarvisTTSGenerateTests")
struct MarvisTTSGenerateTests {

    /// Test basic end-to-end audio generation with the Marvis TTS (CSM / Sesame) model.
    ///
    /// Mirrors LlamaTTSTests.testLlamaTTSGenerate — fixed prompt, default voice
    /// (conversationalA), asserting:
    ///   - audio.shape.count == 1  (mono)
    ///   - audio.shape[0] >= 24000 (≥ 1 second at 24 kHz)
    ///
    /// Model keys: "csm" and "sesame" both route to MarvisTTSModel via TTSModelUtils
    /// (see Sources/MLXAudioTTS/TTSModelUtils.swift, case "csm", "sesame").
    @Test func testMarvisGenerate() async throws {
        // 1. Load Marvis TTS (CSM / Sesame) model from Acervo / HuggingFace
        print("\u{001B}[33mLoading Marvis TTS (csm/sesame) model...\u{001B}[0m")
        let model = try await MarvisTTSModel.fromPretrained(
            "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit"
        )
        print("\u{001B}[32mMarvis TTS model loaded! sampleRate=\(model.sampleRate)\u{001B}[0m")

        // 2. Generate audio — fixed prompt, default voice (.conversationalA)
        let text = "Hello, this is a test of the Marvis text to speech model."
        print("\u{001B}[33mGenerating audio for: \"\(text)\"...\u{001B}[0m")

        let audio = try await model.generate(
            text: text,
            voice: nil,          // resolves to .conversationalA (default)
            refAudio: nil,
            refText: nil,
            language: nil,
            instruct: nil,
            generationParameters: GenerateParameters()
        )

        print("\u{001B}[32mGenerated audio shape: \(audio.shape)\u{001B}[0m")

        // 3. Shape assertions: mono (1-D) and ≥ 1 second at 24 kHz
        let shapeDesc = "\(audio.shape)"
        let samplesDesc = "\(audio.shape[0])"
        #expect(audio.shape.count == 1,
                "Expected 1-D mono audio array; got shape \(shapeDesc)")
        #expect(audio.shape[0] >= 24000,
                "Expected >=24000 samples (>=1s at 24 kHz); got \(samplesDesc)")

        // 4. Save generated audio for manual inspection
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marvis_tts_test_output.wav")
        try saveAudioArray(audio, sampleRate: Double(model.sampleRate), to: outputURL)
        print("\u{001B}[32mSaved generated audio to\u{001B}[0m: \(outputURL.path)")
    }
}
