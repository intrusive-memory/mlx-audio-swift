import Foundation
import MLX
import MLXAudioCore
import MLXNN
import MLXLMCommon
import Tokenizers
import SwiftAcervo

// MARK: - Configs

public struct MimiConfig {
    public let channels: Int
    public let sampleRate: Double
    public let frameRate: Double
    public let renormalize: Bool
    public let seanet: SeanetConfig
    public let transformer: TransformerConfig
    public let quantizerNQ: Int
    public let quantizerBins: Int
    public let quantizerDim: Int

    public init(
        channels: Int,
        sampleRate: Double,
        frameRate: Double,
        renormalize: Bool,
        seanet: SeanetConfig,
        transformer: TransformerConfig,
        quantizerNQ: Int,
        quantizerBins: Int,
        quantizerDim: Int
    ) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.frameRate = frameRate
        self.renormalize = renormalize
        self.seanet = seanet
        self.transformer = transformer
        self.quantizerNQ = quantizerNQ
        self.quantizerBins = quantizerBins
        self.quantizerDim = quantizerDim
    }
}

@inline(__always) private func product(_ xs: [Int]) -> Int { xs.reduce(1, *) }

public func mimi_202407(numCodebooks: Int) -> MimiConfig {
    let seanet = SeanetConfig(
        dimension: 512,
        channels: 1,
        causal: true,
        nfilters: 64,
        nresidualLayers: 1,
        ratios: [8, 6, 5, 4],
        ksize: 7,
        residualKsize: 3,
        lastKsize: 3,
        dilationBase: 2,
        padMode: .constant,
        trueSkip: true,
        compress: 2
    )
    let transformer = TransformerConfig(
        dModel: seanet.dimension,
        numHeads: 8,
        numLayers: 8,
        causal: true,
        normFirst: true,
        biasFF: false,
        biasAttn: false,
        layerScale: 0.01,
        positionalEmbedding: "rope",
        useConvBlock: false,
        crossAttention: false,
        convKernelSize: 3,
        useConvBias: true,
        gating: false,
        norm: "layer_norm",
        context: 250,
        maxPeriod: 10_000,
        maxSeqLen: 8_192,
        kvRepeat: 1,
        dimFeedforward: 2_048,
        convLayout: true // transformer expects [B,C,T] at API boundary
    )
    return MimiConfig(
        channels: 1,
        sampleRate: 24_000,
        frameRate: 12.5,
        renormalize: true,
        seanet: seanet,
        transformer: transformer,
        quantizerNQ: numCodebooks,
        quantizerBins: 2_048,
        quantizerDim: 256
    )
}

// MARK: - Mimi

/// Mimi neural audio codec.
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
/// Use the async overloads ``encode(_:)`` (async), ``decode(_:)`` (async),
/// and ``encodeStep(_:)`` (async) to get telemetry emission;
/// the synchronous overloads are retained for backward-compatible callers.
///
/// For streaming decode through ``MimiStreamingDecoder``, call
/// ``MimiStreamingDecoder/setTelemetry(_:)`` on the streaming decoder — it
/// emits ``codecDecodeStart`` / ``codecDecodeComplete`` once per
/// ``MimiStreamingDecoder/decodeFrames(_:)`` call (never inside the per-frame
/// loop).
public final class Mimi: Module {
    public let cfg: MimiConfig

    @ModuleInfo public var encoder: SeanetEncoder
    @ModuleInfo public var decoder: SeanetDecoder
    @ModuleInfo public var quantizer: SplitResidualVectorQuantizer

    @ModuleInfo public var encoder_transformer: ProjectedTransformer
    @ModuleInfo public var decoder_transformer: ProjectedTransformer

    @ModuleInfo public var downsample: ConvDownsample1d
    @ModuleInfo public var upsample: ConvTrUpsample1d

    public private(set) var encoderCache: [KVCache]
    public private(set) var decoderCache: [KVCache]

    private let downsampleStride: Int

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

