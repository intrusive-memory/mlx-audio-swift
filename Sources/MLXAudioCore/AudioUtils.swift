import AVFoundation
import Foundation
import MLX

public class AudioUtils {
  enum AudioUtilsErrors: Error {
    case cannotCreateAVAudioFormat
  }

  private init() {}

  // Debug method to write output to .wav file for checking the speech generation
  static func writeWavFile(samples: [Float], sampleRate: Double, fileURL: URL) throws {
    let frameCount = AVAudioFrameCount(samples.count)

    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else {
      throw AudioUtilsErrors.cannotCreateAVAudioFormat
    }

    buffer.frameLength = frameCount
    let channelData = buffer.floatChannelData![0]
    for i in 0 ..< Int(frameCount) {
      channelData[i] = samples[i]
    }

    let audioFile = try AVAudioFile(
      forWriting: fileURL,
      settings: format.settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )

    try audioFile.write(from: buffer)
  }
}




/// Load audio from a file and return the sample rate and audio data.
///
/// For WAV files, parses the RIFF/WAVE header directly and decodes Int16 PCM,
/// Int32 PCM, or IEEE float samples to Float32. AVAudioFile.read(into:) silently
/// truncates to 1024-frame boundaries for non-aligned file lengths (Sortie 14
/// finding, originally mis-attributed to saveAudioArray); the hand-rolled WAV
/// path avoids that. Non-WAV containers fall back to AVAudioFile.
///
/// - Parameters:
///   - url: The file URL to load audio from.
///   - telemetry: Optional telemetry reporter. When `nil` (the default), no
///     events are emitted and no payload primitives are computed — zero overhead.
///     When non-nil, emits `audioLoadStart`, `audioLoadComplete`, and
///     `audioIOError` (on failure).
///
/// Existing call sites that omit `telemetry:` compile unchanged because the
/// parameter is defaulted to `nil`.
public func loadAudioArray(
    from url: URL,
    telemetry: (any MLXAudioTelemetryReporter)? = nil
) throws -> (Int, MLXArray) {
    // Compute file size only when a reporter is attached (invariant 3: zero overhead).
    if let telemetry {
        let fileSizeMB: Double
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? Int {
            fileSizeMB = Double(fileSize) / (1024.0 * 1024.0)
        } else {
            fileSizeMB = 0
        }
        let path = url.path
        Task { await telemetry.capture(.audioLoadStart(path: path, fileSizeMB: fileSizeMB)) }
    }

    do {
        let result: (Int, MLXArray)
        if let wav = try readWavFile(at: url) {
            result = wav
        } else {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw NSError(domain: "TestHelpers", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
            }

            try audioFile.read(into: buffer)

            guard let floatChannelData = buffer.floatChannelData else {
                throw NSError(domain: "TestHelpers", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get float channel data"])
            }

            let sampleRate = Int(format.sampleRate)
            let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: Int(buffer.frameLength)))
            let audioData = MLXArray(samples)
            result = (sampleRate, audioData)
        }

        if let telemetry {
            let (sampleRate, audioData) = result
            let samples = audioData.shape[0]
            let durationSeconds = samples > 0 && sampleRate > 0
                ? Double(samples) / Double(sampleRate) : 0.0
            let path = url.path
            Task {
                await telemetry.capture(.audioLoadComplete(
                    path: path,
                    samples: samples,
                    sampleRate: sampleRate,
                    durationSeconds: durationSeconds
                ))
            }
        }

        return result
    } catch {
        if let telemetry {
            let path = url.path
            let errorString = String(describing: error)
            Task { await telemetry.capture(.audioIOError(path: path, operation: "load", error: errorString)) }
        }
        throw error
    }
}

