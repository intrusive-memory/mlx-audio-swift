//
//  TelemetryCounterStoreTests.swift
//  MLXAudioTests
//
//  Sortie 4 of OPERATION LEAK BLOODHOUND — counter store actor +
//  snapshot / reset API for the MLXAudio telemetry surface.
//
//  These tests exercise the actor-backed `CounterStore` indirectly via
//  the public `Telemetry.snapshot()` / `Telemetry.resetCounters()`
//  surface, plus a few `@testable` calls on the actor's internal
//  helpers to seed peak state and read raw counts without poking the
//  real MLX allocator.
//
//  Concurrency note: tests use `await CounterStore.shared.increment(...)`
//  directly (not the fire-and-forget `Telemetry.trackLifecycle(...)`)
//  so we can deterministically wait for mutations to land before
//  asserting. The fire-and-forget path is exercised separately in
//  `testTrackLifecycleEnqueuesIncrement` with an explicit drain.
//
//  Test targets compile with `MLXAUDIO_TELEMETRY_FULL`, so
//  `Telemetry.ceiling` is `.verbose` and `Telemetry.level` resolves to
//  `.lifecycle` by default — increments and decrements are NOT
//  short-circuited by the `.off` guard.
//

import Foundation
import Testing

@testable import MLXAudioCore

// `.serialized` is required: every test mutates the shared
// `CounterStore.shared` singleton, so parallel execution of test methods
// would let increments / decrements / resets interleave across cases and
// produce non-deterministic counts. The suite is small enough that
// serial execution is acceptable.
@Suite("TelemetryCounterStoreTests", .serialized)
struct TelemetryCounterStoreTests {

    // MARK: - Helpers

    /// Reset the shared store before each scenario so independent test
    /// methods don't collide on the singleton's `liveCounts`. Peak is
    /// monotonic by design and is not reset between tests; specific
    /// peak-tests seed it explicitly via `_setPeakForTesting`.
    private func resetForTest() async {
        await Telemetry.resetCounters()
    }

    /// Drain any in-flight detached `Task`s that the fire-and-forget
    /// `trackLifecycle` helpers spawn. Routing through the actor with a
    /// no-op `snapshot()` is enough to serialize behind any prior
    /// detached enqueues — the actor processes messages FIFO per
    /// caller, and `Task.detached` enqueues land in the actor's queue
    /// before we await our snapshot. To be robust against scheduling,
    /// we also yield twice and re-snapshot.
    private func drain() async -> TelemetrySnapshot {
        await Task.yield()
        await Task.yield()
        return await Telemetry.snapshot()
    }

    // MARK: - Increment / decrement balance

    @Test("increment then decrement returns to zero")
    func incrementDecrementBalance() async {
        await resetForTest()

        await CounterStore.shared.increment(className: "Test.Foo")
        await CounterStore.shared.increment(className: "Test.Foo")
        await CounterStore.shared.increment(className: "Test.Foo")

        var snap = await Telemetry.snapshot()
        #expect(snap.liveCounts["Test.Foo"] == 3)

        await CounterStore.shared.decrement(className: "Test.Foo")
        await CounterStore.shared.decrement(className: "Test.Foo")
        await CounterStore.shared.decrement(className: "Test.Foo")

        snap = await Telemetry.snapshot()
        #expect(snap.liveCounts["Test.Foo"] == 0)
    }

    @Test("multiple class labels are tracked independently")
    func independentClassLabels() async {
        await resetForTest()

        await CounterStore.shared.increment(className: "Test.A")
        await CounterStore.shared.increment(className: "Test.A")
        await CounterStore.shared.increment(className: "Test.B")

        let snap = await Telemetry.snapshot()
        #expect(snap.liveCounts["Test.A"] == 2)
        #expect(snap.liveCounts["Test.B"] == 1)
    }

    // MARK: - Reset semantics

    @Test("reset zeroes liveCounts")
    func resetZeroesLiveCounts() async {
        await resetForTest()

        await CounterStore.shared.increment(className: "Test.Reset")
        await CounterStore.shared.increment(className: "Test.Reset")
        await CounterStore.shared.increment(className: "Test.Other")

        var snap = await Telemetry.snapshot()
        #expect(snap.liveCounts["Test.Reset"] == 2)
        #expect(snap.liveCounts["Test.Other"] == 1)

        await Telemetry.resetCounters()

        snap = await Telemetry.snapshot()
        #expect(snap.liveCounts["Test.Reset", default: 0] == 0)
        #expect(snap.liveCounts["Test.Other", default: 0] == 0)
        #expect(snap.liveCounts.isEmpty)
    }

