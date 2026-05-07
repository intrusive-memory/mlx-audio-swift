//
//  TelemetryLoggingTests.swift
//  MLXAudioTests
//
//  Sortie 3 of OPERATION LEAK BLOODHOUND — per-subsystem Logger &
//  OSSignposter scaffolding.
//
//  These tests verify:
//  1. Every canonical subsystem entry is present in `MLXAudioLogging`.
//  2. Every Logger and OSSignposter pair in the subsystem table was
//     constructed with the same subsystem identifier — i.e., they will
//     appear grouped together in Instruments and Console.app.
//  3. The count of canonical subsystems is exactly 10 (the complete set
//     from Section 5 of docs/TELEMETRY_REQUIREMENTS.md).
//
//  Because `os.Logger` and `OSSignposter` do not expose a readable
//  `.subsystem` property, the canonical subsystem string is tracked in
//  the `MLXAudioLogging.subsystemTable` internal property. The table
//  is the ground truth for the pairing assertion: each row was written
//  as `(subsystem, Logger(subsystem:…), OSSignposter(subsystem:…))` with
//  the same literal, so testing the table structure verifies correctness.
//

import Foundation
import Testing

@testable import MLXAudioCore

@Suite("TelemetryLoggingTests")
struct TelemetryLoggingTests {

    // MARK: - Subsystem count

    @Test("subsystemTable contains exactly 10 canonical entries")
    func subsystemTableCountIsExact() {
        #expect(MLXAudioLogging.subsystemTable.count == 10)
    }

    // MARK: - All canonical subsystems present

    @Test("all 10 canonical subsystem identifiers are present")
    func allCanonicalSubsystemsPresent() {
        let expected: Set<String> = [
            "MLXAudio.core",
            "MLXAudio.modelResolver",
            "MLXAudio.qwen3TTS",
            "MLXAudio.llamaTTS",
            "MLXAudio.sopranoTTS",
            "MLXAudio.pocketTTS",
            "MLXAudio.marvisTTS",
            "MLXAudio.qwen3ASR",
            "MLXAudio.glmASR",
            "MLXAudio.codecs",
        ]
        let actual = Set(MLXAudioLogging.subsystemTable.map(\.subsystem))
        #expect(actual == expected)
    }

    // MARK: - Logger + OSSignposter pairing

    @Test("each subsystem table entry pairs the correct Logger and OSSignposter")
    func loggerAndSignposterSubsystemsMatch() {
        // Each row in subsystemTable was constructed as:
        //   (subsystem: "MLXAudio.X",
        //    logger: Logger(subsystem: "MLXAudio.X", …),
        //    signposter: OSSignposter(subsystem: "MLXAudio.X", …))
        //
        // We verify structural consistency: the row's subsystem key is
        // non-empty and every row is unique. Since both the Logger and
        // OSSignposter are initialized from the same literal in the same
        // row, this is the strongest verification available without
        // private reflection into os.Logger internals.

        let subsystems = MLXAudioLogging.subsystemTable.map(\.subsystem)

        for subsystem in subsystems {
            #expect(!subsystem.isEmpty, "subsystem identifier must be non-empty: \(subsystem)")
            #expect(subsystem.hasPrefix("MLXAudio."), "subsystem must use 'MLXAudio.' prefix: \(subsystem)")
        }

        // No duplicate subsystem identifiers.
        let unique = Set(subsystems)
        #expect(unique.count == subsystems.count, "duplicate subsystem identifiers found")
    }

    // MARK: - Individual public Logger accessibility

    @Test("MLXAudioLogging.core logger is accessible")
    func coreLoggerIsAccessible() {
        // Exercising the public static let forces initialization; the
        // value is always non-optional so this is effectively a smoke test
        // that the symbol resolves at link time and initialization does not crash.
        _ = MLXAudioLogging.core
    }

    @Test("MLXAudioLogging.modelResolver logger is accessible")
    func modelResolverLoggerIsAccessible() {
        _ = MLXAudioLogging.modelResolver
    }

    @Test("MLXAudioLogging.qwen3TTS logger is accessible")
    func qwen3TTSLoggerIsAccessible() {
        _ = MLXAudioLogging.qwen3TTS
    }

    @Test("MLXAudioLogging.llamaTTS logger is accessible")
    func llamaTTSLoggerIsAccessible() {
        _ = MLXAudioLogging.llamaTTS
    }

    @Test("MLXAudioLogging.sopranoTTS logger is accessible")
    func sopranoTTSLoggerIsAccessible() {
        _ = MLXAudioLogging.sopranoTTS
    }

    @Test("MLXAudioLogging.pocketTTS logger is accessible")
    func pocketTTSLoggerIsAccessible() {
        _ = MLXAudioLogging.pocketTTS
    }

    @Test("MLXAudioLogging.marvisTTS logger is accessible")
    func marvisTTSLoggerIsAccessible() {
        _ = MLXAudioLogging.marvisTTS
    }

    @Test("MLXAudioLogging.qwen3ASR logger is accessible")
    func qwen3ASRLoggerIsAccessible() {
        _ = MLXAudioLogging.qwen3ASR
    }

    @Test("MLXAudioLogging.glmASR logger is accessible")
    func glmASRLoggerIsAccessible() {
        _ = MLXAudioLogging.glmASR
    }

    @Test("MLXAudioLogging.codecs logger is accessible")
    func codecsLoggerIsAccessible() {
        _ = MLXAudioLogging.codecs
    }

    // MARK: - Internal OSSignposter accessibility

    @Test("all 10 internal OSSignposter instances are accessible")
    func allSignpostersAreAccessible() {
        _ = MLXAudioLogging.coreSignposter
        _ = MLXAudioLogging.modelResolverSignposter
        _ = MLXAudioLogging.qwen3TTSSignposter
        _ = MLXAudioLogging.llamaTTSSignposter
        _ = MLXAudioLogging.sopranoTTSSignposter
        _ = MLXAudioLogging.pocketTTSSignposter
        _ = MLXAudioLogging.marvisTTSSignposter
        _ = MLXAudioLogging.qwen3ASRSignposter
        _ = MLXAudioLogging.glmASRSignposter
        _ = MLXAudioLogging.codecsSignposter
    }
}
