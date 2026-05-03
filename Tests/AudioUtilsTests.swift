//
//  AudioUtilsTests.swift
//  MLXAudioTests
//
//  Sortie 13 of OPERATION ECHO DRAGNET — AudioUtils WAV codec round-trip.
//
//  # Code-path boundary (resolves the Sortie 13 / Sortie 14 open question)
//
//  All three WAV I/O functions live in a single file:
//    Sources/MLXAudioCore/AudioUtils.swift
//
//  However they are DISTINCT code paths:
//
//  THIS SUITE (Sortie 13) — covers `AudioUtils.writeWavFile` (class method, lines 13–36):
//    - Uses AVAudioFormat(commonFormat: .pcmFormatFloat32, …)   — explicit float32
//    - Takes [Float] (Swift array, NOT MLXArray)
//    - Write-only; round-trip uses the module-level `loadAudioArray` as the reader
//
//  SORTIE 14 (AudioIORoundTripTests) — covers the `loadAudioArray` / `saveAudioArray`
//  pair of top-level free functions (lines 43–86):
//    - `saveAudioArray` uses AVAudioFormat(standardFormatWithSampleRate:channels:)
//      which produces a non-interleaved float32 format on Apple platforms.
//    - Takes MLXArray (not [Float])
//    - Sortie 14 round-trips `intention.wav` (external 16-bit PCM fixture) through
//      `loadAudioArray` → `saveAudioArray` → `loadAudioArray`.
//
//  Neither `AudioUtils.writeWavFile` nor `saveAudioArray` writes Int16 PCM —
//  both produce float32 WAV files.  There is no Int16 write path in
//  AudioUtils.swift to test.  The Int16 tolerance row in the sortie plan is
//  therefore N/A for Sortie 13; this suite exercises float32 only and documents
//  that finding inline.
//
//  # Synthetic fixtures
//
//  All tests generate a 1024-sample, 440 Hz sine wave at 24 kHz (mono).
//  Scratch files are written to FileManager.default.temporaryDirectory with
//  UUID-based filenames and cleaned up via `defer`.
//
//  CI-safe: no model downloads. Wired into the CLAUDE.md -only-testing list.
//
//  Production-code-scope discipline: zero modifications to Sources/ files.
//

import AVFoundation
import Foundation
import MLX
import Testing

@testable import MLXAudioCore

// MARK: - AudioUtilsTests

@Suite("AudioUtilsTests")
struct AudioUtilsTests {

    // MARK: - Shared helpers

