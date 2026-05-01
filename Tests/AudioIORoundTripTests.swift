//
//  AudioIORoundTripTests.swift
//  MLXAudioTests
//
//  Sortie 14 of OPERATION ECHO DRAGNET — AudioIO load/save round-trip via intention.wav.
//
//  # Code-path boundary (resolves the Sortie 13 / Sortie 14 open question)
//
//  Sortie 13 (AudioUtilsTests) covers `AudioUtils.writeWavFile` (class method,
//  AudioUtils.swift lines 13–36), which uses an explicit
//  `AVAudioFormat(commonFormat: .pcmFormatFloat32, …)` constructor and takes [Float].
//
//  THIS SUITE (Sortie 14) covers the `loadAudioArray` / `saveAudioArray` pair of
//  top-level free functions (AudioUtils.swift lines 43–86):
//    - `saveAudioArray` uses `AVAudioFormat(standardFormatWithSampleRate:channels:)`
//      — a DISTINCT constructor that produces a non-interleaved float32 format
//      on Apple platforms.
//    - Takes MLXArray (not [Float]).
//    - Round-trips `intention.wav` (an external 16-bit PCM fixture at 24 kHz mono)
//      through `loadAudioArray` → `saveAudioArray` → `loadAudioArray`.
//
//  # Int16 byte-exact path — N/A
//
//  The sortie plan included a "byte-exact for int16 path" exit criterion.
//  That criterion is N/A here. Neither `saveAudioArray` nor `loadAudioArray`
//  exposes an Int16 PCM write path — both produce and consume float32 WAV files.
//
//  # Historical note: saveAudioArray 1024-sample truncation
//
//  Sortie 14 found that `saveAudioArray` silently truncated output to the nearest
//  multiple of 1024 samples (intention.wav 36480 → 35840, losing ~26.7 ms at
//  24 kHz). The truncation was traced to AVAudioFile's 2-arg `forWriting:` init
//  letting `processingFormat` differ from the buffer's format, which triggered an
//  internal conversion at write that quantized to 1024-frame packet boundaries
//  and dropped the trailing partial packet.
//
//  Resolved in the OPERATION ECHO DRAGNET follow-up by switching `saveAudioArray`
//  to the 4-arg `forWriting:settings:commonFormat:interleaved:` init (matching the
//  pattern in `AudioUtils.writeWavFile`) and forcing the file to close+flush
//  before the function returns. The round-trip now asserts byte-exact sample
//  counts and full-range float32 allclose on `intention.wav` (non-1024-aligned
//  input) without the prior `withKnownIssue` wrapper.
//
//  # Fixture
//
//  `Tests/media/intention.wav` — 16-bit PCM, mono, 24000 Hz, 36480 samples (1.52 s).
//  Accessed via Bundle.module (the media directory is copied in Package.swift).
//
//  # CI safety
//
//  No model downloads. Wired into the CLAUDE.md -only-testing list.
//  Production-code-scope discipline: zero modifications to Sources/ files.
//

import AVFoundation
import Foundation
import MLX
import Testing

@testable import MLXAudioCore

// MARK: - AudioIORoundTripTests

@Suite("AudioIORoundTripTests")
struct AudioIORoundTripTests {

    // MARK: - Helpers

    /// Scratch URL in the temp directory, cleaned up by the caller via `defer`.
    private func scratchURL(extension ext: String = "wav") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    // MARK: - intention.wav round-trip

    /// Full round-trip: load `intention.wav` (Int16 PCM source) → save via
    /// `saveAudioArray` (float32 WAV) → reload via `loadAudioArray`.
    ///
    /// Assertions:
    ///   - Source file loads with expected sample rate (24000) and non-zero count.
    ///   - Sample rate is preserved across save/reload.
    ///   - Sample count is preserved (or, if the known 1024-block truncation
    ///     occurs, records a finding and skips allclose to avoid a fatal crash).
    ///   - For the overlapping prefix, values match allclose(atol: 1e-6).
    ///
    /// NOTE: The Int16→Float32 conversion occurs once (step 1, handled by
    /// AVFoundation's processingFormat). The save/reload sub-path is purely
    /// float32→float32, so it is effectively bit-exact on Apple platforms.
    ///
    /// KNOWN PRODUCTION BUG (Sortie 14 finding):
    ///   `saveAudioArray` silently truncates output to the nearest multiple of
    ///   1024 samples. For `intention.wav` (36480 samples), the reloaded count
    ///   is 35840 (−640 samples, −26.7 ms). Fix is out-of-scope for this sortie
    ///   (DO NOT modify Sources/). The truncation is documented here for tracking.
    @Test func intentionWav_loadSaveReload_float32Allclose() throws {
        // Locate the fixture via the test bundle.
        guard let fixtureURL = Bundle.module.url(
            forResource: "intention",
            withExtension: "wav",
            subdirectory: "media"
        ) else {
            Issue.record("intention.wav not found in Bundle.module — check Package.swift resource copy")
            return
        }

        // Step 1: Load the original file (Int16 PCM source → float32 in memory).
        let (originalSampleRate, originalArray) = try loadAudioArray(from: fixtureURL)

        let originalSampleCount = originalArray.shape[0]
        #expect(originalSampleCount > 0, "intention.wav loaded 0 samples — fixture may be empty or unreadable")
        #expect(originalSampleRate == 24_000,
                "intention.wav: expected sample rate 24000, got \(originalSampleRate)")