    public init(cfg: MimiConfig) {
        self.cfg = cfg

        let encFPS = cfg.sampleRate / Double(product(cfg.seanet.ratios))
        self.downsampleStride = Int(encFPS / cfg.frameRate)

        self._encoder = ModuleInfo(wrappedValue: SeanetEncoder(cfg: cfg.seanet))
        self._decoder = ModuleInfo(wrappedValue: SeanetDecoder(cfg: cfg.seanet))

        self._quantizer = ModuleInfo(wrappedValue: SplitResidualVectorQuantizer(
            dim: cfg.quantizerDim,
            inputDim: cfg.seanet.dimension,
            outputDim: cfg.seanet.dimension,
            nq: cfg.quantizerNQ,
            bins: cfg.quantizerBins
        ))

        self._encoder_transformer = ModuleInfo(wrappedValue: ProjectedTransformer(
            cfg: cfg.transformer,
            inputDim: cfg.seanet.dimension,
            outputDims: [cfg.seanet.dimension]
        ))
        self._decoder_transformer = ModuleInfo(wrappedValue: ProjectedTransformer(
            cfg: cfg.transformer,
            inputDim: cfg.seanet.dimension,
            outputDims: [cfg.seanet.dimension]
        ))

        self._downsample = ModuleInfo(wrappedValue: ConvDownsample1d(
            stride: downsampleStride, dim: cfg.seanet.dimension, causal: true
        ))
        self._upsample = ModuleInfo(wrappedValue: ConvTrUpsample1d(
            stride: downsampleStride, dim: cfg.seanet.dimension, causal: true
        ))

        self.encoderCache = _encoder_transformer.wrappedValue.makeCache()
        self.decoderCache = _decoder_transformer.wrappedValue.makeCache()
        super.init()
        Telemetry.trackLifecycle(self, className: "Mimi.Model")
    }

    deinit {
        Telemetry.trackLifecycleEnd(className: "Mimi.Model")
    }

    public func resetState() {
        encoder.resetState()
        decoder.resetState()
        for c in decoderCache { c.trim(c.offset)}
        for c in encoderCache { c.trim(c.offset) }
    }

    public var frameRate: Double { cfg.frameRate }
    public var sampleRate: Double { cfg.sampleRate }

    /// Encodes the input audio waveform into discrete codes (synchronous overload).
    ///
    /// This overload is retained for backward compatibility with existing
    /// synchronous callers. No public-surface telemetry is emitted from
    /// this path — use the `async` overload if you need telemetry.
    public func encode(_ xs: MLXArray) -> MLXArray {
        // S11: Mimi.encode interval (Level 2 = .operations).
        #if MLXAUDIO_TELEMETRY_FULL
        if Telemetry.level >= .operations {
            return Telemetry.emitInterval(name: "Mimi.encode", family: .codecs) {
                self.encoder.resetState()
                for c in self.encoderCache { c.trim(c.offset) }
                var z = self.encoder(xs)
                z = self.encoder_transformer(z, cache: self.encoderCache)[0]
                z = self.downsample(z)
                return self.quantizer.encode(z)
            }
        }
        #endif
        encoder.resetState()
        for c in encoderCache { c.trim(c.offset)  }

        var z = encoder(xs)
        z = encoder_transformer(z, cache: encoderCache)[0]
        z = downsample(z)
        return quantizer.encode(z) // [B, nq, Tq]
    }

    /// Encodes the input audio waveform into discrete codes with telemetry emission.
    ///
    /// Emits ``MLXAudioTelemetryEvent/codecEncodeStart(codec:inputSamples:)``
    /// before encoding, then
    /// ``MLXAudioTelemetryEvent/codecEncodeComplete(codec:durationSeconds:compressionRatio:)``
    /// on success.
    ///
    /// `inputSamples` is the time-dimension of `xs` (last dimension of `[B, C, T]`).
    /// `compressionRatio` = `Double(inputBytes) / Double(outputBytes)` where
    /// `inputBytes` = time-samples × channels × 4 (Float32) and
    /// `outputBytes` = total quantized code elements × 4 (Int32 indices).
    ///
    /// Telemetry emission is a boundary-level operation — no events are emitted
    /// inside the encoder transformer layers.
    public func encode(_ xs: MLXArray) async -> MLXArray {
        // inputSamples: last dimension of [B, C, T].
        let inputSamples: Int = xs.ndim >= 1 ? xs.shape[xs.ndim - 1] : 0
        let inputChannels: Int = xs.ndim >= 2 ? xs.shape[xs.ndim - 2] : 1

        await emit(.codecEncodeStart(codec: "mimi", inputSamples: inputSamples))

        let start = Date()
        let result = encode(xs)
        let elapsed = Date().timeIntervalSince(start)

        let inputBytes = inputSamples * inputChannels * 4 // Float32
        let outputElements = result.shape.reduce(1, *)
        let outputBytes = outputElements * 4 // Int32 indices

        if inputBytes > 0 && outputBytes > 0 {
            let compressionRatio = Double(inputBytes) / Double(outputBytes)
            await emit(.codecEncodeComplete(
                codec: "mimi",
                durationSeconds: elapsed,
                compressionRatio: compressionRatio
            ))
        } else {
            await emit(.codecError(
                codec: "mimi",
                operation: "encode",
                error: "compressionRatio unavailable: inputBytes=\(inputBytes) outputBytes=\(outputBytes)"
            ))
        }

        return result
    }

