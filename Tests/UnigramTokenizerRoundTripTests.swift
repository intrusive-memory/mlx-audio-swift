//
//  UnigramTokenizerRoundTripTests.swift
//  MLXAudioTests
//
//  Sortie 20 Phase B of OPERATION ECHO DRAGNET — UnigramTokenizer round-trip
//  parity against the Python reference fixtures produced by Phase A.
//
//  Vocab source
//  ------------
//  Tests/media/parity/tokenizer/tokenizer.json — the mlx-community/pocket-tts
//  Unigram vocabulary (4000 entries) committed with byte_fallback patched to
//  true to match Swift's unconditional byte-fallback behaviour.  File is 239 KB.
//  See Tests/media/parity/tokenizer/_generate.py for provenance.
//
//  Reference fixture
//  -----------------
//  Tests/media/parity/tokenizer/unigram_reference.json — 14 entries emitted by
//  Phase A's _generate.py.  Format: [{"text": <str>, "ids": [<int>, ...]}, ...]
//
//  Test contract (for each of the 14 fixture entries)
//  --------------------------------------------------
//  1. Encode: tokenizer.encodeWithByteFallback(text) == referenceIds
//  2. Decode: tokenizer.decode(referenceIds) == text
//
//  Byte-fallback coverage
//  ----------------------
//  The fixture includes entries that exercise encodeWithByteFallback (line 207)
//  and decode (line 246) byte-token paths:
//    - "Test 123"     → [602, 552, 260, 341, 365, 450]  (▁1, 2, 3 as byte tokens)
//    - "test\ttab"    → [1115, 13, 274, 1222]            (tab via <0x09>)
//    - "Hello 中文"   → mixed in-vocab + byte-fallback CJK bytes
//    - "你好", "日本" etc. — pure CJK, all byte-fallback
//    - "😊", "🎵"    — emoji, all byte-fallback
//    - "测试"         — pure-CJK byte-fallback
//
//  CI-safe: no model downloads.  Vocab committed under Tests/media/parity/tokenizer/.
//  Zero modifications to Sources/ files.
//

import Foundation
import Testing

@testable import MLXAudioTTS

// MARK: - Fixture models

private struct TokenizerRoundTripEntry: Decodable {
    let text: String
    let ids: [Int]
}

// MARK: - UnigramTokenizerRoundTripTests

@Suite("UnigramTokenizerRoundTripTests")
struct UnigramTokenizerRoundTripTests {

    // MARK: - Shared setup

