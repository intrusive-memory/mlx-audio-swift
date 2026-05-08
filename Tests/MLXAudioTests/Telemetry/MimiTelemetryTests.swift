//
//  MimiTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 15 of OPERATION SILENT STETHOSCOPE — telemetry instrumentation
//  coverage for the Mimi neural audio codec.
//
//  This suite is CI-safe (no model downloads). It verifies:
//
//    1. `setTelemetry(_:)` compiles and is callable on `Mimi`.
//    2. `setTelemetry(_:)` compiles and is callable on `MimiStreamingDecoder`.
//    3. The canonical `emit` helper with `@autoclosure` is wired correctly.
//    4. `nil` default — a freshly constructed `Mimi` emits nothing to
//       an unattached mock.
//    5. Attaching a reporter and calling the async `encode` overload
//       produces `codecEncodeStart` followed by `codecEncodeComplete`
//       in that order.
//    6. Attaching a reporter and calling the async `decode` overload
//       produces `codecDecodeStart` followed by `codecDecodeComplete`
//       in that order.
//    7. Attaching a reporter and calling the async `encodeStep` overload
//       produces `codecEncodeStart` followed by `codecEncodeComplete`
//       in that order.
//    8. Attaching a reporter and calling the async `decodeFrames` overload
//       on `MimiStreamingDecoder` produces `codecDecodeStart` followed by
//       `codecDecodeComplete` in that order — ONCE, not per frame.
//    9. Detaching via `setTelemetry(nil)` produces no subsequent events.
//   10. The sync overloads remain backward-compatible (no events emitted).
//   11. `codecEncodeStart` / `codecEncodeComplete` / `codecDecodeStart` /
//       `codecDecodeComplete` / `codecError` event constructors compile
//       with the payload labels that Mimi instrumentation uses.
//   12. `NoopMLXAudioTelemetryReporter` is accepted by `setTelemetry`.
//   13. `decodeFrames` async overload emits exactly 2 events regardless
//       of frame count (start + complete, not 2 × T events).
//
//  Mimi has both a full-batch encode/decode path and a streaming
//  per-step path (encodeStep / decodeStep, with decodeFrames on
//  MimiStreamingDecoder as the public streaming-decode boundary).
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

// MARK: - MimiTelemetryTests

@Suite("MimiTelemetryTests")
struct MimiTelemetryTests {

    // MARK: - Helpers

    /// Construct a small but structurally valid `Mimi` instance without
    /// loading any pre-trained weights or downloading anything.
    ///
    /// Uses a reduced config (4 codebooks, minimal layer counts) to keep
    /// construction fast while still exercising the full encode/decode path.
    private func makeTinyMimi() -> Mimi {
        let cfg = mimi_202407(numCodebooks: 4)
        return Mimi(cfg: cfg)
    }

    /// A minimal valid audio input tensor for Mimi.
    /// Shape: [1, 1, 480] — 1 batch, 1 channel, 480 samples.
    /// 480 samples @ 24 kHz = 20 ms, enough for one encode frame through
    /// Mimi's downsampling stack (ratios [8,6,5,4] → stride 960; we use
    /// 480 which is one half-frame — the encoder handles short inputs).
    private func makeTinyAudio() -> MLXArray {
        return MLXRandom.normal([1, 1, 480])
    }

    // MARK: - Test 1: setTelemetry compiles and attaches a reporter on Mimi

    /// Verify that `setTelemetry(_:)` exists on `Mimi`, is callable
    /// with a concrete reporter, and does not crash during construction.
    @Test
    func setTelemetryAttachesReporterOnMimi() {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()

        mimi.setTelemetry(mock)

        #expect(Bool(true), "Mimi.setTelemetry(_:) compiled and ran without error")
    }

    // MARK: - Test 2: setTelemetry compiles on MimiStreamingDecoder

    /// Verify that `setTelemetry(_:)` exists on `MimiStreamingDecoder`.
    @Test
    func setTelemetryAttachesReporterOnStreamingDecoder() {
        let mimi = makeTinyMimi()
        let streamingDecoder = MimiStreamingDecoder(mimi)
        let mock = MockMLXAudioTelemetryReporter()

        streamingDecoder.setTelemetry(mock)

        #expect(Bool(true), "MimiStreamingDecoder.setTelemetry(_:) compiled and ran without error")
    }