    /// Decodes discrete codes into an audio waveform (synchronous overload).
    ///
    /// This overload is retained for backward compatibility with existing
    /// synchronous callers. No public-surface telemetry is emitted from
    /// this path — use the `async` overload if you need telemetry.
    public func decode(_ codes: MLXArray) -> MLXArray {
        // S11: Mimi.decode interval (Level 2 = .operations).
        #if MLXAUDIO_TELEMETRY_FULL
        if Telemetry.level >= .operations {
            return Telemetry.emitInterval(name: "Mimi.decode", family: .codecs) {
                self.decoder.resetState()
                for c in self.decoderCache { c.trim(c.offset) }
                var z = self.quantizer.decode(codes)
                z = self.upsample(z)
                z = self.decoder_transformer(z, cache: self.decoderCache)[0]
                return self.decoder(z)
            }
        }
        #endif
        decoder.resetState()
        for c in decoderCache { c.trim(c.offset)  }

        var z = quantizer.decode(codes) // [B, Cdim, Tq]
        z = upsample(z)
        z = decoder_transformer(z, cache: decoderCache)[0]
        return decoder(z) // [B, 1, T]
    }

    /// Decodes discrete codes into an audio waveform with telemetry emission.
    ///
    /// Emits ``MLXAudioTelemetryEvent/codecDecodeStart(codec:codedFrames:)``
    /// before decoding, then
    /// ``MLXAudioTelemetryEvent/codecDecodeComplete(codec:durationSeconds:outputSamples:)``
    /// on success.
    ///
    /// `codedFrames` is the last dimension of the `codes` tensor (the Tq
    /// quantized-frame dimension of `[B, nq, Tq]`).
    /// `outputSamples` is the last dimension of the decoded audio waveform
    /// (`[B, 1, T]` → `T`).
    ///
    /// Telemetry emission is a boundary-level operation — no events are emitted
    /// inside the decoder transformer layers.
    public func decode(_ codes: MLXArray) async -> MLXArray {
        // codedFrames: last dimension of [B, nq, Tq].
        let codedFrames: Int = codes.ndim >= 1 ? codes.shape[codes.ndim - 1] : 0

        await emit(.codecDecodeStart(codec: "mimi", codedFrames: codedFrames))

        let start = Date()
        let audioValues = decode(codes)
        let elapsed = Date().timeIntervalSince(start)

        // outputSamples: last dimension of [B, 1, T].
        let outputSamples: Int = audioValues.ndim >= 1 ? audioValues.shape[audioValues.ndim - 1] : 0

        await emit(.codecDecodeComplete(
            codec: "mimi",
            durationSeconds: elapsed,
            outputSamples: outputSamples
        ))

        return audioValues
    }

    /// Streams one audio chunk through the encoder (synchronous overload).
    ///
    /// This overload is retained for backward compatibility with existing callers
    /// (e.g. Marvis's `encodeChunked`). No public-surface telemetry is emitted
    /// from this path — use the `async` overload if you need telemetry.
    public func encodeStep(_ xs: MLXArray) -> MLXArray {
        var z = encoder.step(xs)
        z = encoder_transformer(z, cache: encoderCache)[0]
        z = downsample.step(z)
        z = quantizer.encode(z)
        return z
    }

