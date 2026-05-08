//
//  MLXAudioTelemetryEventTests.swift
//  MLXAudioTests
//
//  Sortie 1 of OPERATION SILENT STETHOSCOPE — sanity coverage for the
//  public telemetry event vocabulary.
//
//  This suite is deliberately minimal: it only proves that
//
//    1. Every case in `MLXAudioTelemetryEvent` can be constructed (so
//       a typo in a label or a payload-type drift would surface here
//       before any instrumentation sortie tries to use it).
//    2. The enum is `Sendable` (a static check — the assertion is
//       compile-time, but we surface it as a runtime test for
//       traceability).
//    3. The `NoopMLXAudioTelemetryReporter` and the shared
//       `MockMLXAudioTelemetryReporter` round-trip an event without
//       mutating it.
//
//  Behavioural emission tests (start / progress / complete ordering,
//  error wiring, hot-loop guards) live in each instrumentation
//  sortie's own `*TelemetryTests.swift` file.
//

import Foundation
import Testing

@testable import MLXAudioCore

@Suite("MLXAudioTelemetryEventTests")
struct MLXAudioTelemetryEventTests {

    // MARK: - Construction smoke test

    /// Construct every documented case at least once. If a downstream
    /// sortie reshapes a payload (e.g. drops a label, changes a type),
    /// this test fails before any instrumentation file does.
    @Test
    func constructEveryCase() {
        let events: [MLXAudioTelemetryEvent] = [
            // Model lifecycle
            .modelDownloadStart(repo: "org/repo", sizeMB: 123.4),
            .modelDownloadStart(repo: "org/repo", sizeMB: nil),
            .modelDownloadComplete(repo: "org/repo", sizeMB: 123.4, cacheHit: false),
            .modelDownloadComplete(repo: "org/repo", sizeMB: 0.0, cacheHit: true),
            .modelDownloadError(repo: "org/repo", error: "network failure"),
            .modelLoadStart(repo: "org/repo", modelType: "tts"),
            .modelLoadComplete(
                repo: "org/repo",
                modelType: "tts",
                sizeMB: 250.0,
                metalAllocatedMB: 180.0
            ),
            .modelLoadError(repo: "org/repo", error: "weights missing"),
            .modelUnloadStart(repo: "org/repo", loadedSizeMB: 250.0),
            .modelUnloadComplete(repo: "org/repo", freedMB: 250.0),

            // TTS
            .ttsGenerationStart(model: "qwen3-tts", textLength: 512, voiceType: "neutral"),
            .ttsGenerationStart(model: "qwen3-tts", textLength: 0, voiceType: nil),
            .ttsGenerationProgress(
                model: "qwen3-tts",
                fractionComplete: 0.5,
                generatedSamples: 24_000
            ),
            .ttsGenerationComplete(
                model: "qwen3-tts",
                durationSeconds: 1.25,
                audioSamples: 30_000,
                sampleRate: 24_000
            ),
            .ttsGenerationError(
                model: "qwen3-tts",
                phase: "decode",
                error: "kv cache exhausted"
            ),

            // STT
            .sttTranscriptionStart(model: "glm-asr", audioSamples: 48_000, sampleRate: 16_000),
            .sttTranscriptionComplete(
                model: "glm-asr",
                durationSeconds: 0.75,
                textLength: 128
            ),
            .sttTranscriptionError(
                model: "glm-asr",
                phase: "feature_extraction",
                error: "stft failed"
            ),

            // Codec
            .codecEncodeStart(codec: "vocos", inputSamples: 24_000),
            .codecEncodeComplete(
                codec: "vocos",
                durationSeconds: 0.05,
                compressionRatio: 16.0
            ),
            .codecDecodeStart(codec: "vocos", codedFrames: 75),
            .codecDecodeComplete(
                codec: "vocos",
                durationSeconds: 0.04,
                outputSamples: 24_000
            ),
            .codecError(codec: "vocos", operation: "decode", error: "invalid codes"),

            // Audio I/O
            .audioLoadStart(path: "/tmp/in.wav", fileSizeMB: 1.5),
            .audioLoadComplete(
                path: "/tmp/in.wav",
                samples: 48_000,
                sampleRate: 24_000,
                durationSeconds: 2.0
            ),
            .audioSaveStart(path: "/tmp/out.wav", samples: 48_000, sampleRate: 24_000),
            .audioSaveComplete(path: "/tmp/out.wav", fileSizeMB: 1.5),
            .audioIOError(path: "/tmp/out.wav", operation: "save", error: "ENOSPC"),

            // Memory
            .metalBufferAllocated(allocatedMB: 320.0, peakMB: 320.0),
            .metalBufferDeallocated(freedMB: 80.0, remainingMB: 240.0),
            .wiredMemoryState(wiredMB: 1024.0, committedMB: 768.0),
            .audioBufferCacheGrowth(entriesCount: 8, totalMB: 4.0)
        ]

        // Construction smoke: every case is buildable.
        #expect(events.count == 33)
    }