/// Hand-rolled RIFF/WAVE reader. Returns nil if the file isn't a WAV (caller
/// falls back to AVAudioFile). Throws if the file has a WAV signature but is
/// malformed or uses an unsupported format.
private func readWavFile(at url: URL) throws -> (Int, MLXArray)? {
    let data = try Data(contentsOf: url)
    guard data.count >= 44 else { return nil }
    guard data.readASCII(at: 0, count: 4) == "RIFF",
          data.readASCII(at: 8, count: 4) == "WAVE" else {
        return nil
    }

    var formatCode: UInt16 = 0
    var channels: UInt16 = 0
    var sampleRate: UInt32 = 0
    var bitsPerSample: UInt16 = 0
    var dataOffset: Int? = nil
    var dataLength: Int = 0

    var cursor = 12
    while cursor + 8 <= data.count {
        let chunkID = data.readASCII(at: cursor, count: 4)
        let chunkSize = Int(data.readLEUInt32(at: cursor + 4))
        let bodyStart = cursor + 8

        switch chunkID {
        case "fmt ":
            guard chunkSize >= 16 else {
                throw NSError(domain: "AudioUtils", code: 10, userInfo: [NSLocalizedDescriptionKey: "WAV fmt chunk too small"])
            }
            formatCode = data.readLEUInt16(at: bodyStart)
            channels = data.readLEUInt16(at: bodyStart + 2)
            sampleRate = data.readLEUInt32(at: bodyStart + 4)
            bitsPerSample = data.readLEUInt16(at: bodyStart + 14)
        case "data":
            dataOffset = bodyStart
            dataLength = chunkSize
        default:
            break
        }

        // Chunks are word-aligned: skip an extra byte if chunkSize is odd.
        cursor = bodyStart + chunkSize + (chunkSize & 1)
        if dataOffset != nil { break }
    }

    guard let dataStart = dataOffset, channels > 0, bitsPerSample > 0, sampleRate > 0 else {
        throw NSError(domain: "AudioUtils", code: 11, userInfo: [NSLocalizedDescriptionKey: "WAV missing fmt or data chunk"])
    }

    let bytesPerSample = Int(bitsPerSample / 8)
    let frameStride = bytesPerSample * Int(channels)
    let frameCount = dataLength / frameStride
    let dataEnd = dataStart + frameCount * frameStride
    guard dataEnd <= data.count else {
        throw NSError(domain: "AudioUtils", code: 12, userInfo: [NSLocalizedDescriptionKey: "WAV data chunk overruns file"])
    }

    var samples = [Float](repeating: 0, count: frameCount)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        let payload = base.advanced(by: dataStart)
        switch (formatCode, bitsPerSample) {
        case (1, 16):
            let int16Ptr = payload.assumingMemoryBound(to: Int16.self)
            let scale = Float(1.0 / 32768.0)
            for i in 0..<frameCount {
                samples[i] = Float(int16Ptr[i * Int(channels)].littleEndian) * scale
            }
        case (1, 32):
            let int32Ptr = payload.assumingMemoryBound(to: Int32.self)
            let scale = Float(1.0 / 2_147_483_648.0)
            for i in 0..<frameCount {
                samples[i] = Float(int32Ptr[i * Int(channels)].littleEndian) * scale
            }
        case (3, 32):
            let floatPtr = payload.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                samples[i] = floatPtr[i * Int(channels)]
            }
        default:
            samples = []
        }
    }

    if samples.isEmpty && frameCount > 0 {
        throw NSError(domain: "AudioUtils", code: 13, userInfo: [
            NSLocalizedDescriptionKey: "WAV format unsupported: code=\(formatCode), bits=\(bitsPerSample)"
        ])
    }

    return (Int(sampleRate), MLXArray(samples))
}

private extension Data {
    func readASCII(at offset: Int, count: Int) -> String {
        guard offset + count <= self.count else { return "" }
        return String(decoding: self[offset..<offset + count], as: UTF8.self)
    }

    func readLEUInt16(at offset: Int) -> UInt16 {
        let lo = UInt16(self[offset])
        let hi = UInt16(self[offset + 1])
        return (hi << 8) | lo
    }

    func readLEUInt32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
}

/// Save audio data to a WAV file.
///
/// - Parameters:
///   - audio: The MLXArray of float32 audio samples to write.
///   - sampleRate: The sample rate in Hz.
///   - url: The destination file URL.
///   - telemetry: Optional telemetry reporter. When `nil` (the default), no
///     events are emitted and no payload primitives are computed — zero overhead.
///     When non-nil, emits `audioSaveStart`, `audioSaveComplete`, and
///     `audioIOError` (on failure).
///
/// Existing call sites that omit `telemetry:` compile unchanged because the
/// parameter is defaulted to `nil`.
func saveAudioArray(
    _ audio: MLXArray,
    sampleRate: Double,
    to url: URL,
    telemetry: (any MLXAudioTelemetryReporter)? = nil
) throws {
    let samples = audio.asArray(Float.self)

    if let telemetry {
        let path = url.path
        let sampleRateInt = Int(sampleRate)
        Task {
            await telemetry.capture(.audioSaveStart(
                path: path,
                samples: samples.count,
                sampleRate: sampleRateInt
            ))
        }
    }

    do {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "TestHelpers", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData {
            for i in 0..<samples.count {
                channelData[0][i] = samples[i]
            }
        }

        try audioFile.write(from: buffer)

        if let telemetry {
            let path = url.path
            let fileSizeMB: Double
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? Int {
                fileSizeMB = Double(fileSize) / (1024.0 * 1024.0)
            } else {
                fileSizeMB = 0
            }
            Task { await telemetry.capture(.audioSaveComplete(path: path, fileSizeMB: fileSizeMB)) }
        }
    } catch {
        if let telemetry {
            let path = url.path
            let errorString = String(describing: error)
            Task { await telemetry.capture(.audioIOError(path: path, operation: "save", error: errorString)) }
        }
        throw error
    }
}

/// A streaming WAV writer that allows writing audio chunks incrementally to a file.
/// This is more memory efficient than collecting all audio in memory before writing.
public class StreamingWAVWriter {
    private let url: URL
    private let sampleRate: Double
    private var audioFile: AVAudioFile?
    private let format: AVAudioFormat
    private(set) public var framesWritten: Int = 0

    public init(url: URL, sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(
                domain: "StreamingWAVWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"]
            )
        }
        self.format = format
        self.audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    /// Write a chunk of audio samples to the file.
    public func writeChunk(_ samples: [Float]) throws {
        guard let audioFile = audioFile else {
            throw NSError(
                domain: "StreamingWAVWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio file not initialized or already finalized"]
            )
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(
                domain: "StreamingWAVWriter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"]
            )
        }

        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData {
            for i in 0..<samples.count {
                channelData[0][i] = samples[i]
            }
        }

        try audioFile.write(from: buffer)
        framesWritten += samples.count
    }

    /// Finalize the WAV file and return the URL.
    /// After calling this method, no more chunks can be written.
    public func finalize() -> URL {
        audioFile = nil  // Close the file by releasing the reference
        return url
    }
}