    /// Streams one audio chunk through the encoder with telemetry emission.
    ///
    /// Emits ``MLXAudioTelemetryEvent/codecEncodeStart(codec:inputSamples:)``
    /// before encoding the chunk, then
    /// ``MLXAudioTelemetryEvent/codecEncodeComplete(codec:durationSeconds:compressionRatio:)``
    /// on success.
    ///
    /// This is the streaming-encode boundary called by Marvis's `encodeChunked`
    /// helper. Each chunk invocation emits one start+complete pair — there is no
    /// per-frame emission inside this method.
    public func encodeStep(_ xs: MLXArray) async -> MLXArray {
        let inputSamples: Int = xs.ndim >= 1 ? xs.shape[xs.ndim - 1] : 0
        let inputChannels: Int = xs.ndim >= 2 ? xs.shape[xs.ndim - 2] : 1

        await emit(.codecEncodeStart(codec: "mimi", inputSamples: inputSamples))

        let start = Date()
        let result = encodeStep(xs)
        let elapsed = Date().timeIntervalSince(start)

        let inputBytes = inputSamples * inputChannels * 4 // Float32
        let outputElements = result.shape.reduce(1, *)
        let outputBytes = outputElements * 4 // Int32 indices

        if inputBytes > 0 && outputBytes > 0 {
            let compressionRatio = Double(inputBytes) / Double(outputBytes)
            await emit(.codecEncodeComplete(
                codec: "mimi",
                durationSeconds: elapsed,
                compressionRatio: compressionRatio
            ))
        } else {
            await emit(.codecError(
                codec: "mimi",
                operation: "encodeStep",
                error: "compressionRatio unavailable: inputBytes=\(inputBytes) outputBytes=\(outputBytes)"
            ))
        }

        return result
    }

    /// Per-frame streaming decode step (synchronous). Called by ``MimiStreamingDecoder``.
    ///
    /// **Not instrumented at the per-step level** — telemetry is emitted by
    /// ``MimiStreamingDecoder/decodeFrames(_:)`` once per batch of frames
    /// (start before the loop, complete after). This prevents per-frame
    /// emission inside hot decode loops.
    public func decodeStep(_ codes: MLXArray) -> MLXArray {
        var z = quantizer.decode(codes)
        z = upsample.step(z)
        z = decoder_transformer(z, cache: decoderCache)[0]
        z = decoder.step(z)
        return z
    }
}

// MARK: - Streaming

/// Streaming decoder for Mimi that processes one batch of frames at a time.
///
/// ## Telemetry
///
/// Attach a reporter via ``setTelemetry(_:)`` to receive
/// ``MLXAudioTelemetryEvent/codecDecodeStart(codec:codedFrames:)`` /
/// ``MLXAudioTelemetryEvent/codecDecodeComplete(codec:durationSeconds:outputSamples:)``
/// once per ``decodeFrames(_:)`` call (never inside the per-frame loop).
///
/// Marvis calls ``decodeFrames(_:)`` from `generateResultChunk`. This
/// is the correct boundary — one start+complete pair per streaming
/// result chunk, not per individual frame.
public final class MimiStreamingDecoder {
    private let mimi: Mimi

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

    public init(_ mimi: Mimi) {
        self.mimi = mimi
        reset()
    }

    public func reset() {
        mimi.decoder.resetState()
        mimi.upsample.resetState()
        for c in mimi.decoderCache { c.trim(c.offset) }
    }

    /// Decode a batch of token frames into audio samples (synchronous overload).
    ///
    /// This overload is retained for backward compatibility with existing
    /// synchronous callers (e.g. Marvis's `generateResultChunk`). No
    /// public-surface telemetry is emitted from this path — use the
    /// `async` overload if you need telemetry.
    ///
    /// Telemetry emission is deferred to the caller level — emit
    /// ``codecDecodeStart`` / ``codecDecodeComplete`` via the async overload
    /// when the call site supports it.
    public func decodeFrames(_ tokens: MLXArray) -> MLXArray {
        let tok = (tokens.ndim == 2) ? tokens.expandedDimensions(axes: [0]) : tokens // ensure [B,C,T]
        let T = tok.shape[2]

        var pcs: [MLXArray] = []
        for t in 0 ..< T {
            let left = split(tok, indices: [t], axis: 2)
            let mid = split(left[1], indices: [1], axis: 2)[0]
            pcs.append(mimi.decodeStep(mid))
            // S14: per-decode-step signpost (Level 4 = .verbose).
            // One event per frame decoded; gated so it strips in release builds.
            #if MLXAUDIO_TELEMETRY_FULL
            if Telemetry.level >= .verbose {
                Telemetry.emitEvent(family: .codecs, name: "Mimi.decodeStep", tokenIndex: t)
            }
            #endif
        }
        return concatenated(pcs, axis: 2) // [B, 1, samples]
    }

