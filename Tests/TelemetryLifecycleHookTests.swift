//
//  TelemetryLifecycleHookTests.swift
//  MLXAudioTests
//
//  Sortie 5 of OPERATION LEAK BLOODHOUND — KV cache lifecycle hook
//  coverage. These tests exercise the internal
//  `KVCacheLifecycleSentinel` and the public
//  `attachKVCacheLifecycle(family:to:)` helper that bind a counter-store
//  increment/decrement pair to the lifetime of an externally-owned
//  KV cache (`MLXLMCommon.KVCacheSimple`).
//
//  Coverage requirements (per EXECUTION_PLAN.md S5 task 5–6):
//  - trackLifecycle increments → sentinel init increments `liveCounts`.
//  - deinit decrements         → sentinel deinit decrements
//                                 `liveCounts`.
//  - multiple instances counted independently.
//  - synthetic KV-cache leak test: create+drop 10 KV caches and assert
//    `liveCount` returns to 0 (no model download).
//
//  Concurrency: every test mutates the shared `CounterStore.shared`
//  singleton, so the suite is `.serialized` to keep increments,
//  decrements, and resets from interleaving across cases.
//
//  Test target compiles with `MLXAUDIO_TELEMETRY_FULL`, so
//  `Telemetry.ceiling == .verbose` and the default level resolves to
//  `.lifecycle` — increments are NOT short-circuited.
//

import Foundation
import Testing
import MLXLMCommon

@testable import MLXAudioCore

@Suite("TelemetryLifecycleHookTests", .serialized)
struct TelemetryLifecycleHookTests {

    // MARK: - Helpers

    /// Reset the shared counter store before every scenario so tests
    /// don't leak state across each other.
    private func resetForTest() async {
        await Telemetry.resetCounters()
    }

    /// Wait for fire-and-forget `trackLifecycle` / `trackLifecycleEnd`
    /// detached Tasks (`.background` priority) to land their actor
    /// messages, then snapshot. The loop bound is generous (200 attempts
    /// at 1 ms each = up to 200 ms) so scheduling jitter on CI doesn't
    /// flake the test. Background-priority tasks can be deferred behind
    /// in-flight test-priority tasks; the explicit `Task.sleep` yields
    /// time to those background tasks instead of just relying on
    /// `Task.yield()` to schedule them.
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

    // MARK: - Sentinel init/deinit balance

    /// Direct test of `KVCacheLifecycleSentinel.init` → counter
    /// increments by 1.
    @Test("KVCacheLifecycleSentinel init increments liveCounts")
    func sentinelInitIncrements() async {
        await resetForTest()

        // Hold a strong reference so the sentinel doesn't deinit before
        // we observe the increment. Use a unique family to keep this
        // test's leftover-deinit decrement (which fires after function
        // return) out of subsequent tests' counter buckets.
        let family = "InitTestFamily"
        let sentinel = KVCacheLifecycleSentinel(family: family)
        defer { _ = sentinel } // keep alive past the snapshot

        let snap = await waitForCounter("\(family).KVCache", target: 1)
        #expect(snap.liveCounts["\(family).KVCache"] == 1)
    }

    /// Direct test of `KVCacheLifecycleSentinel.deinit` → counter
    /// decrements back to 0 once the sentinel is released.
    @Test("KVCacheLifecycleSentinel deinit decrements liveCounts")
    func sentinelDeinitDecrements() async {
        await resetForTest()

        // Pattern that forces ARC release: build the sentinel inside an
        // immediately-invoked closure so the only reference is the
        // optional we hold; setting it to nil drops the last reference.
        // We use a unique family name per test to avoid any cross-test
        // contamination from delayed detached-Task fire-and-forget
        // decrements landing after `resetForTest()` zeros liveCounts.
        let family = "DeinitTestFamily"
        var s: KVCacheLifecycleSentinel? = KVCacheLifecycleSentinel(family: family)
        _ = await waitForCounter("\(family).KVCache", target: 1)
        s = nil

        let snap = await waitForCounter("\(family).KVCache", target: 0)
        #expect(snap.liveCounts["\(family).KVCache", default: 0] == 0)
    }

