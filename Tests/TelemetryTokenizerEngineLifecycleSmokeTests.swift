//
//  TelemetryTokenizerEngineLifecycleSmokeTests.swift
//  MLXAudioTests
//
//  Sortie 8 of OPERATION LEAK BLOODHOUND — Tokenizer + engine (aligner) lifecycle
//  hook coverage. Exercises the paired `init`/`deinit` Telemetry.trackLifecycle
//  call sites added to the tokenizer and engine classes in S8.
//
//  Each test:
//    1. Resets the shared CounterStore.
//    2. Constructs the tokenizer/engine with a synthetic config (no model download).
//    3. Waits for the fire-and-forget increment Task to land.
//    4. Drops the instance (sets the binding to nil).
//    5. Waits for the fire-and-forget decrement Task to land.
//    6. Asserts `snapshot.liveCounts["<Family>.Tokenizer"|"<Family>.Aligner"] == 0`.
//
//  All tokenizer and engine (aligner) classes use synthetic configs / direct
//  inits — no model downloads are required. All tests are CI-safe.
//
//  Concurrency: the suite is `.serialized` — every test mutates the shared
//  CounterStore singleton and calls `Telemetry.resetCounters()`.
//

import Foundation
import Testing
import MLX
import MLXNN

@testable import MLXAudioCore
@testable import MLXAudioTTS
@testable import MLXAudioSTT
@testable import MLXAudioCodecs

@Suite("TelemetryTokenizerEngineLifecycleSmokeTests", .serialized)
struct TelemetryTokenizerEngineLifecycleSmokeTests {

    // MARK: - Helpers

    private func resetForTest() async {
        await Telemetry.resetCounters()
    }

    /// Poll the counter store until the key reaches `target` or the attempt
    /// budget is exhausted (200 × 1 ms = up to 200 ms). Background-priority
    /// Tasks need an explicit `Task.sleep` to be scheduled.
    private func waitForCounter(
        _ key: String,
        target: Int,
        attempts: Int = 200
    ) async -> TelemetrySnapshot {
        var snap = await Telemetry.snapshot()
        for _ in 0..<attempts {
            if (snap.liveCounts[key] ?? 0) == target { return snap }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
            snap = await Telemetry.snapshot()
        }
        return snap
    }

    // MARK: - Qwen3TTS.Tokenizer (CI-safe — synthetic config, no download)

    @Test("Qwen3TTSSpeechTokenizer lifecycle: liveCount returns to 0 after deinit")
    func qwen3TTSSpeechTokenizerLifecycle() async throws {
        await resetForTest()

        let key = "Qwen3TTS.Tokenizer"
        let json = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(Qwen3TTSTokenizerConfig.self, from: json)

        var tokenizer: Qwen3TTSSpeechTokenizer? = Qwen3TTSSpeechTokenizer(config: config)
        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        tokenizer = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - Core.Tokenizer (UnigramTokenizer — CI-safe — synthetic JSON, no download)

    @Test("UnigramTokenizer lifecycle: liveCount returns to 0 after deinit")
    func unigramTokenizerLifecycle() async throws {
        await resetForTest()

        // Each UnigramTokenizer increments the Core.Tokenizer counter.
        // However, PocketTTSModuleSetupTests and other suites in the CI block
        // may have already constructed UnigramTokenizers — reset ensures clean baseline.
        let key = "Core.Tokenizer"
        let baseSnap = await Telemetry.snapshot()
        let baseline = baseSnap.liveCounts[key, default: 0]

        let stubJSON: [String: Any] = [
            "model": [
                "unk_id": 0,
                "vocab": [["<unk>", -100.0], ["hello", -1.0]]
            ]
        ]
        var tokenizer: UnigramTokenizer? = try UnigramTokenizer(tokenizerJSON: stubJSON)

        let snap = await waitForCounter(key, target: baseline + 1)
        #expect(
            (snap.liveCounts[key] ?? 0) == baseline + 1,
            "Expected liveCount[\(key)] == \(baseline + 1) after init"
        )

        tokenizer = nil

        let after = await waitForCounter(key, target: baseline)
        #expect(
            after.liveCounts[key, default: 0] == baseline,
            "Expected liveCount[\(key)] == \(baseline) after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - PocketTTS.Tokenizer (SentencePieceTokenizer — CI-safe — testStub init)

    @Test("SentencePieceTokenizer lifecycle: liveCount returns to 0 after deinit")
    func sentencePieceTokenizerLifecycle() async {
        await resetForTest()

        let key = "PocketTTS.Tokenizer"
        // Use the testing-only internal stub init: no file I/O, no model download.
        var tokenizer: SentencePieceTokenizer? = SentencePieceTokenizer(__testStub: 64)

        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        tokenizer = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - Mimi.Tokenizer (CI-safe — synthetic Mimi codec, no download)

    @Test("MimiTokenizer lifecycle: liveCount returns to 0 after deinit")
    func mimiTokenizerLifecycle() async {
        await resetForTest()

        let key = "Mimi.Tokenizer"
        // Construct a tiny Mimi codec (same pattern as TelemetryCodecLifecycleSmokeTests),
        // then wrap it in a MimiTokenizer. No model download.
        let cfg = mimi_202407(numCodebooks: 1)
        let mimi = Mimi(cfg: cfg)
        var tokenizer: MimiTokenizer? = MimiTokenizer(mimi)

        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        tokenizer = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - Qwen3ASR.Aligner (Qwen3ForcedAlignerModel — CI-safe — synthetic config)

    @Test("Qwen3ForcedAlignerModel lifecycle: liveCount returns to 0 after deinit")
    func qwen3ForcedAlignerModelLifecycle() async {
        await resetForTest()

        let key = "Qwen3ASR.Aligner"
        let config = Qwen3ASRConfig(
            audioConfig: Qwen3AudioEncoderConfig(
                encoderLayers: 1,
                encoderAttentionHeads: 4,
                encoderFfnDim: 512,
                dModel: 256,
                maxSourcePositions: 100,
                outputDim: 128
            ),
            textConfig: Qwen3TextConfig(
                vocabSize: 1000,
                hiddenSize: 128,
                intermediateSize: 256,
                numHiddenLayers: 1,
                numAttentionHeads: 4,
                numKeyValueHeads: 2,
                headDim: 32,
                tieWordEmbeddings: true
            )
        )

        var model: Qwen3ForcedAlignerModel? = Qwen3ForcedAlignerModel(config)
        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        model = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }
}
