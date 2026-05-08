import Foundation
import MLX
import MLXAudioCore
import MLXNN



// MARK: - SNAC Model

/// Scalable Neural Audio Codec (SNAC).
///
/// ## Telemetry
///
/// Attach a reporter via ``setTelemetry(_:)`` to receive
/// ``MLXAudioTelemetryEvent/codecEncodeStart(codec:inputSamples:)`` /
/// ``MLXAudioTelemetryEvent/codecEncodeComplete(codec:durationSeconds:compressionRatio:)`` and
/// ``MLXAudioTelemetryEvent/codecDecodeStart(codec:codedFrames:)`` /
/// ``MLXAudioTelemetryEvent/codecDecodeComplete(codec:durationSeconds:outputSamples:)``
/// (and ``MLXAudioTelemetryEvent/codecError(codec:operation:error:)`` on failure)
/// at the public encode/decode boundaries.
///
/// Use the async overloads ``encode(_:)`` (async) and ``decode(_:)`` (async)
/// to get telemetry emission; the synchronous overloads are retained for
/// backward-compatible callers.
public class SNAC: Module {
    public let samplingRate: Int
    public let encoderDim: Int
    public let encoderRates: [Int]
    public let decoderDim: Int
    public let decoderRates: [Int]
    public let latentDim: Int
    public let hopLength: Int
    public let nCodebooks: Int
    public let codebookSize: Int
    public let codebookDim: Int
    public let vqStrides: [Int]
    public let attnWindowSize: Int?

    let encoder: Encoder
    let quantizer: ResidualVectorQuantize
    let decoder: Decoder

    public init(
        samplingRate: Int = 44100,
        encoderDim: Int = 64,
        encoderRates: [Int] = [3, 3, 7, 7],
        latentDim: Int? = nil,
        decoderDim: Int = 1536,
        decoderRates: [Int] = [7, 7, 3, 3],
        attnWindowSize: Int? = 32,
        codebookSize: Int = 4096,
        codebookDim: Int = 8,
        vqStrides: [Int] = [8, 4, 2, 1],
        noise: Bool = true,
        depthwise: Bool = true
    ) {
        self.samplingRate = samplingRate
        self.encoderDim = encoderDim
        self.encoderRates = encoderRates
        self.decoderDim = decoderDim
        self.decoderRates = decoderRates

        // Calculate latent_dim if not provided
        let calculatedLatentDim = latentDim ?? (encoderDim * Int(pow(2.0, Double(encoderRates.count))))
        self.latentDim = calculatedLatentDim

        // Calculate hop_length (product of encoder rates)
        self.hopLength = encoderRates.reduce(1, *)

        self.nCodebooks = vqStrides.count
        self.codebookSize = codebookSize
        self.codebookDim = codebookDim
        self.vqStrides = vqStrides
        self.attnWindowSize = attnWindowSize

        self.encoder = Encoder(
            dModel: encoderDim,
            strides: encoderRates,
            depthwise: depthwise,
            attnWindowSize: attnWindowSize
        )

        self.quantizer = ResidualVectorQuantize(
            inputDim: calculatedLatentDim,
            codebookSize: codebookSize,
            codebookDim: codebookDim,
            vqStrides: vqStrides
        )

        self.decoder = Decoder(
            inputChannel: calculatedLatentDim,
            channels: decoderDim,
            rates: decoderRates,
            noise: noise,
            depthwise: depthwise,
            attnWindowSize: attnWindowSize
        )
        super.init()
        Telemetry.trackLifecycle(self, className: "SNAC.Model")
    }

    deinit {
        Telemetry.trackLifecycleEnd(className: "SNAC.Model")
    }

    // MARK: - Telemetry

    /// Optional vendor-neutral telemetry reporter. `nil` by default — zero
    /// overhead when no reporter is attached.
    private var telemetry: (any MLXAudioTelemetryReporter)?

    /// Attach or detach a telemetry reporter.
    ///
    /// Set to `nil` (the default) to disable telemetry entirely. Setting a
    /// reporter enables ``MLXAudioTelemetryEvent`` emission at every public
    /// encode/decode boundary.
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

    public func preprocess(_ audioData: MLXArray) -> MLXArray {
        let length = audioData.shape[audioData.ndim - 1]

        // Calculate LCM of all vq_strides
        var lcmValue = vqStrides[0]
        for i in 1..<vqStrides.count {
            lcmValue = lcm(lcmValue, vqStrides[i])
        }

        // Include attention window size in LCM calculation if present
        if let attnWindowSize = attnWindowSize {
            lcmValue = lcm(lcmValue, attnWindowSize)
        }

        let padTo = hopLength * lcmValue
        let rightPad = Int(ceil(Double(length) / Double(padTo))) * padTo - length

        // Pad the audio data: [(0, 0), (0, 0), (0, right_pad)]
        return audioData.padded([(0, 0), (0, 0), (0, rightPad)])
    }