        // Step 2: Save the float32 array to a scratch file via `saveAudioArray`.
        let scratchFile = scratchURL()
        defer { try? FileManager.default.removeItem(at: scratchFile) }

        try saveAudioArray(originalArray, sampleRate: Double(originalSampleRate), to: scratchFile)

        #expect(FileManager.default.fileExists(atPath: scratchFile.path),
                "saveAudioArray did not create the scratch file at \(scratchFile.path)")

        // Step 3: Reload the scratch file (float32 WAV → float32 in memory).
        let (reloadedSampleRate, reloadedArray) = try loadAudioArray(from: scratchFile)

        // Assert sample rate preserved.
        #expect(reloadedSampleRate == originalSampleRate,
                "Round-trip sample rate mismatch: original=\(originalSampleRate), reloaded=\(reloadedSampleRate)")

        // Assert sample count preserved.
        // Sortie 14 originally found that saveAudioArray silently truncated output
        // to the nearest multiple of 1024 samples (intention.wav 36480 → 35840,
        // losing ~26.7 ms at 24 kHz). Root cause was AVAudioFile's 2-arg
        // forWriting initializer letting processingFormat differ from the buffer
        // format, triggering a conversion at write that dropped the trailing
        // partial packet. Fixed by switching to the 4-arg init in AudioUtils.swift
        // and forcing the file to close+flush before saveAudioArray returns.
        let reloadedSampleCount = reloadedArray.shape[0]
        #expect(reloadedSampleCount == originalSampleCount,
                "Round-trip sample count: original=\(originalSampleCount), reloaded=\(reloadedSampleCount)")

        // Assert float32 allclose(atol: 1e-6) on the full sample range.
        let originalPrefix = originalArray
        let reloadedPrefix = reloadedArray
        eval(originalPrefix, reloadedPrefix)

        let diff = MLX.abs(originalPrefix - reloadedPrefix)
        let maxDiff = diff.max().item(Float.self)
        let allClose = MLX.all(diff .<= Float(1e-6)).item(Bool.self)

        #expect(allClose,
                "Round-trip float32 allclose(atol:1e-6) failed; maxAbsDiff=\(maxDiff)")
    }

    // MARK: - Synthetic float32 round-trip (saveAudioArray / loadAudioArray)

    /// Complementary test: round-trip a purely synthetic float32 MLXArray with
    /// a length that is an exact multiple of 1024 samples, avoiding the known
    /// 1024-block truncation bug. Confirms the `saveAudioArray` + `loadAudioArray`
    /// path is bit-exact when sample count is 1024-aligned.
    ///
    /// Uses a 1024-sample 440 Hz sine at 24 kHz. Asserts allclose(atol: 1e-6).
    ///
    /// NOTE — Int16 path: `saveAudioArray` writes float32 PCM WAV exclusively.
    /// There is no Int16 write path. The plan's byte-exact Int16 row is N/A.
    @Test func synthetic_float32_saveAudioArray_loadAudioArray_allclose() throws {
        let sampleRate: Double = 24_000
        // Use exactly 1024 samples (multiple of 1024) to avoid the truncation bug.
        let count = 1_024

        // Generate a 440 Hz sine wave scaled to [-0.5, 0.5].
        let samples: [Float] = (0..<count).map { i in
            Float(sin(2 * Double.pi * 440.0 * Double(i) / sampleRate)) * 0.5
        }
        let mlxSamples = MLXArray(samples)

        let scratchFile = scratchURL()
        defer { try? FileManager.default.removeItem(at: scratchFile) }

        // Write via saveAudioArray (standardFormatWithSampleRate path).
        try saveAudioArray(mlxSamples, sampleRate: sampleRate, to: scratchFile)

        // Read back via loadAudioArray.
        let (readSampleRate, readArray) = try loadAudioArray(from: scratchFile)

        #expect(readSampleRate == Int(sampleRate),
                "Sample rate mismatch: got \(readSampleRate), expected \(Int(sampleRate))")

        let readCount = readArray.shape[0]
        #expect(readCount == count,
                "Sample count mismatch: got \(readCount), expected \(count)")

        guard readCount == count else {
            // If counts don't match, skip allclose to avoid fatal MLX broadcast crash.
            return
        }

        let reference = MLXArray(samples)
        eval(readArray, reference)

        let diff = MLX.abs(readArray - reference)
        let maxDiff = diff.max().item(Float.self)
        let allClose = MLX.all(diff .<= Float(1e-6)).item(Bool.self)

        #expect(allClose,
                "Synthetic float32 round-trip allclose(atol:1e-6) failed; maxAbsDiff=\(maxDiff)")
    }
}
