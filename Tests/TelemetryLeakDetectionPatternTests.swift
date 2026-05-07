//
//  TelemetryLeakDetectionPatternTests.swift
//  MLXAudioTests
//
//  Sortie 9 of OPERATION LEAK BLOODHOUND — Canonical leak-detection pattern
//  (CI-safe). Encodes the verbatim pattern from docs/TELEMETRY_REQUIREMENTS.md
//  Section 7:
//
//      await Telemetry.resetCounters()
//      let before = await Telemetry.snapshot()
//      for _ in 0..<N {
//          // construct + drop a long-lived object
//      }
//      let after = await Telemetry.snapshot()
//      // assert delta in liveCounts is zero per relevant key
//
//  Two tests exercise the two distinct instrumentation idioms used in S5–S8:
//
//  1. In-class init/deinit style (S6/S7/S8): Used by `Qwen3TTSModel`,
//     `LlamaTTSModel`, `SopranoModel`, codec models, and tokenizers. The
//     lifecycle hook calls `Telemetry.trackLifecycle(self, className:)` in
//     `init` and `Telemetry.trackLifecycleEnd(className:)` in `deinit`.
//
//  2. Sentinel / associated-object style (S5): Used by KV cache classes that
//     are externally owned (`KVCacheSimple` from MLXLMCommon). The hook calls
//     `attachKVCacheLifecycle(family:to:)` which binds a
//     `KVCacheLifecycleSentinel` to the cache via `objc_setAssociatedObject`.
//     When the cache is released, ARC releases the sentinel, firing its
//     `deinit` which calls `Telemetry.trackLifecycleEnd`.
//
//  Both use synthetic configs — no model downloads required. The suite is
//  CI-safe and is included in the CLAUDE.md CI-safe block.
//
//  Concurrency: the suite is `.serialized` — every test mutates the shared
//  `CounterStore.shared` singleton and calls `Telemetry.resetCounters()`.
//

import Foundation
import Testing
import MLX
import MLXNN
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioTTS

// MARK: - Suite

@Suite("TelemetryLeakDetectionPatternTests", .serialized)
struct TelemetryLeakDetectionPatternTests {

    // MARK: - Helpers

    /// Reset the shared counter store before each scenario.
    private func resetForTest() async {
        await Telemetry.resetCounters()
    }

    /// Poll the counter store until `key` reaches `target` or the attempt
    /// budget is exhausted (200 × 1 ms = 200 ms). Background-priority
    /// detached Tasks need explicit `Task.sleep` slots to be scheduled.
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

    // MARK: - Idiom 1: In-class init/deinit style (S6/S7/S8 pattern)
    //
    // Tests the pattern used by model classes (`Qwen3TTSModel`, `LlamaTTSModel`,
    // etc.) and codec models that call `Telemetry.trackLifecycle(self, className:)`
    // directly in their `init` and `Telemetry.trackLifecycleEnd(className:)` in
    // their `deinit`. This is the most common style in the codebase.

