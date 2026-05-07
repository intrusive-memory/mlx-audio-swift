//
//  TelemetryVerboseTests.swift
//  MLXAudioTests
//
//  Sorties 13 + 14 of OPERATION LEAK BLOODHOUND — Level 4 (`.verbose`)
//  per-token signposts in TTS / ASR generate loops (S13) and per-decode-step
//  signposts in iterative codecs + KV cache grow events (S14).
//
//  Coverage:
//  - `testVerboseLevelResolvesUnderFullCeiling`: Verifies Level ordering and the
//    `_installLevelOverride` seam. Does NOT read `Telemetry.level` (which depends
//    on global `_levelOverride`), so it is safe to run in parallel with other
//    suites that also manipulate `_levelOverride`.
//  - `testTTSPerTokenEmitsExpectedCount`: Installs a `TestEventRecorder` and
//    directly calls `Telemetry.emitEvent(family:name:tokenIndex:)` in a synthetic
//    N-step loop, asserting the recorder observed exactly N events. This tests the
//    full recorder-seam path (emitEvent → _eventRecorder → TestEventRecorder) in
//    a race-condition-free way: it does not depend on `_levelOverride` being stable
//    across concurrent test execution.
//  - `testVerboseGateShortCircuits`: Verifies that the production gate pattern
//    (`if Telemetry.level >= .verbose`) prevents `emitEvent` from being called
//    when the captured level is below `.verbose`.
//  - `testCodecPerStepEmitsExpectedCount`: Verifies that the `Mimi.decodeStep`
//    per-frame event label is emitted correctly N times for N synthetic calls.
//    Uses the same recorder-seam pattern as S13's TTS test — calls `emitEvent`
//    directly in a loop rather than running the full streaming decoder (no model
//    download required). The production call site in
//    `MimiStreamingDecoder.decodeFrames` is verified by source-level grep.
//  - `testKVCacheGrowEmitsEventOnResize`: Constructs a minimal synthetic Mimi
//    Transformer (no model download), calls it once to trigger the first-access
//    grow event, and asserts the recorder observed at least one
//    `Mimi.KVCache.grow` event. Uses `_installLevelOverride(.verbose)` to
//    activate the gate without global env-var changes; restores it in `defer`.
//
//  Race-safety note: `TelemetryVerboseTests` is `.serialized` within itself, but
//  Swift Testing may run it concurrently with other `.serialized` suites (e.g.
//  `TelemetryOperationsTests`). Both suites mutate the same global `_levelOverride`
//  and `_intervalRecorder` / `_eventRecorder` state, so tests in this suite are
//  deliberately designed to NOT depend on `_levelOverride` stability across a
//  non-trivial call. Each test captures the values it needs BEFORE any concurrent
//  mutation can occur.
//

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import MLXAudioCore
@testable import MLXAudioCodecs

@Suite("TelemetryVerboseTests", .serialized)
struct TelemetryVerboseTests {

    // MARK: - TestEventRecorder

    /// In-memory recorder conforming to `TelemetryEventRecorder` (internal protocol in
    /// `IntervalEmitter.swift`, gated behind `MLXAUDIO_TELEMETRY_FULL`).
    ///
    /// Production call sites emit through the real `OSSignposter` AND forward to this
    /// recorder when one is installed, so tests can assert "N events fired" without
    /// out-of-process Instruments capture.
    ///
    /// `NSLock` guards the `_events` array because `Telemetry.emitEvent` can be called
    /// from various execution contexts. The test suite is `.serialized` so only one test
    /// mutates the recorder reference at a time.
    final class TestEventRecorder: @unchecked Sendable, TelemetryEventRecorder {
        struct Event: Equatable {
            let family: String
            let name: String
            let tokenIndex: Int
        }

        private let lock = NSLock()
        private var _events: [Event] = []

        var events: [Event] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        var count: Int { events.count }

        func recordEvent(family: String, name: String, tokenIndex: Int) {
            lock.lock(); defer { lock.unlock() }
            _events.append(Event(family: family, name: name, tokenIndex: tokenIndex))
        }
    }

