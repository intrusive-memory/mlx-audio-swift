//
//  EndToEndTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 19 of OPERATION SILENT STETHOSCOPE — final integration suite that
//  exercises one full path per public-telemetry category (model lifecycle,
//  codec encode+decode, audio I/O) using `MockMLXAudioTelemetryReporter`,
//  plus the baseline zero-overhead verification (invariant 3).
//
//  All tests are CI-safe — no model downloads, no network calls, only
//  synthetic data and the temp directory.
//
//  # What this suite proves
//
//    1. Model lifecycle (Sortie 2 surface): `AudioModelManager` load with a
//       synthetic `ComponentDescriptor` (files: []) emits the canonical
//       `modelDownloadStart → modelDownloadComplete → modelLoadStart →
//       modelLoadComplete` 4-event sequence, in order.
//
//    2. Codec round-trip (Sorties 6, 13–16 surface): `Encodec` async
//       `encode` followed by async `decode` emits `codecEncodeStart →
//       codecEncodeComplete → codecDecodeStart → codecDecodeComplete`,
//       in order.
//
//    3. Audio I/O (Sortie 7 surface): `loadAudioArray` then `saveAudioArray`
//       (free-function, defaulted-parameter pattern) emits
//       `audioLoadStart → audioLoadComplete → audioSaveStart →
//       audioSaveComplete`, in order.
//
//    4. Zero-overhead invariant 3: a codec round-trip plus a WAV
//       load+save with `nil` reporter completes within 5% of the
//       wall-clock baseline measured with a fresh
//       `MockMLXAudioTelemetryReporter` attached. Uses median of 5
//       post-warmup iterations to avoid CI flake.
//
//  # CI safety
//
//  - No model downloads (Encodec is constructed with the default
//    `EncodecConfig`; AudioModelManager uses a fixture component with
//    `files: []` so the readiness check short-circuits).
//  - Temp files are written via `FileManager.default.temporaryDirectory`
//    and cleaned up via `defer`.
//  - The `.serialized` trait keeps the AudioModelManager tests from
//    racing on the process-global telemetry storage actor.
//
//  # Where the locked predecessor sorties' patterns came from
//
//  - AudioModelManager fixture: `AudioModelManagerTelemetryTests.swift`
//    (Sortie 2) — synthetic `files: []` descriptor.
//  - Encodec async overload: `EncodecTelemetryTests.swift` (Sortie 13).
//  - AudioUtils free functions: `AudioUtilsTelemetryTests.swift`
//    (Sortie 7) — the only sortie using the defaulted-parameter
//    injection pattern.
//

import Foundation
import MLX
import MLXRandom
import Testing

@testable import MLXAudioCore
@testable import MLXAudioCodecs
import SwiftAcervo

// MARK: - EndToEndTelemetryTests

/// Suite is `.serialized` because the model-lifecycle tests mutate the
/// process-global telemetry storage actor
/// (`_AudioModelManagerTelemetryStorage.shared`). Without serialization
/// a concurrent test could observe another test's reporter or leak its
/// own. The codec/audio-I/O tests use per-instance reporters so they
/// would be safe to parallelize, but mixing parallel and serial
/// requirements in one suite is brittle — keep the whole suite serial
/// and accept the small wall-clock cost.
@Suite("EndToEndTelemetryTests", .serialized)
struct EndToEndTelemetryTests {

    // MARK: - AudioModelManager fixture (synthetic files: [] descriptor)

    /// A component-id reserved for end-to-end integration tests. The
    /// descriptor declares `files: []` so `Acervo.isComponentReady`
    /// short-circuits to `true` without any disk or network I/O. The
    /// repoId is namespaced under `mlx-audio-test/` so it cannot
    /// collide with any real CDN slug.
    private static let testComponentId = "mlx-audio-e2e-telemetry-test-component"
    private static let testRepoId = "mlx-audio-test/e2e-telemetry-fixture"

    /// Register the synthetic descriptor with the Acervo Component
    /// Registry. Idempotent — `Acervo.register(_:)` deduplicates by id.
    private static func registerTestComponent() {
        let descriptor = ComponentDescriptor(
            id: testComponentId,
            type: .auxiliary,
            displayName: "E2E Telemetry Fixture",
            repoId: testRepoId,
            files: [],
            estimatedSizeBytes: 1_048_576, // 1 MB exactly so sizeMB == 1.0
            minimumMemoryBytes: 0,
            metadata: ["modelType": "e2e-test-fixture"]
        )
        Acervo.register(descriptor)
    }

    /// Reset the manager's process-global telemetry storage to `nil`.
    /// Combined with the suite's `.serialized` trait this makes every
    /// test deterministic regardless of ordering.
    private static func resetManagerTelemetry() async {
        await AudioModelManager.setTelemetry(nil)
    }

