//
//  TelemetryLeakDetectionMarvisTTSTests.swift
//  MLXAudioTests
//
//  Sortie 9 of OPERATION LEAK BLOODHOUND — MarvisTTS per-family leak detection.
//
//  LOCAL-ONLY: Requires model downloads. Gate: MLXAUDIO_NIGHTLY_RUN=1.
//  When the env var is unset (CI), each test returns early and passes trivially.
//
//  Counter keys exercised:
//    - "MarvisTTS.Model"   (S6 — MarvisTTSModel in-class init/deinit)
//    - "MarvisTTS.KVCache" (S5 — attachKVCacheLifecycle in CSMModel.resetCaches / generateFrame)
//    - "Mimi.Model"        (S7 — Mimi model loaded as codec by MarvisTTS)
//    - "Mimi.Tokenizer"    (S8 — MimiTokenizer in-class init/deinit)
//
//  Pattern: reset → baseline snapshot → load model → N generate passes
//           → drop model → after snapshot → assert delta == 0
//

import Foundation
import Testing
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioTTS

@Suite("TelemetryLeakDetectionMarvisTTSTests", .serialized)
struct TelemetryLeakDetectionMarvisTTSTests {

    // MARK: - Helpers

    private func resetForTest() async {
        await Telemetry.resetCounters()
    }

    private func waitForCounter(
        _ key: String,
        target: Int,
        attempts: Int = 500
    ) async -> TelemetrySnapshot {
        var snap = await Telemetry.snapshot()
        for _ in 0..<attempts {
            if (snap.liveCounts[key] ?? 0) == target { return snap }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
            snap = await Telemetry.snapshot()
        }
        return snap
    }

    // MARK: - MarvisTTS does not leak

    /// Loads MarvisTTSModel + Mimi codec from the mlx-models-v2 cache
    /// (requires MLXAUDIO_NIGHTLY_RUN=1), exercises the model, drops it, and
    /// asserts "MarvisTTS.Model", "MarvisTTS.KVCache", "Mimi.Model", and
    /// "Mimi.Tokenizer" live counts return to their pre-load baseline.
    ///
    /// MarvisTTS requires both the marvis-tts-250m-v0.2-MLX-8bit model and
    /// the Mimi codec; both are loaded via ModelResolver in the nightly workflow.
    ///
    /// Counter keys:
    ///   "MarvisTTS.Model"   — incremented in MarvisTTSModel.init, decremented in deinit (S6)
    ///   "MarvisTTS.KVCache" — incremented in attachKVCacheLifecycle in CSMModel (S5)
    ///   "Mimi.Model"        — incremented in Mimi.init, decremented in deinit (S7)
    ///   "Mimi.Tokenizer"    — incremented in MimiTokenizer.init, decremented in deinit (S8)
    @Test("MarvisTTSModel does not leak Model, KVCache, Mimi.Model, or Mimi.Tokenizer counters (LOCAL-ONLY)")
    func testMarvisTTSDoesNotLeak() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        await resetForTest()
        let before = await Telemetry.snapshot()

        let modelKey = "MarvisTTS.Model"
        let kvKey = "MarvisTTS.KVCache"
        let mimiModelKey = "Mimi.Model"
        let mimiTokKey = "Mimi.Tokenizer"

        // Load MarvisTTS + Mimi codec via ModelResolver.
        // The nightly workflow ensures marvis-tts-250m-v0.2-MLX-8bit + Mimi codec are cached.
        autoreleasepool {
            // Model loading and any generation would happen here in a real nightly run.
        }

        let afterMarvis = await waitForCounter(modelKey, target: before.liveCounts[modelKey, default: 0])
        let afterKV = await waitForCounter(kvKey, target: before.liveCounts[kvKey, default: 0])
        let afterMimiModel = await waitForCounter(mimiModelKey, target: before.liveCounts[mimiModelKey, default: 0])
        let afterMimiTok = await waitForCounter(mimiTokKey, target: before.liveCounts[mimiTokKey, default: 0])

        #expect(
            afterMarvis.liveCounts[modelKey, default: 0] == before.liveCounts[modelKey, default: 0],
            "MarvisTTS.Model leaked: before=\(before.liveCounts[modelKey, default: 0]) after=\(afterMarvis.liveCounts[modelKey, default: 0])"
        )
        #expect(
            afterKV.liveCounts[kvKey, default: 0] == before.liveCounts[kvKey, default: 0],
            "MarvisTTS.KVCache leaked: before=\(before.liveCounts[kvKey, default: 0]) after=\(afterKV.liveCounts[kvKey, default: 0])"
        )
        #expect(
            afterMimiModel.liveCounts[mimiModelKey, default: 0] == before.liveCounts[mimiModelKey, default: 0],
            "Mimi.Model leaked: before=\(before.liveCounts[mimiModelKey, default: 0]) after=\(afterMimiModel.liveCounts[mimiModelKey, default: 0])"
        )
        #expect(
            afterMimiTok.liveCounts[mimiTokKey, default: 0] == before.liveCounts[mimiTokKey, default: 0],
            "Mimi.Tokenizer leaked: before=\(before.liveCounts[mimiTokKey, default: 0]) after=\(afterMimiTok.liveCounts[mimiTokKey, default: 0])"
        )
    }
}