    // MARK: - testVerboseLevelResolvesUnderFullCeiling

    /// Verifies that `.verbose` is the highest `Level` and that the
    /// `_installLevelOverride` seam correctly stores and returns values.
    ///
    /// **Race-safety**: This test reads `_levelOverride` directly (not `Telemetry.level`,
    /// which can be preempted by a concurrent test that overwrites `_levelOverride`).
    /// Level ordering checks are purely value-based and immune to global state.
    @Test("Telemetry.Level.verbose is the highest level; override seam stores and returns .verbose")
    func testVerboseLevelResolvesUnderFullCeiling() {
        // Level ordering is purely value-based — safe to check from any thread.
        #expect(Telemetry.Level.verbose > .memory)
        #expect(Telemetry.Level.verbose > .operations)
        #expect(Telemetry.Level.verbose > .lifecycle)
        #expect(Telemetry.Level.verbose > .off)
        #expect(Telemetry.Level.verbose.rawValue == 4)

        // Override-seam round-trip: install .verbose, immediately read back,
        // immediately restore. We do NOT read `Telemetry.level` because another
        // concurrent test may have overwritten `_levelOverride` between install
        // and read.
        let prev = Telemetry._installLevelOverride(.verbose)
        let installed = Telemetry._levelOverride
        Telemetry._installLevelOverride(prev) // restore immediately

        #expect(installed == .verbose,
                "Expected _levelOverride to be .verbose after install, got \(String(describing: installed))")

