import Foundation
import MLX

/// Actor-backed counter store for the MLXAudio telemetry surface.
///
/// `CounterStore.shared` owns three pieces of state:
///
/// - `liveCounts`: Per-class-label live object counts. Mutated by paired
///   `increment` / `decrement` calls fired from instrumented `init` /
///   `deinit` of long-lived objects (models, KV caches, tokenizers,
///   engines).
/// - `perOpDeltas`: Placeholder dictionary for WU-4 per-operation memory
///   deltas. Empty in WU-1; surfaced for forward-compatibility so future
///   sorties can accumulate without changing the public API.
/// - `mlxPeakBytes`: Process-lifetime high-water mark of MLX active
///   memory. **Monotonic** — survives `reset()` so test iterations can
///   still observe the worst-case footprint (requirements §9).
///
/// Updates short-circuit when `Telemetry.level == .off` so the actor is
/// a no-op on a non-default-but-equally-fast path for embedded /
/// sensitive deployments.
internal actor CounterStore {

    /// Process-wide singleton. The actor isolation domain is global and
    /// shared by every instrumented call site.
    static let shared = CounterStore()

    private var liveCounts: [String: Int] = [:]
    private var perOpDeltas: [String: Int] = [:]
    private var mlxPeakBytes: Int = 0

    /// Designated initializer is private — there is exactly one
    /// `CounterStore` per process (the `shared` singleton).
    private init() {}

    // MARK: - Mutators

    /// Increment the live-count for `className`.
    ///
    /// No-op when `Telemetry.level == .off`. Counts are stored as `Int`
    /// (signed) so a decrement before an increment will not crash; tests
    /// assert balance, not non-negativity.
    func increment(className: String) {
        guard Telemetry.level != .off else { return }
        liveCounts[className, default: 0] += 1
    }

    /// Decrement the live-count for `className`.
    ///
    /// No-op when `Telemetry.level == .off`. May produce negative values
    /// if increment/decrement are unbalanced — that's a callsite bug and
    /// surfaces in tests; we deliberately do not clamp at 0 so the bug
    /// is observable.
    func decrement(className: String) {
        guard Telemetry.level != .off else { return }
        liveCounts[className, default: 0] -= 1
    }

    // MARK: - Per-op delta accumulation (WU-4 / S12)

    /// Accumulate an MLX active-memory delta for the named operation interval.
    ///
    /// Called by `Telemetry.emitInterval` / `emitIntervalAsync` when
    /// `Telemetry.level >= .memory`. The delta is the difference
    /// `(MLX.Memory.activeMemory after closure) - (MLX.Memory.activeMemory before closure)`.
    /// Positive values indicate memory growth; negative values indicate reclamation.
    /// Values accumulate additively across calls so a leak shows as steady positive
    /// growth over repeated calls. Zeroed by `reset()`.
    ///
    /// No-op when `Telemetry.level < .memory` or `.off` — the call sites gate
    /// this via `Telemetry.level >= .memory` before calling.
    func recordPerOpDelta(opName: String, delta: Int) {
        perOpDeltas[opName, default: 0] += delta
    }

    // MARK: - Queries

    /// Capture a `TelemetrySnapshot` reflecting current state.
    ///
    /// Always reads `MLX.Memory.activeMemory` for `mlxActiveBytes` and
    /// updates the high-water mark `mlxPeakBytes` to
    /// `max(mlxPeakBytes, mlxActiveBytes)` before returning. We maintain
    /// the peak ourselves rather than depending on MLX's own peak API,
    /// per the resolved Q1 in EXECUTION_PLAN.md.
    func snapshot() -> TelemetrySnapshot {
        let active = MLX.Memory.activeMemory
        if active > mlxPeakBytes {
            mlxPeakBytes = active
        }
        return TelemetrySnapshot(
            liveCounts: liveCounts,
            mlxActiveBytes: active,
            mlxPeakBytes: mlxPeakBytes,
            perOpDeltas: perOpDeltas,
            timestamp: Date()
        )
    }

    /// Zero `liveCounts` and `perOpDeltas`. Preserves `mlxPeakBytes`
    /// — the peak is process-lifetime monotonic per requirements §9.
    func reset() {
        liveCounts.removeAll(keepingCapacity: true)
        perOpDeltas.removeAll(keepingCapacity: true)
        // mlxPeakBytes intentionally NOT touched.
    }

    // MARK: - Test-only introspection

    /// Force `mlxPeakBytes` to a specific value. Test-only — used by
    /// `TelemetryCounterStoreTests.testResetPreservesPeak` to seed a
    /// known peak before exercising `reset()` without depending on real
    /// MLX allocations.
    func _setPeakForTesting(_ value: Int) {
        mlxPeakBytes = value
    }

    /// Read raw `liveCounts` without going through `snapshot()` — avoids
    /// the MLX memory read in tests that only care about counter balance.
    func _liveCountsForTesting() -> [String: Int] {
        liveCounts
    }

    /// Read raw `perOpDeltas` without going through `snapshot()` — used
    /// by `TelemetryMemoryTests` to inspect accumulated deltas without
    /// triggering an MLX memory read.
    func _perOpDeltasForTesting() -> [String: Int] {
        perOpDeltas
    }

    /// Zero only `perOpDeltas` without touching `liveCounts` or
    /// `mlxPeakBytes`. Used by `TelemetryMemoryTests` so that delta tests
    /// can start with a clean per-op slate without racing against
    /// `TelemetryCounterStoreTests`'s lifecycle-counter assertions.
    func _resetPerOpDeltasForTesting() {
        perOpDeltas.removeAll(keepingCapacity: true)
    }

    /// Atomically apply a batch of per-op deltas (opName → delta) and
    /// return the resulting values for each key after applying the batch.
    ///
    /// Used by `TelemetryMemoryTests` to accumulate multiple deltas in a
    /// single actor message so no concurrent reset can interleave between
    /// individual `recordPerOpDelta` calls during the test.
    @discardableResult
    func _batchRecordAndReadForTesting(_ entries: [(opName: String, delta: Int)]) -> [String: Int] {
        for entry in entries {
            perOpDeltas[entry.opName, default: 0] += entry.delta
        }
        return perOpDeltas
    }

    /// Atomically clear `perOpDeltas`, apply a batch of deltas, and return
    /// the resulting per-op dict. Combines `_resetPerOpDeltasForTesting` and
    /// `_batchRecordAndReadForTesting` into one actor turn so no concurrent
    /// operation can interleave between the clear and the additions.
    @discardableResult
    func _clearAndBatchRecordForTesting(_ entries: [(opName: String, delta: Int)]) -> [String: Int] {
        perOpDeltas.removeAll(keepingCapacity: true)
        for entry in entries {
            perOpDeltas[entry.opName, default: 0] += entry.delta
        }
        return perOpDeltas
    }
}
