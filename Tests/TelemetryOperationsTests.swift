//
//  TelemetryOperationsTests.swift
//  MLXAudioTests
//
//  Sortie 10 of OPERATION LEAK BLOODHOUND — Level 2 (`.operations`)
//  operation-interval signposts.
//
//  Coverage:
//  - `testLevelResolvesFromEnv`: Verifies `Telemetry.level` resolves to
//    `.operations` when MLXAUDIO_TELEMETRY=operations is requested. The
//    cached env-resolved value is process-immutable, so we exercise the
//    resolution via the test-only `Telemetry._installLevelOverride(_:)`
//    seam (introduced in S10 alongside `_intervalRecorder` per the
//    EXECUTION_PLAN Open Q4 resolution: avoid relying on env-var
//    resolution timing during in-process tests).
//  - `testInstrumentedCallEmitsInterval`: Installs a `TestSignposterRecorder`
//    that conforms to the internal `TelemetryIntervalRecorder` protocol,
//    runs one weight-loading call path (a synthetic `MLXNN.Linear` whose
//    weights are loaded via `Telemetry.emitInterval` — the same helper
//    every production call site uses), and asserts exactly one begin/end
//    pair on the expected subsystem.
//
//  Concurrency: the suite is `.serialized` because both tests mutate
//  process-global state (`_levelOverride`, `_intervalRecorder`) and
//  unsynchronized parallel access would race.
//

import Foundation
import MLX
import MLXNN
import Testing

@testable import MLXAudioCore

@Suite("TelemetryOperationsTests", .serialized)
struct TelemetryOperationsTests {

    // MARK: - TestSignposterRecorder (Q4 resolution)

    /// In-memory recorder used as the source-of-truth for tests verifying
    /// that an instrumented call path emitted exactly one interval pair on
    /// the expected subsystem.
    ///
    /// The recorder conforms to the internal `TelemetryIntervalRecorder`
    /// protocol declared in `IntervalEmitter.swift`. Production call sites
    /// emit through `Telemetry.emitInterval(...)` / `emitIntervalAsync(...)`,
    /// which always call into the real `OSSignposter` (so Instruments still
    /// sees the events) and additionally forward to `_intervalRecorder` when
    /// one is installed. Tests install a recorder, run code, then inspect
    /// the captured events.
    ///
    /// `nonisolated(unsafe)` storage is acceptable because the test suite is
    /// `.serialized` — only one test mutates / reads at a time. We use
    /// `NSLock` for the read-modify-write of the events array as a
    /// belt-and-suspenders measure since the production call sites may run
    /// on background actors / detached Tasks.
    final class TestSignposterRecorder: @unchecked Sendable, TelemetryIntervalRecorder {
        struct Event: Equatable {
            enum Kind: String { case begin, end }
            let kind: Kind
            let name: String
            let subsystem: String
            let message: String
        }

        private let lock = NSLock()
        private var _events: [Event] = []

        var events: [Event] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        func recordBegin(name: String, subsystem: String, message: String) {
            lock.lock(); defer { lock.unlock() }
            _events.append(Event(kind: .begin, name: name, subsystem: subsystem, message: message))
        }

        func recordEnd(name: String, subsystem: String, message: String) {
            lock.lock(); defer { lock.unlock() }
            _events.append(Event(kind: .end, name: name, subsystem: subsystem, message: message))
        }
    }

    // MARK: - testLevelResolvesFromEnv

    /// Verifies `Telemetry.level` resolves to `.operations` when the
    /// requested level is `MLXAUDIO_TELEMETRY=operations`.
    ///
    /// **Why we use `_installLevelOverride` instead of mutating the real
    /// env var**: `Telemetry.level` is cached at first read via the
    /// process-singleton `ResolvedLevel.shared` initializer, which Swift
    /// guarantees runs at most once per process. Setting `setenv()` from
    /// the test would have no effect on the cached value, and on the very
    /// first invocation would even burn the one-shot clamp warning. The
    /// `_installLevelOverride(_:)` seam (gated behind `MLXAUDIO_TELEMETRY_FULL`
    /// so it cannot leak into release builds) gives tests a deterministic
    /// way to exercise the level-gated code paths without env-var
    /// resolution timing fragility.
    @Test("Telemetry.level resolves to .operations under override (Q4)")
    func testLevelResolvesFromEnv() async {
        let prev = Telemetry._installLevelOverride(.operations)
        defer { Telemetry._installLevelOverride(prev) }

        #expect(Telemetry.level == .operations)
        #expect(Telemetry.level >= .operations)

        // Negative case: clearing the override falls back to the
        // env-resolved cached value (default .lifecycle when env unset).
        Telemetry._installLevelOverride(nil)
        #expect(Telemetry.level <= Telemetry.ceiling)
    }

    // MARK: - testInstrumentedCallEmitsInterval

