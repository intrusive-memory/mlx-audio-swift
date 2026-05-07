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
}
