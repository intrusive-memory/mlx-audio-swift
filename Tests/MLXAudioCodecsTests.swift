//
//  MLXAudioTests.swift
//  MLXAudioTests
//
//  Created by Ben Harraway on 14/04/2025.
//


import Testing
import MLX
import MLXNN
import Foundation

@testable import MLXAudioCore
@testable import MLXAudioTTS
@testable import MLXAudioCodecs


// Run ALL tests with:  xcodebuild test \
// -scheme MLXAudio-Package \
// -destination 'platform=macOS' \
// -only-testing:MLXAudioTests/MLXAudioCodecsTests
//  2>&1 | grep -E "(Suite.*started|Test test.*started|Loaded|Loading|model loaded|input shape|Encoding|Encoded|Decoding|Decoded|Reconstructed|Saved|passed after|failed after|TEST SUCCEEDED|TEST FAILED|Suite.*passed|Test run)"


// MARK: - SNAC Tests
// Run SNAC tests with:  xcodebuild test \
// -scheme MLXAudio-Package \
// -destination 'platform=macOS' \
// -only-testing:MLXAudioTests/SNACTests
//  2>&1 | grep -E "(Suite.*started|Test test.*started|Loaded|Loading|model loaded|input shape|Encoding|Encoded|Decoding|Decoded|Reconstructed|Saved|passed after|failed after|TEST SUCCEEDED|TEST FAILED|Suite.*passed|Test run)"


struct SNACTests {

    @Test func testSNACEncodeDecodeCycle() async throws {
        // 1. Load audio from file
        let audioURL = Bundle.module.url(forResource: "intention", withExtension: "wav", subdirectory: "media")!
        let (_, audioData) = try loadAudioArray(from: audioURL)

        // 2. Load SNAC model from HuggingFace (24kHz model)
        let snac = try await SNAC.fromPretrained("mlx-community/snac_24khz")

        // 3. Reshape audio for SNAC: [batch, channels, samples]
        let audioInput = audioData.reshaped([1, 1, audioData.shape[0]])

        // 4. Encode audio to codes
        let codes = snac.encode(audioInput)

        // 5. Decode codes back to audio
        let reconstructed = snac.decode(codes)

        // 6. Save reconstructed audio to the same media folder as input
        let outputURL = audioURL.deletingLastPathComponent().appendingPathComponent("intention_snac_reconstructed.wav")
        let outputAudio = reconstructed.squeezed()  // Remove batch/channel dims
        try saveAudioArray(outputAudio, sampleRate: Double(snac.samplingRate), to: outputURL)

        // Basic check: output should have samples
        #expect(reconstructed.shape.last! > 0)
    }
}


// MARK: - Mimi Tests
// Run Mimi tests with:  xcodebuild test \
// -scheme MLXAudio-Package \
// -destination 'platform=macOS' \
// -only-testing:MLXAudioTests/MimiTests \
// 2>&1 | grep -E "(Suite.*started|Test test.*started|Loaded|Loading|model loaded|input shape|Encoding|Encoded|Decoding|Decoded|Reconstructed|Saved|passed after|failed after|TEST SUCCEEDED|TEST FAILED|Suite.*passed|Test run)"


struct MimiTests {

    @Test func testMimiEncodeDecodeCycle() async throws {
        // 1. Load audio from file
        let audioURL = Bundle.module.url(forResource: "intention", withExtension: "wav", subdirectory: "media")!
        let (_, audioData) = try loadAudioArray(from: audioURL)

        // 2. Load Mimi model from HuggingFace
        let mimi = try await Mimi.fromPretrained()

        // 3. Reshape audio for Mimi: [batch, channels, samples]
        let audioInput = audioData.reshaped([1, 1, audioData.shape[0]])

        // 4. Encode audio to codes
        let codes = mimi.encode(audioInput)

        // 5. Decode codes back to audio
        let reconstructed = mimi.decode(codes)
        GPU.clearCache()

        // 6. Save reconstructed audio
        let outputURL = audioURL.deletingLastPathComponent().appendingPathComponent("intention_mimi_reconstructed.wav")
        let outputAudio = reconstructed.squeezed()  // Remove batch/channel dims
        try saveAudioArray(outputAudio, sampleRate: mimi.sampleRate, to: outputURL)

        // Basic check: output should have samples
        #expect(reconstructed.shape.last! > 0)
    }
}


// MARK: - Vocos Tests
// Run Vocos tests with:  xcodebuild test \
// -scheme MLXAudio-Package \
// -destination 'platform=macOS' \
// -only-testing:MLXAudioTests/VocosTests \
// 2>&1 | grep -E "(Suite.*started|Test test.*started|passed after|failed after|TEST SUCCEEDED|TEST FAILED|Suite.*passed|Test run)"


struct VocosTests {

