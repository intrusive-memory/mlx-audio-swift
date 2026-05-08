//
//  Vocos.swift
//  MLXAudioCodecs
//
//  Created by Prince Canuma on 04/01/2026.
//

import Foundation
import MLX
import MLXAudioCore
import MLXNN

// MARK: - AdaLayerNorm

/// Adaptive Layer Normalization for conditional generation.
///
/// Learns scale and shift parameters conditioned on an embedding ID.
public class AdaLayerNorm: Module {
    let eps: Float
    let dim: Int
    @ModuleInfo(key: "scale") var scale: Linear
    @ModuleInfo(key: "shift") var shift: Linear

    public init(numEmbeddings: Int, embeddingDim: Int, eps: Float = 1e-6) {
        self.eps = eps
        self.dim = embeddingDim

        self._scale.wrappedValue = Linear(numEmbeddings, embeddingDim)
        self._shift.wrappedValue = Linear(numEmbeddings, embeddingDim)
    }

    public func callAsFunction(_ x: MLXArray, condEmbedding: MLXArray) -> MLXArray {
        let scaleVal = scale(condEmbedding)
        let shiftVal = shift(condEmbedding)

        // Manual layer norm without learnable parameters
        // Compute mean and variance along last axis
        let mean = MLX.mean(x, axis: -1, keepDims: true)
        let variance = MLX.variance(x, axis: -1, keepDims: true)
        let normalized = (x - mean) / MLX.sqrt(variance + eps)

        // Apply adaptive scale and shift: x * scale[:, None, :] + shift[:, None, :]
        let scaleBroadcast = scaleVal.expandedDimensions(axis: 1)
        let shiftBroadcast = shiftVal.expandedDimensions(axis: 1)

        return normalized * scaleBroadcast + shiftBroadcast
    }
}

// MARK: - ISTFTHead

/// ISTFT Head for converting decoder output to audio waveforms.
///
/// Predicts magnitude and phase from backbone output, then uses ISTFT to reconstruct audio.
public class ISTFTHead: Module {
    let nFft: Int
    let hopLength: Int
    @ModuleInfo(key: "out") var out: Linear

    public init(dim: Int, nFft: Int, hopLength: Int, padding: String = "center") {
        self.nFft = nFft
        self.hopLength = hopLength
        // Output n_fft + 2 for magnitude and phase (n_fft/2 + 1 each)
        self._out.wrappedValue = Linear(dim, nFft + 2)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Project to STFT coefficients: (B, L, C) -> (B, L, n_fft+2)
        var h = out(x)

        // Transpose: (B, L, n_fft+2) -> (B, n_fft+2, L)
        h = h.swappedAxes(1, 2)

        // Split into magnitude and phase
        let halfSize = (nFft + 2) / 2
        let mag = exp(h[0..., 0..<halfSize, 0...])
        let clippedMag = clip(mag, max: MLXArray(Float(1e2)))
        let phase = h[0..., halfSize..., 0...]

        // Construct complex STFT: S = mag * e^(i * phase)
        let cosPhase = cos(phase)
        let sinPhase = sin(phase)

        // For ISTFT, create complex representation
        let stftReal = clippedMag * cosPhase
        let stftImag = clippedMag * sinPhase

        // Perform ISTFT
        let audio = performISTFT(real: stftReal, imag: stftImag)

        return audio
    }