    // MARK: - Sendable conformance

    /// Compile-time existence check that the enum and reporter
    /// protocol are `Sendable`. The assignment to `any Sendable`
    /// fails to compile if either drops the conformance.
    @Test
    func sendableConformanceIsAvailable() {
        let event: MLXAudioTelemetryEvent = .modelLoadStart(repo: "r", modelType: "t")
        let asSendable: any Sendable = event
        #expect(String(describing: type(of: asSendable)).contains("MLXAudioTelemetryEvent"))

        let reporter: any MLXAudioTelemetryReporter = NoopMLXAudioTelemetryReporter()
        let reporterAsSendable: any Sendable = reporter
        // Suppress unused-variable warning while keeping the
        // compile-time conformance check load-bearing.
        _ = reporterAsSendable
    }

    // MARK: - Noop round-trip

    /// `NoopMLXAudioTelemetryReporter` accepts every event without
    /// mutating state or throwing. A reporter that swallowed events
    /// silently is the documented baseline behaviour for hosts that
    /// haven't yet wired a real sink.
    @Test
    func noopReporterAcceptsEvents() async {
        let reporter = NoopMLXAudioTelemetryReporter()
        await reporter.capture(.modelLoadStart(repo: "noop", modelType: "tts"))
        await reporter.capture(
            .modelLoadComplete(
                repo: "noop",
                modelType: "tts",
                sizeMB: 1.0,
                metalAllocatedMB: 1.0
            )
        )
        // No assertion target — the test is that the calls return
        // without throwing or trapping. Reaching this line is the
        // success condition.
        #expect(Bool(true))
    }

    // MARK: - Mock round-trip

    /// `MockMLXAudioTelemetryReporter` records events in order and
    /// preserves payload labels intact. This is the contract every
    /// downstream instrumentation sortie depends on.
    @Test
    func mockReporterRoundTripPreservesOrderAndPayload() async {
        let mock = MockMLXAudioTelemetryReporter()

        await mock.capture(.modelLoadStart(repo: "round-trip", modelType: "tts"))
        await mock.capture(
            .ttsGenerationComplete(
                model: "qwen3-tts",
                durationSeconds: 2.5,
                audioSamples: 60_000,
                sampleRate: 24_000
            )
        )
        await mock.capture(
            .ttsGenerationError(
                model: "qwen3-tts",
                phase: "decode",
                error: "boom"
            )
        )

        let events = await mock.events()
        #expect(events.count == 3)

        // Order preserved.
        guard events.count == 3 else { return }

        // Payload integrity: pattern-match each recorded case.
        if case let .modelLoadStart(repo, modelType) = events[0] {
            #expect(repo == "round-trip")
            #expect(modelType == "tts")
        } else {
            Issue.record("events[0] should be .modelLoadStart, got \(events[0])")
        }

        if case let .ttsGenerationComplete(model, durationSeconds, audioSamples, sampleRate) = events[1] {
            #expect(model == "qwen3-tts")
            #expect(durationSeconds == 2.5)
            #expect(audioSamples == 60_000)
            #expect(sampleRate == 24_000)
        } else {
            Issue.record("events[1] should be .ttsGenerationComplete, got \(events[1])")
        }

        if case let .ttsGenerationError(model, phase, error) = events[2] {
            #expect(model == "qwen3-tts")
            #expect(phase == "decode")
            #expect(error == "boom")
        } else {
            Issue.record("events[2] should be .ttsGenerationError, got \(events[2])")
        }
    }

    /// Reset clears the buffer without affecting future captures.
    @Test
    func mockReporterResetClearsBuffer() async {
        let mock = MockMLXAudioTelemetryReporter()
        await mock.capture(.modelLoadStart(repo: "r", modelType: "t"))
        #expect(await mock.eventCount() == 1)

        await mock.reset()
        #expect(await mock.eventCount() == 0)

        await mock.capture(.modelUnloadStart(repo: "r", loadedSizeMB: 10.0))
        #expect(await mock.eventCount() == 1)
    }
}
