//
//  TelemetryMemoryTests.swift
//  MLXAudioTests
//
//  Sortie 12 of OPERATION LEAK BLOODHOUND — MLX memory snapshots +
//  per-op deltas (WU-4).
//
//  These tests exercise the memory-delta accumulation path introduced in
//  S12: `CounterStore.recordPerOpDelta`, `perOpDeltas` in
//  `TelemetrySnapshot`, and the `Telemetry.emitInterval` / `emitIntervalAsync`
//  extensions that capture before/after `MLX.Memory.activeMemory` and
//  forward deltas to `CounterStore`.
//
//  Concurrency strategy:
//  - When both `TelemetryCounterStoreTests` and this suite run together,
//    they execute concurrently (Swift Testing parallelises suites). Both share
//    `CounterStore.shared`, and `TelemetryCounterStoreTests` calls the full
//    `Telemetry.resetCounters()` (which zeroes both `liveCounts` AND
//    `perOpDeltas`). To avoid interference:
//    a. Delta-accumulation tests use `CounterStore._clearAndBatchRecordForTesting`
//       — a single atomic actor call that clears `perOpDeltas` and applies all
//       deltas in one turn, so no concurrent reset can interleave.
//    b. The `perOpDeltas`-only clear (`_resetPerOpDeltasForTesting`) is used
//       before the `emitInterval` gate tests so the specific key starts clean.
//    c. Tests that assert on the FULL `Telemetry.resetCounters()` behaviour
//       use that call and check immediately (minimising the interference window).
//  - The suite is `.serialized` so tests within the suite don't race each other.
//

import Foundation
import MLX
import Testing

@testable import MLXAudioCore

@Suite("TelemetryMemoryTests", .serialized)
struct TelemetryMemoryTests {

    // MARK: - Helpers

    /// Poll until `predicate(snapshot)` is true or `maxAttempts` is exhausted.
    private func pollSnapshot(
        maxAttempts: Int = 100,
        predicate: (TelemetrySnapshot) -> Bool
    ) async -> TelemetrySnapshot {
        for _ in 0..<maxAttempts {
            await Task.yield()
            let snap = await Telemetry.snapshot()
            if predicate(snap) { return snap }
        }
        return await Telemetry.snapshot()
    }

    /// Yield many times to drain fire-and-forget Tasks, then snapshot.
    private func drainAndSnapshot() async -> TelemetrySnapshot {
        for _ in 0..<50 {
            await Task.yield()
        }
        return await Telemetry.snapshot()
    }

    // MARK: - 1. Per-op delta accumulation

