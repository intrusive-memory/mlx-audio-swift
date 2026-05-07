import Foundation
import MLX
import os

/// Test-only protocol for capturing operation-interval signposts.
///
/// Production code emits operation intervals (Level 2 = `.operations`) via
/// `Telemetry.emitInterval(...)` / `Telemetry.emitIntervalAsync(...)`. Those
/// helpers always call through to the requested `OSSignposter` so Instruments
/// traces are emitted as usual; in addition, when a `TelemetryIntervalRecorder`
/// is installed via `Telemetry._installIntervalRecorder(_:)`, every begin/end
/// pair is also forwarded to the recorder.
///
/// Tests use this seam to verify "exactly one begin/end pair on subsystem X"
/// without depending on out-of-process signpost capture (Instruments / xctrace),
/// and without depending on `MLXAUDIO_TELEMETRY` env-var resolution timing —
/// per Open Question Q4's resolution in `EXECUTION_PLAN.md`, the recorder is
/// the source of truth for the test, NOT live env-var resolution.
///
/// Conformance is internal to MLXAudioCore + the test target (which uses
/// `@testable import MLXAudioCore`). Host apps must not adopt this protocol —
/// the entire seam is gated under `MLXAUDIO_TELEMETRY_FULL`, so it disappears
/// in release builds.
#if MLXAUDIO_TELEMETRY_FULL
internal protocol TelemetryIntervalRecorder: AnyObject, Sendable {
    func recordBegin(name: String, subsystem: String, message: String)
    func recordEnd(name: String, subsystem: String, message: String)
    /// Called synchronously in the `defer` block when `Telemetry.level >= .memory`,
    /// BEFORE the fire-and-forget Task forwards the delta to `CounterStore`.
    /// Default implementation is a no-op so existing recorders need not change.
    func recordMemoryDelta(name: String, before: Int, after: Int, delta: Int)
}

extension TelemetryIntervalRecorder {
    func recordMemoryDelta(name: String, before: Int, after: Int, delta: Int) {}
}
#endif

extension Telemetry {

    #if MLXAUDIO_TELEMETRY_FULL
    /// Test-only injection point. Production code reads this through the
    /// `emitInterval` helpers; only test code installs / uninstalls it.
    /// Marked `nonisolated(unsafe)` because it is only mutated from the
    /// suite-serialized test setup/teardown path; production reads are
    /// idempotent nil-checks.
    nonisolated(unsafe) internal static var _intervalRecorder: TelemetryIntervalRecorder?

    /// Install a recorder. Returns the previous recorder so tests can
    /// restore on teardown.
    @discardableResult
    internal static func _installIntervalRecorder(
        _ recorder: TelemetryIntervalRecorder?
    ) -> TelemetryIntervalRecorder? {
        let previous = _intervalRecorder
        _intervalRecorder = recorder
        return previous
    }
    #endif

    // MARK: - Public emitInterval helpers (used by production call sites)