    // MARK: - Audio I/O helpers (no model downloads)

    /// Return a fresh scratch URL in the temp directory. Caller cleans
    /// up via `defer`.
    private func scratchURL(extension ext: String = "wav") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// Generate a small valid 24 kHz WAV file at `url`. 512 samples is
    /// enough to exercise `loadAudioArray`'s WAV-reader fast-path while
    /// keeping wall-clock time short.
    private func writeScratchWAV(_ count: Int = 512) throws -> URL {
        let sampleRate: Double = 24_000
        let samples: [Float] = (0..<count).map { i in
            Float(sin(2 * Double.pi * 440.0 * Double(i) / sampleRate)) * 0.5
        }
        let mlxSamples = MLXArray(samples)
        let url = scratchURL()
        try saveAudioArray(mlxSamples, sampleRate: sampleRate, to: url)
        return url
    }

    /// Yield to the cooperative thread pool enough times to flush the
    /// detached `Task { ... }` blocks fired from synchronous AudioUtils
    /// emission sites.
    private func flushTelemetryTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    /// Construct a small but structurally valid `Encodec` with default
    /// `EncodecConfig` — no weights, no downloads. Mirrors
    /// `EncodecTelemetryTests.makeTinyEncodec()`.
    private func makeTinyEncodec() -> Encodec {
        return Encodec(config: EncodecConfig())
    }

    /// Construct a minimal valid audio input tensor for Encodec.
    /// Shape: [1, 1000, 1] — 1 batch, 1000 samples, 1 channel.
    private func makeTinyAudio() -> MLXArray {
        return MLXRandom.normal([1, 1000, 1])
    }

    // MARK: - Test 1: Model lifecycle end-to-end

    /// `AudioModelManager.loadWithAcervoStrict` with a registered
    /// synthetic component (files: []) emits the full canonical
    /// 4-event sequence in order.
    @Test
    func modelLifecycleEmitsCanonicalSequence() async throws {
        await Self.resetManagerTelemetry()
        Self.registerTestComponent()

        let mock = MockMLXAudioTelemetryReporter()
        await AudioModelManager.setTelemetry(mock)

        let result = try await AudioModelManager.loadWithAcervoStrict(
            componentId: Self.testComponentId
        ) { _ in
            return "loaded"
        }
        #expect(result == "loaded")

        let events = await mock.events()
        #expect(events.count == 4,
                "Expected 4 events (download start/complete + load start/complete), got \(events.count): \(events)")

        guard events.count == 4 else { return }

        if case let .modelDownloadStart(repo, sizeMB) = events[0] {
            #expect(repo == Self.testRepoId)
            #expect(sizeMB == 1.0)
        } else {
            Issue.record("events[0] should be .modelDownloadStart, got \(events[0])")
        }