    @Test("reset preserves mlxPeakBytes (monotonic across resets)")
    func testResetPreservesPeak() async {
        await resetForTest()

        // Seed peak deterministically — we cannot rely on a real MLX
        // allocation in unit tests, and the requirement under test is
        // about the reset semantic, not the peak-tracking semantic.
        let seededPeak = 1_234_567_890
        await CounterStore.shared._setPeakForTesting(seededPeak)

        let before = await Telemetry.snapshot()
        #expect(before.mlxPeakBytes >= seededPeak)
        let observedPeak = before.mlxPeakBytes

        await Telemetry.resetCounters()

        let after = await Telemetry.snapshot()
        // Peak must be at least the seeded value — `snapshot()` only
        // ever bumps it upward, never downward, so it must remain >= observedPeak.
        #expect(after.mlxPeakBytes >= observedPeak)
        // And in the test scenario where no large MLX allocation happens
        // between snapshots, the peak should stay exactly at observedPeak.
        #expect(after.mlxPeakBytes == observedPeak)
    }

    @Test("snapshot updates mlxPeakBytes when activeMemory exceeds it")
    func snapshotBumpsPeak() async {
        await resetForTest()

        // Seed peak at zero.
        await CounterStore.shared._setPeakForTesting(0)
        let snap = await Telemetry.snapshot()
        // After snapshot: mlxPeakBytes == max(0, mlxActiveBytes) == mlxActiveBytes.
        #expect(snap.mlxPeakBytes == snap.mlxActiveBytes)
    }

    // MARK: - Concurrent mutation

    @Test("snapshot is consistent under concurrent increment/decrement")
    func concurrentMutationBalance() async {
        await resetForTest()

        let iterations = 500

        // 500 increments + 500 decrements interleaved across many tasks.
        // Net delta must be 0 on the actor's serialized queue.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await CounterStore.shared.increment(className: "Test.Concurrent")
                }
                group.addTask {
                    await CounterStore.shared.decrement(className: "Test.Concurrent")
                }
            }
        }

        let snap = await Telemetry.snapshot()
        #expect(snap.liveCounts["Test.Concurrent", default: 0] == 0)
    }

    @Test("snapshot under concurrent unbalanced increments matches submitted total")
    func concurrentIncrementOnly() async {
        await resetForTest()

        let iterations = 200

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await CounterStore.shared.increment(className: "Test.Inc")
                }
            }
        }

        let snap = await Telemetry.snapshot()
        #expect(snap.liveCounts["Test.Inc"] == iterations)
    }

    // MARK: - trackLifecycle (fire-and-forget)

    @Test("trackLifecycle enqueues an increment via detached Task")
    func testTrackLifecycleEnqueuesIncrement() async {
        await resetForTest()

        final class Dummy {}
        let d = Dummy()
        Telemetry.trackLifecycle(d, className: "Test.Lifecycle")

        // Drain: detached Tasks may not have executed yet. Loop with a
        // bounded number of yields until the increment lands.
        var observed = 0
        for _ in 0..<50 {
            let snap = await drain()
            if let n = snap.liveCounts["Test.Lifecycle"], n >= 1 {
                observed = n
                break
            }
        }
        #expect(observed == 1)
    }

    @Test("trackLifecycleEnd enqueues a decrement via detached Task")
    func testTrackLifecycleEndEnqueuesDecrement() async {
        await resetForTest()

        // Pre-seed a count of 1 directly through the actor so the
        // fire-and-forget decrement can balance it cleanly.
        await CounterStore.shared.increment(className: "Test.LifecycleEnd")

        Telemetry.trackLifecycleEnd(className: "Test.LifecycleEnd")

        var observed: Int? = nil
        for _ in 0..<50 {
            let snap = await drain()
            if let n = snap.liveCounts["Test.LifecycleEnd"], n == 0 {
                observed = n
                break
            }
        }
        #expect(observed == 0)
    }

    // MARK: - snapshot fields

    @Test("snapshot fields are populated and well-formed")
    func snapshotFieldShape() async {
        await resetForTest()

        let snap = await Telemetry.snapshot()
        // mlxActiveBytes is unsigned in spirit; in tests we just assert non-negative.
        #expect(snap.mlxActiveBytes >= 0)
        #expect(snap.mlxPeakBytes >= snap.mlxActiveBytes)
        // timestamp is recent (within the last 5 seconds).
        let delta = abs(Date().timeIntervalSince(snap.timestamp))
        #expect(delta < 5.0)
    }
}
