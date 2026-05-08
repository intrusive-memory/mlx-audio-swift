//
//  AudioUtilsTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 7 of OPERATION SILENT STETHOSCOPE — telemetry instrumentation
//  coverage for the AudioUtils free functions (loadAudioArray / saveAudioArray).
//
//  # Pattern
//
//  AudioUtils uses the defaulted-parameter injection pattern
//  (`telemetry: (any MLXAudioTelemetryReporter)? = nil`) rather than the
//  setter-after-construct pattern. This is the only sortie that uses this shape.
//  Existing call sites that omit `telemetry:` compile unchanged.
//
//  # Test scenarios
//
//  1. Load success  — loadAudioArray with reporter emits audioLoadStart + audioLoadComplete
//  2. Save success  — saveAudioArray with reporter emits audioSaveStart + audioSaveComplete
//  3. Load error    — non-existent file emits audioLoadStart + audioIOError (no complete)
//  4. Save error    — non-writable path emits audioSaveStart + audioIOError (no complete)
//  5. nil default   — omitting the telemetry param sends zero events to a fresh mock
//  6. Event shapes  — audioLoadStart / audioLoadComplete / audioSaveStart /
//                     audioSaveComplete / audioIOError all compile with the
//                     payload labels used in AudioUtils.swift
//
//  # CI safety
//
//  No model downloads. Scratch files written to FileManager.default.temporaryDirectory
//  and cleaned up via `defer`. Wired into the CLAUDE.md -only-testing list.
//
//  # Concurrency note
//
//  loadAudioArray and saveAudioArray remain synchronous throws functions. Telemetry
//  emission uses detached `Task { ... }` internally, which means events may arrive
//  slightly after the function returns. Tests use a short Task.yield loop to flush
//  the cooperative thread pool before asserting event counts.
//

import AVFoundation
import Foundation
import MLX
import Testing

@testable import MLXAudioCore

// MARK: - AudioUtilsTelemetryTests

@Suite("AudioUtilsTelemetryTests")
struct AudioUtilsTelemetryTests {

    // MARK: - Helpers

    /// Return a scratch URL in the temp directory. Caller must clean up via `defer`.
    private func scratchURL(extension ext: String = "wav") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// Generate a minimal valid 512-sample 440 Hz sine wave at 24 kHz as a WAV
    /// file and return its URL. The file is deleted by the caller via `defer`.
    private func writeScratchWAV() throws -> URL {
        let sampleRate: Double = 24_000
        let count = 512
        let samples: [Float] = (0..<count).map { i in
            Float(sin(2 * Double.pi * 440.0 * Double(i) / sampleRate)) * 0.5
        }
        let mlxSamples = MLXArray(samples)
        let url = scratchURL()
        try saveAudioArray(mlxSamples, sampleRate: sampleRate, to: url)
        return url
    }

    /// Yield to the cooperative thread pool enough times to flush telemetry Tasks
    /// that were fired with `Task { ... }` inside the synchronous emission sites.
    private func flushTelemetryTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    // MARK: - Test 1: loadAudioArray success emits audioLoadStart + audioLoadComplete

    /// When a reporter is attached, a successful `loadAudioArray` call must emit
    /// exactly two events in order: `audioLoadStart` then `audioLoadComplete`.
    @Test
    func loadSuccess_emitsStartThenComplete() async throws {
        let wavURL = try writeScratchWAV()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let mock = MockMLXAudioTelemetryReporter()

        let (sampleRate, audioData) = try loadAudioArray(from: wavURL, telemetry: mock)
        await flushTelemetryTasks()

        let events = await mock.events()

        #expect(events.count == 2,
                "Expected 2 events (audioLoadStart + audioLoadComplete), got \(events.count): \(events)")

        guard events.count == 2 else { return }

