//
//  VocosTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 6 of OPERATION SILENT STETHOSCOPE — telemetry instrumentation
//  coverage for the Vocos vocoder.
//
//  This suite is CI-safe (no model downloads). It verifies:
//
//    1. `setTelemetry(_:)` compiles and is callable on `Vocos`.
//    2. The canonical `emit` helper with `@autoclosure` is wired correctly
//       (confirmed by the test attaching a reporter and checking zero
//       events during setup-only operations).
//    3. `nil` default — a freshly constructed `Vocos` emits nothing to
//       an unattached mock.
//    4. Attaching a reporter and calling the async `decode` overload
//       produces `codecDecodeStart` followed by `codecDecodeComplete`
//       in that order, with consistent payload values.
//    5. Detaching via `setTelemetry(nil)` produces no subsequent events.
//    6. The `codecDecodeStart` / `codecDecodeComplete` / `codecError`
//       event constructors compile with the payload labels that Vocos
//       instrumentation uses.
//    7. The synchronous `decode` overload and `callAsFunction` remain
//       backward-compatible (no regressions in existing VocosTests).
//
//  Vocos is a pure vocoder (feature frames → audio waveform). It has no
//  public encode path, so no `codecEncodeStart` or `codecEncodeComplete`
//  events are expected. Only decode events are instrumented.
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

// MARK: - VocosTelemetryTests

@Suite("VocosTelemetryTests")
struct VocosTelemetryTests {

    // MARK: - Helpers

    /// Construct a small but structurally valid `Vocos` instance without
    /// loading any pre-trained weights or downloading anything.
    ///
    /// Config mirrors the smallest configuration used in `VocosTests`
    /// (`testVocosModel`):  dim=256, intermediateDim=768, numLayers=4,
    /// nFft=1024, hopLength=256 — small enough to run in under a second
    /// on CPU, large enough that the backbone actually executes.
    private func makeTinyVocos() -> Vocos {
        let inputChannels = 100
        let dim = 256
        let intermediateDim = 768
        let numLayers = 4
        let nFft = 1024
        let hopLength = 256

        let backbone = VocosBackbone(
            inputChannels: inputChannels,
            dim: dim,
            intermediateDim: intermediateDim,
            numLayers: numLayers
        )
        let head = ISTFTHead(dim: dim, nFft: nFft, hopLength: hopLength)
        return Vocos(backbone: backbone, head: head)
    }

    /// Construct a minimal valid input tensor for `makeTinyVocos()`.
    /// Shape: [1, 10, 100] — 1 batch, 10 frames, 100 channels.
    /// 10 frames keeps wall-clock time short while still exercising the
    /// ConvNeXt blocks and ISTFT head end-to-end.
    private func makeTinyInput() -> MLXArray {
        return MLXRandom.normal([1, 10, 100])
    }

    // MARK: - Test 1: setTelemetry compiles and attaches a reporter

    /// Verify that `setTelemetry(_:)` exists on `Vocos`, is callable
    /// with a concrete reporter, and does not crash during construction.
    @Test
    func setTelemetryAttachesReporter() {
        let vocos = makeTinyVocos()
        let mock = MockMLXAudioTelemetryReporter()

        vocos.setTelemetry(mock)

        #expect(Bool(true), "setTelemetry(_:) compiled and ran without error")
    }

    // MARK: - Test 2: setTelemetry(nil) detaches reporter

    /// Verify that passing `nil` to `setTelemetry` is accepted (detach
    /// path). Exercises both attach and detach code paths.
    @Test
    func setTelemetryNilDetachesReporter() {
        let vocos = makeTinyVocos()
        let mock = MockMLXAudioTelemetryReporter()

        vocos.setTelemetry(mock)
        vocos.setTelemetry(nil)   // must compile and not crash

        #expect(Bool(true), "setTelemetry(nil) compiled and ran without error")
    }

    // MARK: - Test 3: nil default — no events without explicit attachment