    /// Load the committed vocab file (byte_fallback=true patched) and construct
    /// the tokenizer once for the entire suite.  Throws on missing fixture.
    private static func makeTokenizer() throws -> UnigramTokenizer {
        guard let vocabURL = Bundle.module.url(
            forResource: "tokenizer",
            withExtension: "json",
            subdirectory: "media/parity/tokenizer"
        ) else {
            throw TestFixtureError.fileNotFound("media/parity/tokenizer/tokenizer.json")
        }
        let data = try Data(contentsOf: vocabURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try UnigramTokenizer(tokenizerJSON: json)
    }

    /// Load the 14-entry reference fixture.
    private static func loadFixtureEntries() throws -> [TokenizerRoundTripEntry] {
        guard let refURL = Bundle.module.url(
            forResource: "unigram_reference",
            withExtension: "json",
            subdirectory: "media/parity/tokenizer"
        ) else {
            throw TestFixtureError.fileNotFound("media/parity/tokenizer/unigram_reference.json")
        }
        let data = try Data(contentsOf: refURL)
        return try JSONDecoder().decode([TokenizerRoundTripEntry].self, from: data)
    }

    // MARK: - Encode round-trip (all 14 entries)

    /// For every fixture entry, assert that Swift encode produces the same token
    /// IDs as the Python reference.
    ///
    /// Byte-fallback path (UnigramTokenizer.swift:207) is exercised by entries
    /// that contain CJK, emoji, tab, or other out-of-vocab characters.
    @Test func encodeMatchesPythonReference() throws {
        let tokenizer = try UnigramTokenizerRoundTripTests.makeTokenizer()
        let entries = try UnigramTokenizerRoundTripTests.loadFixtureEntries()

        #expect(entries.count >= 10, "Expected at least 10 fixture entries; got \(entries.count)")

        var failures: [String] = []
        for entry in entries {
            let swiftIds = tokenizer.encodeWithByteFallback(entry.text)
            if swiftIds != entry.ids {
                failures.append(
                    "ENCODE mismatch for \(repr(entry.text)):\n"
                    + "  expected: \(entry.ids)\n"
                    + "  got:      \(swiftIds)"
                )
            }
        }
        #expect(failures.isEmpty, "Encode mismatches:\n\(failures.joined(separator: "\n"))")
    }

    // MARK: - Decode round-trip (all 14 entries)

    /// For every fixture entry, assert that Swift decode reconstructs the original
    /// text from the reference token IDs.
    ///
    /// Byte-token reassembly path (UnigramTokenizer.swift:246) is exercised by
    /// entries containing CJK characters, emoji, and the tab byte.
    @Test func decodeMatchesPythonReference() throws {
        let tokenizer = try UnigramTokenizerRoundTripTests.makeTokenizer()
        let entries = try UnigramTokenizerRoundTripTests.loadFixtureEntries()

        #expect(entries.count >= 10, "Expected at least 10 fixture entries; got \(entries.count)")

        var failures: [String] = []
        for entry in entries {
            let swiftDecoded = tokenizer.decode(entry.ids)
            if swiftDecoded != entry.text {
                failures.append(
                    "DECODE mismatch for ids=\(entry.ids):\n"
                    + "  expected: \(repr(entry.text))\n"
                    + "  got:      \(repr(swiftDecoded))"
                )
            }
        }
        #expect(failures.isEmpty, "Decode mismatches:\n\(failures.joined(separator: "\n"))")
    }

    // MARK: - Byte-fallback explicit coverage

    /// ASCII digit sequence "Test 123" must encode exactly as
    /// [602, 552, 260, 341, 365, 450] — the digits 1, 2, 3 are byte-fallback
    /// tokens (▁1, 2, 3).
    ///
    /// This guards against a regression where the tokenizer collapses "123"
    /// into a single numeric token rather than three separate byte tokens.
    @Test func byteFallbackDigitsEncodeCorrectly() throws {
        let tokenizer = try UnigramTokenizerRoundTripTests.makeTokenizer()
        let result = tokenizer.encodeWithByteFallback("Test 123")
        // ▁Test → 602, ▁1 → 552? Actually per fixture: [602, 552, 260, 341, 365, 450]
        // Swift must match Phase A reference exactly.
        #expect(result == [602, 552, 260, 341, 365, 450],
                "Expected [602, 552, 260, 341, 365, 450] for \"Test 123\", got \(result)")
    }

    /// The tab character (U+0009) is not a standalone Unigram token.
    /// "test\ttab" must decode back to the exact string "test\ttab" —
    /// i.e. the <0x09> byte token must round-trip through UTF-8 reassembly
    /// to produce the literal tab character.
    @Test func byteFallbackTabDecodeReconstructsTab() throws {
        let tokenizer = try UnigramTokenizerRoundTripTests.makeTokenizer()
        // IDs from Phase A fixture: [1115, 13, 274, 1222]
        let ids = [1115, 13, 274, 1222]
        let decoded = tokenizer.decode(ids)
        #expect(decoded == "test\ttab",
                "Expected \"test\\ttab\", got \(repr(decoded))")
    }

    /// Mixed in-vocab + byte-fallback: "Hello 中文" contains ASCII tokens for
    /// "Hello" and byte-fallback tokens for the CJK characters.
    /// decode must reconstruct the full string correctly.
    @Test func byteFallbackMixedCJKDecodeCorrectly() throws {
        let tokenizer = try UnigramTokenizerRoundTripTests.makeTokenizer()
        // IDs from Phase A fixture: [2994, 260, 232, 188, 177, 234, 154, 139]
        let ids = [2994, 260, 232, 188, 177, 234, 154, 139]
        let decoded = tokenizer.decode(ids)
        #expect(decoded == "Hello 中文",
                "Expected \"Hello 中文\", got \(repr(decoded))")
    }
}

// MARK: - Internal helpers

private enum TestFixtureError: Error, CustomStringConvertible {
    case fileNotFound(String)
    var description: String {
        switch self {
        case .fileNotFound(let path): return "Test fixture not found: \(path)"
        }
    }
}

/// Returns a debug-printable representation of a String, showing escape sequences
/// for non-printable characters (tab, newline, etc.).
private func repr(_ s: String) -> String {
    s.debugDescription
}