    /// Multiple instances increment independently and decrement back to
    /// zero in aggregate.
    @Test("multiple sentinels are counted independently")
    func multipleSentinels() async {
        await resetForTest()

        // Box sentinels in optionals declared at function scope so we
        // can release them deterministically by setting to nil. Swift
        // does NOT guarantee release of `let` bindings at end of `do`
        // scope (ownership lifetime can extend); explicit nil-out via
        // `var` is the only reliable way.
        var a1: KVCacheLifecycleSentinel? = KVCacheLifecycleSentinel(family: "FamA")
        var a2: KVCacheLifecycleSentinel? = KVCacheLifecycleSentinel(family: "FamA")
        var a3: KVCacheLifecycleSentinel? = KVCacheLifecycleSentinel(family: "FamA")
        var b1: KVCacheLifecycleSentinel? = KVCacheLifecycleSentinel(family: "FamB")

        // Wait for all 4 increments to land.
        _ = await waitForCounter("FamA.KVCache", target: 3)
        let mid = await waitForCounter("FamB.KVCache", target: 1)
        #expect(mid.liveCounts["FamA.KVCache"] == 3)
        #expect(mid.liveCounts["FamB.KVCache"] == 1)

        a1 = nil
        a2 = nil
        a3 = nil
        b1 = nil

        _ = await waitForCounter("FamA.KVCache", target: 0)
        let after = await waitForCounter("FamB.KVCache", target: 0)
        #expect(after.liveCounts["FamA.KVCache", default: 0] == 0)
        #expect(after.liveCounts["FamB.KVCache", default: 0] == 0)
    }

    // MARK: - attachKVCacheLifecycle integration

    /// `attachKVCacheLifecycle` binds the sentinel's lifetime to its
    /// host. Releasing the host triggers ARC release of the associated
    /// sentinel, which fires `trackLifecycleEnd`.
    @Test("attachKVCacheLifecycle binds sentinel lifetime to host")
    func attachBindsLifetime() async {
        await resetForTest()

        var cache: KVCacheSimple? = KVCacheSimple()
        attachKVCacheLifecycle(family: "FamHost", to: cache!)
        let snap = await waitForCounter("FamHost.KVCache", target: 1)
        #expect(snap.liveCounts["FamHost.KVCache"] == 1)

        cache = nil // release host → ARC releases associated sentinel → deinit fires

        let after = await waitForCounter("FamHost.KVCache", target: 0)
        #expect(after.liveCounts["FamHost.KVCache", default: 0] == 0)
    }

    // MARK: - Leak test (synthetic, no model downloads)

    /// Synthetic KV-cache leak test: create 10 `KVCacheSimple` instances,
    /// each tagged with a sentinel via `attachKVCacheLifecycle`, drop
    /// them all, and assert `liveCount` returns to 0.
    ///
    /// This is the focused leak test required by S5 task 6 — proves the
    /// counter mechanism works end-to-end without any model downloads.
    @Test("create + drop 10 KV caches: liveCount returns to 0")
    func tenCachesLeakDetection() async {
        await resetForTest()

        let family = "LeakTest"
        let key = "\(family).KVCache"

        // Loop 10 times, allocating + releasing inside an autorelease
        // pool to ensure ARC drops the cache (and therefore the
        // associated sentinel) at the end of each iteration.
        for _ in 0..<10 {
            autoreleasepool {
                let cache = KVCacheSimple()
                attachKVCacheLifecycle(family: family, to: cache)
                _ = cache // use locally so the compiler can't elide
            }
        }

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            """
            Expected \(key) to return to 0 after creating + dropping 10 \
            instances; observed \(after.liveCounts[key, default: 0])
            """
        )
    }

    // MARK: - Family signposter selection

    /// The sentinel must accept any of the canonical family names without
    /// crashing — the signposter map has a default fallback for unknown
    /// families. Smoke-test by constructing one sentinel per known
    /// family from the audit.
    @Test("sentinel constructs cleanly for every audited family")
    func everyAuditedFamilyConstructs() async {
        await resetForTest()

        let families = [
            "Qwen3TTS", "Qwen3", "LlamaTTS", "SopranoTTS", "PocketTTS",
            "MarvisTTS", "Qwen3ASR", "GLMASR", "Mimi",
        ]

        var sentinels: [KVCacheLifecycleSentinel]? =
            families.map { KVCacheLifecycleSentinel(family: $0) }

        for f in families {
            _ = await waitForCounter("\(f).KVCache", target: 1)
        }
        let mid = await Telemetry.snapshot()
        for f in families {
            #expect(mid.liveCounts["\(f).KVCache"] == 1)
        }

        sentinels = nil // release the array → all sentinels deinit

        for f in families {
            _ = await waitForCounter("\(f).KVCache", target: 0)
        }
        let after = await Telemetry.snapshot()
        for f in families {
            #expect(after.liveCounts["\(f).KVCache", default: 0] == 0)
        }
    }
}
