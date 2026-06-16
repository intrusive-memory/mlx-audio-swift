//
//  Qwen3TTSBreathSplitTests.swift
//  MLXAudioTests
//
//  Sortie 2 of OPERATION SEAMSTRESS BELLOWS — CI-safe unit tests for
//  splitTextAtBreaths(_:offsets:) (TR1).
//
//  The function under test lives in:
//    Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSBreath.swift
//  It is file-internal and reached via @testable import MLXAudioTTS.
//
//  Contract (verified against source):
//  - Offsets are cut points in text.unicodeScalars (NOT grapheme clusters).
//  - end = text.unicodeScalars.count.
//  - Only STRICTLY-INTERIOR offsets are used: 0 < offset < end.
//  - Offsets <= 0 or >= end are dropped.
//  - Offsets are de-duplicated and sorted internally.
//  - Empty input string returns [].
//  - No interior cut points returns [text] (single segment).
//  - Concatenating returned segments in order reconstructs the original text.
//
//  CI-safe: no model downloads, no App Group access, no MLXArray.
//

import Testing

@testable import MLXAudioTTS

// MARK: - Qwen3TTSBreathSplitTests

@Suite("Qwen3TTSBreathSplitTests")
struct Qwen3TTSBreathSplitTests {

    // MARK: - TR1-a: empty offsets → single segment equal to input

    /// When no offsets are provided, the entire text is returned as one segment.
    @Test func emptyOffsetsReturnsSingleSegment() {
        let text = "Hello, world!"
        let result = splitTextAtBreaths(text, offsets: [])
        #expect(result.count == 1, "Expected 1 segment, got \(result.count)")
        #expect(result[0] == text, "Expected segment to equal original text")
    }

    // MARK: - TR1-b: unsorted offsets → same result as sorted version