    /// Decode a batch of token frames into audio samples with telemetry emission.
    ///
    /// Emits ``MLXAudioTelemetryEvent/codecDecodeStart(codec:codedFrames:)``
    /// **once** before the frame loop, then
    /// ``MLXAudioTelemetryEvent/codecDecodeComplete(codec:durationSeconds:outputSamples:)``
    /// **once** after the loop completes.
    ///
    /// No events are emitted inside the per-frame decode loop — only boundary
    /// events are produced.
    ///
    /// `codedFrames` is `tokens.shape[2]` (the T dimension of `[B, C, T]`).
    /// `outputSamples` is the last dimension of the decoded `[B, 1, S]` result.
    public func decodeFrames(_ tokens: MLXArray) async -> MLXArray {
        let tok = (tokens.ndim == 2) ? tokens.expandedDimensions(axes: [0]) : tokens // ensure [B,C,T]
        let codedFrames: Int = tok.ndim >= 3 ? tok.shape[2] : (tok.ndim >= 1 ? tok.shape[tok.ndim - 1] : 0)

        // Emit start ONCE before the frame loop — never inside it.
        await emit(.codecDecodeStart(codec: "mimi", codedFrames: codedFrames))

        let start = Date()
        let result = decodeFrames(tokens)
        let elapsed = Date().timeIntervalSince(start)

        // outputSamples: last dimension of [B, 1, S].
        let outputSamples: Int = result.ndim >= 1 ? result.shape[result.ndim - 1] : 0

        // Emit complete ONCE after the frame loop — never inside it.
        await emit(.codecDecodeComplete(
            codec: "mimi",
            durationSeconds: elapsed,
            outputSamples: outputSamples
        ))

        return result
    }
}

public extension Mimi {
    /// Load Mimi model using Acervo strict API (ComponentAccess).
    /// Always loads via the registered `mimi-pytorch-bf16` component descriptor.
    static func fromPretrained(
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> Mimi {
        ensureComponentsRegistered()
        print("[Mimi] Loading Mimi Audio Codec (PyTorch BF16) via loadWithAcervoStrict...")

        return try await AudioModelManager.loadWithAcervoStrict(componentId: "mimi-pytorch-bf16") { modelDir in
            // Construct model inside the closure so it isn't captured from the
            // outer @Sendable scope (the model type is not Sendable).
            let cfg = mimi_202407(numCodebooks: 32)
            let modelInitStart = CFAbsoluteTimeGetCurrent()
            let model = Mimi(cfg: cfg)
            let modelInitTime = CFAbsoluteTimeGetCurrent() - modelInitStart
            print(String(format: "[Mimi] Model initialization completed in %.2f seconds", modelInitTime))

            let weightFileURL = modelDir.appendingPathComponent("tokenizer-e351c8d8-checkpoint125.safetensors")

            guard FileManager.default.fileExists(atPath: weightFileURL.path) else {
                throw NSError(domain: "MimiModel", code: 1, userInfo: [
                    "file": "tokenizer-e351c8d8-checkpoint125.safetensors",
                    "dir": modelDir.path
                ])
            }

            print("[Mimi] Loading weight arrays from safetensors file...")
            let loadStart = CFAbsoluteTimeGetCurrent()
            var weights = [String: MLXArray]()
            let w = try loadArrays(url: weightFileURL)
            for (key, value) in w {
                weights[key] = value
            }
            let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
            print(String(format: "[Mimi] Weight arrays loaded in %.2f seconds. Total weights: %d", loadTime, weights.count))

            print("[Mimi] Sanitizing weights...")
            let sanitizeStart = CFAbsoluteTimeGetCurrent()
            weights = model.sanitize(weights: weights)
            let sanitizeTime = CFAbsoluteTimeGetCurrent() - sanitizeStart
            print(String(format: "[Mimi] Weights sanitized in %.2f seconds. Final weight count: %d", sanitizeTime, weights.count))

            print("[Mimi] Processing codebook updates...")
            let filterStart = CFAbsoluteTimeGetCurrent()
            func filterFn(_ module: Module, _ name: String, _ item: ModuleItem) -> Bool {
                if let codebook = module as? EuclideanCodebook, name == "initialized" {
                    codebook.updateInPlace()
                }
                return true
            }
            _ = model.filterMap(filter: filterFn)
            let filterTime = CFAbsoluteTimeGetCurrent() - filterStart
            print(String(format: "[Mimi] Codebook processing completed in %.2f seconds", filterTime))

            print("[Mimi] Updating model parameters...")
            let updateStart = CFAbsoluteTimeGetCurrent()
            let parameters = ModuleParameters.unflattened(weights)
            // S10: Mimi loadWeights interval (Level 2 = .operations).
            #if MLXAUDIO_TELEMETRY_FULL
            if Telemetry.level >= .operations {
                try Telemetry.emitInterval(
                    name: "Mimi.loadWeights",
                    family: .codecs,
                    message: "mimi-pytorch-bf16"
                ) {
                    try model.update(parameters: parameters, verify: [.all])
                }
            } else {
                try model.update(parameters: parameters, verify: [.all])
            }
            #else
            try model.update(parameters: parameters, verify: [.all])
            #endif
            let updateTime = CFAbsoluteTimeGetCurrent() - updateStart
            print(String(format: "[Mimi] Model parameters updated in %.2f seconds", updateTime))

            print("[Mimi] Evaluating model...")
            let evalStart = CFAbsoluteTimeGetCurrent()
            eval(model)
            let evalTime = CFAbsoluteTimeGetCurrent() - evalStart
            print(String(format: "[Mimi] Model evaluation completed in %.2f seconds", evalTime))

            print("[Mimi] Mimi model loading completed successfully")
            return model
        }
    }

    private func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]