    @Test func testConvNeXtBlock() throws {
        // Test basic ConvNeXtBlock forward pass
        let dim = 64
        let intermediateDim = 192
        let block = ConvNeXtBlock(
            dim: dim,
            intermediateDim: intermediateDim,
            layerScaleInitValue: 0.125,
            dwKernelSize: 7
        )

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, dim])
        let output = block(input)

        // Output should have same shape as input (residual connection)
        #expect(output.shape == input.shape)
    }

    @Test func testConvNeXtBlockWithAdaNorm() throws {
        // Test ConvNeXtBlock with adaptive normalization
        let dim = 64
        let intermediateDim = 192
        let numEmbeddings = 4

        let block = ConvNeXtBlock(
            dim: dim,
            intermediateDim: intermediateDim,
            layerScaleInitValue: 0.125,
            adanormNumEmbeddings: numEmbeddings,
            dwKernelSize: 7
        )

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, dim])
        let condEmbedding = MLXRandom.normal([1, numEmbeddings])

        let output = block(input, condEmbeddingId: condEmbedding)

        // Output should have same shape as input
        #expect(output.shape == input.shape)
    }

    @Test func testVocosBackbone() throws {
        // Test VocosBackbone forward pass
        let inputChannels = 100
        let dim = 512
        let intermediateDim = 1536
        let numLayers = 8

        let backbone = VocosBackbone(
            inputChannels: inputChannels,
            dim: dim,
            intermediateDim: intermediateDim,
            numLayers: numLayers
        )

        // Input shape: (batch, length, input_channels)
        let input = MLXRandom.normal([1, 50, inputChannels])
        let output = backbone(input)

        // Output should have shape (batch, length, dim)
        #expect(output.shape[0] == 1)
        #expect(output.shape[1] == 50)
        #expect(output.shape[2] == dim)
    }

    @Test func testVocosBackboneWithAdaNorm() throws {
        // Test VocosBackbone with adaptive normalization
        let inputChannels = 100
        let dim = 256
        let intermediateDim = 768
        let numLayers = 4
        let numEmbeddings = 4

        let backbone = VocosBackbone(
            inputChannels: inputChannels,
            dim: dim,
            intermediateDim: intermediateDim,
            numLayers: numLayers,
            adanormNumEmbeddings: numEmbeddings
        )

        // Input shape: (batch, length, input_channels)
        let input = MLXRandom.normal([1, 50, inputChannels])
        let bandwidthId = MLXRandom.normal([1, numEmbeddings])

        let output = backbone(input, bandwidthId: bandwidthId)

        // Output should have shape (batch, length, dim)
        #expect(output.shape[0] == 1)
        #expect(output.shape[1] == 50)
        #expect(output.shape[2] == dim)
    }

    @Test func testISTFTHead() throws {
        // Test ISTFTHead forward pass
        let dim = 512
        let nFft = 1024
        let hopLength = 256

        let head = MLXAudioCodecs.ISTFTHead(dim: dim, nFft: nFft, hopLength: hopLength)

        // Input shape: (batch, length, dim)
        let numFrames = 100
        let input = MLXRandom.normal([1, numFrames, dim])

        let output = head(input)

        // Output should be audio waveform
        // Expected length: approximately (numFrames - 1) * hopLength after trimming
        #expect(output.ndim == 1 || output.ndim == 2)
    }

    @Test func testAdaLayerNorm() throws {
        // Test AdaLayerNorm
        let numEmbeddings = 4
        let embeddingDim = 256

        let adaNorm = AdaLayerNorm(
            numEmbeddings: numEmbeddings,
            embeddingDim: embeddingDim
        )

        // Input shape: (batch, length, dim)
        let input = MLXRandom.normal([2, 50, embeddingDim])
        let condEmbedding = MLXRandom.normal([2, numEmbeddings])

        let output = adaNorm(input, condEmbedding: condEmbedding)

        // Output should have same shape as input
        #expect(output.shape == input.shape)
    }

    @Test func testVocosModel() throws {
        // Test full Vocos model
        let inputChannels = 100
        let dim = 256
        let intermediateDim = 768
        let numLayers = 4
        let nFft = 1024
        let hopLength = 256

        let backbone = VocosBackbone(
            inputChannels: inputChannels,
            dim: dim,
            intermediateDim: intermediateDim,
            numLayers: numLayers
        )

        let head = MLXAudioCodecs.ISTFTHead(dim: dim, nFft: nFft, hopLength: hopLength)

        let vocos = Vocos(backbone: backbone, head: head)

        // Input shape: (batch, length, input_channels)
        let numFrames = 50
        let input = MLXRandom.normal([1, numFrames, inputChannels])

        let output = vocos(input)

        // Output should be audio waveform
        #expect(output.shape.count >= 1)
    }

    @Test func testVocosDecodeWithBandwidthId() throws {
        // Test Vocos decode with bandwidth conditioning
        let inputChannels = 128
        let dim = 256
        let intermediateDim = 768
        let numLayers = 4
        let numEmbeddings = 4
        let nFft = 1024
        let hopLength = 256

        let backbone = VocosBackbone(
            inputChannels: inputChannels,
            dim: dim,
            intermediateDim: intermediateDim,
            numLayers: numLayers,
            adanormNumEmbeddings: numEmbeddings
        )

        let head = MLXAudioCodecs.ISTFTHead(dim: dim, nFft: nFft, hopLength: hopLength)

        let vocos = Vocos(backbone: backbone, head: head)

        // Input shape: (batch, length, input_channels)
        let numFrames = 50
        let input = MLXRandom.normal([1, numFrames, inputChannels])
        let bandwidthId = MLXRandom.normal([1, numEmbeddings])

        let output = vocos.decode(input, bandwidthId: bandwidthId)

        // Output should be audio waveform
        #expect(output.shape.count >= 1)
    }

    // MARK: - vocosISTFTHeadMatchesPythonReference
    //
    // Sortie 19 — numeric-parity assertion for VocosISTFTHead.
    //
    // Fixture: Tests/media/parity/vocos_istft_head/
    //   input.safetensors    — key "x"          shape [1, 8, 16]  (B, T, dim)
    //   weights.safetensors  — keys "proj.weight" [34, 16], "proj.bias" [34], "window" [32]
    //   expected.safetensors — key "audio"       shape [1, 56]    (B, samples)
    //
    // Config derived from fixture shapes:
    //   dim=16, n_fft=32 (proj output = n_fft+2 = 34), hop_length=8.
    //
    // ISTFTHead uses a periodic Hann window (0.5 - 0.5*cos(2π*k/N)) matching
    // torch.hann_window(periodic=True), and always preserves the batch dimension.

    @Test func vocosISTFTHeadMatchesPythonReference() throws {
        let fixture = try loadParityFixture("vocos_istft_head")

        // --- Load input ---
        guard let inputArr = fixture.input["x"] else {
            Issue.record("vocos_istft_head input.safetensors missing key 'x'")
            return
        }
        // inputArr shape: [1, 8, 16] — already in (B, T, dim) NLC format

        // --- Load expected ---
        guard let expectedAudio = fixture.expected["audio"] else {
            Issue.record("vocos_istft_head expected.safetensors missing key 'audio'")
            return
        }
        // expectedAudio shape: [1, 56] — (B, samples)

        // --- Load weights ---
        guard
            let projWeight = fixture.weights["proj.weight"],
            let projBias   = fixture.weights["proj.bias"]
        else {
            Issue.record("vocos_istft_head weights.safetensors missing 'proj.weight' or 'proj.bias'")
            return
        }
        // projWeight: [34, 16] = [n_fft+2, dim], projBias: [34]
        // Derive config from shapes:
        let dim        = projWeight.shape[1]          // 16
        let nFft       = projWeight.shape[0] - 2      // 32
        let hopLength  = 8  // documented in fixture README (nFft/4)

        // --- Construct ISTFTHead ---
        let head = MLXAudioCodecs.ISTFTHead(dim: dim, nFft: nFft, hopLength: hopLength)

        // --- Inject weights into head.out (Linear) via update(parameters:) ---
        // Linear stores weight as [out, in], bias as [out].
        // Python proj.weight [34, 16] = [out=34, in=16] matches MLX Linear layout.
        let vocosParams: [String: MLXArray] = [
            "out.weight": projWeight,
            "out.bias":   projBias
        ]
        head.update(parameters: ModuleParameters.unflattened(vocosParams))
        eval(head)

        // --- Forward pass ---
        // ISTFTHead expects NLC input [B, T, dim].
        let swiftAudio = head(inputArr)
        eval(swiftAudio)

        // --- Shape assertion ---
        #expect(
            swiftAudio.shape == expectedAudio.shape,
            "ISTFTHead audio shape mismatch: swift=\(swiftAudio.shape) expected=\(expectedAudio.shape)"
        )

        // --- Numeric-parity assertion ---
        let close = MLX.allClose(swiftAudio, expectedAudio, rtol: 1e-4, atol: 1e-4)
        let isClose = close.item(Bool.self)

        if !isClose {
            let maxAbsErr = abs(swiftAudio - expectedAudio).max().item(Float.self)
            Issue.record("ISTFTHead audio != Python reference. max_abs_err=\(maxAbsErr) (atol=1e-4, rtol=1e-4)")
        }
        #expect(isClose, "vocosISTFTHeadMatchesPythonReference: allClose failed (atol=1e-4, rtol=1e-4)")
    }
}


