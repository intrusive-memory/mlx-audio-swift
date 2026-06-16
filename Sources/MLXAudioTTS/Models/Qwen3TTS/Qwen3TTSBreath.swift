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

// MARK: - Optional crossfade seam (default-off scaffold)

/// Default-off flag for optional equal-power crossfade at breath seams.
/// When false (default), seams are direct concatenation (glosa-av = ~0 silence).
/// When true, `crossfadeConcatenateChunks` applies an equal-power crossfade.
///
/// **IMPORTANT**: Crossfade audio quality must be verified against real audio (A/B listen)
/// by the human user before this flag is ever enabled by default. It MUST NOT be enabled
/// by default in this mission. This is a dormant scaffold for future experimentation.
let breathSeamCrossfadeEnabled = false

/// Optional equal-power crossfade helper for chunk seams (invoked only when enabled).
///
/// Applies a constant-power (equal-power) crossfade of `fadeMilliseconds` duration
/// at each seam between consecutive chunks. The outgoing tail uses `cos(t * π/2)` weighting,
/// the incoming head uses `sin(t * π/2)`, ensuring power sums to 1 over the overlap.
///
/// - Parameters:
///   - chunks: Array of 1-D waveform chunks.
///   - sampleRate: Audio sample rate (e.g. 22050 for Qwen3-TTS output).
///   - fadeMilliseconds: Crossfade duration in milliseconds (default 5).
///
/// - Returns: Concatenated waveform with crossfades applied at seams, or via
///   plain concatenation if the flag is off or if any edge case prevents crossfade.
///
/// **Edge cases**:
/// - Empty input returns empty.
/// - Single chunk returns unchanged.
/// - If any chunk is shorter than the fade window, that seam falls back to plain concatenation.
func crossfadeConcatenateChunks(
    _ chunks: [MLXArray],
    sampleRate: Int,
    fadeMilliseconds: Double = 5
) -> MLXArray {
    // Dormant scaffold: only invoke if explicitly enabled (and verified A/B).
    guard breathSeamCrossfadeEnabled else { return concatenateChunks(chunks) }

    if chunks.isEmpty {
        return MLXArray(Array<Float>())
    }
    if chunks.count == 1 {
        return chunks[0]
    }

    let fadeSamples = Int(Double(sampleRate) * fadeMilliseconds / 1000.0)
    var resultData: [Float] = chunks[0].asArray(Float.self)

    for i in 1..<chunks.count {
        let incomingData: [Float] = chunks[i].asArray(Float.self)
        let outgoingLength = resultData.count
        let incomingLength = incomingData.count

        // Require both chunks to have enough samples for the fade window.
        if outgoingLength < fadeSamples || incomingLength < fadeSamples {
            // Edge case: chunk too short; fall back to plain concatenation for this seam.
            resultData.append(contentsOf: incomingData)
            continue
        }

        // Extract tail of outgoing and head of incoming.
        let outgoingTailStart = outgoingLength - fadeSamples
        let outgoingTail = Array(resultData[outgoingTailStart...])
        let incomingHead = Array(incomingData[..<fadeSamples])

        // Generate fade envelope: t ∈ [0, 1] over fadeSamples, with equal-power weighting.
        // Outgoing tail fades down via cos(t * π/2), incoming head fades up via sin(t * π/2).
        let piOverTwo = Float.pi / 2.0
        var crossfadedSeam = [Float](repeating: 0, count: fadeSamples)
        for j in 0..<fadeSamples {
            let t = Float(j) / Float(fadeSamples)
            let cosWeight = cos(t * piOverTwo)
            let sinWeight = sin(t * piOverTwo)
            crossfadedSeam[j] = outgoingTail[j] * cosWeight + incomingHead[j] * sinWeight
        }

        // Construct result: [outgoing (without tail)] + [crossfaded seam] + [incoming (without head)]
        resultData.removeLast(fadeSamples)
        resultData.append(contentsOf: crossfadedSeam)
        resultData.append(contentsOf: incomingData[fadeSamples...])
    }

    return MLXArray(resultData)
}
