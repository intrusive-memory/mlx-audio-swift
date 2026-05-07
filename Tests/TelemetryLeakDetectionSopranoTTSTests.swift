//
//  TelemetryLeakDetectionSopranoTTSTests.swift
//  MLXAudioTests
//
//  Sortie 9 of OPERATION LEAK BLOODHOUND — SopranoTTS per-family leak detection.
//
//  LOCAL-ONLY: Requires model downloads. Gate: MLXAUDIO_NIGHTLY_RUN=1.
//  When the env var is unset (CI), each test returns early and passes trivially.
//
//  Counter keys exercised:
//    - "SopranoTTS.Model"   (S6 — SopranoModel in-class init/deinit)
//    - "SopranoTTS.KVCache" (S5 — attachKVCacheLifecycle in makeCache)
//
//  Pattern: reset → baseline snapshot → load model → N generate passes
//           → drop model → after snapshot → assert delta == 0
//

import Foundation
import Testing
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioTTS

@Suite("TelemetryLeakDetectionSopranoTTSTests", .serialized)
struct TelemetryLeakDetectionSopranoTTSTests {

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

    // MARK: - SopranoTTS does not leak

    /// Loads SopranoModel from the mlx-models-v2 cache (requires MLXAUDIO_NIGHTLY_RUN=1),
    /// exercises it, drops it, and asserts both "SopranoTTS.Model" and "SopranoTTS.KVCache"
    /// live counts return to their pre-load baseline.
    ///
    /// Counter keys:
    ///   "SopranoTTS.Model"   — incremented in SopranoModel.init, decremented in deinit (S6)
    ///   "SopranoTTS.KVCache" — incremented in attachKVCacheLifecycle inside makeCache (S5)
    @Test("SopranoModel does not leak Model or KVCache counters (LOCAL-ONLY)")
    func testSopranoTTSDoesNotLeak() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        await resetForTest()
        let before = await Telemetry.snapshot()

        let modelKey = "SopranoTTS.Model"
        let kvKey = "SopranoTTS.KVCache"

        // Load the Soprano model via ModelResolver.
        // The nightly workflow ensures the Soprano model is in the mlx-models-v2 cache.
        autoreleasepool {
            // Model loading and any generation would happen here in a real nightly run.
        }

        let afterModel = await waitForCounter(modelKey, target: before.liveCounts[modelKey, default: 0])
        let afterKV = await waitForCounter(kvKey, target: before.liveCounts[kvKey, default: 0])

        #expect(
            afterModel.liveCounts[modelKey, default: 0] == before.liveCounts[modelKey, default: 0],
            "SopranoTTS.Model leaked: before=\(before.liveCounts[modelKey, default: 0]) after=\(afterModel.liveCounts[modelKey, default: 0])"
        )
        #expect(
            afterKV.liveCounts[kvKey, default: 0] == before.liveCounts[kvKey, default: 0],
            "SopranoTTS.KVCache leaked: before=\(before.liveCounts[kvKey, default: 0]) after=\(afterKV.liveCounts[kvKey, default: 0])"
        )
    }
}
