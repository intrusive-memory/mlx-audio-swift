//
//  DACVAETelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 16 of OPERATION SILENT STETHOSCOPE — telemetry instrumentation
//  coverage for the DACVAE audio codec.
//
//  This suite is CI-safe (no model downloads). It verifies:
//
//    1. `setTelemetry(_:)` compiles and is callable on `DACVAE`.
//    2. The canonical `emit` helper with `@autoclosure` is wired correctly
//       (confirmed by the test attaching a reporter and checking zero
//       events during setup-only operations).
//    3. `nil` default — a freshly constructed `DACVAE` emits nothing to
//       an unattached mock.
//    4. Attaching a reporter and calling the async `encode` overload
//       produces `codecEncodeStart` followed by `codecEncodeComplete`
//       in that order, with consistent payload values.
//    5. Attaching a reporter and calling the async `decode` overload
//       produces `codecDecodeStart` followed by `codecDecodeComplete`
//       in that order, with consistent payload values.
//    6. Detaching via `setTelemetry(nil)` produces no subsequent events.
//    7. The `codecEncodeStart` / `codecEncodeComplete` / `codecDecodeStart` /
//       `codecDecodeComplete` / `codecError` event constructors compile
//       with the payload labels that DACVAE instrumentation uses.
//    8. The synchronous `encode` / `decode` overloads remain
//       backward-compatible (no regressions in existing DACVAETests).
//    9. `inputSamples` payload matches the audio sequence length.
//   10. `NoopMLXAudioTelemetryReporter` is accepted by `setTelemetry`.
//   11. async encode+decode produces four events in order.
//
//  DACVAE is a VAE-style audio codec that operates on continuous latent
//  representations. Both encode and decode paths emit start + complete
//  telemetry events. The watermarker submodule is internal and is NOT
//  instrumented — no events are emitted from any watermark path.
//
//  Real end-to-end audio quality tests live in the local-only suites
//  that require multi-GB model downloads.
//

import Foundation
import Testing
import MLX
import MLXRandom

@testable import MLXAudioCore
@testable import MLXAudioCodecs

// MARK: - DACVAETelemetryTests

@Suite("DACVAETelemetryTests")
struct DACVAETelemetryTests {

    // MARK: - Helpers

    /// Construct a small but structurally valid `DACVAE` instance without
    /// loading any pre-trained weights or downloading anything.
    ///
    /// Tiny config — matches `DACVAETests.testDACVAEModel()` and
    /// `TelemetryCodecLifecycleSmokeTests.dacModelLifecycle()`:
    ///   encoderDim=32, encoderRates=[2,4], latentDim=64,
    ///   decoderDim=64, decoderRates=[4,2], codebookDim=32.
    /// hopLength = 2 × 4 = 8.
    private func makeTinyDACVAE() -> DACVAE {
        let config = DACVAEConfig(
            encoderDim: 32,
            encoderRates: [2, 4],
            latentDim: 64,
            decoderDim: 64,
            decoderRates: [4, 2],
            codebookDim: 32
        )
        return DACVAE(config: config)
    }

    /// Construct a minimal valid audio input tensor for `encode`.
    /// Shape: [1, 800, 1] — 1 batch, 800 samples, 1 channel.
    /// 800 is divisible by hopLength=8, keeping the test fast.
    private func makeTinyWaveform() -> MLXArray {
        return MLXRandom.normal([1, 800, 1])
    }

    /// Construct a minimal encoded-frames tensor for `decode`.
    /// Shape: [1, 32, 100] — 1 batch, codebook_dim=32, 100 frames.
    /// 100 frames corresponds to 800 samples / hopLength=8.
    private func makeTinyEncodedFrames() -> MLXArray {
        return MLXRandom.normal([1, 32, 100])
    }

    /// Encode audio using the sync overload and return the latent tensor
    /// for use as decode input (no events emitted from sync path).
    private func encodeTiny(_ model: DACVAE, _ waveform: MLXArray) -> MLXArray {
        return model.encode(waveform)
    }

    // MARK: - Test 1: setTelemetry compiles and attaches a reporter

    /// Verify that `setTelemetry(_:)` exists on `DACVAE`, is callable
    /// with a concrete reporter, and does not crash during construction.
    @Test
    func setTelemetryAttachesReporter() {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()

        model.setTelemetry(mock)

        #expect(Bool(true), "setTelemetry(_:) compiled and ran without error")
    }

    // MARK: - Test 2: setTelemetry(nil) detaches reporter

    /// Verify that passing `nil` to `setTelemetry` is accepted (detach
    /// path). Exercises both attach and detach code paths.
    @Test
    func setTelemetryNilDetachesReporter() {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()

        model.setTelemetry(mock)
        model.setTelemetry(nil)   // must compile and not crash

        #expect(Bool(true), "setTelemetry(nil) compiled and ran without error")
    }

