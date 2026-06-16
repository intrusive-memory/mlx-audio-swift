// Pure split/concat helpers for Qwen3-TTS breath-aware chunked synthesis (FR3).
// Side-effect free, deterministic utilities used to partition input text at
// breath boundaries and to reassemble per-chunk waveforms into a single stream.

@preconcurrency import MLX
import Foundation

// MARK: - Text splitting

/// Splits `text` into segments at the given unicode-scalar `offsets`.
///
/// Behavior:
/// - Offsets are interpreted as cut points in `text.unicodeScalars`.
/// - Offsets are sorted and de-duplicated.
/// - Out-of-range offsets (`< 0` or `> text.unicodeScalars.count`) are ignored/clamped.
/// - The boundary offsets `0` and `end` produce no spurious leading/trailing empty
///   segment; empty segments are dropped.
/// - Pure, deterministic, and side-effect free.
///
/// Concatenating the returned segments in order reconstructs the original `text`.
func splitTextAtBreaths(_ text: String, offsets: [Int]) -> [String] {
    let scalars = text.unicodeScalars
    let end = scalars.count

    // Keep only interior cut points: sorted, de-duplicated, strictly inside (0, end).
    let cuts = Array(Set(offsets.filter { $0 > 0 && $0 < end })).sorted()

    if cuts.isEmpty {
        return text.isEmpty ? [] : [text]
    }

    var segments: [String] = []
    var previous = 0
    for cut in cuts {
        let lower = scalars.index(scalars.startIndex, offsetBy: previous)
        let upper = scalars.index(scalars.startIndex, offsetBy: cut)
        let segment = String(scalars[lower ..< upper])
        if !segment.isEmpty { segments.append(segment) }
        previous = cut
    }
    // Trailing segment from the last cut to the end.
    let lower = scalars.index(scalars.startIndex, offsetBy: previous)
    let tail = String(scalars[lower ..< scalars.endIndex])
    if !tail.isEmpty { segments.append(tail) }

    return segments
}

// MARK: - Waveform concatenation

/// Concatenates 1-D waveform chunks along axis 0.
///
/// - A single chunk is returned unchanged.
/// - An empty input returns a defined empty 1-D `Float` `MLXArray`.
func concatenateChunks(_ chunks: [MLXArray]) -> MLXArray {
    if chunks.isEmpty {
        return MLXArray(Array<Float>())
    }
    if chunks.count == 1 {
        return chunks[0]
    }
    return concatenated(chunks, axis: 0)
}