        for (rawKey, rawVal) in weights {
            var k = rawKey
                .split(separator: ".")
                .map { seg -> String in
                    if seg.hasPrefix("_") { return String(seg.dropFirst()) }
                    return String(seg)
                }
                .joined(separator: ".")

            if k.hasPrefix("encoder.model.") {
                k = k.replacingOccurrences(of: "encoder.model.", with: "encoder.")
            }
            if k.hasPrefix("decoder.model.") {
                k = k.replacingOccurrences(of: "decoder.model.", with: "decoder.")
            }

            if k.hasSuffix(".in_proj_weight") {
                k = k.replacingOccurrences(of: ".in_proj_weight", with: ".in_proj.weight")
            }
            if k.hasSuffix(".linear1.weight") {
                k = k.replacingOccurrences(of: ".linear1.weight", with: ".gating.linear1.weight")
            }
            if k.hasSuffix(".linear2.weight") {
                k = k.replacingOccurrences(of: ".linear2.weight", with: ".gating.linear2.weight")
            }

            let decIdx = [2, 5, 8, 11]
            for (layerIdx, decoderIdx) in decIdx.enumerated() {
                k = k.replacingOccurrences(of: "decoder.\(decoderIdx).",
                                           with: "decoder.layers.\(layerIdx).upsample.")
                k = k.replacingOccurrences(of: "decoder.\(decoderIdx + 1).",
                                           with: "decoder.layers.\(layerIdx).residuals.0.")
            }
            let encIdx = [1, 4, 7, 10]
            for (layerIdx, encoderIdx) in encIdx.enumerated() {
                k = k.replacingOccurrences(of: "encoder.\(encoderIdx).",
                                           with: "encoder.layers.\(layerIdx).residuals.0.")
                k = k.replacingOccurrences(of: "encoder.\(encoderIdx + 2).",
                                           with: "encoder.layers.\(layerIdx).downsample.")
            }

            k = k.replacingOccurrences(of: "decoder.0.", with: "decoder.init_conv1d.")
            k = k.replacingOccurrences(of: "decoder.14.", with: "decoder.final_conv1d.")
            k = k.replacingOccurrences(of: "encoder.0.", with: "encoder.init_conv1d.")
            k = k.replacingOccurrences(of: "encoder.14.", with: "encoder.final_conv1d.")
            k = k.replacingOccurrences(of: ".block.1.", with: ".block.0.")
            k = k.replacingOccurrences(of: ".block.3.", with: ".block.1.")

            var v = rawVal
            if k.hasSuffix(".conv.weight")
                || k.hasSuffix(".output_proj.weight")
                || k.hasSuffix(".input_proj.weight") {
                if v.ndim >= 2 {
                    v = swappedAxes(v, v.ndim - 1, v.ndim - 2)
                }
            }
            if k.hasSuffix(".convtr.weight") {
                if v.ndim == 3 {
                    var w = swappedAxes(v, 0, 1) // [1,0,2]
                    w = swappedAxes(w, 1, 2) // [1,2,0]
                    v = w
                }
            }

            out[k] = v
        }

        return out
    }
}

// MARK: -

public final class MimiTokenizer {
    public let codec: Mimi
    public init(_ codec: Mimi) {
        codec.train(false)
        self.codec = codec
        Telemetry.trackLifecycle(self, className: "Mimi.Tokenizer")
    }

    deinit {
        Telemetry.trackLifecycleEnd(className: "Mimi.Tokenizer")
    }
}
