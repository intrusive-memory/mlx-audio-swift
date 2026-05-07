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
/// - `timestamp`: When the snapshot was taken.
public struct TelemetrySnapshot: Sendable {
    public let liveCounts: [String: Int]
    public let mlxActiveBytes: Int
    public let mlxPeakBytes: Int
    public let timestamp: Date

    public init(
        liveCounts: [String: Int],
        mlxActiveBytes: Int,
        mlxPeakBytes: Int,
        timestamp: Date
    ) {
        self.liveCounts = liveCounts
        self.mlxActiveBytes = mlxActiveBytes
        self.mlxPeakBytes = mlxPeakBytes
        self.timestamp = timestamp
    }
}
