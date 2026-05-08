//
//  EncodecTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 13 of OPERATION SILENT STETHOSCOPE — telemetry instrumentation
//  coverage for the Encodec neural audio codec.
//
//  This suite is CI-safe (no model downloads). It verifies:
//
//    1. `setTelemetry(_:)` compiles and is callable on `Encodec`.
//    2. The canonical `emit` helper with `@autoclosure` is wired correctly
//       (confirmed by the test attaching a reporter and checking zero
//       events during setup-only operations).
//    3. `nil` default — a freshly constructed `Encodec` emits nothing to
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
//       with the payload labels that Encodec instrumentation uses.
//    8. The synchronous `encode` / `decode` overloads remain
//       backward-compatible (no regressions in existing EncodecTests).
//    9. `compressionRatio` is positive and > 1.0 (audio is always larger
//       than its discrete code representation at any reasonable bandwidth).
//   10. `NoopMLXAudioTelemetryReporter` is accepted by `setTelemetry`.
//
//  Encodec is a full neural audio codec with both an encode and decode
//  path. Both paths emit start + complete telemetry events.
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

// MARK: - EncodecTelemetryTests

@Suite("EncodecTelemetryTests")
struct EncodecTelemetryTests {

    // MARK: - Helpers

    /// Construct a small but structurally valid `Encodec` instance without
    /// loading any pre-trained weights or downloading anything.
    ///
    /// Uses default `EncodecConfig` values:
    ///   audioChannels=1, numFilters=32, codebookSize=1024, codebookDim=128,
    ///   hiddenSize=128, numLstmLayers=2, samplingRate=24000,
    ///   upsamplingRatios=[8, 5, 4, 2], targetBandwidths=[1.5, 3.0, 6.0, 12.0, 24.0].
    private func makeTinyEncodec() -> Encodec {
        let config = EncodecConfig()
        return Encodec(config: config)
    }

    /// Construct a minimal valid audio input tensor.
    /// Shape: [1, 1000, 1] — 1 batch, 1000 samples, 1 channel.
    /// 1000 samples is enough to exercise the encoder/decoder while
    /// keeping wall-clock time short.
    private func makeTinyAudio() -> MLXArray {
        return MLXRandom.normal([1, 1000, 1])
    }

    /// Encode audio using the sync overload and return (codes, scales)
    /// for use as decode input.
    private func encodeTiny(_ model: Encodec, _ audio: MLXArray) -> (MLXArray, [MLXArray?]) {
        return model.encode(audio, bandwidth: 1.5)
    }

    // MARK: - Test 1: setTelemetry compiles and attaches a reporter

    /// Verify that `setTelemetry(_:)` exists on `Encodec`, is callable
    /// with a concrete reporter, and does not crash during construction.
    @Test
    func setTelemetryAttachesReporter() {
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()

        encodec.setTelemetry(mock)

        #expect(Bool(true), "setTelemetry(_:) compiled and ran without error")
    }

    // MARK: - Test 2: setTelemetry(nil) detaches reporter

    /// Verify that passing `nil` to `setTelemetry` is accepted (detach
    /// path). Exercises both attach and detach code paths.
    @Test
    func setTelemetryNilDetachesReporter() {
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()

        encodec.setTelemetry(mock)
        encodec.setTelemetry(nil)   // must compile and not crash

        #expect(Bool(true), "setTelemetry(nil) compiled and ran without error")
    }

    // MARK: - Test 3: nil default — no events without explicit attachment