// MARK: - Encodec Tests
// Run Encodec tests with:  xcodebuild test \
// -scheme MLXAudio-Package \
// -destination 'platform=macOS' \
// -only-testing:MLXAudioTests/EncodecTests \
// 2>&1 | grep -E "(Suite.*started|Test test.*started|passed after|failed after|TEST SUCCEEDED|TEST FAILED|Suite.*passed|Test run)"


struct EncodecTests {

    @Test func testEncodecConfig() throws {
        // Test default config
        let config = EncodecConfig()

        #expect(config.audioChannels == 1)
        #expect(config.numFilters == 32)
        #expect(config.codebookSize == 1024)
        #expect(config.codebookDim == 128)
        #expect(config.hiddenSize == 128)
        #expect(config.numLstmLayers == 2)
        #expect(config.samplingRate == 24000)
        #expect(config.upsamplingRatios == [8, 5, 4, 2])
    }

    @Test func testEncodecConv1d() throws {
        // Test EncodecConv1d layer
        let config = EncodecConfig()
        let conv = EncodecConv1d(
            config: config,
            inChannels: 32,
            outChannels: 64,
            kernelSize: 7
        )

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, 32])
        let output = conv(input)

        #expect(output.shape[0] == 1)
        #expect(output.shape[2] == 64)
    }

    @Test func testEncodecLSTM() throws {
        // Test EncodecLSTM layer
        let lstm = EncodecLSTM(inputSize: 64, hiddenSize: 64)

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 50, 64])
        let output = lstm(input)

        #expect(output.shape[0] == 1)
        #expect(output.shape[1] == 50)
        #expect(output.shape[2] == 64)
    }

    @Test func testEncodecResnetBlock() throws {
        // Test EncodecResnetBlock
        let config = EncodecConfig()
        let block = EncodecResnetBlock(
            config: config,
            dim: 64,
            dilations: [1, 1]
        )

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, 64])
        let output = block(input)

        // Output should have same shape (residual connection)
        #expect(output.shape == input.shape)
    }

    @Test func testEncodecEuclideanCodebook() throws {
        // Test codebook quantization
        let config = EncodecConfig()
        let codebook = EncodecEuclideanCodebook(config: config)

        // Input shape: (batch, length, dim)
        let input = MLXRandom.normal([1, 50, config.codebookDim])
        let indices = codebook.encode(input)

        #expect(indices.shape[0] == 1)
        #expect(indices.shape[1] == 50)

        // Decode back
        let decoded = codebook.decode(indices)
        #expect(decoded.shape[0] == 1)
        #expect(decoded.shape[1] == 50)
        #expect(decoded.shape[2] == config.codebookDim)
    }

    @Test func testEncodecRVQ() throws {
        // Test Residual Vector Quantizer
        let config = EncodecConfig()
        let rvq = EncodecResidualVectorQuantizer(config: config)

        // Input shape: (batch, length, dim)
        let input = MLXRandom.normal([1, 50, config.codebookDim])
        let codes = rvq.encode(input, bandwidth: 1.5)

        // Codes shape should be (batch, num_quantizers, length)
        #expect(codes.shape[0] == 1)

        // Decode
        let decoded = rvq.decode(codes)
        #expect(decoded.shape[0] == 1)
        #expect(decoded.shape[1] == 50)
    }

    @Test func testEncodecModel() throws {
        // Test full Encodec model
        let config = EncodecConfig()
        let model = Encodec(config: config)

        // Input shape: (batch, length, channels)
        let audio = MLXRandom.normal([1, 1000, 1])

        // Encode
        let (codes, scales) = model.encode(audio, bandwidth: 1.5)
        #expect(codes.shape[0] >= 1)

        // Decode
        let decoded = model.decode(codes, scales)
        #expect(decoded.shape[0] == 1)
        #expect(decoded.shape[2] == 1)
    }

    // MARK: - encodecQuantizerMatchesPythonReference
    //
    // Sortie 19 — numeric-parity assertion for Encodec residual VQ.
    //
    // Fixture: Tests/media/parity/encodec_quantizer/
    //   input.safetensors    — key "x"         shape [1, 8, 12]  (B, dim, T) — Python NCL
    //   weights.safetensors  — keys "layers.0.codebook" [16, 8], "layers.1.codebook" [16, 8]
    //   expected.safetensors — key "quantized"  shape [1, 8, 12]  (B, dim, T) — Python NCL
    //                          key "indices"    shape [1, 2, 12]  (B, nq, T) — Python layout
    //
    // Layout note: Python uses NCL [B, dim, T]; Swift uses NLC [B, T, dim].
    //   - Transpose fixture input [1,8,12] → [1,12,8] before Swift encode.
    //   - Transpose Swift quantized output [1,12,8] → [1,8,12] before comparison.
    //
    // Config: codebookSize=16, codebookDim=8, 2 quantizer layers.
    // To produce exactly 2 quantizer layers via EncodecResidualVectorQuantizer.init:
    //   samplingRate=1000, upsamplingRatios=[10] → hopLength=10, frameRate=100
    //   targetBandwidths=[2.0] → numQuantizers = Int(1000*2/(100*10)) = 2.

    @Test func encodecQuantizerMatchesPythonReference() throws {
        let fixture = try loadParityFixture("encodec_quantizer")

        // --- Load input (Python NCL [B, dim, T]) ---
        guard let inputNCL = fixture.input["x"] else {
            Issue.record("encodec_quantizer input.safetensors missing key 'x'")
            return
        }
        // Transpose NCL → NLC for Swift: [1, 8, 12] → [1, 12, 8]
        let inputNLC = inputNCL.swappedAxes(1, 2)

        // --- Load expected ---
        guard let expectedQuantizedNCL = fixture.expected["quantized"] else {
            Issue.record("encodec_quantizer expected.safetensors missing key 'quantized'")
            return
        }
        // expectedQuantizedNCL: [1, 8, 12] in Python NCL

        // --- Load weights ---
        guard
            let cb0 = fixture.weights["layers.0.codebook"],
            let cb1 = fixture.weights["layers.1.codebook"]
        else {
            Issue.record("encodec_quantizer weights.safetensors missing 'layers.0.codebook' or 'layers.1.codebook'")
            return
        }
        // cb0, cb1 each [codebook_size=16, codebook_dim=8]
        let codebookSize = cb0.shape[0]
        let codebookDim  = cb0.shape[1]

        // --- Construct EncodecResidualVectorQuantizer with exactly 2 layers ---
        // samplingRate=1000, upsamplingRatios=[10] → hopLength=10, frameRate=100
        // targetBandwidths=[2.0] → numQuantizers = Int(1000*2/(100*10)) = 2
        let config = EncodecConfig(
            codebookSize: codebookSize,
            codebookDim: codebookDim,
            upsamplingRatios: [10],
            targetBandwidths: [2.0],
            samplingRate: 1000
        )
        let rvq = EncodecResidualVectorQuantizer(config: config)
        #expect(rvq.layers.count == 2, "Expected 2 quantizer layers, got \(rvq.layers.count)")

        // --- Inject codebook weights ---
        // EncodecEuclideanCodebook stores embed [codebook_size, codebook_dim].
        // Inject via update(parameters:) using flat dot-path keys.
        let encodecParams: [String: MLXArray] = [
            "layers.0.codebook.embed": cb0,
            "layers.1.codebook.embed": cb1
        ]
        rvq.update(parameters: ModuleParameters.unflattened(encodecParams))
        eval(rvq)

        // --- Forward pass ---
        // Swift encode expects NLC [B, L, codebook_dim].
        // Returns codes [B, nq, L] = [1, 2, 12].
        let codes = rvq.encode(inputNLC)

        // Swift decode returns NLC [B, L, codebook_dim] = [1, 12, 8].
        let swiftQuantizedNLC = rvq.decode(codes)
        eval(swiftQuantizedNLC)

        // --- Transpose Swift output NLC → NCL for comparison ---
        let swiftQuantizedNCL = swiftQuantizedNLC.swappedAxes(1, 2)  // [1, 8, 12]

        // --- Shape assertion ---
        #expect(
            swiftQuantizedNCL.shape == expectedQuantizedNCL.shape,
            "Encodec quantized shape mismatch: swift=\(swiftQuantizedNCL.shape) expected=\(expectedQuantizedNCL.shape)"
        )

        // --- Numeric-parity assertion ---
        let close = MLX.allClose(swiftQuantizedNCL, expectedQuantizedNCL, rtol: 1e-4, atol: 1e-4)
        let isClose = close.item(Bool.self)

        if !isClose {
            let maxAbsErr = abs(swiftQuantizedNCL - expectedQuantizedNCL).max().item(Float.self)
            Issue.record("Encodec quantized != Python reference. max_abs_err=\(maxAbsErr) (atol=1e-4, rtol=1e-4)")
        }
        #expect(isClose, "encodecQuantizerMatchesPythonReference: allClose failed (atol=1e-4, rtol=1e-4)")
    }
}


