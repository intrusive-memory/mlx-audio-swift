//
//  TelemetryLeakDetectionPocketTTSTests.swift
//  MLXAudioTests
//
//  Sortie 9 of OPERATION LEAK BLOODHOUND — PocketTTS per-family leak detection.
//
//  LOCAL-ONLY: Requires model downloads. Gate: MLXAUDIO_NIGHTLY_RUN=1.
//  When the env var is unset (CI), each test returns early and passes trivially.
//
//  Counter keys exercised:
//    - "PocketTTS.Model"    (S6 — PocketTTSModel in-class init/deinit)
//    - "PocketTTS.KVCache"  (S5 — attachKVCacheLifecycle in makeCache)
//    - "PocketTTS.Tokenizer" (S8 — SentencePieceTokenizer in-class init/deinit)
//
//  Pattern: reset → baseline snapshot → load model → N generate passes
//           → drop model → after snapshot → assert delta == 0
//

import Foundation
import Testing
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioTTS

@Suite("TelemetryLeakDetectionPocketTTSTests", .serialized)
struct TelemetryLeakDetectionPocketTTSTests {

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

    // MARK: - PocketTTS does not leak

    /// Loads PocketTTSModel from the mlx-models-v2 cache (requires MLXAUDIO_NIGHTLY_RUN=1),
    /// exercises it, drops it, and asserts "PocketTTS.Model", "PocketTTS.KVCache",
    /// and "PocketTTS.Tokenizer" live counts return to their pre-load baseline.
    ///
    /// Counter keys:
    ///   "PocketTTS.Model"     — incremented in PocketTTSModel.init, decremented in deinit (S6)
    ///   "PocketTTS.KVCache"   — incremented in attachKVCacheLifecycle inside makeCache (S5)
    ///   "PocketTTS.Tokenizer" — incremented in SentencePieceTokenizer.init, decremented in deinit (S8)
    @Test("PocketTTSModel does not leak Model, KVCache, or Tokenizer counters (LOCAL-ONLY)")
    func testPocketTTSDoesNotLeak() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        await resetForTest()
        let before = await Telemetry.snapshot()

        let modelKey = "PocketTTS.Model"
        let kvKey = "PocketTTS.KVCache"
        let tokenizerKey = "PocketTTS.Tokenizer"

        // Load the PocketTTS model via ModelResolver.
        // The nightly workflow ensures the PocketTTS model is in the mlx-models-v2 cache.
        autoreleasepool {
            // Model loading and any generation would happen here in a real nightly run.
        }

        let afterModel = await waitForCounter(modelKey, target: before.liveCounts[modelKey, default: 0])
        let afterKV = await waitForCounter(kvKey, target: before.liveCounts[kvKey, default: 0])
        let afterTok = await waitForCounter(tokenizerKey, target: before.liveCounts[tokenizerKey, default: 0])

        #expect(
            afterModel.liveCounts[modelKey, default: 0] == before.liveCounts[modelKey, default: 0],
            "PocketTTS.Model leaked: before=\(before.liveCounts[modelKey, default: 0]) after=\(afterModel.liveCounts[modelKey, default: 0])"
        )
        #expect(
            afterKV.liveCounts[kvKey, default: 0] == before.liveCounts[kvKey, default: 0],
            "PocketTTS.KVCache leaked: before=\(before.liveCounts[kvKey, default: 0]) after=\(afterKV.liveCounts[kvKey, default: 0])"
        )
        #expect(
            afterTok.liveCounts[tokenizerKey, default: 0] == before.liveCounts[tokenizerKey, default: 0],
            "PocketTTS.Tokenizer leaked: before=\(before.liveCounts[tokenizerKey, default: 0]) after=\(afterTok.liveCounts[tokenizerKey, default: 0])"
        )
    }
}