    public func callAsFunction(_ audioData: MLXArray) -> (MLXArray, [MLXArray]) {
        let length = audioData.shape[audioData.ndim - 1]
        let preprocessed = preprocess(audioData)

        let z = encoder(preprocessed)
        let (zQ, codes) = quantizer(z)
        let audioHat = decoder(zQ)

        // Trim to original length
        let trimmed = audioHat[.ellipsis, 0..<length]
        return (trimmed, codes)
    }

    /// Encodes the input audio waveform into discrete codes (synchronous overload).
    ///
    /// This overload is retained for backward compatibility with existing
    /// synchronous callers. No public-surface telemetry is emitted from
    /// this path — use the `async` overload if you need telemetry.
    ///
    /// - Parameter audioData: The input audio waveform with shape (batch, channels, time) in NCT format.
    /// - Returns: An array of code tensors, one per RVQ codebook.
    public func encode(_ audioData: MLXArray) -> [MLXArray] {
        // S11: SNAC.encode interval (Level 2 = .operations).
        #if MLXAUDIO_TELEMETRY_FULL
        if Telemetry.level >= .operations {
            return Telemetry.emitInterval(name: "SNAC.encode", family: .codecs) {
                self._snacEncodeImpl(audioData)
            }
        }
        #endif
        return _snacEncodeImpl(audioData)
    }

    /// Encodes the input audio waveform into discrete codes with telemetry emission.
    ///
    /// Emits ``MLXAudioTelemetryEvent/codecEncodeStart(codec:inputSamples:)``
    /// before encoding, then
    /// ``MLXAudioTelemetryEvent/codecEncodeComplete(codec:durationSeconds:compressionRatio:)``
    /// on success.
    ///
    /// `inputSamples` is the last dimension of `audioData` (the time/samples
    /// dimension in NCT format: `[batch, channels, time]`).
    /// `compressionRatio` = `Double(inputBytes) / Double(outputBytes)` where
    /// `inputBytes = time × channels × 4` (Float32 input) and
    /// `outputBytes = total code elements across all codebooks × 4` (Int32 indices).
    /// If either byte count is zero the complete event is replaced by ``codecError``.
    ///
    /// Telemetry emission is a boundary-level operation — no events are emitted
    /// inside the per-codebook quantization loops.
    ///
    /// - Parameter audioData: The input audio waveform with shape (batch, channels, time) in NCT format.
    /// - Returns: An array of code tensors, one per RVQ codebook.
    public func encode(_ audioData: MLXArray) async -> [MLXArray] {
        // inputSamples: last dimension (time) of NCT-format [batch, channels, time].
        let inputSamples: Int = audioData.shape[audioData.ndim - 1]

        await emit(.codecEncodeStart(codec: "snac", inputSamples: inputSamples))

        let start = Date()
        let codes = _snacEncodeImpl(audioData)
        let elapsed = Date().timeIntervalSince(start)

        // inputBytes: time × channels × 4 (Float32). channels is dim ndim-2 in NCT.
        let channels = audioData.ndim >= 2 ? audioData.shape[audioData.ndim - 2] : 1
        let inputBytes = inputSamples * channels * 4
        // outputBytes: total code elements across all codebooks × 4 (Int32 indices).
        let outputElements = codes.reduce(0) { $0 + $1.shape.reduce(1, *) }
        let outputBytes = outputElements * 4

        if inputBytes > 0 && outputBytes > 0 {
            let compressionRatio = Double(inputBytes) / Double(outputBytes)
            await emit(.codecEncodeComplete(
                codec: "snac",
                durationSeconds: elapsed,
                compressionRatio: compressionRatio
            ))
        } else {
            await emit(.codecError(
                codec: "snac",
                operation: "encode",
                error: "compressionRatio unavailable: inputBytes=\(inputBytes) outputBytes=\(outputBytes)"
            ))
        }

        return codes
    }

    private func _snacEncodeImpl(_ audioData: MLXArray) -> [MLXArray] {
        let preprocessed = preprocess(audioData)
        let z = encoder(preprocessed)
        let (_, codes) = quantizer(z)
        return codes
    }

    /// Decodes the given codes into an output audio waveform (synchronous overload).
    ///
    /// This overload is retained for backward compatibility with existing
    /// synchronous callers. No public-surface telemetry is emitted from
    /// this path — use the `async` overload if you need telemetry.
    ///
    /// - Parameter codes: An array of code tensors, one per RVQ codebook.
    /// - Returns: The decoded audio waveform.
    public func decode(_ codes: [MLXArray]) -> MLXArray {
        // S11: SNAC.decode interval (Level 2 = .operations).
        #if MLXAUDIO_TELEMETRY_FULL
        if Telemetry.level >= .operations {
            return Telemetry.emitInterval(name: "SNAC.decode", family: .codecs) {
                self._snacDecodeImpl(codes)
            }
        }
        #endif
        return _snacDecodeImpl(codes)
    }