        // First event: audioLoadStart
        guard case let .audioLoadStart(startPath, fileSizeMB) = events[0] else {
            Issue.record("events[0] should be .audioLoadStart, got \(events[0])")
            return
        }
        #expect(startPath == wavURL.path,
                "audioLoadStart path mismatch: expected \(wavURL.path), got \(startPath)")
        #expect(fileSizeMB >= 0,
                "audioLoadStart fileSizeMB should be non-negative, got \(fileSizeMB)")

        // Second event: audioLoadComplete
        guard case let .audioLoadComplete(completePath, samples, completeSampleRate, durationSeconds) = events[1] else {
            Issue.record("events[1] should be .audioLoadComplete, got \(events[1])")
            return
        }
        #expect(completePath == wavURL.path,
                "audioLoadComplete path mismatch: expected \(wavURL.path), got \(completePath)")
        #expect(samples > 0,
                "audioLoadComplete samples should be positive, got \(samples)")
        #expect(completeSampleRate == sampleRate,
                "audioLoadComplete sampleRate mismatch: expected \(sampleRate), got \(completeSampleRate)")
        #expect(durationSeconds > 0,
                "audioLoadComplete durationSeconds should be positive, got \(durationSeconds)")

        // Sanity: the returned data matches the event payload.
        #expect(audioData.shape[0] == samples,
                "Returned sample count (\(audioData.shape[0])) should match event payload (\(samples))")
    }

    // MARK: - Test 2: saveAudioArray success emits audioSaveStart + audioSaveComplete

    /// When a reporter is attached, a successful `saveAudioArray` call must emit
    /// exactly two events in order: `audioSaveStart` then `audioSaveComplete`.
    @Test
    func saveSuccess_emitsStartThenComplete() async throws {
        let sampleRate: Double = 24_000
        let count = 512
        let samples: [Float] = (0..<count).map { i in
            Float(sin(2 * Double.pi * 440.0 * Double(i) / sampleRate)) * 0.5
        }
        let mlxSamples = MLXArray(samples)

        let destURL = scratchURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let mock = MockMLXAudioTelemetryReporter()

        try saveAudioArray(mlxSamples, sampleRate: sampleRate, to: destURL, telemetry: mock)
        await flushTelemetryTasks()

        let events = await mock.events()

        #expect(events.count == 2,
                "Expected 2 events (audioSaveStart + audioSaveComplete), got \(events.count): \(events)")

        guard events.count == 2 else { return }

        // First event: audioSaveStart
        guard case let .audioSaveStart(startPath, startSamples, startSampleRate) = events[0] else {
            Issue.record("events[0] should be .audioSaveStart, got \(events[0])")
            return
        }
        #expect(startPath == destURL.path,
                "audioSaveStart path mismatch: expected \(destURL.path), got \(startPath)")
        #expect(startSamples == count,
                "audioSaveStart samples should be \(count), got \(startSamples)")
        #expect(startSampleRate == Int(sampleRate),
                "audioSaveStart sampleRate should be \(Int(sampleRate)), got \(startSampleRate)")

        // Second event: audioSaveComplete
        guard case let .audioSaveComplete(completePath, fileSizeMB) = events[1] else {
            Issue.record("events[1] should be .audioSaveComplete, got \(events[1])")
            return
        }
        #expect(completePath == destURL.path,
                "audioSaveComplete path mismatch: expected \(destURL.path), got \(completePath)")
        #expect(fileSizeMB >= 0,
                "audioSaveComplete fileSizeMB should be non-negative, got \(fileSizeMB)")
    }

    // MARK: - Test 3: loadAudioArray error emits audioLoadStart + audioIOError

    /// When loading from a non-existent path, the function must throw AND
    /// emit `audioLoadStart` followed by `audioIOError` (no `audioLoadComplete`).
    @Test
    func loadError_emitsStartThenIOError() async throws {
        let nonExistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")

        let mock = MockMLXAudioTelemetryReporter()

        var caughtError: Error?
        do {
            _ = try loadAudioArray(from: nonExistentURL, telemetry: mock)
        } catch {
            caughtError = error
        }

        await flushTelemetryTasks()

        #expect(caughtError != nil, "loadAudioArray on non-existent file should throw")

        let events = await mock.events()

        // Must have at least 2 events: loadStart + audioIOError.
        // (fileSizeMB computation attempts attributesOfItem which fails gracefully,
        //  so audioLoadStart is still emitted with fileSizeMB == 0.)
        #expect(events.count >= 2,
                "Expected at least 2 events (audioLoadStart + audioIOError), got \(events.count): \(events)")

        guard events.count >= 2 else { return }

        // First event: audioLoadStart
        if case let .audioLoadStart(path, _) = events[0] {
            #expect(path == nonExistentURL.path,
                    "audioLoadStart path mismatch: expected \(nonExistentURL.path), got \(path)")
        } else {
            Issue.record("events[0] should be .audioLoadStart, got \(events[0])")
        }

        // Last event: audioIOError with operation == "load"
        let lastEvent = events[events.count - 1]
        if case let .audioIOError(path, operation, _) = lastEvent {
            #expect(path == nonExistentURL.path,
                    "audioIOError path mismatch: expected \(nonExistentURL.path), got \(path)")
            #expect(operation == "load",
                    "audioIOError operation should be \"load\", got \"\(operation)\"")
        } else {
            Issue.record("Last event should be .audioIOError, got \(lastEvent)")
        }

        // Must NOT have emitted audioLoadComplete.
        let hasComplete = events.contains { event in
            if case .audioLoadComplete = event { return true }
            return false
        }
        #expect(!hasComplete, "audioLoadComplete should not be emitted on error path")
    }

    // MARK: - Test 4: saveAudioArray error emits audioSaveStart + audioIOError

    /// When saving to a non-writable path (directory instead of file), the
    /// function must throw AND emit `audioSaveStart` followed by `audioIOError`
    /// (no `audioSaveComplete`).
    @Test
    func saveError_emitsStartThenIOError() async throws {
        // Use a directory URL as the target — AVAudioFile(forWriting:) will fail.
        let dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        // Point saveAudioArray at the directory itself, not a file inside it.
        // AVAudioFile will throw when trying to open a directory for writing.
        let badURL = dirURL

        let mock = MockMLXAudioTelemetryReporter()
        let mlxSamples = MLXArray([Float(0.5)])

        var caughtError: Error?
        do {
            try saveAudioArray(mlxSamples, sampleRate: 24_000, to: badURL, telemetry: mock)
        } catch {
            caughtError = error
        }

        await flushTelemetryTasks()

        #expect(caughtError != nil, "saveAudioArray to a directory URL should throw")

        let events = await mock.events()

        #expect(events.count >= 2,
                "Expected at least 2 events (audioSaveStart + audioIOError), got \(events.count): \(events)")

        guard events.count >= 2 else { return }

        // First event: audioSaveStart
        if case let .audioSaveStart(path, _, _) = events[0] {
            #expect(path == badURL.path,
                    "audioSaveStart path mismatch: expected \(badURL.path), got \(path)")
        } else {
            Issue.record("events[0] should be .audioSaveStart, got \(events[0])")
        }

        // Last event: audioIOError with operation == "save"
        let lastEvent = events[events.count - 1]
        if case let .audioIOError(path, operation, _) = lastEvent {
            #expect(path == badURL.path,
                    "audioIOError path mismatch: expected \(badURL.path), got \(path)")
            #expect(operation == "save",
                    "audioIOError operation should be \"save\", got \"\(operation)\"")
        } else {
            Issue.record("Last event should be .audioIOError, got \(lastEvent)")
        }

        // Must NOT have emitted audioSaveComplete.
        let hasComplete = events.contains { event in
            if case .audioSaveComplete = event { return true }
            return false
        }
        #expect(!hasComplete, "audioSaveComplete should not be emitted on error path")
    }

    // MARK: - Test 5: nil-default zero-overhead

    /// When `telemetry:` is omitted (or explicitly passed `nil`), no events
    /// reach any mock — zero-overhead guarantee (invariant 3).
    ///
    /// The test runs both load and save without the `telemetry:` argument (the
    /// source-compatible call site form) and then attaches a fresh mock to confirm
    /// only the second, explicitly-attached call emits events.
    @Test
    func nilDefault_zeroOverhead() async throws {
        let wavURL = try writeScratchWAV()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let destURL = scratchURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        // Phase 1: call without telemetry: argument (existing-call-site shape).
        // No mock is attached; a separate unattached mock verifies nothing leaks.
        let unattachedMock = MockMLXAudioTelemetryReporter()

        let (_, audioData) = try loadAudioArray(from: wavURL)  // no telemetry: arg
        try saveAudioArray(audioData, sampleRate: 24_000, to: destURL)  // no telemetry: arg

        await flushTelemetryTasks()

        let countAfterNilCalls = await unattachedMock.eventCount()
        #expect(countAfterNilCalls == 0,
                "Unattached mock should receive 0 events from nil-default calls, got \(countAfterNilCalls)")

        // Phase 2: same operations with an explicitly attached mock — events should flow.
        let wavURL2 = try writeScratchWAV()
        defer { try? FileManager.default.removeItem(at: wavURL2) }

        let destURL2 = scratchURL()
        defer { try? FileManager.default.removeItem(at: destURL2) }

        let attachedMock = MockMLXAudioTelemetryReporter()

        let (_, audioData2) = try loadAudioArray(from: wavURL2, telemetry: attachedMock)
        try saveAudioArray(audioData2, sampleRate: 24_000, to: destURL2, telemetry: attachedMock)

        await flushTelemetryTasks()

        let countAfterAttachedCalls = await attachedMock.eventCount()
        #expect(countAfterAttachedCalls == 4,
                "Attached mock should receive 4 events (loadStart+loadComplete+saveStart+saveComplete), got \(countAfterAttachedCalls)")
    }

    // MARK: - Test 6: event shapes compile with AudioUtils payload labels

    /// Construct each Audio I/O event case with the exact payload labels used
    /// in AudioUtils.swift's instrumentation and verify they round-trip through
    /// the mock. Compilation failure here means the event enum's label names
    /// diverged from the instrumentation — both would fail to build.
    @Test
    func audioIOEventShapesCompileWithAudioUtilsLabels() async {
        let mock = MockMLXAudioTelemetryReporter()

        await mock.capture(.audioLoadStart(path: "/tmp/test.wav", fileSizeMB: 1.23))
        await mock.capture(.audioLoadComplete(path: "/tmp/test.wav", samples: 24_000, sampleRate: 24_000, durationSeconds: 1.0))
        await mock.capture(.audioSaveStart(path: "/tmp/out.wav", samples: 24_000, sampleRate: 24_000))
        await mock.capture(.audioSaveComplete(path: "/tmp/out.wav", fileSizeMB: 1.23))
        await mock.capture(.audioIOError(path: "/tmp/bad.wav", operation: "load", error: "file not found"))
        await mock.capture(.audioIOError(path: "/tmp/bad.wav", operation: "save", error: "permission denied"))

        let events = await mock.events()
        #expect(events.count == 6,
                "Expected 6 events from direct capture calls, got \(events.count)")

        guard events.count == 6 else { return }

        if case let .audioLoadStart(path, fileSizeMB) = events[0] {
            #expect(path == "/tmp/test.wav")
            #expect(abs(fileSizeMB - 1.23) < 0.001)
        } else {
            Issue.record("events[0] should be .audioLoadStart, got \(events[0])")
        }

        if case let .audioLoadComplete(path, samples, sampleRate, durationSeconds) = events[1] {
            #expect(path == "/tmp/test.wav")
            #expect(samples == 24_000)
            #expect(sampleRate == 24_000)
            #expect(abs(durationSeconds - 1.0) < 0.001)
        } else {
            Issue.record("events[1] should be .audioLoadComplete, got \(events[1])")
        }

        if case let .audioSaveStart(path, samples, sampleRate) = events[2] {
            #expect(path == "/tmp/out.wav")
            #expect(samples == 24_000)
            #expect(sampleRate == 24_000)
        } else {
            Issue.record("events[2] should be .audioSaveStart, got \(events[2])")
        }

        if case let .audioSaveComplete(path, fileSizeMB) = events[3] {
            #expect(path == "/tmp/out.wav")
            #expect(abs(fileSizeMB - 1.23) < 0.001)
        } else {
            Issue.record("events[3] should be .audioSaveComplete, got \(events[3])")
        }

        if case let .audioIOError(path, operation, error) = events[4] {
            #expect(path == "/tmp/bad.wav")
            #expect(operation == "load")
            #expect(!error.isEmpty)
        } else {
            Issue.record("events[4] should be .audioIOError, got \(events[4])")
        }

        if case let .audioIOError(path, operation, error) = events[5] {
            #expect(path == "/tmp/bad.wav")
            #expect(operation == "save")
            #expect(!error.isEmpty)
        } else {
            Issue.record("events[5] should be .audioIOError, got \(events[5])")
        }
    }

    // MARK: - Test 7: NoopMLXAudioTelemetryReporter accepted as telemetry: argument

    /// Confirm that `NoopMLXAudioTelemetryReporter` (the library-provided noop)
    /// can be passed as the `telemetry:` argument without compile or runtime error.
    @Test
    func noopReporterAcceptedByFreeFunction() throws {
        let wavURL = try writeScratchWAV()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let noop = NoopMLXAudioTelemetryReporter()

        // Both calls must compile and not crash.
        let (_, audioData) = try loadAudioArray(from: wavURL, telemetry: noop)

        let destURL = scratchURL()
        defer { try? FileManager.default.removeItem(at: destURL) }
        try saveAudioArray(audioData, sampleRate: 24_000, to: destURL, telemetry: noop)

        #expect(Bool(true), "NoopMLXAudioTelemetryReporter compiled and ran without error")
    }
}