    /// Perform inverse STFT using overlap-add synthesis.
    private func performISTFT(real: MLXArray, imag: MLXArray) -> MLXArray {
        // real/imag shape: (B, n_fft/2+1, L)
        let batchSize = real.shape[0]
        let numFrames = real.shape[2]

        // Create window (matches Python hanning function)
        let window = hanningWindow(length: nFft)

        // Output length: t = (num_frames - 1) * hop_length + win_length
        let outputLength = (numFrames - 1) * hopLength + nFft

        var outputs: [MLXArray] = []

        for b in 0..<batchSize {
            // Get single batch: (n_fft/2+1, L)
            let realB = real[b]
            let imagB = imag[b]

            // Create complex STFT
            let complexSpec = realB + MLXArray(real: Float(0), imaginary: Float(1)) * imagB

            // Perform IRFFT along axis 0 (frequency axis)
            let framesFreq = MLXFFT.irfft(complexSpec, axis: 0)

            // Transpose to get (num_frames, n_fft)
            let framesTime = framesFreq.transposed(1, 0)

            // Apply window
            let windowedFrames = framesTime * window

            // Overlap-add synthesis
            var audioSamples = [Float](repeating: 0, count: outputLength)
            var windowSum = [Float](repeating: 0, count: outputLength)

            let windowArray = window.asArray(Float.self)

            for i in 0..<numFrames {
                let start = i * hopLength
                let frameData = windowedFrames[i].asArray(Float.self)

                for j in 0..<min(nFft, frameData.count) {
                    if start + j < outputLength {
                        audioSamples[start + j] += frameData[j]
                        windowSum[start + j] += windowArray[j] * windowArray[j]
                    }
                }
            }

            // Normalize by window sum
            for i in 0..<outputLength {
                if windowSum[i] != 0 {
                    audioSamples[i] /= windowSum[i]
                }
            }

            // Trim center padding
            let trimStart = nFft / 2
            let trimEnd = outputLength - nFft / 2
            let trimmedAudio: [Float]
            if trimEnd > trimStart {
                trimmedAudio = Array(audioSamples[trimStart..<trimEnd])
            } else {
                trimmedAudio = audioSamples
            }

            outputs.append(MLXArray(trimmedAudio))
        }

        // Stack outputs — always preserve batch dimension
        return MLX.stacked(outputs, axis: 0)
    }

    /// Generate Hanning window
    private func hanningWindow(length: Int) -> MLXArray {
        if length == 1 {
            return MLXArray([Float(1.0)])
        }
        let n = Array(stride(from: 0, to: length, by: 1)).map { Float($0) }
        let factor = Float.pi / Float(length)
        let window = n.map { 0.5 - 0.5 * cos(2.0 * factor * $0) }
        return MLXArray(window)
    }
}

// MARK: - Feature Extractor Protocol

/// Protocol for feature extractors used by Vocos.
public protocol FeatureExtractor {
    func callAsFunction(_ audio: MLXArray, bandwidthId: Int?) -> MLXArray
}

// MARK: - EncodecFeatures

/// Feature extractor that uses Encodec to extract audio features.
///
/// This class wraps an Encodec model to extract features from audio for use with Vocos.
public class EncodecFeatures: Module {
    @ModuleInfo(key: "encodec") var encodec: Encodec
    public let bandwidths: [Float]
    public let numQ: Int
    @ModuleInfo(key: "codebook_weights") var codebookWeights: MLXArray

    public init(
        encodecModel: String = "encodec_24khz",
        bandwidths: [Float] = [1.5, 3.0, 6.0, 12.0],
        trainCodebooks: Bool = false
    ) async throws {
        self.bandwidths = bandwidths

        // Load the Encodec model
        let repoId: String
        switch encodecModel {
        case "encodec_24khz":
            repoId = "mlx-community/encodec-24khz-float32"
        case "encodec_48khz":
            repoId = "mlx-community/encodec-48khz-float32"
        default:
            throw EncodecFeaturesError.unsupportedModel(encodecModel)
        }

        let model = try await Encodec.fromPretrained(repoId)
        self._encodec.wrappedValue = model

        // Get number of quantizers for max bandwidth
        let maxBandwidth = bandwidths.max() ?? 12.0
        self.numQ = model.quantizer.getNumQuantizersForBandwidth(maxBandwidth)

        // Concatenate codebook embeddings
        var codebookEmbeds: [MLXArray] = []
        for i in 0..<numQ {
            codebookEmbeds.append(model.quantizer.layers[i].codebook.embed)
        }
        self._codebookWeights.wrappedValue = MLX.concatenated(codebookEmbeds, axis: 0)
    }

    /// Get encodec codes for the given audio.
    public func getEncodecCodes(_ audio: MLXArray, bandwidthId: Int) -> MLXArray {
        // Preprocess audio - add channel dimension if needed
        var processedAudio = audio
        if processedAudio.ndim == 1 {
            processedAudio = processedAudio.expandedDimensions(axis: 0).expandedDimensions(axis: -1)
        } else if processedAudio.ndim == 2 {
            processedAudio = processedAudio.expandedDimensions(axis: -1)
        }

        let bandwidth = bandwidths[bandwidthId]
        let (codes, _) = encodec.encode(processedAudio, bandwidth: bandwidth)

        // Reshape codes: (num_chunks, batch, num_codebooks, frames) -> (num_codebooks, 1, frames)
        let reshaped = codes.reshaped([codes.shape[2], 1, codes.shape[3]])
        return reshaped
    }