    /// Decodes the given codes into an output audio waveform with telemetry emission.
    ///
    /// Emits ``MLXAudioTelemetryEvent/codecDecodeStart(codec:codedFrames:)``
    /// before decoding, then
    /// ``MLXAudioTelemetryEvent/codecDecodeComplete(codec:durationSeconds:outputSamples:)``
    /// on success.
    ///
    /// `codedFrames` is the total number of code elements across all codebooks
    /// (sum of each codebook tensor's element count). `outputSamples` is the
    /// last dimension (time) of the decoded audio waveform in NCT format.
    ///
    /// Telemetry emission is a boundary-level operation — no events are emitted
    /// inside the per-codebook decode loop or VQ codebook lookups.
    ///
    /// - Parameter codes: An array of code tensors, one per RVQ codebook.
    /// - Returns: The decoded audio waveform.
    public func decode(_ codes: [MLXArray]) async -> MLXArray {
        // codedFrames: total code elements across all codebooks.
        let codedFrames = codes.reduce(0) { $0 + $1.shape.reduce(1, *) }

        await emit(.codecDecodeStart(codec: "snac", codedFrames: codedFrames))

        let start = Date()
        let audioHat = _snacDecodeImpl(codes)
        let elapsed = Date().timeIntervalSince(start)

        // outputSamples: last dimension (time) of the decoded audio in NCT format.
        let outputSamples: Int = audioHat.shape[audioHat.ndim - 1]

        await emit(.codecDecodeComplete(
            codec: "snac",
            durationSeconds: elapsed,
            outputSamples: outputSamples
        ))

        return audioHat
    }

    private func _snacDecodeImpl(_ codes: [MLXArray]) -> MLXArray {
        let zQ = quantizer.fromCodes(codes)
        let audioHat = decoder(zQ)
        return audioHat
    }

    // MARK: - Loading Methods

    public static func fromConfig(_ configPath: URL) throws -> SNAC {
        let data = try Data(contentsOf: configPath)
        let decoder = JSONDecoder()
        let config = try decoder.decode(SNACConfig.self, from: data)

        return SNAC(
            samplingRate: config.samplingRate,
            encoderDim: config.encoderDim,
            encoderRates: config.encoderRates,
            latentDim: config.latentDim,
            decoderDim: config.decoderDim,
            decoderRates: config.decoderRates,
            attnWindowSize: config.attnWindowSize,
            codebookSize: config.codebookSize,
            codebookDim: config.codebookDim,
            vqStrides: config.vqStrides,
            noise: config.noise,
            depthwise: config.depthwise
        )
    }

    public static func fromPretrained(_ modelRepo: String) async throws -> SNAC {
        print("[SNAC] Loading snac-24khz via Acervo strict API...")
        return try await AudioModelManager.loadWithAcervoStrict(componentId: "snac-24khz") { modelDir in
            let configPath = modelDir.appendingPathComponent("config.json")
            let weightsPath = modelDir.appendingPathComponent("model.safetensors")

            guard FileManager.default.fileExists(atPath: weightsPath.path) else {
                throw SNACError.modelNotFound("Could not find model at \(weightsPath.path)")
            }

            let snac = try fromConfig(configPath)

            let weights = try loadArrays(url: weightsPath)
            // S10: SNAC loadWeights interval (Level 2 = .operations).
            #if MLXAUDIO_TELEMETRY_FULL
            if Telemetry.level >= .operations {
                try Telemetry.emitInterval(
                    name: "SNAC.loadWeights",
                    family: .codecs,
                    message: "snac-24khz"
                ) {
                    try snac.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
                }
            } else {
                try snac.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
            }
            #else
            try snac.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
            #endif
            eval(snac)

            return snac
        }
    }
}

// MARK: - Helper Functions

func lcm(_ a: Int, _ b: Int) -> Int {
    return abs(a * b) / gcd(a, b)
}

func gcd(_ a: Int, _ b: Int) -> Int {
    var a = a
    var b = b
    while b != 0 {
        let temp = b
        b = a % b
        a = temp
    }
    return a
}
// MARK: - Error Types

public enum SNACError: Error {
    case modelNotFound(String)
    case configLoadError(String)
    case weightsLoadError(String)
}

// MARK: - Extension for Padded

extension MLXArray {
    func padded(_ padWidths: [(Int, Int)]) -> MLXArray {
        // Convert [(Int, Int)] to [IntOrPair]
        let paddingArray = padWidths.map { IntOrPair($0) }
        return MLX.padded(self, widths: paddingArray)
    }
}

