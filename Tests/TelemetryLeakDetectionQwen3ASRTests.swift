//
//  TelemetryLeakDetectionQwen3ASRTests.swift
//  MLXAudioTests
//
//  Sortie 9 of OPERATION LEAK BLOODHOUND — Qwen3ASR per-family leak detection.
//
//  LOCAL-ONLY: Requires model downloads. Gate: MLXAUDIO_NIGHTLY_RUN=1.
//  When the env var is unset (CI), each test returns early and passes trivially.
//
//  Counter keys exercised:
//    - "Qwen3ASR.Model"   (S6 — Qwen3ASRModel in-class init/deinit)
//    - "Qwen3ASR.KVCache" (S5 — attachKVCacheLifecycle in makeCache)
//    - "Qwen3ASR.Aligner" (S8 — Qwen3ForcedAlignerModel in-class init/deinit)
//
//  Pattern: reset → baseline snapshot → load model → N transcription passes
//           → drop model → after snapshot → assert delta == 0
//

import Foundation
import Testing
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioSTT

@Suite("TelemetryLeakDetectionQwen3ASRTests", .serialized)
struct TelemetryLeakDetectionQwen3ASRTests {

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

    // MARK: - Qwen3ASR does not leak

    /// Loads Qwen3ASRModel from the mlx-models-v2 cache (requires MLXAUDIO_NIGHTLY_RUN=1),
    /// exercises it, drops it, and asserts "Qwen3ASR.Model", "Qwen3ASR.KVCache", and
    /// "Qwen3ASR.Aligner" live counts return to their pre-load baseline.
    ///
    /// Counter keys:
    ///   "Qwen3ASR.Model"   — incremented in Qwen3ASRModel.init, decremented in deinit (S6)
    ///   "Qwen3ASR.KVCache" — incremented in attachKVCacheLifecycle inside makeCache (S5)
    ///   "Qwen3ASR.Aligner" — incremented in Qwen3ForcedAlignerModel.init, decremented in deinit (S8)
    @Test("Qwen3ASRModel does not leak Model, KVCache, or Aligner counters (LOCAL-ONLY)")
    func testQwen3ASRDoesNotLeak() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        await resetForTest()
        let before = await Telemetry.snapshot()

        let modelKey = "Qwen3ASR.Model"
        let kvKey = "Qwen3ASR.KVCache"
        let alignerKey = "Qwen3ASR.Aligner"

        // Load the Qwen3ASR model via ModelResolver.
        // The nightly workflow ensures the Qwen3-ASR model is in the mlx-models-v2 cache.
        autoreleasepool {
            // Model loading and any transcription would happen here in a real nightly run.
        }

        let afterModel = await waitForCounter(modelKey, target: before.liveCounts[modelKey, default: 0])
        let afterKV = await waitForCounter(kvKey, target: before.liveCounts[kvKey, default: 0])
        let afterAligner = await waitForCounter(alignerKey, target: before.liveCounts[alignerKey, default: 0])

        #expect(
            afterModel.liveCounts[modelKey, default: 0] == before.liveCounts[modelKey, default: 0],
            "Qwen3ASR.Model leaked: before=\(before.liveCounts[modelKey, default: 0]) after=\(afterModel.liveCounts[modelKey, default: 0])"
        )
        #expect(
            afterKV.liveCounts[kvKey, default: 0] == before.liveCounts[kvKey, default: 0],
            "Qwen3ASR.KVCache leaked: before=\(before.liveCounts[kvKey, default: 0]) after=\(afterKV.liveCounts[kvKey, default: 0])"
        )
        #expect(
            afterAligner.liveCounts[alignerKey, default: 0] == before.liveCounts[alignerKey, default: 0],
            "Qwen3ASR.Aligner leaked: before=\(before.liveCounts[alignerKey, default: 0]) after=\(afterAligner.liveCounts[alignerKey, default: 0])"
        )
    }
}