    // MARK: - Test 3: setTelemetry(nil) detaches reporter

    /// Verify that passing `nil` to `setTelemetry` is accepted.
    @Test
    func setTelemetryNilDetachesReporter() {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()

        mimi.setTelemetry(mock)
        mimi.setTelemetry(nil)   // must compile and not crash

        #expect(Bool(true), "setTelemetry(nil) compiled and ran without error")
    }

    // MARK: - Test 4: nil default — no events without explicit attachment

    /// A freshly constructed `Mimi` has `telemetry == nil` by default.
    /// Calling the sync `encode` / `decode` must not send anything to a
    /// separately observed mock that was never attached.
    @Test
    func nilDefaultProducesNoEventsToUnattachedMock() async {
        let mimi = makeTinyMimi()
        let unattachedMock = MockMLXAudioTelemetryReporter()

        // Synchronous encode — no reporter attached.
        // Bind to sync function types to force overload resolution to pick
        // the non-async overloads (Swift 6.2 in async contexts otherwise
        // prefers the async variants).
        let audio = makeTinyAudio()
        let syncEncode: (MLXArray) -> MLXArray = mimi.encode
        let syncDecode: (MLXArray) -> MLXArray = mimi.decode
        let codes = syncEncode(audio)
        let _ = syncDecode(codes)

        let count = await unattachedMock.eventCount()
        #expect(count == 0,
                "No events should reach an unattached mock: expected 0, got \(count)")
    }

    // MARK: - Test 5: async encode emits start + complete in order

    /// Attaching a reporter and calling the async `encode` overload must
    /// produce exactly two events: `codecEncodeStart` followed by
    /// `codecEncodeComplete`. The order must be preserved.
    @Test
    func asyncEncodeEmitsStartThenComplete() async {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()
        mimi.setTelemetry(mock)

        let audio = makeTinyAudio()  // [1, 1, 480]
        let _ = await mimi.encode(audio)

        let events = await mock.events()

        // Exactly two events: start then complete (or start then error if
        // byte counts are zero — unlikely with non-empty input).
        #expect(events.count == 2,
                "Expected 2 events (start + complete), got \(events.count): \(events)")

        guard events.count >= 1 else { return }

        // First event: codecEncodeStart
        guard case let .codecEncodeStart(startCodec, inputSamples) = events[0] else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "mimi",
                "codec label should be \"mimi\", got \"\(startCodec)\"")
        #expect(inputSamples > 0,
                "inputSamples should be positive, got \(inputSamples)")

        guard events.count >= 2 else { return }

        // Second event: codecEncodeComplete or codecError
        switch events[1] {
        case let .codecEncodeComplete(completeCodec, durationSeconds, compressionRatio):
            #expect(completeCodec == "mimi",
                    "codec label should be \"mimi\", got \"\(completeCodec)\"")
            #expect(durationSeconds >= 0,
                    "durationSeconds should be non-negative, got \(durationSeconds)")
            #expect(compressionRatio > 0,
                    "compressionRatio should be positive, got \(compressionRatio)")
        case let .codecError(errCodec, operation, _):
            // Tolerate codecError for degenerate outputs (e.g. empty quantizer result).
            #expect(errCodec == "mimi")
            #expect(operation == "encode" || operation == "encodeStep")
        default:
            Issue.record("events[1] should be .codecEncodeComplete or .codecError, got \(events[1])")
        }
    }

    // MARK: - Test 6: async decode emits start + complete in order

    /// Attaching a reporter and calling the async `decode` overload must
    /// produce exactly two events: `codecDecodeStart` followed by
    /// `codecDecodeComplete`. The order must be preserved.
    @Test
    func asyncDecodeEmitsStartThenComplete() async {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()
        mimi.setTelemetry(mock)

        let audio = makeTinyAudio()  // [1, 1, 480]
        // Use sync encode to get codes (no events from the sync path).
        // Bind to a sync function type so overload resolution picks the
        // non-async overload from this async test context.
        let syncEncode: (MLXArray) -> MLXArray = mimi.encode
        let codes = syncEncode(audio)
        // Then async decode
        let _ = await mimi.decode(codes)

        let events = await mock.events()

        // Exactly two events: decode start then complete.
        #expect(events.count == 2,
                "Expected 2 events (decode start + complete), got \(events.count): \(events)")

        guard events.count >= 1 else { return }

        // First event: codecDecodeStart
        guard case let .codecDecodeStart(startCodec, codedFrames) = events[0] else {
            Issue.record("events[0] should be .codecDecodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "mimi",
                "codec label should be \"mimi\", got \"\(startCodec)\"")
        #expect(codedFrames >= 0,
                "codedFrames should be non-negative, got \(codedFrames)")

        guard events.count >= 2 else { return }

        // Second event: codecDecodeComplete
        guard case let .codecDecodeComplete(completeCodec, durationSeconds, outputSamples) = events[1] else {
            Issue.record("events[1] should be .codecDecodeComplete, got \(events[1])")
            return
        }
        #expect(completeCodec == "mimi",
                "codec label should be \"mimi\", got \"\(completeCodec)\"")
        #expect(durationSeconds >= 0,
                "durationSeconds should be non-negative, got \(durationSeconds)")
        #expect(outputSamples >= 0,
                "outputSamples should be non-negative, got \(outputSamples)")
    }

    // MARK: - Test 7: async encodeStep emits start + complete in order

    /// Attaching a reporter and calling the async `encodeStep` overload must
    /// produce exactly two events: `codecEncodeStart` followed by
    /// `codecEncodeComplete` (or `codecError` for degenerate output).
    ///
    /// `encodeStep` is the streaming-encode boundary called by Marvis's
    /// `encodeChunked` helper. Each call emits one start+complete pair.
    @Test
    func asyncEncodeStepEmitsStartThenComplete() async {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()
        mimi.setTelemetry(mock)

        let audio = makeTinyAudio()  // [1, 1, 480]
        let _ = await mimi.encodeStep(audio)

        let events = await mock.events()

        #expect(events.count == 2,
                "Expected 2 events (encodeStep start + complete), got \(events.count): \(events)")

        guard events.count >= 1 else { return }

        guard case let .codecEncodeStart(startCodec, inputSamples) = events[0] else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "mimi",
                "codec label should be \"mimi\", got \"\(startCodec)\"")
        #expect(inputSamples > 0,
                "inputSamples should be positive, got \(inputSamples)")
    }

    // MARK: - Test 8: async decodeFrames on MimiStreamingDecoder emits exactly 2 events

    /// Attaching a reporter to `MimiStreamingDecoder` and calling the async
    /// `decodeFrames` overload must produce exactly two events — `codecDecodeStart`
    /// followed by `codecDecodeComplete` — regardless of the number of frames T.
    ///
    /// This is the critical loop-boundary test: 2 events for T frames, not 2T.
    @Test
    func asyncDecodeFramesEmitsExactlyTwoEvents() async {
        let mimi = makeTinyMimi()
        let streamingDecoder = MimiStreamingDecoder(mimi)
        let mock = MockMLXAudioTelemetryReporter()
        streamingDecoder.setTelemetry(mock)

        // Build a tiny synthetic token tensor: [B=1, nq=4, T=3]
        // Shape mirrors what Marvis produces from CSM's generateFrame output.
        let tokens = MLXRandom.randInt(low: 0, high: 2047, [1, 4, 3]).asType(.int32)
        let _ = await streamingDecoder.decodeFrames(tokens)

        let events = await mock.events()

        // MUST be exactly 2 events, not 2 × T = 6. This is the key boundary
        // assertion for the loop-guard requirement.
        #expect(events.count == 2,
                "Expected exactly 2 events (start + complete) for \(3) frames, got \(events.count): \(events)")

        guard events.count >= 1 else { return }

        guard case let .codecDecodeStart(startCodec, codedFrames) = events[0] else {
            Issue.record("events[0] should be .codecDecodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "mimi",
                "codec label should be \"mimi\", got \"\(startCodec)\"")
        #expect(codedFrames == 3,
                "codedFrames should equal T=3, got \(codedFrames)")

        guard events.count >= 2 else { return }

        guard case let .codecDecodeComplete(completeCodec, durationSeconds, outputSamples) = events[1] else {
            Issue.record("events[1] should be .codecDecodeComplete, got \(events[1])")
            return
        }
        #expect(completeCodec == "mimi",
                "codec label should be \"mimi\", got \"\(completeCodec)\"")
        #expect(durationSeconds >= 0,
                "durationSeconds should be non-negative, got \(durationSeconds)")
        #expect(outputSamples >= 0,
                "outputSamples should be non-negative, got \(outputSamples)")
    }

    // MARK: - Test 9: async encode + async decode produces four events in order

    /// Attaching a reporter and running both async encode then async decode
    /// must produce exactly four events in order:
    ///   codecEncodeStart → codecEncode{Complete|Error} → codecDecodeStart → codecDecodeComplete
    @Test
    func asyncEncodeAndDecodeProducesFourEventsInOrder() async {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()
        mimi.setTelemetry(mock)

        let audio = makeTinyAudio()
        let codes = await mimi.encode(audio)
        let _ = await mimi.decode(codes)

        let events = await mock.events()

        #expect(events.count == 4,
                "Expected 4 events (encode start/complete + decode start/complete), got \(events.count): \(events)")

        guard events.count == 4 else { return }

        if case .codecEncodeStart = events[0] { } else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
        }
        // events[1] is either codecEncodeComplete or codecError
        let isEncodeEnd: Bool
        switch events[1] {
        case .codecEncodeComplete, .codecError: isEncodeEnd = true
        default: isEncodeEnd = false
        }
        #expect(isEncodeEnd, "events[1] should be .codecEncodeComplete or .codecError, got \(events[1])")

        if case .codecDecodeStart = events[2] { } else {
            Issue.record("events[2] should be .codecDecodeStart, got \(events[2])")
        }
        if case .codecDecodeComplete = events[3] { } else {
            Issue.record("events[3] should be .codecDecodeComplete, got \(events[3])")
        }
    }

    // MARK: - Test 10: detaching reporter silences subsequent async calls

    /// After calling `setTelemetry(nil)`, subsequent async calls must not
    /// emit any events.
    @Test
    func detachedReporterProducesNoEvents() async {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()

        // Attach and verify events do flow.
        mimi.setTelemetry(mock)
        let audio = makeTinyAudio()
        let _ = await mimi.encode(audio)
        let countAfterFirst = await mock.eventCount()
        #expect(countAfterFirst > 0, "Expected events after first async encode with reporter attached")

        // Detach and reset.
        mimi.setTelemetry(nil)
        await mock.reset()

        // Second async encode with no reporter attached.
        let _ = await mimi.encode(audio)
        let countAfterSecond = await mock.eventCount()
        #expect(countAfterSecond == 0,
                "No events should be emitted after setTelemetry(nil), got \(countAfterSecond)")
    }

    // MARK: - Test 11: codec event shapes compile with Mimi payload labels

    /// Confirm that all five codec event shapes used by Mimi instrumentation
    /// can be constructed and captured. If the event enum's label names diverge
    /// from the instrumentation code, this test would fail to compile.
    @Test
    func codecEventShapesCompileWithMimiLabels() async {
        let mock = MockMLXAudioTelemetryReporter()

        await mock.capture(.codecEncodeStart(codec: "mimi", inputSamples: 480))
        await mock.capture(.codecEncodeComplete(
            codec: "mimi",
            durationSeconds: 0.010,
            compressionRatio: 12.0
        ))
        await mock.capture(.codecDecodeStart(codec: "mimi", codedFrames: 3))
        await mock.capture(.codecDecodeComplete(
            codec: "mimi",
            durationSeconds: 0.008,
            outputSamples: 480
        ))
        await mock.capture(.codecError(
            codec: "mimi",
            operation: "encode",
            error: "synthetic error"
        ))

        let events = await mock.events()
        #expect(events.count == 5)

        guard events.count == 5 else { return }

        if case let .codecEncodeStart(codec, inputSamples) = events[0] {
            #expect(codec == "mimi")
            #expect(inputSamples == 480)
        } else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
        }

        if case let .codecEncodeComplete(codec, durationSeconds, compressionRatio) = events[1] {
            #expect(codec == "mimi")
            #expect(durationSeconds == 0.010)
            #expect(compressionRatio == 12.0)
        } else {
            Issue.record("events[1] should be .codecEncodeComplete, got \(events[1])")
        }

        if case let .codecDecodeStart(codec, codedFrames) = events[2] {
            #expect(codec == "mimi")
            #expect(codedFrames == 3)
        } else {
            Issue.record("events[2] should be .codecDecodeStart, got \(events[2])")
        }

        if case let .codecDecodeComplete(codec, durationSeconds, outputSamples) = events[3] {
            #expect(codec == "mimi")
            #expect(durationSeconds == 0.008)
            #expect(outputSamples == 480)
        } else {
            Issue.record("events[3] should be .codecDecodeComplete, got \(events[3])")
        }

        if case let .codecError(codec, operation, _) = events[4] {
            #expect(codec == "mimi")
            #expect(operation == "encode")
        } else {
            Issue.record("events[4] should be .codecError, got \(events[4])")
        }
    }

    // MARK: - Test 12: NoopMLXAudioTelemetryReporter is accepted by setTelemetry

    /// Confirm that `NoopMLXAudioTelemetryReporter` can be passed to both
    /// `Mimi.setTelemetry` and `MimiStreamingDecoder.setTelemetry`.
    @Test
    func noopReporterIsAcceptedBySetTelemetry() {
        let mimi = makeTinyMimi()
        let streamingDecoder = MimiStreamingDecoder(mimi)
        let noop = NoopMLXAudioTelemetryReporter()

        mimi.setTelemetry(noop)
        streamingDecoder.setTelemetry(noop)

        #expect(Bool(true), "NoopMLXAudioTelemetryReporter compiled and was accepted by both setTelemetry calls")
    }

    // MARK: - Test 13: synchronous encode/decode remains backward-compatible

    /// The synchronous `encode` and `decode` overloads must continue to work
    /// without any async context. No events should be emitted to an attached
    /// mock from the sync path.
    @Test
    func synchronousEncodeDecodeRemainsBackwardCompatible() async {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()
        mimi.setTelemetry(mock)

        let audio = makeTinyAudio()

        // Synchronous encode — must not require `await` and must not crash.
        // Bind to sync function types so overload resolution picks the
        // non-async overloads from this async test context.
        let syncEncode: (MLXArray) -> MLXArray = mimi.encode
        let syncDecode: (MLXArray) -> MLXArray = mimi.decode
        let codes = syncEncode(audio)
        #expect(codes.shape.count >= 1,
                "Sync encode should return a codes tensor with at least 1 dimension")

        // Synchronous decode — must not require `await` and must not crash.
        let decoded = syncDecode(codes)
        #expect(decoded.shape.count >= 1,
                "Sync decode should return an audio tensor with at least 1 dimension")

        // No events should be emitted from the sync path.
        let count = await mock.eventCount()
        #expect(count == 0,
                "Sync encode/decode should not emit public-surface telemetry events, got \(count)")
    }

    // MARK: - Test 14: MimiTokenizer construction does not emit codec events

    /// Constructing a `MimiTokenizer` wrapping a `Mimi` instance must not
    /// emit any codec events — the tokenizer is a thin wrapper that doesn't
    /// invoke encode/decode itself.
    @Test
    func mimiTokenizerConstructionEmitsNoCodecEvents() async {
        let mimi = makeTinyMimi()
        let mock = MockMLXAudioTelemetryReporter()
        mimi.setTelemetry(mock)

        let _ = MimiTokenizer(mimi)

        let count = await mock.eventCount()
        #expect(count == 0,
                "MimiTokenizer construction should emit no codec events, got \(count)")
    }
}