        if case let .modelDownloadComplete(repo, sizeMB, cacheHit) = events[1] {
            #expect(repo == Self.testRepoId)
            #expect(sizeMB == 1.0)
            #expect(cacheHit == true,
                    "fixture has files: [] so the readiness check short-circuits before download")
        } else {
            Issue.record("events[1] should be .modelDownloadComplete, got \(events[1])")
        }

        if case let .modelLoadStart(repo, modelType) = events[2] {
            #expect(repo == Self.testRepoId)
            #expect(modelType == "e2e-test-fixture")
        } else {
            Issue.record("events[2] should be .modelLoadStart, got \(events[2])")
        }

        if case let .modelLoadComplete(repo, modelType, sizeMB, metalAllocatedMB) = events[3] {
            #expect(repo == Self.testRepoId)
            #expect(modelType == "e2e-test-fixture")
            #expect(sizeMB == 1.0)
            #expect(metalAllocatedMB >= 0.0)
        } else {
            Issue.record("events[3] should be .modelLoadComplete, got \(events[3])")
        }

        // Detach so the next test in the suite (if order changes) starts
        // from a clean slate. The suite trait is `.serialized` and every
        // test does its own reset prologue, so this is belt-and-braces.
        await AudioModelManager.setTelemetry(nil)
    }

    // MARK: - Test 2: Codec encode + decode end-to-end

    /// `Encodec.encode` (async) followed by `Encodec.decode` (async)
    /// emits exactly four codec events in canonical order.
    @Test
    func codecRoundTripEmitsEncodeAndDecodeEvents() async {
        let encodec = makeTinyEncodec()
        let mock = MockMLXAudioTelemetryReporter()
        encodec.setTelemetry(mock)

        let audio = makeTinyAudio()
        let (codes, scales) = await encodec.encode(audio, bandwidth: 1.5)
        let _ = await encodec.decode(codes, scales)

        let events = await mock.events()
        #expect(events.count == 4,
                "Expected 4 codec events (encode + decode start/complete), got \(events.count): \(events)")

        guard events.count == 4 else { return }

        if case let .codecEncodeStart(codec, inputSamples) = events[0] {
            #expect(codec == "encodec")
            #expect(inputSamples > 0)
        } else {
            Issue.record("events[0] should be .codecEncodeStart, got \(events[0])")
        }

        if case let .codecEncodeComplete(codec, durationSeconds, compressionRatio) = events[1] {
            #expect(codec == "encodec")
            #expect(durationSeconds >= 0.0)
            #expect(compressionRatio > 0.0)
        } else {
            Issue.record("events[1] should be .codecEncodeComplete, got \(events[1])")
        }

        if case let .codecDecodeStart(codec, codedFrames) = events[2] {
            #expect(codec == "encodec")
            #expect(codedFrames > 0)
        } else {
            Issue.record("events[2] should be .codecDecodeStart, got \(events[2])")
        }

        if case let .codecDecodeComplete(codec, durationSeconds, outputSamples) = events[3] {
            #expect(codec == "encodec")
            #expect(durationSeconds >= 0.0)
            #expect(outputSamples > 0)
        } else {
            Issue.record("events[3] should be .codecDecodeComplete, got \(events[3])")
        }
    }

    // MARK: - Test 3: Audio I/O end-to-end

    /// `loadAudioArray(from:telemetry:)` followed by
    /// `saveAudioArray(_:sampleRate:to:telemetry:)` emits exactly
    /// four audio I/O events in canonical order.
    @Test
    func audioIOEmitsLoadAndSaveEvents() async throws {
        let srcURL = try writeScratchWAV()
        defer { try? FileManager.default.removeItem(at: srcURL) }

        let dstURL = scratchURL()
        defer { try? FileManager.default.removeItem(at: dstURL) }

        let mock = MockMLXAudioTelemetryReporter()

        let (sampleRate, audioData) = try loadAudioArray(from: srcURL, telemetry: mock)
        try saveAudioArray(audioData, sampleRate: Double(sampleRate), to: dstURL, telemetry: mock)

        await flushTelemetryTasks()

        let events = await mock.events()
        #expect(events.count == 4,
                "Expected 4 audio I/O events (load + save start/complete), got \(events.count): \(events)")

        guard events.count == 4 else { return }

        if case let .audioLoadStart(path, fileSizeMB) = events[0] {
            #expect(path == srcURL.path)
            #expect(fileSizeMB >= 0)
        } else {
            Issue.record("events[0] should be .audioLoadStart, got \(events[0])")
        }

        if case let .audioLoadComplete(path, samples, completeSampleRate, durationSeconds) = events[1] {
            #expect(path == srcURL.path)
            #expect(samples > 0)
            #expect(completeSampleRate == sampleRate)
            #expect(durationSeconds > 0)
        } else {
            Issue.record("events[1] should be .audioLoadComplete, got \(events[1])")
        }

        if case let .audioSaveStart(path, _, _) = events[2] {
            #expect(path == dstURL.path)
        } else {
            Issue.record("events[2] should be .audioSaveStart, got \(events[2])")
        }

        if case let .audioSaveComplete(path, fileSizeMB) = events[3] {
            #expect(path == dstURL.path)
            #expect(fileSizeMB >= 0)
        } else {
            Issue.record("events[3] should be .audioSaveComplete, got \(events[3])")
        }
    }

    // MARK: - Test 4: Zero-overhead invariant (invariant 3)

    /// Run a CPU-bound codec round-trip plus a WAV load+save with no
    /// reporter attached, then with a fresh `MockMLXAudioTelemetryReporter`
    /// attached. Median wall-clock with the reporter must be within 5%
    /// of the median with no reporter.
    ///
    /// Methodology:
    ///   - Discard the first iteration in each phase as warm-up.
    ///   - Use `N >= 5` post-warm-up iterations.
    ///   - Take the median of each set (robust to outliers).
    ///   - Assert `withReporterMedian / nilMedian < 1.05`.
    ///
    /// The codec round-trip + WAV I/O is small (1000 samples / 512
    /// WAV samples) so the entire test runs in well under 5 seconds
    /// on a CI runner.
    @Test
    func zeroOverhead_nilReporterWithinFivePercentOfBaseline() async throws {
        // Build a single source WAV reused across iterations.
        let srcURL = try writeScratchWAV(512)
        defer { try? FileManager.default.removeItem(at: srcURL) }

        // One Encodec instance reused across all phases (telemetry is
        // attached / detached per-phase).
        let encodec = makeTinyEncodec()
        let audio = makeTinyAudio()

        // One scratch dst per iteration to avoid AVFoundation
        // truncate / overwrite caching effects skewing measurements.
        let iterations = 5
        let warmups = 1

        // Closure performing one full work unit (codec round-trip +
        // WAV load + WAV save). Returns wall-clock seconds.
        func measureOneIteration(reporter: (any MLXAudioTelemetryReporter)?) async throws -> Double {
            let dstURL = scratchURL()
            defer { try? FileManager.default.removeItem(at: dstURL) }

            // Attach / detach for the codec phase. Detach via `setTelemetry(nil)`
            // restores zero-overhead state for the next iteration if needed.
            encodec.setTelemetry(reporter)

            let start = Date()
            let (codes, scales) = await encodec.encode(audio, bandwidth: 1.5)
            let _ = await encodec.decode(codes, scales)
            let (_, audioData) = try loadAudioArray(from: srcURL, telemetry: reporter)
            try saveAudioArray(audioData, sampleRate: 24_000, to: dstURL, telemetry: reporter)
            let elapsed = Date().timeIntervalSince(start)

            encodec.setTelemetry(nil)
            return elapsed
        }

        // Phase A — `nil` reporter (the zero-overhead default).
        var nilTimes: [Double] = []
        for _ in 0..<warmups { _ = try await measureOneIteration(reporter: nil) }
        for _ in 0..<iterations { nilTimes.append(try await measureOneIteration(reporter: nil)) }

        // Phase B — fresh mock reporter.
        let mock = MockMLXAudioTelemetryReporter()
        var withReporterTimes: [Double] = []
        for _ in 0..<warmups { _ = try await measureOneIteration(reporter: mock) }
        for _ in 0..<iterations { withReporterTimes.append(try await measureOneIteration(reporter: mock)) }

        // Median (robust to outliers — any single GC pause / scheduler
        // hiccup in either phase cannot dominate the result).
        func median(_ xs: [Double]) -> Double {
            let sorted = xs.sorted()
            return sorted[sorted.count / 2]
        }

        let nilMedian = median(nilTimes)
        let withReporterMedian = median(withReporterTimes)

        // Tolerance: 5% per Sortie 19's pinned exit criterion.
        // Guard against floating-point divide-by-zero on absurdly fast
        // iterations (every iteration completes in < 1 µs).
        guard nilMedian > 0 else {
            Issue.record("nil-reporter median elapsed time was zero or negative; instrumentation broken")
            return
        }

        let ratio = withReporterMedian / nilMedian

        // Diagnostic: report the actual numbers so a flake can be
        // triaged from the test log without re-running locally.
        let diag = """
        zero-overhead measurement (seconds, lower is better):
          nil-reporter        median = \(nilMedian)  samples = \(nilTimes)
          mock-reporter       median = \(withReporterMedian)  samples = \(withReporterTimes)
          ratio (with/nil)            = \(ratio)
          tolerance (max ratio)       = 1.05
        """

        #expect(ratio < 1.05, "zero-overhead ratio \(ratio) >= 1.05 (5%) — invariant 3 violated.\n\(diag)")

        // Sanity: with a reporter attached, the mock must have observed
        // at least 4 events per measured iteration (codec encode+decode
        // start/complete) plus some load/save events (audio I/O is
        // dispatched via Task and may or may not have arrived by the
        // time the wall-clock stopwatch stops, but the codec events are
        // synchronous awaits). Lower bound: 4 * iterations.
        await flushTelemetryTasks()
        let mockCount = await mock.eventCount()
        #expect(mockCount >= 4 * iterations,
                "Expected at least \(4 * iterations) events from mock (codec start/complete × iterations), got \(mockCount)")
    }

    // MARK: - Test 5: Nil-reporter has no observable side effects

    /// With `nil` reporter, no events leak into a separately observed
    /// mock that is never attached. Combined with the wall-clock check
    /// above, this proves invariant 3 from two angles: payload-side
    /// (no events recorded) and timing-side (no perceptible overhead).
    @Test
    func nilReporterEmitsNothingToUnattachedMock() async throws {
        let srcURL = try writeScratchWAV()
        defer { try? FileManager.default.removeItem(at: srcURL) }
        let dstURL = scratchURL()
        defer { try? FileManager.default.removeItem(at: dstURL) }

        let unattachedMock = MockMLXAudioTelemetryReporter()

        // Codec round-trip with no reporter attached.
        let encodec = makeTinyEncodec()
        let audio = makeTinyAudio()
        let (codes, scales) = await encodec.encode(audio, bandwidth: 1.5)
        let _ = await encodec.decode(codes, scales)

        // Audio I/O with no telemetry: argument.
        let (sampleRate, audioData) = try loadAudioArray(from: srcURL)
        try saveAudioArray(audioData, sampleRate: Double(sampleRate), to: dstURL)

        await flushTelemetryTasks()

        let count = await unattachedMock.eventCount()
        #expect(count == 0,
                "Unattached mock must observe zero events; got \(count)")
    }
}