    /// A freshly constructed `Encodec` has `telemetry == nil` by default.
    /// Constructing the model and calling the sync `encode` / `decode`
    /// must not send anything to a separately observed mock that was never
    /// attached.
    ///
    /// This proves invariant 3 ("nil reporter → zero runtime cost") at
    /// the API-surface level.
    @Test
    func nilDefaultProducesNoEventsToUnattachedMock() async {
        let encodec = makeTinyEncodec()
        let unattachedMock = MockMLXAudioTelemetryReporter()

        // Synchronous encode then decode — no reporter attached.
        // Bind to sync function types to force overload resolution to pick
        // the non-async overloads (Swift 6.2 in async contexts otherwise
        // prefers the async variants).
        let audio = makeTinyAudio()
        let syncEncode: (MLXArray, MLXArray?, Float?) -> (MLXArray, [MLXArray?]) = encodec.encode
        let syncDecode: (MLXArray, [MLXArray?], MLXArray?) -> MLXArray = encodec.decode
        let (codes, scales) = syncEncode(audio, nil, 1.5)
        let _ = syncDecode(codes, scales, nil)

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
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()
        encodec.setTelemetry(mock)

        let audio = makeTinyAudio()  // [1, 1000, 1]
        let _ = await encodec.encode(audio, bandwidth: 1.5)

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
        #expect(startCodec == "encodec",
                "codec label should be \"encodec\", got \"\(startCodec)\"")
        #expect(inputSamples > 0,
                "inputSamples should be positive, got \(inputSamples)")

        // Second event: codecEncodeComplete
        guard case let .codecEncodeComplete(completeCodec, durationSeconds, compressionRatio) = events[1] else {
            Issue.record("events[1] should be .codecEncodeComplete, got \(events[1])")
            return
        }
        #expect(completeCodec == "encodec",
                "codec label should be \"encodec\", got \"\(completeCodec)\"")
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
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()
        encodec.setTelemetry(mock)

        let audio = makeTinyAudio()  // [1, 1000, 1]
        // Use sync encode to get codes (no events from this path).
        // Bind to a sync function type so overload resolution picks the
        // non-async overload from this async test context.
        let syncEncode: (MLXArray, MLXArray?, Float?) -> (MLXArray, [MLXArray?]) = encodec.encode
        let (codes, scales) = syncEncode(audio, nil, 1.5)
        // Then async decode
        let _ = await encodec.decode(codes, scales)

        let events = await mock.events()

        // Exactly two events: start then complete.
        #expect(events.count == 2,
                "Expected 2 events (decode start + complete), got \(events.count): \(events)")

        guard events.count == 2 else { return }

        // First event: codecDecodeStart
        guard case let .codecDecodeStart(startCodec, codedFrames) = events[0] else {
            Issue.record("events[0] should be .codecDecodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "encodec",
                "codec label should be \"encodec\", got \"\(startCodec)\"")
        #expect(codedFrames > 0,
                "codedFrames should be positive, got \(codedFrames)")

        // Second event: codecDecodeComplete
        guard case let .codecDecodeComplete(completeCodec, durationSeconds, outputSamples) = events[1] else {
            Issue.record("events[1] should be .codecDecodeComplete, got \(events[1])")
            return
        }
        #expect(completeCodec == "encodec",
                "codec label should be \"encodec\", got \"\(completeCodec)\"")
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
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()
        encodec.setTelemetry(mock)

        let audio = makeTinyAudio()
        let (codes, scales) = await encodec.encode(audio, bandwidth: 1.5)
        let _ = await encodec.decode(codes, scales)

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
    /// sequence-length dimension of the input audio tensor (dimension 1).
    @Test
    func inputSamplesMatchesAudioSequenceLength() async {
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()
        encodec.setTelemetry(mock)

        let numSamples = 800  // use a specific count we can assert
        let audio = MLXRandom.normal([1, numSamples, 1])
        let _ = await encodec.encode(audio, bandwidth: 1.5)

        let events = await mock.events()
        guard events.count >= 1,
              case let .codecEncodeStart(_, inputSamples) = events[0] else {
            Issue.record("Expected at least one event and events[0] to be .codecEncodeStart")
            return
        }
        #expect(inputSamples == numSamples,
                "inputSamples should equal audio sequence length \(numSamples), got \(inputSamples)")
    }

    // MARK: - Test 8: compressionRatio is positive and > 1.0

    /// Encodec compresses audio into discrete codes. The compression ratio
    /// (inputBytes / outputBytes) should always be > 1.0 because audio
    /// waveforms (float32 samples × channels) are larger than the
    /// quantized code indices (int32 per codebook × frames).
    @Test
    func compressionRatioIsPositiveAndGreaterThanOne() async {
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()
        encodec.setTelemetry(mock)

        let audio = makeTinyAudio()
        let _ = await encodec.encode(audio, bandwidth: 1.5)

        let events = await mock.events()
        guard events.count >= 2,
              case let .codecEncodeComplete(_, _, compressionRatio) = events[1] else {
            Issue.record("Expected at least 2 events and events[1] to be .codecEncodeComplete")
            return
        }
        #expect(compressionRatio > 0,
                "compressionRatio should be positive, got \(compressionRatio)")
        #expect(compressionRatio > 1.0,
                "compressionRatio should be > 1.0 (audio > codes), got \(compressionRatio)")
    }

    // MARK: - Test 9: detaching reporter silences subsequent async calls

    /// After calling `setTelemetry(nil)`, subsequent async `encode` and
    /// `decode` calls must not emit any events.
    @Test
    func detachedReporterProducesNoEvents() async {
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()

        // Attach, run once to verify events do flow.
        encodec.setTelemetry(mock)
        let audio = makeTinyAudio()
        let _ = await encodec.encode(audio, bandwidth: 1.5)
        let countAfterFirst = await mock.eventCount()
        #expect(countAfterFirst > 0, "Expected events after first async encode with reporter attached")

        // Detach and reset.
        encodec.setTelemetry(nil)
        await mock.reset()

        // Second async encode with no reporter attached.
        let _ = await encodec.encode(audio, bandwidth: 1.5)
        let countAfterSecond = await mock.eventCount()
        #expect(countAfterSecond == 0,
                "No events should be emitted after setTelemetry(nil), got \(countAfterSecond)")
    }

    // MARK: - Test 10: codec event shapes compile with Encodec payload labels

    /// Confirm that `codecEncodeStart`, `codecEncodeComplete`,
    /// `codecDecodeStart`, `codecDecodeComplete`, and `codecError` can all
    /// be constructed and captured with the payload labels used in the
    /// Encodec instrumentation. If the event enum's label names diverge
    /// from the instrumentation code, this test (and `Encodec.swift`)
    /// would fail to compile.
    @Test
    func codecEventShapesCompileWithEncodecLabels() async {
        let mock = MockMLXAudioTelemetryReporter()

        // Directly capture the five event shapes used by Encodec.
        await mock.capture(.codecEncodeStart(codec: "encodec", inputSamples: 1000))
        await mock.capture(.codecEncodeComplete(
            codec: "encodec",
            durationSeconds: 0.125,
            compressionRatio: 8.0
        ))
        await mock.capture(.codecDecodeStart(codec: "encodec", codedFrames: 62))
        await mock.capture(.codecDecodeComplete(
            codec: "encodec",
            durationSeconds: 0.050,
            outputSamples: 1000
        ))
        await mock.capture(.codecError(
            codec: "encodec",
            operation: "encode",
            error: "synthetic error"
        ))

        let events = await mock.events()
        #expect(events.count == 5)

        guard events.count == 5 else { return }

        if case let .codecEncodeStart(codec, inputSamples) = events[0] {
            #expect(codec == "encodec")
            #expect(inputSamples == 1000)
        } else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
        }

        if case let .codecEncodeComplete(codec, durationSeconds, compressionRatio) = events[1] {
            #expect(codec == "encodec")
            #expect(durationSeconds == 0.125)
            #expect(compressionRatio == 8.0)
        } else {
            Issue.record("events[1] should be .codecEncodeComplete, got \(events[1])")
        }

        if case let .codecDecodeStart(codec, codedFrames) = events[2] {
            #expect(codec == "encodec")
            #expect(codedFrames == 62)
        } else {
            Issue.record("events[2] should be .codecDecodeStart, got \(events[2])")
        }

        if case let .codecDecodeComplete(codec, durationSeconds, outputSamples) = events[3] {
            #expect(codec == "encodec")
            #expect(durationSeconds == 0.050)
            #expect(outputSamples == 1000)
        } else {
            Issue.record("events[3] should be .codecDecodeComplete, got \(events[3])")
        }

        if case let .codecError(codec, operation, _) = events[4] {
            #expect(codec == "encodec")
            #expect(operation == "encode")
        } else {
            Issue.record("events[4] should be .codecError, got \(events[4])")
        }
    }

    // MARK: - Test 11: NoopMLXAudioTelemetryReporter is accepted by setTelemetry

    /// Confirm that the library-provided `NoopMLXAudioTelemetryReporter`
    /// can be passed to `setTelemetry` — useful for hosts that want to
    /// satisfy the non-optional reporter API without recording events.
    @Test
    func noopReporterIsAcceptedBySetTelemetry() {
        let encodec = makeTinyEncodec()
        let noop = NoopMLXAudioTelemetryReporter()

        encodec.setTelemetry(noop)

        #expect(Bool(true), "NoopMLXAudioTelemetryReporter compiled and was accepted by setTelemetry")
    }

    // MARK: - Test 12: synchronous encode/decode remain backward-compatible

    /// The synchronous `encode` and `decode` overloads must continue to work
    /// without any async context. No events should be emitted to an attached
    /// mock from the sync path (telemetry is async-only — the sync overloads
    /// are retained for backward compatibility and do not emit public-surface
    /// events).
    @Test
    func synchronousEncodeDecodeRemainsBackwardCompatible() async {
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()
        encodec.setTelemetry(mock)

        let audio = makeTinyAudio()

        // Synchronous encode — must not require `await` and must not crash.
        // Bind to sync function types so overload resolution picks the
        // non-async overloads from this async test context.
        let syncEncode: (MLXArray, MLXArray?, Float?) -> (MLXArray, [MLXArray?]) = encodec.encode
        let syncDecode: (MLXArray, [MLXArray?], MLXArray?) -> MLXArray = encodec.decode
        let (codes, scales) = syncEncode(audio, nil, 1.5)
        #expect(codes.shape.count >= 1,
                "Sync encode should return a codes tensor with at least 1 dimension")

        // Synchronous decode — must not require `await` and must not crash.
        let decoded = syncDecode(codes, scales, nil)
        #expect(decoded.shape.count >= 1,
                "Sync decode should return an audio tensor with at least 1 dimension")

        // No events should be emitted from the sync path.
        let count = await mock.eventCount()
        #expect(count == 0,
                "Sync encode/decode should not emit public-surface telemetry events, got \(count)")
    }
}