// MARK: - DACVAE Tests
// Run DACVAE tests with:  xcodebuild test \
// -scheme MLXAudio-Package \
// -destination 'platform=macOS' \
// -only-testing:MLXAudioTests/DACVAETests \
// 2>&1 | grep -E "(Suite.*started|Test test.*started|passed after|failed after|TEST SUCCEEDED|TEST FAILED|Suite.*passed|Test run)"


struct DACVAETests {

    @Test func testDACVAEConfig() throws {
        // Test default config
        let config = DACVAEConfig()

        #expect(config.encoderDim == 64)
        #expect(config.encoderRates == [2, 8, 10, 12])
        #expect(config.latentDim == 1024)
        #expect(config.decoderDim == 1536)
        #expect(config.decoderRates == [12, 10, 8, 2])
        #expect(config.codebookDim == 128)
        #expect(config.sampleRate == 48000)
        #expect(config.hopLength == 1920)  // 2 * 8 * 10 * 12
    }

    @Test func testDACVAESnake1d() throws {
        // Test Snake activation
        let channels = 64
        let snake = DACVAESnake1d(channels: channels)

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, channels])
        let output = snake(input)

        // Output should have same shape
        #expect(output.shape == input.shape)
    }

    @Test func testDACVAEWNConv1d() throws {
        // Test weight-normalized Conv1d
        let conv = DACVAEWNConv1d(
            inChannels: 32,
            outChannels: 64,
            kernelSize: 7,
            padding: 3
        )

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, 32])
        let output = conv(input)

        #expect(output.shape[0] == 1)
        #expect(output.shape[2] == 64)
    }

    @Test func testDACVAEResidualUnit() throws {
        // Test ResidualUnit
        let dim = 64
        let unit = DACVAEResidualUnit(dim: dim, dilation: 1)

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, dim])
        let output = unit(input)

        // Output should have similar shape (may differ slightly due to padding)
        #expect(output.shape[0] == 1)
        #expect(output.shape[2] == dim)
    }

    @Test func testDACVAEEncoderBlock() throws {
        // Test encoder block
        let dim = 128
        let block = DACVAEEncoderBlock(dim: dim, stride: 2)

        // Input shape: (batch, length, channels)
        let input = MLXRandom.normal([1, 100, dim / 2])
        let output = block(input)

        #expect(output.shape[0] == 1)
        #expect(output.shape[2] == dim)
    }

    @Test func testDACVAEEncoder() throws {
        // Test full encoder
        let encoder = DACVAEEncoder(
            dModel: 64,
            strides: [2, 4],
            dLatent: 128
        )

        // Input shape: (batch, length, 1)
        let input = MLXRandom.normal([1, 1000, 1])
        let output = encoder(input)

        #expect(output.shape[0] == 1)
        #expect(output.shape[2] == 128)
    }

    @Test func testDACVAEQuantizerProj() throws {
        // Test quantizer projections
        let inProj = DACVAEQuantizerInProj(inDim: 128, outDim: 64)
        let outProj = DACVAEQuantizerOutProj(inDim: 64, outDim: 128)

        // Input shape: (batch, length, dim)
        let input = MLXRandom.normal([1, 50, 128])
        let projected = inProj(input)

        // Should project to 2*outDim (mean + logvar)
        #expect(projected.shape[0] == 1)
        #expect(projected.shape[2] == 128)  // 64 * 2

        // Take mean (first half)
        let mean = MLXRandom.normal([1, 50, 64])
        let unprojected = outProj(mean)

        #expect(unprojected.shape[0] == 1)
        #expect(unprojected.shape[2] == 128)
    }

    @Test func testDACVAEModel() throws {
        // Test full DACVAE model with smaller config for faster testing
        let config = DACVAEConfig(
            encoderDim: 32,
            encoderRates: [2, 4],
            latentDim: 64,
            decoderDim: 64,
            decoderRates: [4, 2],
            codebookDim: 32
        )
        let model = DACVAE(config: config)

        // Input shape: (batch, 1, length) for callAsFunction
        let audio = MLXRandom.normal([1, 1, 800])

        // Encode to codebook space
        let encoded = model(audio)
        #expect(encoded.shape[0] == 1)
        #expect(encoded.shape[1] == config.codebookDim)

        // Decode back to audio
        let decoded = model.decode(encoded)
        #expect(decoded.shape[0] == 1)
        #expect(decoded.shape[2] == 1)
    }

    @Test func testDACVAEHopLength() throws {
        // Test hop length calculation
        let config1 = DACVAEConfig(encoderRates: [2, 4, 8])
        #expect(config1.hopLength == 64)  // 2 * 4 * 8

        let config2 = DACVAEConfig(encoderRates: [2, 8, 10, 12])
        #expect(config2.hopLength == 1920)  // 2 * 8 * 10 * 12
    }

    // MARK: - dacvaeEncoderBlockMatchesPythonReference
    //
    // Sortie 19 — numeric-parity assertion for DACVAEEncoderBlock.
    //
    // Fixture: Tests/media/parity/dacvae_encoder_block/
    //   input.safetensors    — key "x"   shape [1, 8, 32]  (B, C, T) — Python NCL
    //   weights.safetensors  — keys:
    //       snake.alpha [1,8,1], down.weight [16,8,4], down.bias [16]
    //       r1.s1.alpha [1,8,1], r1.c1.weight [8,8,7], r1.c1.bias [8]
    //       r1.s2.alpha [1,8,1], r1.c2.weight [8,8,1], r1.c2.bias [8]
    //       r2.s1.alpha [1,8,1], r2.c1.weight [8,8,7], r2.c1.bias [8]
    //       r2.s2.alpha [1,8,1], r2.c2.weight [8,8,1], r2.c2.bias [8]
    //       r3.s1.alpha [1,8,1], r3.c1.weight [8,8,7], r3.c1.bias [8]
    //       r3.s2.alpha [1,8,1], r3.c2.weight [8,8,1], r3.c2.bias [8]
    //   expected.safetensors — key "y"   shape [1, 16, 16] (B, C, T) — Python NCL
    //
    // Layout note: Python uses NCL [B, C, T]; Swift uses NLC [B, T, C].
    //   - Transpose fixture input [1,8,32] → [1,32,8] before Swift forward.
    //   - Transpose Swift output [1,16,16] → [1,16,16] (same shape) before comparison.
    //     (Axes 1 and 2 are both 16, so shape is invariant but values differ.)
    //
    // Weight injection note:
    //   Python uses plain nn.Conv1d; weight shape is [out, in, k].
    //   Swift uses DACVAEWNConv1d; weight_v/weight_g shape is [out, k, in].
    //   → Transpose Python weight axes (1, 2) before injecting as weight_v.
    //   → Compute weight_g = per-output-channel L2 norm (sqrt(sum(w^2, axes=[1,2])))
    //
    //   Python snake alpha shape [1, C, 1] (NCL) → Swift needs [1, 1, C] (NLC).
    //   → Transpose alpha axes (1, 2) or reshape.
    //
    // Key remapping (Python fixture key → Swift module path):
    //   "r1.s1.alpha"   → "res1.act1.alpha"
    //   "r1.c1.weight"  → "res1.conv1.weight_v" (transposed), "res1.conv1.weight_g"
    //   "r1.c1.bias"    → "res1.conv1.bias"
    //   "r1.s2.alpha"   → "res1.act2.alpha"
    //   "r1.c2.weight"  → "res1.conv2.weight_v" (transposed), "res1.conv2.weight_g"
    //   "r1.c2.bias"    → "res1.conv2.bias"
    //   (same pattern for r2→res2, r3→res3)
    //   "snake.alpha"   → "snake.alpha"
    //   "down.weight"   → "conv.weight_v" (transposed), "conv.weight_g"
    //   "down.bias"     → "conv.bias"

    @Test func dacvaeEncoderBlockMatchesPythonReference() throws {
        let fixture = try loadParityFixture("dacvae_encoder_block")

        // --- Load input (Python NCL [B, C, T] = [1, 8, 32]) ---
        guard let inputNCL = fixture.input["x"] else {
            Issue.record("dacvae_encoder_block input.safetensors missing key 'x'")
            return
        }
        // Transpose NCL → NLC: [1, 8, 32] → [1, 32, 8]
        let inputNLC = inputNCL.swappedAxes(1, 2)

        // --- Load expected output (Python NCL [B, C, T] = [1, 16, 16]) ---
        guard let expectedNCL = fixture.expected["y"] else {
            Issue.record("dacvae_encoder_block expected.safetensors missing key 'y'")
            return
        }

        // --- Helper: compute weight_g from a plain weight [out, k, in] ---
        // weight_g = per-output-channel L2 norm = sqrt(sum(w^2, axes=[1,2], keepDims=true))
        func wg(_ w: MLXArray) -> MLXArray {
            MLX.sqrt(MLX.sum(w * w, axes: [1, 2], keepDims: true))
        }

        // --- Helper: transpose Python weight [out, in, k] → Swift [out, k, in] ---
        func wv(_ w: MLXArray) -> MLXArray {
            w.swappedAxes(1, 2)
        }

        // --- Helper: transpose snake alpha [1, C, 1] → [1, 1, C] ---
        func alphaT(_ a: MLXArray) -> MLXArray {
            a.swappedAxes(1, 2)
        }

        // --- Load and prepare all weights ---
        // Residual 1
        guard
            let r1s1a = fixture.weights["r1.s1.alpha"],
            let r1c1w = fixture.weights["r1.c1.weight"],
            let r1c1b = fixture.weights["r1.c1.bias"],
            let r1s2a = fixture.weights["r1.s2.alpha"],
            let r1c2w = fixture.weights["r1.c2.weight"],
            let r1c2b = fixture.weights["r1.c2.bias"],
            // Residual 2
            let r2s1a = fixture.weights["r2.s1.alpha"],
            let r2c1w = fixture.weights["r2.c1.weight"],
            let r2c1b = fixture.weights["r2.c1.bias"],
            let r2s2a = fixture.weights["r2.s2.alpha"],
            let r2c2w = fixture.weights["r2.c2.weight"],
            let r2c2b = fixture.weights["r2.c2.bias"],
            // Residual 3
            let r3s1a = fixture.weights["r3.s1.alpha"],
            let r3c1w = fixture.weights["r3.c1.weight"],
            let r3c1b = fixture.weights["r3.c1.bias"],
            let r3s2a = fixture.weights["r3.s2.alpha"],
            let r3c2w = fixture.weights["r3.c2.weight"],
            let r3c2b = fixture.weights["r3.c2.bias"],
            // Final snake + downsampling conv
            let snakeA = fixture.weights["snake.alpha"],
            let downW  = fixture.weights["down.weight"],
            let downB  = fixture.weights["down.bias"]
        else {
            Issue.record("dacvae_encoder_block weights.safetensors missing one or more expected keys")
            return
        }

        // Config: input has C=8, output has C=16, stride=2.
        // DACVAEEncoderBlock(dim: 16, stride: 2) creates residuals with dim/2=8.
        let block = DACVAEEncoderBlock(dim: 16, stride: 2)

        // Inject weights via update(parameters:) using flat dot-paths.
        // weight_v = Python weight transposed [out, in, k] → [out, k, in]
        // weight_g = per-output-channel norm of weight_v
        let r1c1wv = wv(r1c1w); let r1c2wv = wv(r1c2w)
        let r2c1wv = wv(r2c1w); let r2c2wv = wv(r2c2w)
        let r3c1wv = wv(r3c1w); let r3c2wv = wv(r3c2w)
        let downWv = wv(downW)

        let dacvaeParams: [String: MLXArray] = [
            "res1.act1.alpha":    alphaT(r1s1a),
            "res1.act2.alpha":    alphaT(r1s2a),
            "res1.conv1.weight_v": r1c1wv,
            "res1.conv1.weight_g": wg(r1c1wv),
            "res1.conv1.bias":    r1c1b,
            "res1.conv2.weight_v": r1c2wv,
            "res1.conv2.weight_g": wg(r1c2wv),
            "res1.conv2.bias":    r1c2b,
            "res2.act1.alpha":    alphaT(r2s1a),
            "res2.act2.alpha":    alphaT(r2s2a),
            "res2.conv1.weight_v": r2c1wv,
            "res2.conv1.weight_g": wg(r2c1wv),
            "res2.conv1.bias":    r2c1b,
            "res2.conv2.weight_v": r2c2wv,
            "res2.conv2.weight_g": wg(r2c2wv),
            "res2.conv2.bias":    r2c2b,
            "res3.act1.alpha":    alphaT(r3s1a),
            "res3.act2.alpha":    alphaT(r3s2a),
            "res3.conv1.weight_v": r3c1wv,
            "res3.conv1.weight_g": wg(r3c1wv),
            "res3.conv1.bias":    r3c1b,
            "res3.conv2.weight_v": r3c2wv,
            "res3.conv2.weight_g": wg(r3c2wv),
            "res3.conv2.bias":    r3c2b,
            "snake.alpha":        alphaT(snakeA),
            "conv.weight_v":      downWv,
            "conv.weight_g":      wg(downWv),
            "conv.bias":          downB,
        ]
        block.update(parameters: ModuleParameters.unflattened(dacvaeParams))
        eval(block)

        // --- Forward pass ---
        // Swift DACVAEEncoderBlock expects NLC [B, T, C].
        let swiftOutputNLC = block(inputNLC)
        eval(swiftOutputNLC)

        // --- Transpose Swift output NLC → NCL for comparison ---
        // swiftOutputNLC: [1, 16, 16] (B, T, C) → NCL: [1, 16, 16] (B, C, T)
        let swiftOutputNCL = swiftOutputNLC.swappedAxes(1, 2)

        // --- Shape assertion ---
        #expect(
            swiftOutputNCL.shape == expectedNCL.shape,
            "DACVAEEncoderBlock output shape mismatch: swift=\(swiftOutputNCL.shape) expected=\(expectedNCL.shape)"
        )

        // --- Numeric-parity assertion ---
        let close = MLX.allClose(swiftOutputNCL, expectedNCL, rtol: 1e-4, atol: 1e-4)
        let isClose = close.item(Bool.self)

        if !isClose {
            let maxAbsErr = abs(swiftOutputNCL - expectedNCL).max().item(Float.self)
            Issue.record("DACVAEEncoderBlock output != Python reference. max_abs_err=\(maxAbsErr) (atol=1e-4, rtol=1e-4)")
        }
        #expect(isClose, "dacvaeEncoderBlockMatchesPythonReference: allClose failed (atol=1e-4, rtol=1e-4)")
    }
}