    /// Synchronous operation-interval helper used by every Level-2
    /// (`.operations`) instrumented call site.
    ///
    /// The helper itself is **always public and always compiled in** — the
    /// gating MUST happen at the call site:
    ///
    /// ```swift
    /// #if MLXAUDIO_TELEMETRY_FULL
    /// if Telemetry.level >= .operations {
    ///     return try Telemetry.emitInterval(
    ///         name: "Qwen3TTS.loadWeights",
    ///         signposter: MLXAudioLogging.qwen3TTSSignposter,
    ///         subsystem: "MLXAudio.qwen3TTS",
    ///         message: "talker"
    ///     ) {
    ///         try model.update(parameters: ..., verify: ...)
    ///     }
    /// }
    /// #endif
    /// try model.update(parameters: ..., verify: ...)
    /// ```
    ///
    /// The two-layer gate (`#if MLXAUDIO_TELEMETRY_FULL` + `if level >= .operations`)
    /// is the contract from `docs/TELEMETRY_REQUIREMENTS.md` Section 4 — the
    /// release ceiling is `.lifecycle`, so the entire `if` block strips out
    /// in release.
    ///
    /// When called from a test path with `Telemetry._intervalRecorder`
    /// installed, the recorder also receives a paired begin/end notification
    /// keyed by `name` + `subsystem` + `message`.
    public static func emitInterval<T>(
        name: StaticString,
        signposter: OSSignposter,
        subsystem: String,
        message: String = "",
        body: () throws -> T
    ) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id, "\(message)")
        let nameString = "\(name)"
        #if MLXAUDIO_TELEMETRY_FULL
        // Capture MLX memory before the body when at .memory level or higher.
        // The read is synchronous and gated so it only fires at level 3+.
        let memBefore: Int = (Telemetry.level >= .memory) ? MLX.Memory.activeMemory : 0
        Telemetry._intervalRecorder?.recordBegin(
            name: nameString,
            subsystem: subsystem,
            message: message
        )
        #endif
        defer {
            signposter.endInterval(name, state)
            #if MLXAUDIO_TELEMETRY_FULL
            Telemetry._intervalRecorder?.recordEnd(
                name: nameString,
                subsystem: subsystem,
                message: message
            )
            // Capture MLX memory after the body, emit before/after/delta as a
            // signpost event so Instruments shows memory metadata on the interval,
            // notify the test recorder (synchronously, no CounterStore race), and
            // forward the delta to CounterStore for `TelemetrySnapshot.perOpDeltas`.
            if Telemetry.level >= .memory {
                let memAfter = MLX.Memory.activeMemory
                let delta = memAfter - memBefore
                signposter.emitEvent(
                    name, id: id,
                    "memory before:\(memBefore) after:\(memAfter) delta:\(delta)"
                )
                Telemetry._intervalRecorder?.recordMemoryDelta(
                    name: nameString, before: memBefore, after: memAfter, delta: delta
                )
                Task.detached(priority: .background) {
                    await CounterStore.shared.recordPerOpDelta(opName: nameString, delta: delta)
                }
            }
            #endif
        }
        return try body()
    }

    /// Async variant of `emitInterval(name:signposter:subsystem:message:body:)`.
    /// `OSSignposter.beginInterval` is synchronous; the begin/end pair is
    /// emitted around the awaited body so Instruments shows the full async
    /// duration including suspension time.
    ///
    /// Memory reads bracket the `await` synchronously: `memBefore` is read
    /// before suspension; `memAfter` is read in the `defer` block after the
    /// awaited body returns (or throws). This correctly accounts for GPU
    /// allocations made inside the async body.
    public static func emitIntervalAsync<T>(
        name: StaticString,
        signposter: OSSignposter,
        subsystem: String,
        message: String = "",
        body: () async throws -> T
    ) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id, "\(message)")
        let nameString = "\(name)"
        #if MLXAUDIO_TELEMETRY_FULL
        // Capture MLX memory before the body when at .memory level or higher.
        // `memBefore` is read synchronously before the first `await` so the
        // baseline is correct even if the body suspends.
        let memBefore: Int = (Telemetry.level >= .memory) ? MLX.Memory.activeMemory : 0
        Telemetry._intervalRecorder?.recordBegin(
            name: nameString,
            subsystem: subsystem,
            message: message
        )
        #endif
        defer {
            signposter.endInterval(name, state)
            #if MLXAUDIO_TELEMETRY_FULL
            Telemetry._intervalRecorder?.recordEnd(
                name: nameString,
                subsystem: subsystem,
                message: message
            )
            // Capture MLX memory after the body, emit before/after/delta as a
            // signpost event so Instruments shows memory metadata on the interval,
            // notify the test recorder (synchronously, no CounterStore race), and
            // forward the delta to CounterStore for `TelemetrySnapshot.perOpDeltas`.
            if Telemetry.level >= .memory {
                let memAfter = MLX.Memory.activeMemory
                let delta = memAfter - memBefore
                signposter.emitEvent(
                    name, id: id,
                    "memory before:\(memBefore) after:\(memAfter) delta:\(delta)"
                )
                Telemetry._intervalRecorder?.recordMemoryDelta(
                    name: nameString, before: memBefore, after: memAfter, delta: delta
                )
                Task.detached(priority: .background) {
                    await CounterStore.shared.recordPerOpDelta(opName: nameString, delta: delta)
                }
            }
            #endif
        }
        return try await body()
    }
}

extension Telemetry {

    // MARK: - Family enum + cross-module signposter dispatch
    //
    // The per-family `OSSignposter` instances in `MLXAudioLogging` are
    // `internal` (per S3, requirements §5: host apps declare their own
    // subsystems, not emit on ours). Sibling targets in this package
    // (`MLXAudioTTS`, `MLXAudioSTT`, `MLXAudioCodecs`) cannot reference
    // those internal symbols across module boundaries, so we expose a
    // `public` family-keyed helper that dispatches to the right
    // signposter without leaking the symbols themselves.