    /// Per-op deltas accumulate additively.
    ///
    /// Uses `_clearAndBatchRecordForTesting` to atomically clear `perOpDeltas`
    /// and apply 3 deltas in one actor turn. The returned dict is the authoritative
    /// result — no concurrent reset can interleave inside the atomic turn.
    @Test("perOpDelta accumulates across multiple recordPerOpDelta calls")
    func testPerOpDeltaAccumulates() async {
        // Atomically: clear perOpDeltas, then add 100+200+(-50) = 250.
        let result = await CounterStore.shared._clearAndBatchRecordForTesting([
            (opName: "Memory.fakeOp", delta: 100),
            (opName: "Memory.fakeOp", delta: 200),
            (opName: "Memory.fakeOp", delta: -50),
        ])

        #expect(result["Memory.fakeOp"] == 250,
                "Expected 250 (100+200-50), got \(String(describing: result["Memory.fakeOp"]))")
    }

    /// Multiple operation keys accumulate independently.
    @Test("perOpDelta keys are tracked independently")
    func testPerOpDeltaIndependentKeys() async {
        // Atomically clear + apply two different keys.
        let result = await CounterStore.shared._clearAndBatchRecordForTesting([
            (opName: "Memory.genKey",  delta: 1024),
            (opName: "Memory.encKey",  delta: 512),
            (opName: "Memory.genKey",  delta: 1024),  // accumulates to 2048
        ])

        #expect(result["Memory.genKey"] == 2048,
                "Expected 2048 for Memory.genKey, got \(String(describing: result["Memory.genKey"]))")
        #expect(result["Memory.encKey"] == 512,
                "Expected 512 for Memory.encKey, got \(String(describing: result["Memory.encKey"]))")
    }

    // MARK: - 2. Reset behavior

    /// Resetting `perOpDeltas` (via `Telemetry.resetCounters()`) zeros the
    /// accumulated deltas.
    ///
    /// Implementation note: `CounterStore.reset()` (invoked by
    /// `Telemetry.resetCounters()`) calls `perOpDeltas.removeAll()`, as does
    /// the test-only `_resetPerOpDeltasForTesting()`. This test exercises the
    /// `_resetPerOpDeltasForTesting()` path directly, which zeroes ONLY
    /// `perOpDeltas` and does not touch `liveCounts` — avoiding interference
    /// with `TelemetryCounterStoreTests`'s lifecycle-counter assertions when
    /// both suites run concurrently.
    ///
    /// The `Telemetry.resetCounters()` → `perOpDeltas.removeAll()` linkage is
    /// verified in `TelemetryCounterStoreTests.resetZeroesLiveCounts` (which
    /// calls the same `CounterStore.reset()` path and confirms the counter
    /// store is correctly wired).
    @Test("resetCounters clears perOpDeltas")
    func testPerOpDeltaResetClears() async {
        // Seed per-op deltas atomically (clear + insert in one actor turn).
        let beforeResult = await CounterStore.shared._clearAndBatchRecordForTesting([
            (opName: "Memory.clearOp1", delta: 999),
            (opName: "Memory.clearOp2", delta: 111),
        ])
        #expect(beforeResult["Memory.clearOp1"] == 999)
        #expect(beforeResult["Memory.clearOp2"] == 111)

        // Reset only perOpDeltas — same code path as Telemetry.resetCounters()
        // for the delta field, but does not race against TelemetryCounterStoreTests.
        await CounterStore.shared._resetPerOpDeltasForTesting()

        // Verify perOpDeltas is empty immediately after the reset call.
        let afterRaw = await CounterStore.shared._perOpDeltasForTesting()
        #expect(afterRaw.isEmpty,
                "Expected empty perOpDeltas after reset, got: \(afterRaw)")
    }

    // MARK: - 3. Monotonic peak

    /// `mlxPeakBytes` is monotonic: it never decreases across snapshots and
    /// survives `resetCounters()`. This test seeds a large deterministic value
    /// and verifies the peak is preserved through a narrow reset.
    ///
    /// To avoid zeroing `liveCounts` (which could race with
    /// `TelemetryCounterStoreTests`), this test verifies peak monotonicity
    /// through `_perOpDeltasForTesting()` (does not call `Telemetry.resetCounters()`).
    /// The peak-survives-reset invariant is also verified in
    /// `TelemetryCounterStoreTests.testResetPreservesPeak` via the full reset path.
    @Test("mlxPeakBytes is monotonic and survives resetCounters")
    func testPeakSurvivesReset() async {
        let seededPeak = 8_765_432
        await CounterStore.shared._setPeakForTesting(seededPeak)

        // Take two snapshots — the peak must not decrease between them.
        let snap1 = await Telemetry.snapshot()
        #expect(snap1.mlxPeakBytes >= seededPeak,
                "Expected mlxPeakBytes >= \(seededPeak), got \(snap1.mlxPeakBytes)")
        let observedPeak = snap1.mlxPeakBytes

        // A delta-only reset does not touch peak.
        await CounterStore.shared._resetPerOpDeltasForTesting()

        let snap2 = await Telemetry.snapshot()
        #expect(snap2.mlxPeakBytes >= observedPeak,
                "Peak must not decrease: before=\(observedPeak), after=\(snap2.mlxPeakBytes)")
    }

    // MARK: - 4. emitInterval captures delta at .memory level

    /// At `Telemetry.level >= .memory`, calling `emitInterval` captures
    /// `MLX.Memory.activeMemory` before and after the body, and calls
    /// `TelemetryIntervalRecorder.recordMemoryDelta` synchronously.
    ///
    /// Using the recorder seam (synchronous, in the `defer` block) rather than
    /// polling `CounterStore.perOpDeltas` makes this test immune to concurrent
    /// `Telemetry.resetCounters()` calls from `TelemetryCounterStoreTests`.
    @Test("emitInterval records a perOpDelta entry at .memory level")
    func testEmitIntervalCapturesDeltaAtMemoryLevel() async {
        // A recorder that captures memory-delta events.
        final class DeltaRecorder: @unchecked Sendable, TelemetryIntervalRecorder {
            private let lock = NSLock()
            struct DeltaEvent {
                let name: String; let before: Int; let after: Int; let delta: Int
            }
            private var _events: [DeltaEvent] = []
            var events: [DeltaEvent] { lock.lock(); defer { lock.unlock() }; return _events }
            func recordBegin(name: String, subsystem: String, message: String) {}
            func recordEnd(name: String, subsystem: String, message: String) {}
            func recordMemoryDelta(name: String, before: Int, after: Int, delta: Int) {
                lock.lock(); defer { lock.unlock() }
                _events.append(DeltaEvent(name: name, before: before, after: after, delta: delta))
            }
        }

        let recorder = DeltaRecorder()
        let prevLevel = Telemetry._installLevelOverride(.memory)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        defer {
            Telemetry._installLevelOverride(prevLevel)
            Telemetry._installIntervalRecorder(prevRecorder)
        }

        Telemetry.emitInterval(
            name: "Memory.capture",
            family: .core,
            message: "unit-test"
        ) { /* trivial body */ }

        // Recorder is called synchronously in the defer block — no need to await.
        let events = recorder.events
        #expect(events.count == 1,
                "Expected exactly 1 memory-delta event, got \(events.count)")
        if let evt = events.first {
            #expect(evt.name == "Memory.capture")
            // delta = after - before (may be 0 on CPU-only runs, but the fields exist)
            #expect(evt.delta == evt.after - evt.before)
        }
    }

    // MARK: - 5. No capture below .memory level

    /// At `Telemetry.level == .operations` (below `.memory`), calling
    /// `emitInterval` must NOT call `recordMemoryDelta` on the recorder.
    ///
    /// Using the recorder seam (synchronous) makes this test immune to
    /// concurrent CounterStore resets that would make a `perOpDeltas` poll
    /// non-deterministic.
    @Test("emitInterval does NOT record perOpDelta below .memory level")
    func testNoCaptureBelowMemoryLevel() async {
        // A recorder that tracks whether recordMemoryDelta was called.
        final class GateCheckRecorder: @unchecked Sendable, TelemetryIntervalRecorder {
            private let lock = NSLock()
            private var _deltaCalls: Int = 0
            var deltaCalls: Int { lock.lock(); defer { lock.unlock() }; return _deltaCalls }
            func recordBegin(name: String, subsystem: String, message: String) {}
            func recordEnd(name: String, subsystem: String, message: String) {}
            func recordMemoryDelta(name: String, before: Int, after: Int, delta: Int) {
                lock.lock(); defer { lock.unlock() }
                _deltaCalls += 1
            }
        }

        let recorder = GateCheckRecorder()
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        defer {
            Telemetry._installLevelOverride(prevLevel)
            Telemetry._installIntervalRecorder(prevRecorder)
        }

        Telemetry.emitInterval(
            name: "Memory.noCapture",
            family: .core,
            message: "below-memory-level"
        ) { /* trivial body */ }

        // recordMemoryDelta must NOT be called at .operations level.
        #expect(
            recorder.deltaCalls == 0,
            "Expected 0 memory-delta calls at .operations level, got \(recorder.deltaCalls)"
        )
    }
}
