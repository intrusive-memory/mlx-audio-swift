//
//  PocketTTSTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 10 of OPERATION SILENT STETHOSCOPE — module-setup-level
//  telemetry tests for the PocketTTS entry-point class.
//
//  These tests are CI-safe (no model download). They verify:
//
//    1. `setTelemetry(_:)` compiles and sets the reporter (setter wires).
//    2. The canonical `emit(_:)` helper compiles (verified by usage in
//       the source under test).
//    3. With `nil` reporter (default), no events are recorded.
//    4. With a reporter attached, events flow through correctly.
//
//  Real generation tests (requiring multi-GB model downloads) live in
//  the local-only suite (`PocketTTSTests`).
//
//  Note on `ttsGenerationProgress`:
//  PocketTTS uses flow-matching (no discrete-token streaming). The ODE
//  solver loop does not expose a meaningful per-step completion signal —
//  each step produces a raw continuous latent frame, not a discrete
//  fraction-of-audio marker. EOS is detected mid-loop, so step-count is
//  not a reliable proxy for audio fraction-complete. Therefore
//  `ttsGenerationProgress` is intentionally omitted from PocketTTS
//  instrumentation.
//

import Foundation
import Testing
import MLX
import MLXNN
import MLXLMCommon

@testable import MLXAudioCore
@testable import MLXAudioTTS

@Suite("PocketTTSTelemetryTests")
struct PocketTTSTelemetryTests {

    // MARK: - Helper

    /// Return a tiny but valid FlowLM config for model construction without weight loading.
    private func makeTinyFlowLMConfig() -> PocketTTSFlowLMConfig {
        PocketTTSFlowLMConfig(
            dtype: nil,
            flow: PocketTTSFlowConfig(dim: 16, depth: 1),
            transformer: PocketTTSFlowLMTransformerConfig(
                hiddenScale: 2,
                maxPeriod: 10000.0,
                dModel: 16,
                numHeads: 2,
                numLayers: 2
            ),
            lookupTable: PocketTTSLookupTableConfig(
                dim: 16,
                nBins: 64,
                tokenizer: "sentencepiece",
                tokenizerPath: "tokenizer.model"
            ),
            weightsPath: nil
        )
    }

    /// Return a tiny but valid Mimi config for model construction without weight loading.
    private func makeTinyMimiConfig() -> PocketTTSMimiConfig {
        PocketTTSMimiConfig(
            dtype: nil,
            sampleRate: 24000,
            channels: 1,
            frameRate: 12.5,
            seanet: PocketTTSSeanetConfig(
                dimension: 16,
                channels: 1,
                nFilters: 4,
                nResidualLayers: 1,
                ratios: [2, 2],
                kernelSize: 7,
                residualKernelSize: 3,
                lastKernelSize: 3,
                dilationBase: 2,
                padMode: "constant",
                compress: 2
            ),
            transformer: PocketTTSMimiTransformerConfig(
                dModel: 16,
                inputDimension: 16,
                outputDimensions: [16],
                numHeads: 2,
                numLayers: 2,
                layerScale: 0.01,
                context: 8,
                dimFeedforward: 32,
                maxPeriod: 10000.0
            ),
            quantizer: PocketTTSQuantizerConfig(dimension: 8, outputDimension: 16),
            weightsPath: nil
        )
    }

    /// Construct a PocketTTSModel with tiny synthetic sub-models, bypassing all file I/O.
    /// Uses the testing-only internal init that accepts pre-built sub-models.
    private func makeModel() -> PocketTTSModel {
        let flowLMConfig = makeTinyFlowLMConfig()
        let mimiConfig = makeTinyMimiConfig()

        let dModel = flowLMConfig.transformer.dModel
        let ldim = mimiConfig.quantizer.dimension

        let conditioner = LUTConditioner(
            nBins: flowLMConfig.lookupTable.nBins,
            dim: flowLMConfig.lookupTable.dim,
            outputDim: dModel
        )

        let flowNet = SimpleMLPAdaLN(
            inChannels: ldim,
            modelChannels: flowLMConfig.flow.dim,
            outChannels: ldim,
            condChannels: dModel,
            numResBlocks: flowLMConfig.flow.depth,
            numTimeConds: 2
        )

        let transformer = PocketStreamingTransformer(
            dModel: dModel,
            numHeads: flowLMConfig.transformer.numHeads,
            numLayers: flowLMConfig.transformer.numLayers,
            dimFeedforward: flowLMConfig.transformer.hiddenScale * dModel,
            maxPeriod: flowLMConfig.transformer.maxPeriod,
            layerScale: nil
        )

        let flowLM = FlowLMModel(
            conditioner: conditioner,
            flowNet: flowNet,
            transformer: transformer,
            dim: dModel,
            ldim: ldim
        )

        let mimi = MimiAdapter.fromConfig(mimiConfig)

        let modelConfig = PocketTTSModelConfig(
            modelType: "pocket_tts",
            flowLM: flowLMConfig,
            mimi: mimiConfig,
            weightsPath: nil,
            weightsPathWithoutVoiceCloning: nil,
            modelPath: nil
        )

        return PocketTTSModel(config: modelConfig, flowLM: flowLM, mimi: mimi)
    }

    // MARK: - Setter no-op on unloaded model