    /// Offsets given in reverse/random order produce the same result as sorted offsets.
    @Test func unsortedOffsetsMatchSortedResult() {
        let text = "abcdefgh"   // 8 ASCII scalars, indices 0–7
        // Interior cut points at 3 and 6 (0 < 3 < 6 < 8)
        let sortedResult   = splitTextAtBreaths(text, offsets: [3, 6])
        let unsortedResult = splitTextAtBreaths(text, offsets: [6, 3])
        #expect(
            sortedResult == unsortedResult,
            "Unsorted offsets should produce same result as sorted offsets"
        )
        // Also verify the actual segments are what we expect
        #expect(sortedResult == ["abc", "def", "gh"])
    }

    // MARK: - TR1-c: duplicate offsets → de-duplicated; no empty segment leaks

    /// Duplicate offsets are collapsed; no empty string appears in the result.
    @Test func duplicateOffsetsProduceNoEmptySegments() {
        let text = "one two three"   // 13 ASCII scalars
        // Cut at 4, then duplicate at 4, and another cut at 7
        let result = splitTextAtBreaths(text, offsets: [4, 4, 4, 7])
        // Expected segments: "one " (0..<4), "two" (4..<7), " three" (7..<13)
        #expect(result.count == 3, "Expected 3 segments, got \(result.count)")
        #expect(!result.contains(""), "No empty segment should appear after de-duplication")
        #expect(result[0] == "one ")
        #expect(result[1] == "two")
        #expect(result[2] == " three")
    }

    // MARK: - TR1-d: out-of-range offsets (negative AND > length) → ignored

    /// Offsets that are negative or >= unicodeScalars.count are silently dropped.
    @Test func outOfRangeOffsetsAreIgnored() {
        let text = "hello"   // 5 ASCII scalars, end = 5
        // -1 and 5 are both out of range (need strictly interior: 0 < offset < 5)
        // 100 is also out of range. Only 2 is valid.
        let result = splitTextAtBreaths(text, offsets: [-1, 2, 5, 100])
        // Only cut at 2 applies → ["he", "llo"]
        #expect(result.count == 2, "Expected 2 segments, got \(result.count)")
        #expect(result[0] == "he")
        #expect(result[1] == "llo")
    }

    // MARK: - TR1-e: offset at 0 and at end → no spurious leading/trailing empty chunk

    /// Offset exactly at 0 and exactly at unicodeScalars.count both produce no
    /// spurious empty leading or trailing segment.
    @Test func boundaryOffsetsProduceNoSpuriousEmptyChunks() {
        let text = "swift"   // 5 ASCII scalars, end = 5
        // 0 and 5 are both boundary values and must be dropped
        let result = splitTextAtBreaths(text, offsets: [0, 5])
        #expect(result.count == 1, "Expected 1 segment (no spurious empties), got \(result.count)")
        #expect(result[0] == text)

        // Mixed: boundary offsets alongside a valid interior cut
        let mixed = splitTextAtBreaths(text, offsets: [0, 2, 5])
        #expect(mixed.count == 2, "Expected 2 segments with only the interior cut, got \(mixed.count)")
        #expect(mixed[0] == "sw")
        #expect(mixed[1] == "ift")
    }

    // MARK: - TR1-f: multibyte / emoji / combining-mark split on scalar counts

    /// Emoji and combining marks occupy multiple unicode scalars.
    /// Split boundaries must be computed using unicodeScalars arithmetic,
    /// NOT grapheme cluster counts.
    ///
    /// Test string construction (verify every count before asserting):
    ///
    ///   "A"       → 1 scalar  (U+0041)
    ///   "e\u{301}" → 2 scalars (U+0065 LATIN SMALL LETTER E + U+0301 COMBINING ACUTE ACCENT)
    ///   "🏴"      → 1 scalar  (U+1F3F4 BLACK FLAG) — single code point, single scalar
    ///   "🇩🇪"    → 2 scalars  (U+1F1E9 REGIONAL INDICATOR D + U+1F1EA REGIONAL INDICATOR E)
    ///   "B"       → 1 scalar  (U+0042)
    ///
    ///   Total = 1 + 2 + 1 + 2 + 1 = 7 scalars
    ///
    /// Cut at scalar index 3 (after "Ae\u{301}🏴" — i.e., scalars 0,1,2 → first segment)
    /// → segment 0: "Ae\u{301}🏴"  (3 scalars)
    /// → segment 1: "🇩🇪B"         (4 scalars = 2+1+1... wait, 2+1 = 3 scalars for 🇩🇪B)
    ///
    /// Let's be precise. Cut at scalar index 3:
    ///   scalars[0..<3]: U+0041, U+0065, U+0301  → "Aé" (2 grapheme clusters, 3 scalars)
    ///   scalars[3..<7]: U+1F3F4, U+1F1E9, U+1F1EA, U+0042  → "🏴🇩🇪B"
    @Test func multibyteEmojiSplitOnScalarCounts() {
        // Build the string explicitly using unicode scalars.
        // "A" + "e" + combining acute + black flag + flag-DE + "B"
        let part0: String = "A"                            // 1 scalar
        let part1: String = "e\u{0301}"                   // 2 scalars (e + combining acute)
        let part2: String = "\u{1F3F4}"                   // 1 scalar  (🏴 BLACK FLAG)
        let part3: String = "\u{1F1E9}\u{1F1EA}"          // 2 scalars (🇩🇪 flag sequence)
        let part4: String = "B"                            // 1 scalar

        let text = part0 + part1 + part2 + part3 + part4

        // Verify scalar counts match expectations before asserting on the split.
        let scalarCount = text.unicodeScalars.count
        #expect(scalarCount == 7, "Expected 7 scalars, got \(scalarCount)")

        // Also verify grapheme cluster count to show it differs.
        let graphemeCount = text.count   // .count uses grapheme clusters
        // graphemes: "A", "é" (e+◌́), "🏴", "🇩🇪", "B" = 5 grapheme clusters
        #expect(graphemeCount == 5, "Expected 5 grapheme clusters, got \(graphemeCount)")

        // Cut at scalar index 3 → splits after "Aé" (scalars 0,1,2)
        let result = splitTextAtBreaths(text, offsets: [3])
        #expect(result.count == 2, "Expected 2 segments from scalar-index cut at 3, got \(result.count)")

        // Verify scalar lengths of each segment match the cut arithmetic.
        let seg0ScalarCount = result[0].unicodeScalars.count
        let seg1ScalarCount = result[1].unicodeScalars.count
        #expect(seg0ScalarCount == 3, "segment[0] should have 3 scalars, got \(seg0ScalarCount)")
        #expect(seg1ScalarCount == 4, "segment[1] should have 4 scalars, got \(seg1ScalarCount)")

        // Verify the actual content of each segment.
        let expectedSeg0 = part0 + part1    // "Aé" — 3 scalars (A, e, combining acute)
        let expectedSeg1 = part2 + part3 + part4  // "🏴🇩🇪B" — 4 scalars
        #expect(result[0] == expectedSeg0, "segment[0] mismatch: got \(result[0].debugDescription)")
        #expect(result[1] == expectedSeg1, "segment[1] mismatch: got \(result[1].debugDescription)")
    }

    // MARK: - TR1-g: round-trip — joining all segments reconstructs original text

    /// Concatenating all returned segments in order must exactly reproduce the
    /// original input text, for several inputs including the emoji/combining case.
    @Test func roundTripConcatenationReconstructsOriginal() {
        let cases: [(text: String, offsets: [Int])] = [
            // Plain ASCII, multiple cuts
            ("The quick brown fox", [4, 10, 16]),
            // Single character split
            ("ab", [1]),
            // Only boundary offsets (no real cut → single segment)
            ("foobar", [0, 6]),
            // Negative, boundary, and a valid interior cut mixed in
            ("abcde", [-99, 0, 3, 5, 200]),
            // Duplicates scattered among valid cuts
            ("Hello, World!", [7, 7, 7]),
            // Emoji and combining marks (mirrors TR1-f)
            ("A" + "e\u{0301}" + "\u{1F3F4}" + "\u{1F1E9}\u{1F1EA}" + "B", [3]),
            // Empty string — result is [], joined is ""
            ("", [1, 2, 3]),
        ]

        for (text, offsets) in cases {
            let segments = splitTextAtBreaths(text, offsets: offsets)
            let joined = segments.joined()
            #expect(
                joined == text,
                "Round-trip failed for \(text.debugDescription) with offsets \(offsets): joined=\(joined.debugDescription)"
            )
        }
    }
}