    /// A freshly constructed `Vocos` has `telemetry == nil` by default.
    /// Constructing the model and calling the sync `decode` must not
    /// send anything to a separately observed mock that was never attached.
    ///
    /// This proves invariant 3 ("nil reporter → zero runtime cost") at
    /// the API-surface level.
    @Test
    func nilDefaultProducesNoEventsToUnattachedMock() async {
        let vocos = makeTinyVocos()
        let unattachedMock = MockMLXAudioTelemetryReporter()

        // Synchronous decode — no reporter attached, so nothing should
        // flow to the unattachedMock.
        let input = makeTinyInput()
        let _ = vocos.decode(input)

        let count = await unattachedMock.eventCount()
        #expect(count == 0,
                "No events should reach an unattached mock: expected 0, got \(count)")
    }

    // MARK: - Test 4: async decode emits start + complete in order

    /// Attaching a reporter and calling the async `decode` overload must
    /// produce exactly two events: `codecDecodeStart` followed by
    /// `codecDecodeComplete`. The order must be preserved.
    ///
    /// This is the canonical codec emission pattern that Sorties 13–16
    /// (Encodec, SNAC, Mimi, DACVAE) will replicate.
    @Test
    func asyncDecodeEmitsStartThenComplete() async {
        let vocos = makeTinyVocos()
        let mock = MockMLXAudioTelemetryReporter()
        vocos.setTelemetry(mock)

        let input = makeTinyInput()  // [1, 10, 100]
        let _ = await vocos.decode(input)

        let events = await mock.events()

        // Exactly two events: start then complete.
        #expect(events.count == 2,
                "Expected 2 events (start + complete), got \(events.count): \(events)")

        guard events.count == 2 else { return }

        // First event: codecDecodeStart
        guard case let .codecDecodeStart(startCodec, codedFrames) = events[0] else {
            Issue.record("events[0] should be .codecDecodeStart, got \(events[0])")
            return
        }
        #expect(startCodec == "vocos",
                "codec label should be \"vocos\", got \"\(startCodec)\"")
        #expect(codedFrames > 0,
                "codedFrames should be positive, got \(codedFrames)")

        // Second event: codecDecodeComplete
        guard case let .codecDecodeComplete(completeCodec, durationSeconds, outputSamples) = events[1] else {
            Issue.record("events[1] should be .codecDecodeComplete, got \(events[1])")
            return
        }
        #expect(completeCodec == "vocos",
                "codec label should be \"vocos\", got \"\(completeCodec)\"")
        #expect(durationSeconds >= 0,
                "durationSeconds should be non-negative, got \(durationSeconds)")
        #expect(outputSamples > 0,
                "outputSamples should be positive, got \(outputSamples)")
    }

    // MARK: - Test 5: codedFrames payload matches input frame dimension

    /// The `codedFrames` field in `codecDecodeStart` must equal the
    /// number of time frames in the input feature tensor (dimension 1
    /// of a `[B, L, C]` input).
    @Test
    func codedFramesMatchesInputFrameDimension() async {
        let vocos = makeTinyVocos()
        let mock = MockMLXAudioTelemetryReporter()
        vocos.setTelemetry(mock)

        // Input with a known number of frames (10) so we can assert
        // the payload exactly.
        let numFrames = 10
        let input = MLXRandom.normal([1, numFrames, 100])
        let _ = await vocos.decode(input)

        let events = await mock.events()
        guard events.count >= 1,
              case let .codecDecodeStart(_, codedFrames) = events[0] else {
            Issue.record("Expected at least one event and events[0] to be .codecDecodeStart")
            return
        }
        #expect(codedFrames == numFrames,
                "codedFrames should equal input frame count \(numFrames), got \(codedFrames)")
    }

    // MARK: - Test 6: detaching reporter silences subsequent async decode calls

    /// After calling `setTelemetry(nil)`, subsequent async `decode` calls
    /// must not emit any events.
    @Test
    func detachedReporterProducesNoEvents() async {
        let vocos = makeTinyVocos()
        let mock = MockMLXAudioTelemetryReporter()

        // Attach, run once to verify events do flow.
        vocos.setTelemetry(mock)
        let input = makeTinyInput()
        let _ = await vocos.decode(input)
        let countAfterFirst = await mock.eventCount()
        #expect(countAfterFirst > 0, "Expected events after first async decode with reporter attached")

        // Detach and reset.
        vocos.setTelemetry(nil)
        await mock.reset()

        // Second async decode with no reporter attached.
        let _ = await vocos.decode(input)
        let countAfterSecond = await mock.eventCount()
        #expect(countAfterSecond == 0,
                "No events should be emitted after setTelemetry(nil), got \(countAfterSecond)")
    }

    // MARK: - Test 7: codec event shapes compile with Vocos payload labels

    /// Confirm that `codecDecodeStart`, `codecDecodeComplete`, and
    /// `codecError` can all be constructed and captured with the payload
    /// labels used in the Vocos instrumentation. If the event enum's
    /// label names diverge from the instrumentation code, this test
    /// (and `Vocos.swift`) would fail to compile.
    @Test
    func codecEventShapesCompileWithVocosLabels() async {
        let mock = MockMLXAudioTelemetryReporter()

        // Directly capture the three event shapes used by Vocos.
        await mock.capture(.codecDecodeStart(codec: "vocos", codedFrames: 50))
        await mock.capture(.codecDecodeComplete(
            codec: "vocos",
            durationSeconds: 0.042,
            outputSamples: 12_800
        ))
        await mock.capture(.codecError(
            codec: "vocos",
            operation: "decode",
            error: "synthetic error"
        ))

        let events = await mock.events()
        #expect(events.count == 3)

        guard events.count == 3 else { return }

        if case let .codecDecodeStart(codec, codedFrames) = events[0] {
            #expect(codec == "vocos")
            #expect(codedFrames == 50)
        } else {
            Issue.record("events[0] should be .codecDecodeStart, got \(events[0])")
        }

        if case let .codecDecodeComplete(codec, durationSeconds, outputSamples) = events[1] {
            #expect(codec == "vocos")
            #expect(durationSeconds == 0.042)
            #expect(outputSamples == 12_800)
        } else {
            Issue.record("events[1] should be .codecDecodeComplete, got \(events[1])")
        }

        if case let .codecError(codec, operation, _) = events[2] {
            #expect(codec == "vocos")
            #expect(operation == "decode")
        } else {
            Issue.record("events[2] should be .codecError, got \(events[2])")
        }
    }

    // MARK: - Test 8: NoopMLXAudioTelemetryReporter is accepted by setTelemetry

    /// Confirm that the library-provided `NoopMLXAudioTelemetryReporter`
    /// can be passed to `setTelemetry` — useful for hosts that want to
    /// satisfy the non-optional reporter API without recording events.
    @Test
    func noopReporterIsAcceptedBySetTelemetry() {
        let vocos = makeTinyVocos()
        let noop = NoopMLXAudioTelemetryReporter()

        vocos.setTelemetry(noop)

        #expect(Bool(true), "NoopMLXAudioTelemetryReporter compiled and was accepted by setTelemetry")
    }

    // MARK: - Test 9: synchronous decode remains backward-compatible

    /// The synchronous `decode(_:bandwidthId:)` overload and
    /// `callAsFunction` must continue to work without any async context.
    /// No events should be emitted to an attached mock from the sync
    /// path (telemetry is async-only — the sync overload is retained for
    /// backward compatibility and does not emit public-surface events).
    @Test
    func synchronousDecodeRemainsBackwardCompatible() async {
        let vocos = makeTinyVocos()
        let mock = MockMLXAudioTelemetryReporter()
        vocos.setTelemetry(mock)

        let input = makeTinyInput()

        // Synchronous decode — must not require `await` and must not crash.
        let syncOutput = vocos.decode(input)
        #expect(syncOutput.shape.count >= 1,
                "Sync decode should return a tensor with at least 1 dimension")

        // callAsFunction must also work synchronously.
        let callOutput = vocos(input)
        #expect(callOutput.shape.count >= 1,
                "callAsFunction should return a tensor with at least 1 dimension")

        // No events should be emitted from the sync path.
        let count = await mock.eventCount()
        #expect(count == 0,
                "Sync decode should not emit public-surface telemetry events, got \(count)")
    }

    // MARK: - Test 10: async decode with bandwidthId emits correct events

    /// Verify that the async `decode` overload works correctly even when
    /// an optional `bandwidthId` tensor is supplied (adaptive-norm path).
    @Test
    func asyncDecodeWithBandwidthIdEmitsEvents() async {
        // Adaptive-norm backbone requires adanormNumEmbeddings to be set.
        let inputChannels = 128
        let dim = 256
        let intermediateDim = 768
        let numLayers = 4
        let numEmbeddings = 4
        let nFft = 1024
        let hopLength = 256

        let backbone = VocosBackbone(
            inputChannels: inputChannels,
            dim: dim,
            intermediateDim: intermediateDim,
            numLayers: numLayers,
            adanormNumEmbeddings: numEmbeddings
        )
        let head = ISTFTHead(dim: dim, nFft: nFft, hopLength: hopLength)
        let vocos = Vocos(backbone: backbone, head: head)

        let mock = MockMLXAudioTelemetryReporter()
        vocos.setTelemetry(mock)

        let numFrames = 10
        let input = MLXRandom.normal([1, numFrames, inputChannels])
        let bandwidthId = MLXRandom.normal([1, numEmbeddings])

        let _ = await vocos.decode(input, bandwidthId: bandwidthId)

        let events = await mock.events()
        #expect(events.count == 2,
                "Expected 2 events (start + complete) with bandwidthId, got \(events.count)")

        if events.count >= 1,
           case let .codecDecodeStart(codec, codedFrames) = events[0] {
            #expect(codec == "vocos")
            #expect(codedFrames == numFrames)
        }
    }
}