    /// Family identifier used by `Telemetry.emitInterval` /
    /// `emitIntervalAsync` to select the correct per-subsystem
    /// `OSSignposter` without exposing the signposter instances themselves.
    public enum Family: String, Sendable {
        case core
        case modelResolver
        case qwen3TTS
        case llamaTTS
        case sopranoTTS
        case pocketTTS
        case marvisTTS
        case qwen3ASR
        case glmASR
        case codecs

        /// The canonical subsystem identifier for this family. Matches the
        /// Logger / Signposter subsystem string in `MLXAudioLogging` exactly,
        /// so the recorder's `subsystem` parameter is the same string an
        /// Instruments os_signpost track would show.
        public var subsystem: String {
            switch self {
            case .core:           return "MLXAudio.core"
            case .modelResolver:  return "MLXAudio.modelResolver"
            case .qwen3TTS:       return "MLXAudio.qwen3TTS"
            case .llamaTTS:       return "MLXAudio.llamaTTS"
            case .sopranoTTS:     return "MLXAudio.sopranoTTS"
            case .pocketTTS:      return "MLXAudio.pocketTTS"
            case .marvisTTS:      return "MLXAudio.marvisTTS"
            case .qwen3ASR:       return "MLXAudio.qwen3ASR"
            case .glmASR:         return "MLXAudio.glmASR"
            case .codecs:         return "MLXAudio.codecs"
            }
        }

        internal var signposter: OSSignposter {
            switch self {
            case .core:           return MLXAudioLogging.coreSignposter
            case .modelResolver:  return MLXAudioLogging.modelResolverSignposter
            case .qwen3TTS:       return MLXAudioLogging.qwen3TTSSignposter
            case .llamaTTS:       return MLXAudioLogging.llamaTTSSignposter
            case .sopranoTTS:     return MLXAudioLogging.sopranoTTSSignposter
            case .pocketTTS:      return MLXAudioLogging.pocketTTSSignposter
            case .marvisTTS:      return MLXAudioLogging.marvisTTSSignposter
            case .qwen3ASR:       return MLXAudioLogging.qwen3ASRSignposter
            case .glmASR:         return MLXAudioLogging.glmASRSignposter
            case .codecs:         return MLXAudioLogging.codecsSignposter
            }
        }
    }

    /// Family-keyed convenience overload of `emitInterval(name:signposter:subsystem:message:body:)`.
    /// Sibling targets call this overload because the `OSSignposter` symbols
    /// in `MLXAudioLogging` are `internal`.
    public static func emitInterval<T>(
        name: StaticString,
        family: Family,
        message: String = "",
        body: () throws -> T
    ) rethrows -> T {
        try emitInterval(
            name: name,
            signposter: family.signposter,
            subsystem: family.subsystem,
            message: message,
            body: body
        )
    }

    /// Family-keyed async overload.
    public static func emitIntervalAsync<T>(
        name: StaticString,
        family: Family,
        message: String = "",
        body: () async throws -> T
    ) async rethrows -> T {
        try await emitIntervalAsync(
            name: name,
            signposter: family.signposter,
            subsystem: family.subsystem,
            message: message,
            body: body
        )
    }

    // MARK: - Test-only level override (S10 task 4 — resolves Open Q4)

    #if MLXAUDIO_TELEMETRY_FULL
    /// Test-only override for `Telemetry.level`. When non-nil, the static
    /// `Telemetry.level` accessor returns this value instead of the cached
    /// once-per-process resolution.
    ///
    /// Process-level environment variables are typically immutable mid-process
    /// (and `Telemetry.level` is cached on first read), so the env-var route
    /// cannot be exercised by an in-process unit test without spawning a
    /// child process. Tests that need to verify "level resolves correctly
    /// when MLXAUDIO_TELEMETRY=operations" therefore use this seam:
    ///
    /// ```swift
    /// let prev = Telemetry._installLevelOverride(.operations)
    /// defer { Telemetry._installLevelOverride(prev) }
    /// #expect(Telemetry.level == .operations)
    /// ```
    ///
    /// Marked `nonisolated(unsafe)` because tests using this seam serialize
    /// access via `.serialized` `@Suite` annotation.
    nonisolated(unsafe) internal static var _levelOverride: Level?

    /// Install a level override. Returns the previous override so tests can
    /// restore it on teardown. Pass `nil` to clear and fall back to the
    /// cached env-resolved value.
    @discardableResult
    internal static func _installLevelOverride(_ level: Level?) -> Level? {
        let prev = _levelOverride
        _levelOverride = level
        return prev
    }
    #endif
}