    /// Canonical leak-detection pattern applied to `LlamaTTSModel` (in-class
    /// init/deinit style). Creates 10 model instances with a tiny synthetic
    /// config, drops them all, and asserts `liveCounts["LlamaTTS.Model"]` delta
    /// is zero relative to the baseline snapshot captured before the loop.
    ///
    /// Pattern mirrors docs/TELEMETRY_REQUIREMENTS.md Section 7 verbatim:
    ///   reset → baseline snapshot → loop (construct + drop) → after snapshot → assert delta == 0
    @Test("in-class init/deinit style: 10 LlamaTTSModel instances leave zero delta")
    func patternInClassInitDeinit() async {
        // Step 1: Reset counters to a known-zero state.
        await Telemetry.resetCounters()

        // Step 2: Capture the baseline snapshot BEFORE the allocation loop.
        // This handles any pre-existing live instances from other tests or
        // framework initialization — the assertion checks the delta, not
        // absolute value, so pre-existing counts don't affect correctness.
        let before = await Telemetry.snapshot()

        let key = "LlamaTTS.Model"
        let iterationCount = 10

        // Step 3: Loop — construct and drop inside autoreleasepool so ARC
        // releases the model at the end of each iteration.
        for _ in 0..<iterationCount {
            autoreleasepool {
                let config = makeTinyLlamaTTSConfig()
                let model = LlamaTTSModel(config)
                _ = model // suppress unused-variable warning
                // model goes out of scope here → ARC releases → deinit fires
                // → Telemetry.trackLifecycleEnd schedules decrement Task
            }
        }

        // Step 4: Snapshot AFTER the loop. The waitForCounter call drains any
        // in-flight background-priority Tasks before we assert.
        let after = await waitForCounter(key, target: before.liveCounts[key, default: 0])

        // Step 5: Assert the delta is zero — no instances leaked.
        let beforeCount = before.liveCounts[key, default: 0]
        let afterCount = after.liveCounts[key, default: 0]
        #expect(
            afterCount == beforeCount,
            """
            LlamaTTS.Model leaked across \(iterationCount) iterations: \
            before=\(beforeCount) after=\(afterCount) delta=\(afterCount - beforeCount)
            """
        )
    }

    // MARK: - Idiom 2: Sentinel / associated-object style (S5 pattern)
    //
    // Tests the pattern used by KV cache classes (`KVCacheSimple` from
    // MLXLMCommon) that cannot be subclassed. The `attachKVCacheLifecycle`
    // free function binds a `KVCacheLifecycleSentinel` to the cache via
    // `objc_setAssociatedObject`. When the cache is released, ARC releases
    // the sentinel, firing its `deinit` which calls `Telemetry.trackLifecycleEnd`.

    /// Canonical leak-detection pattern applied to `KVCacheSimple` (sentinel /
    /// associated-object style). Creates 15 cache instances tagged with the
    /// sentinel, drops them all, and asserts `liveCounts["Sentinel.KVCache"]`
    /// delta is zero relative to the baseline.
    ///
    /// This test documents WHY the sentinel style is needed: `KVCacheSimple`
    /// is `public class` (not `open`) from an external package and cannot be
    /// subclassed. The associated-objects pattern binds lifecycle tracking to
    /// any non-final class instance without modifying its source.
    @Test("sentinel/associated-object style: 15 KVCacheSimple instances leave zero delta")
    func patternSentinelAssociatedObject() async {
        // Step 1: Reset counters to a known-zero state.
        await Telemetry.resetCounters()

        // Step 2: Capture the baseline snapshot BEFORE the allocation loop.
        let before = await Telemetry.snapshot()

        let family = "Sentinel"
        let key = "\(family).KVCache"
        let iterationCount = 15

        // Step 3: Loop — construct KVCacheSimple, attach sentinel, and drop
        // inside autoreleasepool so ARC releases both the cache (and therefore
        // its associated sentinel) at the end of each iteration.
        for _ in 0..<iterationCount {
            autoreleasepool {
                let cache = KVCacheSimple()
                attachKVCacheLifecycle(family: family, to: cache)
                _ = cache // suppress unused-variable warning
                // cache goes out of scope here → ARC releases cache →
                // objc_setAssociatedObject releases sentinel → sentinel.deinit
                // fires → Telemetry.trackLifecycleEnd schedules decrement Task
            }
        }

        // Step 4: Snapshot AFTER the loop. waitForCounter drains in-flight Tasks.
        let after = await waitForCounter(key, target: before.liveCounts[key, default: 0])

        // Step 5: Assert the delta is zero — no caches leaked.
        let beforeCount = before.liveCounts[key, default: 0]
        let afterCount = after.liveCounts[key, default: 0]
        #expect(
            afterCount == beforeCount,
            """
            \(key) leaked across \(iterationCount) iterations: \
            before=\(beforeCount) after=\(afterCount) delta=\(afterCount - beforeCount)
            """
        )
    }

    // MARK: - Config helpers

    /// Tiny LlamaTTSConfiguration — hiddenSize (32) divisible by attentionHeads (4).
    /// No weight loading. Fast enough for 10 iterations in well under 1 second.
    private func makeTinyLlamaTTSConfig() -> LlamaTTSConfiguration {
        LlamaTTSConfiguration(
            hiddenSize: 32,
            hiddenLayers: 2,
            intermediateSize: 64,
            attentionHeads: 4,
            rmsNormEps: 1e-5,
            vocabularySize: 256,
            kvHeads: 2,
            ropeTheta: 10000,
            ropeScaling: [
                "factor": .float(32.0),
                "rope_type": .string("llama3")
            ]
        )
    }
}