    /// Get features from encodec codes.
    public func getFeaturesFromCodes(_ codes: MLXArray) -> MLXArray {
        let codebookSize = encodec.quantizer.codebookSize
        let numCodebooks = codes.shape[0]

        // Create offsets for each codebook
        let offsetValues = (0..<numCodebooks).map { $0 * codebookSize }
        let offsets = MLXArray(offsetValues.map { Int32($0) })

        // Add offsets to codes: (num_codebooks, 1, frames) + (num_codebooks, 1, 1)
        let offsetsReshaped = offsets.reshaped([numCodebooks, 1, 1])
        let embeddingsIdxs = codes + offsetsReshaped

        // Gather embeddings
        let embeddings = codebookWeights[embeddingsIdxs]

        // Sum across codebooks: (num_codebooks, 1, frames, embed_dim) -> (1, frames, embed_dim)
        let features = embeddings.sum(axis: 0)

        return features
    }

    /// Extract features from audio.
    public func callAsFunction(_ audio: MLXArray, bandwidthId: Int) -> MLXArray {
        let codes = getEncodecCodes(audio, bandwidthId: bandwidthId)
        return getFeaturesFromCodes(codes)
    }
}

/// Errors for EncodecFeatures.
public enum EncodecFeaturesError: Error {
    case unsupportedModel(String)
}

// MARK: - Vocos

/// Vocos vocoder model for high-quality audio synthesis.
///
/// Combines a feature extractor, backbone, and ISTFT head for audio reconstruction.
///
/// ## Telemetry
///
/// Attach a reporter via ``setTelemetry(_:)`` to receive
/// ``MLXAudioTelemetryEvent/codecDecodeStart(codec:codedFrames:)`` and
/// ``MLXAudioTelemetryEvent/codecDecodeComplete(codec:durationSeconds:outputSamples:)``
/// (and ``MLXAudioTelemetryEvent/codecError(codec:operation:error:)`` on failure)
/// at the public decode boundary.
///
/// Vocos is a pure vocoder — it converts feature frames to audio waveform
/// and therefore exposes only decode telemetry events (no encode path).
///
/// Use the async ``decode(_:bandwidthId:)`` overload to get telemetry emission;
/// the synchronous overload is retained for backward-compatible callers.
public class Vocos: Module {
    @ModuleInfo(key: "backbone") var backbone: VocosBackbone
    @ModuleInfo(key: "head") var head: ISTFTHead

    // MARK: - Telemetry

    /// Optional vendor-neutral telemetry reporter. `nil` by default — zero
    /// overhead when no reporter is attached.
    private var telemetry: (any MLXAudioTelemetryReporter)?

    /// Attach or detach a telemetry reporter.
    ///
    /// Set to `nil` (the default) to disable telemetry entirely. Setting a
    /// reporter enables ``MLXAudioTelemetryEvent`` emission at every public
    /// decode boundary.
    public func setTelemetry(_ reporter: (any MLXAudioTelemetryReporter)?) {
        self.telemetry = reporter
    }

    /// Canonical per-instance emit helper (copied verbatim from
    /// `MLXAudioTelemetryReporter.swift` doc comment).
    ///
    /// The `@autoclosure` is load-bearing: when `telemetry` is `nil` the
    /// closure is never evaluated, so payload-construction work (shape
    /// reads, multiplications) is completely elided.
    private func emit(_ event: @autoclosure () -> MLXAudioTelemetryEvent) async {
        guard let telemetry else { return }
        await telemetry.capture(event())
    }

    // MARK: - Lifecycle

    public init(
        backbone: VocosBackbone,
        head: ISTFTHead
    ) {
        self._backbone.wrappedValue = backbone
        self._head.wrappedValue = head
        super.init()
        Telemetry.trackLifecycle(self, className: "Vocos.Model")
    }

    deinit {
        Telemetry.trackLifecycleEnd(className: "Vocos.Model")
    }

    // MARK: - Decode implementation (private)