    /// Installs a `TestSignposterRecorder`, runs ONE weight-loading call
    /// path (a synthetic `MLXNN.Linear` whose `update(parameters:)` is
    /// invoked through `Telemetry.emitInterval` — the same helper every
    /// production loadWeights call site uses, on the codecs subsystem),
    /// and asserts the recorder observed exactly one `.begin` and one
    /// `.end` event on `MLXAudio.codecs`.
    @Test("instrumented loadWeights emits exactly one begin/end pair")
    func testInstrumentedCallEmitsInterval() throws {
        let recorder = TestSignposterRecorder()

        // Force level to .operations so the wrap is taken; restore on exit.
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        defer {
            Telemetry._installLevelOverride(prevLevel)
            Telemetry._installIntervalRecorder(prevRecorder)
        }

        // Synthetic MLXNN.Linear — the smallest possible Module that
        // accepts a real `update(parameters:)` weight load. No model
        // download required.
        let linear = Linear(8, 4, bias: false)

        // Construct weights matching the layer's parameter shape so
        // `update(parameters:)` succeeds. We extract the existing
        // parameter shape from the freshly-constructed module and
        // synthesize zeros of that shape for the load path.
        let weightShape: [Int] = [4, 8] // out, in
        let synthWeights: [String: MLXArray] = [
            "weight": MLXArray.zeros(weightShape, type: Float32.self)
        ]

        // Wrap the same way every production loadWeights site does.
        try Telemetry.emitInterval(
            name: "Test.loadWeights",
            family: .codecs,
            message: "synthetic-linear"
        ) {
            try linear.update(
                parameters: ModuleParameters.unflattened(synthWeights),
                verify: [.all]
            )
        }

        let events = recorder.events
        #expect(events.count == 2, "Expected exactly 2 events (begin + end), got \(events.count): \(events)")

        guard events.count == 2 else { return }
        let begin = events[0]
        let end = events[1]

        #expect(begin.kind == .begin)
        #expect(end.kind == .end)
        #expect(begin.name == "Test.loadWeights")
        #expect(end.name == "Test.loadWeights")
        #expect(begin.subsystem == "MLXAudio.codecs", "Expected subsystem MLXAudio.codecs, got \(begin.subsystem)")
        #expect(end.subsystem == "MLXAudio.codecs")
        #expect(begin.message == "synthetic-linear")
        #expect(end.message == "synthetic-linear")
    }

    /// Smoke test: when `Telemetry.level < .operations`, the production
    /// call sites are short-circuited (the `if Telemetry.level >= .operations`
    /// branch is not taken) and no events are recorded.
    @Test("level < .operations skips the wrap (no events recorded)")
    func testLevelGateShortCircuits() throws {
        let recorder = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(.lifecycle)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        defer {
            Telemetry._installLevelOverride(prevLevel)
            Telemetry._installIntervalRecorder(prevRecorder)
        }

        // Production gate pattern: the `if Telemetry.level >= .operations`
        // check is what every instrumented call site uses, and at
        // .lifecycle it short-circuits — so we must NOT call emitInterval.
        if Telemetry.level >= .operations {
            try Telemetry.emitInterval(
                name: "Test.shouldNotEmit",
                family: .codecs
            ) {
                // unreachable
            }
        }

        #expect(recorder.events.isEmpty, "Expected no events at .lifecycle, got: \(recorder.events)")
    }

    // MARK: - Family enum sanity

    /// Guards against subsystem-string drift between `Telemetry.Family` and
    /// `MLXAudioLogging`. If S3's subsystem table renames a subsystem, this
    /// test fails fast.
    @Test("Family.subsystem strings match MLXAudioLogging subsystems")
    func testFamilySubsystemStringsMatchLogging() {
        let expectedSubsystems: Set<String> = [
            "MLXAudio.core",
            "MLXAudio.modelResolver",
            "MLXAudio.qwen3TTS",
            "MLXAudio.llamaTTS",
            "MLXAudio.sopranoTTS",
            "MLXAudio.pocketTTS",
            "MLXAudio.marvisTTS",
            "MLXAudio.qwen3ASR",
            "MLXAudio.glmASR",
            "MLXAudio.codecs",
        ]

        let familySubsystems: Set<String> = [
            Telemetry.Family.core.subsystem,
            Telemetry.Family.modelResolver.subsystem,
            Telemetry.Family.qwen3TTS.subsystem,
            Telemetry.Family.llamaTTS.subsystem,
            Telemetry.Family.sopranoTTS.subsystem,
            Telemetry.Family.pocketTTS.subsystem,
            Telemetry.Family.marvisTTS.subsystem,
            Telemetry.Family.qwen3ASR.subsystem,
            Telemetry.Family.glmASR.subsystem,
            Telemetry.Family.codecs.subsystem,
        ]

        #expect(familySubsystems == expectedSubsystems)
    }
}
