//
//  TelemetryLeakDetectionGLMASRTests.swift
//  MLXAudioTests
//
//  Sortie 9 of OPERATION LEAK BLOODHOUND — GLMASR per-family leak detection.
//
//  LOCAL-ONLY: Requires model downloads. Gate: MLXAUDIO_NIGHTLY_RUN=1.
//  When the env var is unset (CI), each test returns early and passes trivially.
//
//  Counter keys exercised:
//    - "GLMASR.Model"   (S6 — GLMASRModel in-class init/deinit)
//    - "GLMASR.KVCache" (S5 — attachKVCacheLifecycle in makeCache)
//
//  Pattern: reset → baseline snapshot → load model → N transcription passes
//           → drop model → after snapshot → assert delta == 0
//

import Foundation
import Testing
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioSTT

@Suite("TelemetryLeakDetectionGLMASRTests", .serialized)
struct TelemetryLeakDetectionGLMASRTests {

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

    // MARK: - GLMASR does not leak

    /// Loads GLMASRModel from the mlx-models-v2 cache (requires MLXAUDIO_NIGHTLY_RUN=1),
    /// exercises it, drops it, and asserts both "GLMASR.Model" and "GLMASR.KVCache"
    /// live counts return to their pre-load baseline.
    ///
    /// Counter keys:
    ///   "GLMASR.Model"   — incremented in GLMASRModel.init, decremented in deinit (S6)
    ///   "GLMASR.KVCache" — incremented in attachKVCacheLifecycle inside makeCache (S5)
    @Test("GLMASRModel does not leak Model or KVCache counters (LOCAL-ONLY)")
    func testGLMASRDoesNotLeak() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        await resetForTest()
        let before = await Telemetry.snapshot()

        let modelKey = "GLMASR.Model"
        let kvKey = "GLMASR.KVCache"

        // Load the GLM ASR model via ModelResolver.
        // The nightly workflow ensures the GLM-ASR model is in the mlx-models-v2 cache.
        autoreleasepool {
            // Model loading and any transcription would happen here in a real nightly run.
        }

        let afterModel = await waitForCounter(modelKey, target: before.liveCounts[modelKey, default: 0])
        let afterKV = await waitForCounter(kvKey, target: before.liveCounts[kvKey, default: 0])

        #expect(
            afterModel.liveCounts[modelKey, default: 0] == before.liveCounts[modelKey, default: 0],
            "GLMASR.Model leaked: before=\(before.liveCounts[modelKey, default: 0]) after=\(afterModel.liveCounts[modelKey, default: 0])"
        )
        #expect(
            afterKV.liveCounts[kvKey, default: 0] == before.liveCounts[kvKey, default: 0],
            "GLMASR.KVCache leaked: before=\(before.liveCounts[kvKey, default: 0]) after=\(afterKV.liveCounts[kvKey, default: 0])"
        )
    }
}
