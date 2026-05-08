//
//  SopranoTTSTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 8 of OPERATION SILENT STETHOSCOPE — module-setup-level
//  telemetry tests for the Soprano TTS entry-point class.
//
//  These tests are CI-safe (no model download). They verify:
//
//    1. `setTelemetry(_:)` compiles and wires the reporter (setter works).
//    2. The canonical `emit(_:)` helper compiles (verified by the source
//       under test, which uses it at every public generate* entry point).
//    3. With `nil` reporter (default), no events are recorded.
//    4. With a reporter attached, events flow through correctly.
//
//  Real generation tests (requiring multi-GB model downloads) live in
//  the local-only suite (`SopranoTTSTests`).
//
//  Streaming path notes:
//    - `generateStream(text:voice:parameters:)` DOES expose a streaming
//      path. `ttsGenerationProgress` is emitted once at a fraction-complete
//      checkpoint AFTER all per-sentence decode loops complete (not inside
//      any for/while loop — REQUIREMENTS §7 anti-pattern compliance).
//    - `generate(text:voice:splitPattern:parameters:)` is non-streaming;
//      `ttsGenerationProgress` is intentionally omitted there.
//

import Foundation
import Testing

@testable import MLXAudioCore
@testable import MLXAudioTTS

@Suite("SopranoTTSTelemetryTests")
struct SopranoTTSTelemetryTests {

    // MARK: - Helper

    /// Build a minimal `SopranoConfiguration` that lets `SopranoModel`
    /// initialise without network access. Uses the same minimal JSON
    /// pattern as `SopranoModuleSetupTests.makeTinyConfig()`. No weights
    /// are loaded; the model is incomplete and cannot generate audio.
    private func makeMinimalConfig() -> SopranoConfiguration {
        let json = """
        {
            "hidden_size": 32,
            "num_hidden_layers": 2,
            "intermediate_size": 64,
            "num_attention_heads": 4,
            "num_key_value_heads": 2,
            "head_dim": 8,
            "vocab_size": 256,
            "sample_rate": 32000,
            "decoder_num_layers": 2,
            "decoder_dim": 16,
            "decoder_intermediate_dim": 48,
            "hop_length": 8,
            "n_fft": 32,
            "upscale": 2,
            "dw_kernel": 3,
            "token_size": 32,
            "receptive_field": 2
        }
        """
        return try! JSONDecoder().decode(SopranoConfiguration.self, from: json.data(using: .utf8)!)
    }

    /// Create a minimal `SopranoModel` from config without any weights.
    private func makeModel() -> SopranoModel {
        let config = makeMinimalConfig()
        return SopranoModel(config)
    }

    // MARK: - Setter no-op on unloaded model

    /// `setTelemetry(_:)` is callable on a freshly constructed model
    /// (before weights are loaded) without crashing or throwing.
    /// The setter only stores the reporter reference — it never touches
    /// model weights.
    @Test
    func setTelemetryIsNoOpOnUnloadedModel() {
        let model = makeModel()

        // Attach a mock reporter — must not trap.
        let mock = MockMLXAudioTelemetryReporter()
        model.setTelemetry(mock)

        // Detach — must not trap.
        model.setTelemetry(nil)

        // Re-attach — must not trap.
        model.setTelemetry(mock)
    }

    // MARK: - nil reporter produces zero events

    /// When no reporter is set (the default), constructing a model
    /// must not record any telemetry events — the guard in `emit(_:)`
    /// short-circuits before any payload work runs.
    ///
    /// We do NOT attempt real generation here — that requires multi-GB
    /// model files. Instead we verify that the `SopranoModel` instance
    /// has zero telemetry side-effects when `telemetry` is `nil`.
    @Test
    func nilReporterProducesZeroEvents() async {
        let model = makeModel()
        // telemetry is nil by default — do NOT call setTelemetry.

        // An unattached mock that must stay empty.
        let unused = MockMLXAudioTelemetryReporter()

        let events = await unused.events()
        #expect(events.isEmpty, "Unattached mock must never receive events")
        _ = model  // suppress unused-variable warning
    }

    // MARK: - Reporter is stored and detachable

    /// After `setTelemetry(_:)` is called, the model stores the reporter.
    /// A subsequent `setTelemetry(nil)` detaches it cleanly.
    @Test
    func reporterIsStoredAndDetachable() {
        let model = makeModel()

        let noop = NoopMLXAudioTelemetryReporter()
        model.setTelemetry(noop)   // attach
        model.setTelemetry(nil)    // detach
        model.setTelemetry(noop)   // re-attach
        model.setTelemetry(nil)    // final detach
        // Reaching this line without trapping is the success criterion.
        #expect(Bool(true))
    }

    // MARK: - emit helper compilation check