// MARK: - Component Descriptor Integration Tests
// Run ComponentDescriptor tests with: xcodebuild test \
// -scheme MLXAudio-Package \
// -destination 'platform=macOS' \
// -only-testing:MLXAudioTests/ComponentDescriptorTests \
// 2>&1 | grep -E "(Suite.*started|Test test.*started|registration|availability|passed after|failed after|TEST SUCCEEDED|TEST FAILED|Suite.*passed|Test run)"

struct ComponentDescriptorTests {

    @Test func testSNACComponentRegistration() {
        // Ensure SNAC components are registered with SwiftAcervo
        SNAC.ensureComponentsRegistered()

        // Verify SNAC 24kHz component is registered
        let snacComponentId = SNACModelRepo.snac24kHz.componentId
        #expect(snacComponentId == "snac-24khz", "SNAC component ID should be 'snac-24khz'")
    }

    @Test func testSNACComponentMetadata() {
        // Verify SNAC component metadata is correct
        SNAC.ensureComponentsRegistered()

        let displayName = SNACModelRepo.snac24kHz.displayName
        #expect(displayName == "SNAC 24 kHz Audio Codec", "Display name should match")
    }

    @Test func testMimiComponentRegistration() {
        // Ensure Mimi components are registered with SwiftAcervo
        Mimi.ensureComponentsRegistered()

        // Verify Mimi PyTorch BF16 component is registered
        let mimiComponentId = MimiModelRepo.mimiPyTorchBF16.componentId
        #expect(mimiComponentId == "mimi-pytorch-bf16", "Mimi component ID should be 'mimi-pytorch-bf16'")
    }