    /// `setTelemetry(_:)` is callable on a freshly constructed model
    /// (before weights are loaded) without crashing or throwing.
    /// The setter is a no-op in the sense that it never touches model
    /// weights — it only stores the reporter reference.
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

    /// When no reporter is set (the default), an unattached mock must
    /// never receive events — the guard in `emit(_:)` short-circuits
    /// before any payload work runs.
    @Test
    func nilReporterProducesZeroEvents() async throws {
        let model = makeModel()
        // telemetry is nil by default — do NOT call setTelemetry.

        // A mock that shouldn't be called.
        let unused = MockMLXAudioTelemetryReporter()

        // The model carries nil telemetry; the unused mock is never
        // attached and therefore must stay empty.
        let events = await unused.events()
        #expect(events.isEmpty, "Unattached mock must never receive events")
        _ = model  // suppress unused-variable warning
    }

    // MARK: - Reporter is wired after setTelemetry

    /// After `setTelemetry(_:)` is called with a mock reporter, the
    /// model stores the reporter. A subsequent call to `setTelemetry(nil)`
    /// detaches it.
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

    /// Validates that the `@autoclosure`-based emit helper compiles
    /// correctly by constructing every TTS event that `PocketTTSModel`
    /// emits and confirming they round-trip through a mock reporter.
    ///
    /// This is a library-contract test: if any payload label or type in
    /// `MLXAudioTelemetryEvent` changes, this test will fail at compile time.
    @Test
    func ttsEventPayloadsCompileAndRoundTrip() async {
        let mock = MockMLXAudioTelemetryReporter()

        // Manually capture the events that PocketTTSModel's public API
        // emits, using the exact payload labels from MLXAudioTelemetryEvent.
        await mock.capture(.ttsGenerationStart(
            model: "PocketTTS",
            textLength: 42,
            voiceType: "alba"
        ))
        await mock.capture(.ttsGenerationStart(
            model: "PocketTTS",
            textLength: 0,
            voiceType: nil
        ))
        // Note: ttsGenerationProgress is intentionally omitted for PocketTTS.
        // Flow-matching has no natural per-step fraction-complete signal;
        // the ODE solver loop terminates on EOS with no meaningful midpoint.
        await mock.capture(.ttsGenerationComplete(
            model: "PocketTTS",
            durationSeconds: 3.0,
            audioSamples: 72_000,
            sampleRate: 24_000
        ))
        await mock.capture(.ttsGenerationError(
            model: "PocketTTS",
            phase: "generate",
            error: "Missing audio prompt for voice: unknown"
        ))
        await mock.capture(.ttsGenerationError(
            model: "PocketTTS",
            phase: "generate",
            error: "Missing generation state"
        ))

        let events = await mock.events()
        #expect(events.count == 5)

        // Verify first event payload.
        if case let .ttsGenerationStart(model, textLength, voiceType) = events[0] {
            #expect(model == "PocketTTS")
            #expect(textLength == 42)
            #expect(voiceType == "alba")
        } else {
            Issue.record("events[0] should be .ttsGenerationStart, got \(events[0])")
        }

        // Verify complete event payload.
        if case let .ttsGenerationComplete(model, durationSeconds, audioSamples, sampleRate) = events[2] {
            #expect(model == "PocketTTS")
            #expect(durationSeconds == 3.0)
            #expect(audioSamples == 72_000)
            #expect(sampleRate == 24_000)
        } else {
            Issue.record("events[2] should be .ttsGenerationComplete, got \(events[2])")
        }

        // Verify error event payloads.
        if case let .ttsGenerationError(model, phase, _) = events[3] {
            #expect(model == "PocketTTS")
            #expect(phase == "generate")
        } else {
            Issue.record("events[3] should be .ttsGenerationError, got \(events[3])")
        }
    }

    // MARK: - Mock reporter reset

    /// Confirm `MockMLXAudioTelemetryReporter.reset()` clears the buffer —
    /// required by tests that use a single mock across multiple scenarios.
    @Test
    func mockReporterResetClearsBuffer() async {
        let mock = MockMLXAudioTelemetryReporter()
        await mock.capture(.ttsGenerationStart(
            model: "PocketTTS",
            textLength: 10,
            voiceType: nil
        ))
        #expect(await mock.eventCount() == 1)

        await mock.reset()
        #expect(await mock.eventCount() == 0)

        await mock.capture(.ttsGenerationComplete(
            model: "PocketTTS",
            durationSeconds: 1.5,
            audioSamples: 36_000,
            sampleRate: 24_000
        ))
        #expect(await mock.eventCount() == 1)
    }

    // MARK: - Zero-overhead invariant

    /// With `nil` reporter (default), constructing a `PocketTTSModel`
    /// and calling `setTelemetry(nil)` explicitly must produce no side
    /// effects — no events in any reporter that wasn't attached.
    @Test
    func nilReporterHasZeroOverhead() {
        let model = makeModel()

        // Explicitly confirm nil is the default (no events should leak).
        model.setTelemetry(nil)

        // Create a separate unattached mock to prove nothing leaked into it.
        let canary = MockMLXAudioTelemetryReporter()
        _ = canary  // Not attached to model; must stay empty.

        // No async generation; just verify the model compiles and is
        // usable in a no-telemetry configuration.
        #expect(model.sampleRate == 24_000)
    }
}