    /// Internal synchronous implementation shared by the public sync and
    /// async decode overloads. Keeping the computation in a private method
    /// avoids overload-resolution ambiguity when the async overload calls
    /// the sync one.
    private func _decodeImpl(_ features: MLXArray, bandwidthId: MLXArray?) -> MLXArray {
        // S11: Vocos.decode interval (Level 2 = .operations).
        #if MLXAUDIO_TELEMETRY_FULL
        if Telemetry.level >= .operations {
            return Telemetry.emitInterval(name: "Vocos.decode", family: .codecs) {
                let x = self.backbone(features, bandwidthId: bandwidthId)
                let audioOutput = self.head(x)
                return audioOutput
            }
        }
        #endif
        let x = backbone(features, bandwidthId: bandwidthId)
        let audioOutput = head(x)
        return audioOutput
    }

    // MARK: - Decode (synchronous — backward-compatible)

    /// Decode features to audio waveform (synchronous overload).
    ///
    /// This overload is retained for backward compatibility with existing
    /// synchronous callers. No public-surface telemetry is emitted from
    /// this path — use the ``async`` overload if you need telemetry.
    public func decode(_ features: MLXArray, bandwidthId: MLXArray? = nil) -> MLXArray {
        return _decodeImpl(features, bandwidthId: bandwidthId)
    }

    // MARK: - Decode (async — instrumented)

    /// Decode features to audio waveform with telemetry emission.
    ///
    /// Emits ``MLXAudioTelemetryEvent/codecDecodeStart(codec:codedFrames:)``
    /// before the backbone+ISTFT pass, then
    /// ``MLXAudioTelemetryEvent/codecDecodeComplete(codec:durationSeconds:outputSamples:)``
    /// on success.
    ///
    /// Vocos is a pure vocoder and has no encode path — no
    /// ``MLXAudioTelemetryEvent/codecEncodeStart`` or
    /// ``MLXAudioTelemetryEvent/codecEncodeComplete`` events are emitted.
    ///
    /// `codedFrames` is the number of time frames in the feature tensor
    /// (dimension 1 of a `[batch, frames, channels]` input). Telemetry
    /// emission is a boundary-level operation — no events are emitted inside
    /// the ConvNeXt block loop or the per-batch ISTFT overlap-add loop.
    ///
    /// - Parameters:
    ///   - features: Input feature tensor. Shape `[B, L, C]` (or `[B, C, L]`;
    ///     the backbone handles the transpose internally).
    ///   - bandwidthId: Optional bandwidth-conditioning embedding for
    ///     adaptive-norm backbones.
    /// - Returns: Audio waveform tensor.
    public func decode(_ features: MLXArray, bandwidthId: MLXArray? = nil) async -> MLXArray {
        // Determine the number of coded frames at the boundary (before any
        // computation). We read the middle dimension of the raw input.
        // For non-3-D inputs (degenerate / unit-batch) we fall back to
        // the first dimension.
        let codedFrames: Int = {
            if features.ndim >= 3 {
                return features.shape[1]
            }
            return features.shape[0]
        }()

        await emit(.codecDecodeStart(codec: "vocos", codedFrames: codedFrames))

        let start = Date()
        let audioOutput = _decodeImpl(features, bandwidthId: bandwidthId)
        let elapsed = Date().timeIntervalSince(start)

        // Output sample count: for ≥2-D output [B, samples] we sum all
        // dimensions after the batch; for 1-D output the single dimension
        // is the sample count.
        let outputSamples: Int = {
            if audioOutput.ndim >= 2 {
                return audioOutput.shape.dropFirst().reduce(1, *)
            }
            return audioOutput.shape[0]
        }()

        await emit(.codecDecodeComplete(
            codec: "vocos",
            durationSeconds: elapsed,
            outputSamples: outputSamples
        ))

        return audioOutput
    }

    // MARK: - callAsFunction (synchronous — backward-compatible)

    /// Forward pass: extract features and decode to audio.
    ///
    /// Delegates to the synchronous ``decode(_:bandwidthId:)`` overload.
    /// For telemetry, call ``decode(_:bandwidthId:)`` from an `async` context.
    public func callAsFunction(_ features: MLXArray, bandwidthId: MLXArray? = nil) -> MLXArray {
        return decode(features, bandwidthId: bandwidthId)
    }
}