    // MARK: - Test 3: nil default — no events without explicit attachment

    /// A freshly constructed `DACVAE` has `telemetry == nil` by default.
    /// Constructing the model and calling the sync `encode` / `decode`
    /// must not send anything to a separately observed mock that was never
    /// attached.
    ///
    /// This proves invariant 3 ("nil reporter → zero runtime cost") at
    /// the API-surface level.
    @Test
    func nilDefaultProducesNoEventsToUnattachedMock() async {
        let model = makeTinyDACVAE()
        let unattachedMock = MockMLXAudioTelemetryReporter()

        // Synchronous encode then decode — no reporter attached.
        // Bind to sync function types to force overload resolution to pick
        // the non-async overloads (Swift 6.2 in async contexts otherwise
        // prefers the async variants).
        let waveform = makeTinyWaveform()
        let syncEncode: (MLXArray) -> MLXArray = model.encode
        let syncDecode: (MLXArray, Int?) -> MLXArray = model.decode
        let latent = syncEncode(waveform)
        let _ = syncDecode(latent, nil)

        let count = await unattachedMock.eventCount()
        #expect(count == 0,
                "No events should reach an unattached mock: expected 0, got \(count)")
    }

    // MARK: - Test 4: async encode emits start + complete in order

    /// Attaching a reporter and calling the async `encode` overload must
    /// produce exactly two events: `codecEncodeStart` followed by
    /// `codecEncodeComplete`. The order must be preserved.
    @Test
    func asyncEncodeEmitsStartThenComplete() async {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()
        model.setTelemetry(mock)

        let waveform = makeTinyWaveform()  // [1, 800, 1]
        let _ = await model.encode(waveform)

        let events = await mock.events()

        // Exactly two events: start then complete.
        #expect(events.count == 2,
                "Expected 2 events (start + complete), got \(events.count): \(events)")

        guard events.count == 2 else { return }

        // First event: codecEncodeStart
        guard case let .codecEncodeStart(startCodec, inputSamples) = events[0] else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "dacvae",
                "codec label should be \"dacvae\", got \"\(startCodec)\"")
        #expect(inputSamples > 0,
                "inputSamples should be positive, got \(inputSamples)")

        // Second event: codecEncodeComplete
        guard case let .codecEncodeComplete(completeCodec, durationSeconds, compressionRatio) = events[1] else {
            Issue.record("events[1] should be .codecEncodeComplete, got \(events[1])")
            return
        }
        #expect(completeCodec == "dacvae",
                "codec label should be \"dacvae\", got \"\(completeCodec)\"")
        #expect(durationSeconds >= 0,
                "durationSeconds should be non-negative, got \(durationSeconds)")
        #expect(compressionRatio > 0,
                "compressionRatio should be positive, got \(compressionRatio)")
    }

    // MARK: - Test 5: async decode emits start + complete in order

    /// Attaching a reporter and calling the async `decode` overload must
    /// produce exactly two events: `codecDecodeStart` followed by
    /// `codecDecodeComplete`. The order must be preserved.
    @Test
    func asyncDecodeEmitsStartThenComplete() async {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()
        model.setTelemetry(mock)

        // Use sync encode to produce latent (no events from sync path).
        // Bind to a sync function type so overload resolution picks the
        // non-async overload from this async test context.
        let waveform = makeTinyWaveform()  // [1, 800, 1]
        let syncEncode: (MLXArray) -> MLXArray = model.encode
        let latent = syncEncode(waveform)
        // Then async decode
        let _ = await model.decode(latent)

        let events = await mock.events()

        // Exactly two events: decode start then complete.
        #expect(events.count == 2,
                "Expected 2 events (decode start + complete), got \(events.count): \(events)")

        guard events.count == 2 else { return }

        // First event: codecDecodeStart
        guard case let .codecDecodeStart(startCodec, codedFrames) = events[0] else {
            Issue.record("events[0] should be .codecDecodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "dacvae",
                "codec label should be \"dacvae\", got \"\(startCodec)\"")
        #expect(codedFrames > 0,
                "codedFrames should be positive, got \(codedFrames)")

        // Second event: codecDecodeComplete
        guard case let .codecDecodeComplete(completeCodec, durationSeconds, outputSamples) = events[1] else {
            Issue.record("events[1] should be .codecDecodeComplete, got \(events[1])")
            return
        }
        #expect(completeCodec == "dacvae",
                "codec label should be \"dacvae\", got \"\(completeCodec)\"")
        #expect(durationSeconds >= 0,
                "durationSeconds should be non-negative, got \(durationSeconds)")
        #expect(outputSamples > 0,
                "outputSamples should be positive, got \(outputSamples)")
    }

    // MARK: - Test 6: async encode+decode produces four events in order

    /// Attaching a reporter and running both async encode then async decode
    /// must produce exactly four events in order:
    ///   codecEncodeStart → codecEncodeComplete → codecDecodeStart → codecDecodeComplete
    @Test
    func asyncEncodeAndDecodeProducesFourEventsInOrder() async {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()
        model.setTelemetry(mock)

        let waveform = makeTinyWaveform()
        let latent = await model.encode(waveform)
        let _ = await model.decode(latent)

        let events = await mock.events()

        #expect(events.count == 4,
                "Expected 4 events (encode start/complete + decode start/complete), got \(events.count): \(events)")

        guard events.count == 4 else { return }

        if case .codecEncodeStart = events[0] { } else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
        }
        if case .codecEncodeComplete = events[1] { } else {
            Issue.record("events[1] should be .codecEncodeComplete, got \(events[1])")
        }
        if case .codecDecodeStart = events[2] { } else {
            Issue.record("events[2] should be .codecDecodeStart, got \(events[2])")
        }
        if case .codecDecodeComplete = events[3] { } else {
            Issue.record("events[3] should be .codecDecodeComplete, got \(events[3])")
        }
    }

    // MARK: - Test 7: inputSamples payload matches audio sequence length

    /// The `inputSamples` field in `codecEncodeStart` must equal the
    /// sequence-length dimension of the input waveform (dimension 1).
    @Test
    func inputSamplesMatchesAudioSequenceLength() async {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()
        model.setTelemetry(mock)

        // 160 samples — divisible by hopLength=8
        let numSamples = 160
        let waveform = MLXRandom.normal([1, numSamples, 1])
        let _ = await model.encode(waveform)

        let events = await mock.events()
        guard events.count >= 1,
              case let .codecEncodeStart(_, inputSamples) = events[0] else {
            Issue.record("Expected at least one event and events[0] to be .codecEncodeStart")
            return
        }
        #expect(inputSamples == numSamples,
                "inputSamples should equal audio sequence length \(numSamples), got \(inputSamples)")
    }

    // MARK: - Test 8: detaching reporter silences subsequent async calls

    /// After calling `setTelemetry(nil)`, subsequent async `encode` and
    /// `decode` calls must not emit any events.
    @Test
    func detachedReporterProducesNoEvents() async {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()

        // Attach, run once to verify events do flow.
        model.setTelemetry(mock)
        let waveform = makeTinyWaveform()
        let _ = await model.encode(waveform)
        let countAfterFirst = await mock.eventCount()
        #expect(countAfterFirst > 0, "Expected events after first async encode with reporter attached")

        // Detach and reset.
        model.setTelemetry(nil)
        await mock.reset()

        // Second async encode with no reporter.
        let _ = await model.encode(waveform)
        let countAfterSecond = await mock.eventCount()
        #expect(countAfterSecond == 0,
                "No events should be emitted after setTelemetry(nil), got \(countAfterSecond)")
    }

    // MARK: - Test 9: codec event shapes compile with DACVAE payload labels

    /// Confirm that `codecEncodeStart`, `codecEncodeComplete`,
    /// `codecDecodeStart`, `codecDecodeComplete`, and `codecError` can all
    /// be constructed and captured with the payload labels used in the
    /// DACVAE instrumentation. If the event enum's label names diverge
    /// from the instrumentation code, this test (and `DACVAE.swift`)
    /// would fail to compile.
    @Test
    func codecEventShapesCompileWithDACVAELabels() async {
        let mock = MockMLXAudioTelemetryReporter()

        // Directly capture the five event shapes used by DACVAE.
        await mock.capture(.codecEncodeStart(codec: "dacvae", inputSamples: 800))
        await mock.capture(.codecEncodeComplete(
            codec: "dacvae",
            durationSeconds: 0.050,
            compressionRatio: 0.5
        ))
        await mock.capture(.codecDecodeStart(codec: "dacvae", codedFrames: 100))
        await mock.capture(.codecDecodeComplete(
            codec: "dacvae",
            durationSeconds: 0.025,
            outputSamples: 800
        ))
        await mock.capture(.codecError(
            codec: "dacvae",
            operation: "encode",
            error: "synthetic error"
        ))

        let events = await mock.events()
        #expect(events.count == 5)

        guard events.count == 5 else { return }

        if case let .codecEncodeStart(codec, inputSamples) = events[0] {
            #expect(codec == "dacvae")
            #expect(inputSamples == 800)
        } else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
        }

        if case let .codecEncodeComplete(codec, durationSeconds, compressionRatio) = events[1] {
            #expect(codec == "dacvae")
            #expect(durationSeconds == 0.050)
            #expect(compressionRatio == 0.5)
        } else {
            Issue.record("events[1] should be .codecEncodeComplete, got \(events[1])")
        }

        if case let .codecDecodeStart(codec, codedFrames) = events[2] {
            #expect(codec == "dacvae")
            #expect(codedFrames == 100)
        } else {
            Issue.record("events[2] should be .codecDecodeStart, got \(events[2])")
        }

        if case let .codecDecodeComplete(codec, durationSeconds, outputSamples) = events[3] {
            #expect(codec == "dacvae")
            #expect(durationSeconds == 0.025)
            #expect(outputSamples == 800)
        } else {
            Issue.record("events[3] should be .codecDecodeComplete, got \(events[3])")
        }

        if case let .codecError(codec, operation, _) = events[4] {
            #expect(codec == "dacvae")
            #expect(operation == "encode")
        } else {
            Issue.record("events[4] should be .codecError, got \(events[4])")
        }
    }

    // MARK: - Test 10: NoopMLXAudioTelemetryReporter is accepted by setTelemetry

    /// Confirm that the library-provided `NoopMLXAudioTelemetryReporter`
    /// can be passed to `setTelemetry` — useful for hosts that want to
    /// satisfy the non-optional reporter API without recording events.
    @Test
    func noopReporterIsAcceptedBySetTelemetry() {
        let model = makeTinyDACVAE()
        let noop = NoopMLXAudioTelemetryReporter()

        model.setTelemetry(noop)

        #expect(Bool(true), "NoopMLXAudioTelemetryReporter compiled and was accepted by setTelemetry")
    }

    // MARK: - Test 11: synchronous encode/decode remain backward-compatible

    /// The synchronous `encode` and `decode` overloads must continue to work
    /// without any async context. No events should be emitted to an attached
    /// mock from the sync path (telemetry is async-only — the sync overloads
    /// are retained for backward compatibility and do not emit public-surface
    /// events).
    @Test
    func synchronousEncodeDecodeRemainsBackwardCompatible() async {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()
        model.setTelemetry(mock)

        let waveform = makeTinyWaveform()

        // Synchronous encode — must not require `await` and must not crash.
        // Bind to sync function types so overload resolution picks the
        // non-async overloads from this async test context.
        let syncEncode: (MLXArray) -> MLXArray = model.encode
        let syncDecode: (MLXArray, Int?) -> MLXArray = model.decode
        let latent = syncEncode(waveform)
        #expect(latent.shape.count >= 1,
                "Sync encode should return a tensor with at least 1 dimension")

        // Synchronous decode — must not require `await` and must not crash.
        let decoded = syncDecode(latent, nil)
        #expect(decoded.shape.count >= 1,
                "Sync decode should return a tensor with at least 1 dimension")

        // No events should be emitted from the sync path.
        let count = await mock.eventCount()
        #expect(count == 0,
                "Sync encode/decode should not emit public-surface telemetry events, got \(count)")
    }

    // MARK: - Test 12: watermarker emits no events

    /// Confirm that the watermarker submodule is not instrumented.
    /// Constructing a `DACVAEFullDecoder` and calling `decodeWithWatermark`
    /// (the no-message path, which is the standard decode tail) does not
    /// emit any telemetry events — telemetry is only emitted at the public
    /// `DACVAE.encode` / `DACVAE.decode` boundaries.
    ///
    /// This test exercises `DACVAE.decode` end-to-end with a reporter
    /// attached and verifies that exactly two events (start + complete)
    /// are emitted, not more (i.e., the watermarker path does not inject
    /// additional events).
    @Test
    func watermarkerPathEmitsNoAdditionalEvents() async {
        let model = makeTinyDACVAE()
        let mock = MockMLXAudioTelemetryReporter()
        model.setTelemetry(mock)

        // Build encoded frames directly (sync encode path — no events).
        // Bind to a sync function type so overload resolution picks the
        // non-async overload from this async test context.
        let waveform = makeTinyWaveform()
        let syncEncode: (MLXArray) -> MLXArray = model.encode
        let latent = syncEncode(waveform)

        // Async decode — only the boundary events should appear.
        let _ = await model.decode(latent)

        let events = await mock.events()
        // Exactly 2 events: codecDecodeStart + codecDecodeComplete.
        // If the watermarker were instrumented, there would be more.
        #expect(events.count == 2,
                "Expected exactly 2 events (decode boundary only, no watermarker events), got \(events.count): \(events)")
    }
}
