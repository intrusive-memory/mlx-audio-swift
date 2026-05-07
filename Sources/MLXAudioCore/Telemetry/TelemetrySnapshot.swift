import Foundation

/// Point-in-time snapshot of MLXAudio telemetry counters and MLX memory state.
///
/// Returned by `Telemetry.snapshot()` (defined in Sortie 4) for in-process
/// leak detection and per-op memory accounting.
///
/// - `liveCounts`: Currently live object counts, keyed by class label
///   (e.g. `"Qwen3TTS.Model"`).
/// - `mlxActiveBytes`: `MLX.GPU.activeMemory()` at the moment of snapshot.
/// - `mlxPeakBytes`: Process-lifetime high-water mark of MLX active memory.
///   Monotonic — survives `Telemetry.resetCounters()`.
/// - `perOpDeltas`: Cumulative MLX active-memory deltas per operation interval,
///   keyed by the interval name used at the call site (e.g. `"Qwen3TTS.generate"`).
///   Populated only when `Telemetry.level >= .memory`. Zeroed by
///   `Telemetry.resetCounters()` (does NOT reset `mlxPeakBytes`).
///   Additive field — empty dictionary when no memory-level data has been
///   captured yet, preserving backward compatibility.
/// - `timestamp`: When the snapshot was taken.
public struct TelemetrySnapshot: Sendable {
    public let liveCounts: [String: Int]
    public let mlxActiveBytes: Int
    public let mlxPeakBytes: Int
    /// Cumulative per-op MLX memory deltas. Keyed by the interval name
    /// (identical to the `name` argument passed to `Telemetry.emitInterval` /
    /// `emitIntervalAsync`, e.g. `"Qwen3TTS.generate"`, `"SNAC.encode"`).
    /// Only populated at `Telemetry.level >= .memory`. Zeroed by `resetCounters()`.
    public let perOpDeltas: [String: Int]
    public let timestamp: Date

    /// Primary initializer. The `perOpDeltas` parameter defaults to `[:]` so
    /// existing call sites (CounterStore, tests) that do not yet pass it remain
    /// source-compatible (additive, non-breaking change).
    public init(
        liveCounts: [String: Int],
        mlxActiveBytes: Int,
        mlxPeakBytes: Int,
        perOpDeltas: [String: Int] = [:],
        timestamp: Date
    ) {
        self.liveCounts = liveCounts
        self.mlxActiveBytes = mlxActiveBytes
        self.mlxPeakBytes = mlxPeakBytes
        self.perOpDeltas = perOpDeltas
        self.timestamp = timestamp
    }
}