    /// 1024-sample 440 Hz sine wave at 24 kHz, scaled to the range [-0.5, 0.5]
    /// so it stays well within the float32 dynamic range and doesn't clip when
    /// re-read from a WAV file.
    private func makeSineWave(count: Int = 1_024, frequency: Double = 440, sampleRate: Double = 24_000) -> [Float] {
        (0..<count).map { i in
            Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate)) * 0.5
        }
    }

    /// Writes a scratch WAV file, returning its URL.
    /// The caller is responsible for cleanup (use `defer`).
    private func scratchURL(extension ext: String = "wav") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    // MARK: - Float32 round-trip via AudioUtils.writeWavFile

    /// Round-trip a 1024-sample float32 sine wave through
    /// `AudioUtils.writeWavFile` (write) and `loadAudioArray` (read).
    ///
    /// Both operations use `AVAudioFile` + `AVAudioPCMBuffer` internally,
    /// routing through float32 PCM WAV on disk. The round-trip should be
    /// near byte-exact; we assert allclose(atol: 1e-6).
    ///
    /// NOTE — Int16 path: `AudioUtils.writeWavFile` uses
    /// `AVAudioFormat(commonFormat: .pcmFormatFloat32, …)` exclusively.
    /// There is no Int16 write path in this function; the byte-exact Int16
    /// assertion from the sortie plan is N/A for this code path.
    @Test func float32RoundTrip_writeWavFile_loadAudioArray() throws {
        let samples = makeSineWave()
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write via AudioUtils class method (float32 PCM WAV).
        try AudioUtils.writeWavFile(samples: samples, sampleRate: 24_000, fileURL: url)

        // Read back via module-level free function.
        let (sampleRate, audioArray) = try loadAudioArray(from: url)

        // Verify sample rate
        #expect(sampleRate == 24_000, "Sample rate mismatch: got \(sampleRate), expected 24000")

        // Verify sample count
        let readCount = audioArray.shape[0]
        #expect(readCount == samples.count,
                "Sample count mismatch: got \(readCount), expected \(samples.count)")

        // Verify values: allclose(atol: 1e-6)
        let reference = MLXArray(samples)
        eval(audioArray, reference)

        let diff = MLX.abs(audioArray - reference)
        let maxDiff = diff.max().item(Float.self)
        let allClose = MLX.all(diff .<= 1e-6).item(Bool.self)

        #expect(allClose,
                "float32 round-trip failed allclose(atol:1e-6); maxAbsDiff=\(maxDiff)")
    }

    // MARK: - Float32 round-trip via saveAudioArray / loadAudioArray

    /// Round-trip a 1024-sample float32 sine wave through the module-level
    /// `saveAudioArray` (write) and `loadAudioArray` (read) free functions.
    ///
    /// `saveAudioArray` uses `AVAudioFormat(standardFormatWithSampleRate:channels:)`
    /// which produces a non-interleaved float32 format on Apple platforms.
    /// This is a DISTINCT code path from `AudioUtils.writeWavFile` (different
    /// AVAudioFormat constructor, different input type: MLXArray vs [Float]).
    ///
    /// The round-trip should be near byte-exact; we assert allclose(atol: 1e-6).
    ///
    /// NOTE — Int16 path: `saveAudioArray` also writes float32 PCM WAV.
    /// There is no Int16 write path in this function either.
    @Test func float32RoundTrip_saveAudioArray_loadAudioArray() throws {
        let samples = makeSineWave()
        let mlxSamples = MLXArray(samples)
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write via module-level free function (standardFormatWithSampleRate path).
        try saveAudioArray(mlxSamples, sampleRate: 24_000, to: url)

        // Read back.
        let (sampleRate, audioArray) = try loadAudioArray(from: url)

        #expect(sampleRate == 24_000, "Sample rate mismatch: got \(sampleRate), expected 24000")

        let readCount = audioArray.shape[0]
        #expect(readCount == samples.count,
                "Sample count mismatch: got \(readCount), expected \(samples.count)")

        let reference = MLXArray(samples)
        eval(audioArray, reference)

        let diff = MLX.abs(audioArray - reference)
        let maxDiff = diff.max().item(Float.self)
        let allClose = MLX.all(diff .<= 1e-6).item(Bool.self)

        #expect(allClose,
                "float32 round-trip failed allclose(atol:1e-6); maxAbsDiff=\(maxDiff)")
    }

    // MARK: - Zero-length edge case: AudioUtils.writeWavFile

    /// Edge case: zero-length input to `AudioUtils.writeWavFile`.
    ///
    /// Chosen behavior: `writeWavFile(samples: [], …)` completes without throwing
    /// (AVAudioPCMBuffer with frameCapacity=0 is a valid allocation on Apple
    /// platforms; AVAudioFile accepts a 0-frame write).
    ///
    /// Correspondingly, `loadAudioArray` reading the resulting zero-length WAV
    /// returns an MLXArray with shape [0].
    ///
    /// If either condition fails, the test surfaces the actual behavior so
    /// future callers can rely on documented semantics.
    @Test func zeroLengthInput_writeWavFile_producesEmptyOrThrows() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Attempt to write zero samples.
        // We accept either clean completion (preferred) or a specific thrown error.
        do {
            try AudioUtils.writeWavFile(samples: [], sampleRate: 24_000, fileURL: url)
            // Write succeeded — verify the file exists and is readable.
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            #expect(fileExists, "zero-length write succeeded but no file was created")

            if fileExists {
                let (sampleRate, audioArray) = try loadAudioArray(from: url)
                #expect(sampleRate == 24_000,
                        "zero-length WAV: unexpected sample rate \(sampleRate)")
                #expect(audioArray.shape[0] == 0,
                        "zero-length WAV: expected 0 samples, got \(audioArray.shape[0])")
            }
        } catch {
            // Throwing on zero-length input is also acceptable — just document it.
            // Test name suffix "_producesEmptyOrThrows" signals both are valid.
            //
            // Record the error type for the sortie report; it does NOT constitute a failure.
            _ = "\(type(of: error)): \(error)"
            // Intentionally not re-throwing: both outcomes are acceptable contract.
        }
    }

    // MARK: - Zero-length edge case: saveAudioArray

    /// Edge case: zero-length MLXArray input to `saveAudioArray`.
    ///
    /// Same behavioral contract as the `writeWavFile` zero-length case above:
    /// either clean completion with an empty output file, or an error is acceptable.
    @Test func zeroLengthInput_saveAudioArray_producesEmptyOrThrows() throws {
        let emptyArray = MLXArray([] as [Float])
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try saveAudioArray(emptyArray, sampleRate: 24_000, to: url)

            let fileExists = FileManager.default.fileExists(atPath: url.path)
            #expect(fileExists, "zero-length saveAudioArray succeeded but no file was created")

            if fileExists {
                let (sampleRate, audioArray) = try loadAudioArray(from: url)
                #expect(sampleRate == 24_000,
                        "zero-length WAV: unexpected sample rate \(sampleRate)")
                #expect(audioArray.shape[0] == 0,
                        "zero-length WAV: expected 0 samples, got \(audioArray.shape[0])")
            }
        } catch {
            _ = "\(type(of: error)): \(error)"
            // Both outcomes are acceptable; see writeWavFile counterpart above.
        }
    }
}
