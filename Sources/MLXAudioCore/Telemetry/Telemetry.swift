import Foundation

/// Top-level namespace for the MLXAudio telemetry surface.
///
/// Exposes a leveled severity model (`Telemetry.Level`) and the public
/// snapshot/reset API used for in-process leak detection. The real
/// resolution of `level` and `ceiling` from the `MLXAUDIO_TELEMETRY` env
/// var and the `MLXAUDIO_TELEMETRY_FULL` compile flag lands in Sortie 2;
/// this file declares only the types and stub accessors.
public enum Telemetry {

    /// Telemetry severity level. Levels are monotonic — each level
    /// includes everything below it.
    ///
    /// - `off`: Nothing emitted.
    /// - `lifecycle`: Init/deinit signposts on long-lived objects (default).
    /// - `operations`: + Interval signposts around `loadWeights`,
    ///   `encode`, `decode`, `generate`, model resolution / download.
    /// - `memory`: + MLX memory snapshots before/after each operation.
    /// - `verbose`: + Per-token / per-decode-step signposts.
    public enum Level: Int, Comparable, Sendable {
        case off = 0
        case lifecycle = 1
        case operations = 2
        case memory = 3
        case verbose = 4

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Currently active level. Resolved at first access from
    /// `MLXAUDIO_TELEMETRY` env var, clamped to the compile-time ceiling.
    ///
    /// - Note: Sortie 1 stub — returns `.lifecycle` placeholder. Real
    ///   env-var resolution lands in Sortie 2.
    public static var level: Level {
        .lifecycle
    }

    /// Compile-time ceiling. `.lifecycle` in release builds, `.verbose`
    /// when `MLXAUDIO_TELEMETRY_FULL` is defined.
    ///
    /// - Note: Sortie 1 stub — returns `.lifecycle` placeholder. Real
    ///   `#if MLXAUDIO_TELEMETRY_FULL` gating lands in Sortie 2.
    public static var ceiling: Level {
        .lifecycle
    }
}