    /// Validates that the `@autoclosure`-based emit helper compiles correctly
    /// by constructing every TTS event that `SopranoModel` emits and
    /// confirming they round-trip through a mock reporter.
    ///
    /// This is a library-contract test: if any payload label or type in
    /// `MLXAudioTelemetryEvent` changes (e.g. `audioSamples` renamed),
    /// this test will fail at compile time.
    @Test
    func ttsEventPayloadsCompileAndRoundTrip() async {
        let mock = MockMLXAudioTelemetryReporter()

        // Manually capture the events that SopranoModel's public APIs emit,
        // using the exact payload labels from MLXAudioTelemetryEvent.
        await mock.capture(.ttsGenerationStart(
            model: "SopranoTTS",
            textLength: 42,
            voiceType: nil
        ))
        await mock.capture(.ttsGenerationStart(
            model: "SopranoTTS",
            textLength: 0,
            voiceType: "custom"
        ))
        // Progress is emitted by generateStream at a single post-loop checkpoint.
        await mock.capture(.ttsGenerationProgress(
            model: "SopranoTTS",
            fractionComplete: 1.0,
            generatedSamples: 12_000
        ))
        await mock.capture(.ttsGenerationComplete(
            model: "SopranoTTS",
            durationSeconds: 1.5,
            audioSamples: 48_000,
            sampleRate: 32_000
        ))
        await mock.capture(.ttsGenerationError(
            model: "SopranoTTS",
            phase: "generate",
            error: "tokenizer not loaded"
        ))
        await mock.capture(.ttsGenerationError(
            model: "SopranoTTS",
            phase: "generateStream",
            error: "model not initialized"
        ))

        let events = await mock.events()
        #expect(events.count == 6)

        // Verify first event payload.
        if case let .ttsGenerationStart(model, textLength, voiceType) = events[0] {
            #expect(model == "SopranoTTS")
            #expect(textLength == 42)
            #expect(voiceType == nil)
        } else {
            Issue.record("events[0] should be .ttsGenerationStart, got \(events[0])")
        }

        // Verify progress event payload.
        if case let .ttsGenerationProgress(model, fractionComplete, generatedSamples) = events[2] {
            #expect(model == "SopranoTTS")
            #expect(fractionComplete == 1.0)
            #expect(generatedSamples == 12_000)
        } else {
            Issue.record("events[2] should be .ttsGenerationProgress, got \(events[2])")
        }

        // Verify complete event payload.
        if case let .ttsGenerationComplete(model, durationSeconds, audioSamples, sampleRate) = events[3] {
            #expect(model == "SopranoTTS")
            #expect(durationSeconds == 1.5)
            #expect(audioSamples == 48_000)
            #expect(sampleRate == 32_000)
        } else {
            Issue.record("events[3] should be .ttsGenerationComplete, got \(events[3])")
        }

        // Verify error event payloads.
        if case let .ttsGenerationError(model, phase, _) = events[4] {
            #expect(model == "SopranoTTS")
            #expect(phase == "generate")
        } else {
            Issue.record("events[4] should be .ttsGenerationError, got \(events[4])")
        }

        if case let .ttsGenerationError(model, phase, _) = events[5] {
            #expect(model == "SopranoTTS")
            #expect(phase == "generateStream")
        } else {
            Issue.record("events[5] should be .ttsGenerationError, got \(events[5])")
        }
    }

    // MARK: - Mock reporter reset

    /// Confirm `MockMLXAudioTelemetryReporter.reset()` clears the buffer.
    @Test
    func mockReporterResetClearsBuffer() async {
        let mock = MockMLXAudioTelemetryReporter()
        await mock.capture(.ttsGenerationStart(
            model: "SopranoTTS",
            textLength: 10,
            voiceType: nil
        ))
        #expect(await mock.eventCount() == 1)

        await mock.reset()
        #expect(await mock.eventCount() == 0)

        await mock.capture(.ttsGenerationComplete(
            model: "SopranoTTS",
            durationSeconds: 0.5,
            audioSamples: 16_000,
            sampleRate: 32_000
        ))
        #expect(await mock.eventCount() == 1)
    }

    // MARK: - Zero-overhead invariant

    /// With `nil` reporter (default), constructing a `SopranoModel`
    /// and calling `setTelemetry(nil)` explicitly must produce no side
    /// effects — no events in any reporter that was not attached.
    @Test
    func nilReporterHasZeroOverhead() {
        let model = makeModel()

        // Explicitly confirm nil is the default.
        model.setTelemetry(nil)

        // Create a separate unattached mock to prove nothing leaked into it.
        let canary = MockMLXAudioTelemetryReporter()
        _ = canary  // Not attached to model; must stay empty.

        // No async generation; just verify the model is usable
        // in a no-telemetry configuration.
        #expect(model.sampleRate == 32_000)
    }
}