    @Test func testMimiComponentMetadata() {
        // Verify Mimi component metadata is correct
        Mimi.ensureComponentsRegistered()

        let displayName = MimiModelRepo.mimiPyTorchBF16.displayName
        #expect(displayName == "Mimi Audio Codec (PyTorch BF16)", "Display name should match")
    }

    @Test func testSNACComponentRepositoryId() {
        // Verify SNAC uses correct HuggingFace repository
        SNAC.ensureComponentsRegistered()

        let repoId = SNACModelRepo.snac24kHz.rawValue
        #expect(repoId == "mlx-community/snac_24khz", "SNAC should use mlx-community/snac_24khz repo")
    }

    @Test func testMimiComponentRepositoryId() {
        // Verify Mimi uses correct HuggingFace repository
        Mimi.ensureComponentsRegistered()

        let repoId = MimiModelRepo.mimiPyTorchBF16.rawValue
        #expect(repoId == "kyutai/moshiko-pytorch-bf16", "Mimi should use kyutai/moshiko-pytorch-bf16 repo")
    }

    @Test func testBothComponentsCanBeRegisteredTogether() {
        // Verify both SNAC and Mimi can be registered without conflicts
        SNAC.ensureComponentsRegistered()
        Mimi.ensureComponentsRegistered()

        let snacId = SNACModelRepo.snac24kHz.componentId
        let mimiId = MimiModelRepo.mimiPyTorchBF16.componentId

        // IDs should be different and non-empty
        #expect(!snacId.isEmpty, "SNAC component ID should not be empty")
        #expect(!mimiId.isEmpty, "Mimi component ID should not be empty")
        #expect(snacId != mimiId, "Component IDs should be unique")
    }
}
