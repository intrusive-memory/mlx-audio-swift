//
//  ParityFixtureLoader.swift
//  MLXAudioTests
//
//  Swift helper for loading parity fixtures under Tests/media/parity/<name>/.
//  Each fixture family contains three safetensors files:
//    - input.safetensors   — inputs fed to the reference forward pass
//    - weights.safetensors — layer parameters (random init, fixed seed)
//    - expected.safetensors — reference outputs to compare Swift against
//
//  Key naming per fixture family is documented in
//  Tests/media/parity/README.md and verified by inspecting each file.
//
//  Reuses MLX.loadArrays(url:) — the same safetensors loader already used
//  throughout Sources/ (e.g., MLX.loadArrays in Qwen3TTS.swift, LlamaTTS.swift).
//  No custom parser is needed.
//

import Foundation
import MLX

// MARK: - Errors

/// Errors thrown by ParityFixtureLoader.
enum ParityFixtureLoaderError: Error, CustomStringConvertible {
    case fixtureDirectoryNotFound(String)
    case fileNotFound(family: String, file: String)

    var description: String {
        switch self {
        case .fixtureDirectoryNotFound(let name):
            return "Parity fixture directory not found in test bundle: media/parity/\(name)"
        case .fileNotFound(let family, let file):
            return "Parity fixture file not found: media/parity/\(family)/\(file)"
        }
    }
}

// MARK: - Fixture result

/// The loaded contents of a parity fixture family.
///
/// - `input`:    All arrays from `input.safetensors` (keyed by tensor name).
/// - `weights`:  All arrays from `weights.safetensors` (keyed by tensor name).
/// - `expected`: All arrays from `expected.safetensors` (keyed by tensor name).
///
/// Callers that only need the primary single-tensor input or expected value
/// can use `input.values.first!` / `expected.values.first!`, but it is safer
/// to key by the documented tensor name for the specific family.
struct ParityFixture {
    let input: [String: MLXArray]
    let weights: [String: MLXArray]
    let expected: [String: MLXArray]
}

// MARK: - Loader

/// Load a parity fixture family from the test bundle.
///
/// - Parameter name: The subdirectory name under `Tests/media/parity/`
///   (e.g. `"dsp"`, `"vocos_istft_head"`, `"encodec_quantizer"`,
///   `"dacvae_encoder_block"`, `"snac_vq"`, `"mimi_rvq"`).
/// - Returns: A `ParityFixture` containing all arrays from the three
///   safetensors files.
/// - Throws: `ParityFixtureLoaderError` if the fixture directory or any
///   required file cannot be found in the test bundle.
func loadParityFixture(_ name: String) throws -> ParityFixture {
    // Locate the fixture directory in the test bundle (media/ is copied via
    // Package.swift resources: [.copy("media")]).
    guard
        let baseURL = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "media/parity"
        )
    else {
        throw ParityFixtureLoaderError.fixtureDirectoryNotFound(name)
    }

    func loadFile(_ filename: String) throws -> [String: MLXArray] {
        let fileURL = baseURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParityFixtureLoaderError.fileNotFound(family: name, file: filename)
        }
        // MLX.loadArrays(url:) is the project-wide safetensors loader.
        // It supports both single-file safetensors and sharded index files.
        return try MLX.loadArrays(url: fileURL)
    }

    let input    = try loadFile("input.safetensors")
    let weights  = try loadFile("weights.safetensors")
    let expected = try loadFile("expected.safetensors")

    return ParityFixture(input: input, weights: weights, expected: expected)
}
