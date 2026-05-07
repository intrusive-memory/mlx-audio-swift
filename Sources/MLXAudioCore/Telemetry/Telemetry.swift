import Foundation
import os

/// Top-level namespace for the MLXAudio telemetry surface.
///
/// Exposes a leveled severity model (`Telemetry.Level`) and the public
/// snapshot/reset API used for in-process leak detection. The active
/// `level` is resolved once-per-process from the `MLXAUDIO_TELEMETRY`
/// environment variable and clamped to the compile-time `ceiling` (which
/// is `.verbose` under `MLXAUDIO_TELEMETRY_FULL` and `.lifecycle`
/// otherwise).
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

    /// Compile-time ceiling. `.lifecycle` in release builds, `.verbose`
    /// when `MLXAUDIO_TELEMETRY_FULL` is defined (debug + tests).
    public static var ceiling: Level {
        #if MLXAUDIO_TELEMETRY_FULL
        return .verbose
        #else
        return .lifecycle
        #endif
    }

    /// Currently active telemetry level. Resolved at first access from
    /// `MLXAUDIO_TELEMETRY` (case-insensitive), defaulting to `.lifecycle`
    /// when the variable is unset or unparseable, then clamped to
    /// `ceiling`. If the requested level exceeded the ceiling, a single
    /// warning is emitted (once per process) on the
    /// `MLXAudio.Telemetry` logger.
    ///
    /// The resolved value is cached on first access; subsequent reads
    /// are O(1) and safe for hot-path use.
    public static var level: Level {
        ResolvedLevel.shared.level
    }

    // MARK: - Public snapshot / reset API (S4)

    /// Snapshot of live object counts and MLX memory state.
    ///
    /// Forwards to the actor-backed `CounterStore.shared`. Reads
    /// `MLX.Memory.activeMemory` and bumps `mlxPeakBytes` to the
    /// process-lifetime high-water mark before returning. Safe to call
    /// from any isolation context.
    public static func snapshot() async -> TelemetrySnapshot {
        await CounterStore.shared.snapshot()
    }

    /// Zero live-object counts and per-op deltas. **Preserves**
    /// `mlxPeakBytes` per requirements §9 — the peak is process-lifetime
    /// monotonic across resets so leak-detection tests can still observe
    /// the worst-case footprint after iterating.
    public static func resetCounters() async {
        await CounterStore.shared.reset()
    }

    // MARK: - Public lifecycle hook (S4 + S6 — used by WU-2)

    // trackLifecycle uses a detached fire-and-forget Task so init / deinit do not block on the actor.
    /// Public lifecycle helper used by WU-2's instrumented
    /// `init` / `deinit` call sites across all modules
    /// (`MLXAudioCore`, `MLXAudioTTS`, `MLXAudioSTT`, `MLXAudioCodecs`).
    ///
    /// Originally declared `internal` in S4; promoted to `public` in S6
    /// when cross-module model classes (`LlamaTTSModel`, `GLMASRModel`, etc.)
    /// needed direct access from their sibling target's `init` / `deinit`.
    ///
    /// **Fire-and-forget contract**: this function spawns a detached
    /// `Task` that calls `CounterStore.shared.increment(className:)` and
    /// returns synchronously. The caller does **not** await the
    /// increment. Pair this with a `trackLifecycleEnd(className:)` call
    /// in `deinit`.
    ///
    /// The `instance` parameter is captured only by reference identity —
    /// we do not retain it. It exists to make future per-instance
    /// signpost IDs trivial to add (S5+) without changing the call
    /// signature.
    ///
    /// No-op when `Telemetry.level == .off` — gated cheaply on the
    /// caller side too via the early-return inside `CounterStore.increment`.
    public static func trackLifecycle(_ instance: AnyObject, className: String) {
        _ = instance // capture-by-reference only; no retention
        guard level != .off else { return }
        Task.detached(priority: .background) {
            await CounterStore.shared.increment(className: className)
        }
    }

    // trackLifecycleEnd uses a detached fire-and-forget Task so deinit does not block on the actor.
    /// Public lifecycle helper paired with `trackLifecycle(_:className:)`.
    ///
    /// Originally declared `internal` in S4; promoted to `public` in S6
    /// alongside `trackLifecycle(_:className:)`.
    ///
    /// **Fire-and-forget contract**: this function spawns a detached
    /// `Task` that calls `CounterStore.shared.decrement(className:)` and
    /// returns synchronously. Call this from `deinit`.
    ///
    /// `deinit` cannot capture `self` for use after deallocation, so this
    /// function takes only the `className` — no `AnyObject`. The class
    /// label is the link between `trackLifecycle` and `trackLifecycleEnd`.
    ///
    /// No-op when `Telemetry.level == .off`.
    public static func trackLifecycleEnd(className: String) {
        guard level != .off else { return }
        Task.detached(priority: .background) {
            await CounterStore.shared.decrement(className: className)
        }
    }

    // MARK: - Internal: resolution & testability hooks

    /// Pure resolver used by both the cached `Telemetry.level` accessor
    /// and the unit tests in `TelemetryConfigTests`. Does NOT touch the
    /// cached singleton so tests can exercise every parse path
    /// deterministically.
    ///
    /// - Parameters:
    ///   - rawValue: Raw env var contents (`nil` if unset).
    ///   - ceiling: Compile-time ceiling to clamp to.
    ///   - warn: Closure invoked exactly once if the requested level
    ///     exceeded the ceiling. Pure resolver does not deduplicate
    ///     across calls — callers are responsible for one-shot semantics.
    /// - Returns: Resolved level (clamped to `ceiling`).
    static func resolveLevel(
        rawValue: String?,
        ceiling: Level,
        warn: (Level) -> Void
    ) -> Level {
        let requested = parseLevel(rawValue) ?? .lifecycle
        if requested > ceiling {
            warn(requested)
            return ceiling
        }
        return requested
    }

    /// Parse a raw env-var string into a `Level`. Case-insensitive.
    /// Returns `nil` when the input is `nil`, empty, or not one of the
    /// known names.
    static func parseLevel(_ raw: String?) -> Level? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "off":        return .off
        case "lifecycle":  return .lifecycle
        case "operations": return .operations
        case "memory":     return .memory
        case "verbose":    return .verbose
        default:           return nil
        }
    }

    // MARK: - Cached singleton

    /// Process-wide cache of the resolved level. Swift's static `let`
    /// initialization is thread-safe and runs at most once, which gives
    /// us the required "warn at most once per process" semantic for
    /// free.
    private struct ResolvedLevel {
        let level: Level

        static let shared = ResolvedLevel(
            env: ProcessInfo.processInfo.environment,
            ceiling: Telemetry.ceiling
        )

        init(env: [String: String], ceiling: Level) {
            self.level = Telemetry.resolveLevel(
                rawValue: env["MLXAUDIO_TELEMETRY"],
                ceiling: ceiling,
                warn: { requested in
                    Telemetry.logClampWarning(requested: requested, ceiling: ceiling)
                }
            )
        }
    }

    // MARK: - One-shot logger

    /// Dedicated logger for telemetry-internal warnings. Subsystem
    /// `"MLXAudio.Telemetry"` matches Section 4 of the requirements doc.
    /// The full per-subsystem logger map (S3) lands later under
    /// `MLXAudioLogging`; we only declare what S2 needs.
    static let warningLogger = Logger(
        subsystem: "MLXAudio.Telemetry",
        category: "telemetry"
    )

    /// Emit the clamp-to-ceiling warning. Called from the cached
    /// resolver; firing happens at most once per process because the
    /// `ResolvedLevel.shared` initializer runs at most once.
    static func logClampWarning(requested: Level, ceiling: Level) {
        warningLogger.warning(
            """
            MLXAUDIO_TELEMETRY requested level \(String(describing: requested), privacy: .public) \
            exceeds compile-time ceiling \(String(describing: ceiling), privacy: .public); \
            clamping to \(String(describing: ceiling), privacy: .public). \
            Rebuild with MLXAUDIO_TELEMETRY_FULL to enable higher levels.
            """
        )
    }
}