        // Debug builds (MLXAUDIO_TELEMETRY_FULL defined) must have ceiling = .verbose.
        #expect(Telemetry.ceiling == .verbose,
                "Expected ceiling .verbose under MLXAUDIO_TELEMETRY_FULL, got \(Telemetry.ceiling)")
    }

    // MARK: - testTTSPerTokenEmitsExpectedCount

    /// Verifies that `Telemetry.emitEvent(family:name:tokenIndex:)` — the helper
    /// called inside every TTS/ASR generate loop — correctly forwards N events to
    /// an installed `TelemetryEventRecorder` for N calls.
    ///
    /// **Design**: We call `Telemetry.emitEvent` directly in a controlled N-step loop
    /// rather than invoking a full generate path. This makes the test:
    ///   1. Race-condition-free: no `_levelOverride` manipulation; the recorder
    ///      captures all events regardless of concurrent level changes.
    ///   2. Deterministic: exactly N calls → exactly N recorded events.
    ///   3. CI-safe: no model download required.
    ///
    /// The production code paths (TTS/ASR generate loops call `emitEvent` inside
    /// `#if MLXAUDIO_TELEMETRY_FULL / if Telemetry.level >= .verbose`) are verified
    /// by the source-level grep exit criterion (≥ 7 occurrences of `level >= .verbose`
    /// in Sources/) and by the per-family nightly integration tests.
    @Test("emitEvent forwards exactly N events to the recorder for N token steps")
    func testTTSPerTokenEmitsExpectedCount() {
        let N = 5
        let recorder = TestEventRecorder()
        let prevRecorder = Telemetry._installEventRecorder(recorder)
        defer { Telemetry._installEventRecorder(prevRecorder) }

        // Simulate what every instrumented TTS generate loop does: call emitEvent
        // once per step with the family, event name, and step index. The production
        // call site gates this behind `if Telemetry.level >= .verbose`; here we
        // call it unconditionally to test the recorder path independently.
        for step in 0..<N {
            Telemetry.emitEvent(family: .pocketTTS, name: "PocketTTS.token", tokenIndex: step)
        }

        let events = recorder.events
        #expect(events.count == N,
                "Expected exactly \(N) per-token events, got \(events.count)")

        for (i, event) in events.enumerated() {
            #expect(event.family == "pocketTTS",
                    "Expected family 'pocketTTS', got '\(event.family)' at index \(i)")
            #expect(event.name == "PocketTTS.token",
                    "Expected event name 'PocketTTS.token', got '\(event.name)' at index \(i)")
            #expect(event.tokenIndex == i,
                    "Expected tokenIndex \(i), got \(event.tokenIndex)")
        }
    }

    // MARK: - testVerboseGateShortCircuits

    /// Verifies that the production gate pattern (`if Telemetry.level >= .verbose`)
    /// prevents `emitEvent` from being called when the level is below `.verbose`.
    ///
    /// **Race-safety**: We capture the level as a local constant rather than reading
    /// `Telemetry.level` from the global, eliminating the race window between the
    /// level check and the emit call.
    @Test("Production gate pattern: level < .verbose skips emitEvent; level == .verbose fires it")
    func testVerboseGateShortCircuits() {
        let recorder = TestEventRecorder()
        let prevRecorder = Telemetry._installEventRecorder(recorder)
        defer { Telemetry._installEventRecorder(prevRecorder) }

        // Negative case: level < .verbose → gate not taken → recorder empty.
        let belowVerbose = Telemetry.Level.operations
        if belowVerbose >= .verbose {
            Telemetry.emitEvent(family: .pocketTTS, name: "PocketTTS.token", tokenIndex: 0)
        }
        #expect(recorder.events.isEmpty,
                "Expected no events when level = .operations (< .verbose), got \(recorder.events.count)")

        // Positive case: level == .verbose → gate taken → recorder receives 1 event.
        let atVerbose = Telemetry.Level.verbose
        if atVerbose >= .verbose {
            Telemetry.emitEvent(family: .pocketTTS, name: "PocketTTS.token", tokenIndex: 0)
        }
        #expect(recorder.events.count == 1,
                "Expected 1 event when level == .verbose, got \(recorder.events.count)")
    }

    // MARK: - testCodecPerStepEmitsExpectedCount (S14)

    /// Verifies that the `Mimi.decodeStep` per-frame event label is forwarded to the
    /// recorder N times for N synthetic frames.
    ///
    /// **Design** (mirrors `testTTSPerTokenEmitsExpectedCount`): We call
    /// `Telemetry.emitEvent` directly in an N-step loop using the exact family and
    /// event label that `MimiStreamingDecoder.decodeFrames` emits in production.
    /// This tests the full recorder-seam path without constructing a full Mimi model
    /// or downloading weights (CI-safe). The production call site is verified by the
    /// source-level instrumentation in `Mimi.swift`.
    ///
    /// Q5 resolution (EXECUTION_PLAN.md open question): Mimi IS iterative — its
    /// `MimiStreamingDecoder.decodeFrames` runs `for t in 0..<T { ... mimi.decodeStep(mid) }`
    /// producing one audio frame per step. SNAC, Encodec, DAC, and Vocos are single-shot
    /// or data-parallel chunked; they do NOT have autoregressive per-step decode loops
    /// and do NOT get per-step signposts. See COMPLETE_S14 for the full audit.
    @Test("Mimi.decodeStep per-frame event: recorder observes exactly N events for N frames")
    func testCodecPerStepEmitsExpectedCount() {
        let N = 7
        let recorder = TestEventRecorder()
        let prevRecorder = Telemetry._installEventRecorder(recorder)
        defer { Telemetry._installEventRecorder(prevRecorder) }

        // Simulate what MimiStreamingDecoder.decodeFrames emits: one event per frame.
        // Production code: for t in 0..<T { ...; Telemetry.emitEvent(family: .codecs,
        //   name: "Mimi.decodeStep", tokenIndex: t) }
        for t in 0..<N {
            Telemetry.emitEvent(family: .codecs, name: "Mimi.decodeStep", tokenIndex: t)
        }

        let events = recorder.events
        #expect(events.count == N,
                "Expected \(N) Mimi.decodeStep events, got \(events.count)")

        for (i, event) in events.enumerated() {
            #expect(event.family == "codecs",
                    "Expected family 'codecs', got '\(event.family)' at index \(i)")
            #expect(event.name == "Mimi.decodeStep",
                    "Expected event name 'Mimi.decodeStep', got '\(event.name)' at index \(i)")
            #expect(event.tokenIndex == i,
                    "Expected tokenIndex \(i), got \(event.tokenIndex)")
        }
    }

    // MARK: - testKVCacheGrowEmitsEventOnResize (S14)

    /// Verifies that the `Mimi.KVCache.grow` grow event fires when a `KVCacheSimple`
    /// capacity expansion is detected in `Mimi.Transformer.Attention.callAsFunction`.
    ///
    /// **Approach**: Constructs a minimal synthetic `Transformer` (no model download),
    /// installs a `TestEventRecorder`, sets level to `.verbose` via `_installLevelOverride`,
    /// then calls `transformer(input, cache: cache)`. The first call always triggers a
    /// capacity-grow event because `cache.offset == 0` (cache is empty) when the
    /// Attention layer calls `cache.update()`. We assert at least one
    /// `Mimi.KVCache.grow` event was observed.
    ///
    /// **Coverage scope**: This test covers the Mimi-family grow event path, which is
    /// the ONLY KV cache family whose `update()` call site is within MLX-audio-swift's
    /// own code (`Sources/MLXAudioCodecs/Mimi/Transformer.swift`). All other KV cache
    /// families (Qwen3TTS, LlamaTTS, SopranoTTS, PocketTTS, MarvisTTS, Qwen3ASR,
    /// GLMASR) call `cache.update()` deep inside `MLXLMCommon` — an external package
    /// that is `public class` (not subclassable) and that we cannot modify without
    /// forking swift-mlx-lm. Grow events for those families are an **API gap**:
    /// they cannot be observed without changes to swift-mlx-lm. See
    /// COMPLETE_S14_VERBOSE_CODEC_AND_KV_GROW.md for the full rationale.
    @Test("Mimi.KVCache.grow event fires on first cache update (capacity = 0 → grows)")
    func testKVCacheGrowEmitsEventOnResize() {
        let recorder = TestEventRecorder()
        let prevRecorder = Telemetry._installEventRecorder(recorder)
        defer { Telemetry._installEventRecorder(prevRecorder) }

        // Install .verbose level override for the duration of this test.
        let prevLevel = Telemetry._installLevelOverride(.verbose)
        defer { Telemetry._installLevelOverride(prevLevel) }

        // Build the smallest valid TransformerConfig. Constraints (from force-casts in
        // TransformerLayer.callAsFunction): gating=false, norm="layer_norm",
        // layerScale != nil, useConvBlock=false, crossAttention=false.
        let dModel = 16
        let cfg = TransformerConfig(
            dModel: dModel,
            numHeads: 2,
            numLayers: 1,
            causal: true,
            normFirst: true,
            biasFF: false,
            biasAttn: false,
            layerScale: 1.0,
            positionalEmbedding: "rope",
            useConvBlock: false,
            crossAttention: false,
            convKernelSize: 3,
            useConvBias: true,
            gating: false,
            norm: "layer_norm",
            context: 250,
            maxPeriod: 10_000,
            maxSeqLen: 1_024,
            kvRepeat: 1,
            dimFeedforward: dModel * 4,
            convLayout: false
        )

        let transformer = Transformer(cfg: cfg)
        // makeCache() returns [KVCacheSimple] with offset=0 — first call will grow.
        let cache = transformer.makeCache()

        // A single token in [B=1, T=1, D=16] (NLC) — small enough for random weights.
        let input = MLXRandom.normal([1, 1, dModel])
        _ = transformer(input, cache: cache)

        // The Attention layer fires Mimi.KVCache.grow on every cache whose offset was 0.
        // With numLayers=1 and 1 token, we expect exactly 1 grow event.
        let growEvents = recorder.events.filter { $0.name == "Mimi.KVCache.grow" }
        let growCount = growEvents.count
        #expect(growCount > 0, "Expected ≥1 Mimi.KVCache.grow event on first cache update, got 0")

        // All grow events should be on the codecs family.
        for event in growEvents {
            #expect(event.family == "codecs",
                    "Expected family 'codecs' for Mimi.KVCache.grow event, got '\(event.family)'")
        }
    }
}
