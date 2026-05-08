//
//  AudioModelManager.swift
//  MLXAudioCore
//
//  Manages audio model component registration and download lifecycle via SwiftAcervo.
//  This module serves as the central registry for:
//    - P1 (priority 1) audio models: SNAC, Mimi codecs (hard-coded in apps)
//    - P2 (priority 2) audio models: VyvoTTS, Orpheus, Soprano, MarvisTTS, PocketTTS
//
//  All required files are pre-declared so Acervo can download and verify before inference.
//
//  Pattern: ComponentDescriptor with lazy module-level registration (following SwiftVoxAlta).
//

import Foundation
import Metal
import SwiftAcervo

// MARK: - Supported Audio Models

/// Known audio model repos supported by mlx-audio-swift.
///
/// Covers both P1 (stable codec models: SNAC, Mimi) and P2 (extended audio codecs and TTS models)
/// suitable for ComponentDescriptor registration. Dynamic models (user-specified variants) use
/// HuggingFace discovery (legacy path, now removed).
public enum AudioModelRepo: String, CaseIterable, Sendable {
  // MARK: - Codecs (P1 — Stable)

  /// SNAC 24 kHz neural audio codec.
  /// Compresses 24 kHz audio to discrete codes at 0.98 kbps.
  /// Used by: Qwen3-TTS for audio encoding during inference.
  case snac24kHz = "mlx-community/snac_24khz"

  /// Mimi PyTorch BF16 neural audio codec.
  /// High-quality 24 kHz audio compression via 32 codebooks.
  /// Used by: MarvisTTS as encoder/decoder, other generative models.
  case mimiPyTorchBF16 = "kyutai/moshiko-pytorch-bf16"

  // MARK: - TTS Models (P2 — Extended)

  /// VyvoTTS / Qwen3 TTS (4-bit quantized).
  /// Fast, multi-language TTS model for real-time synthesis.
  case vyvoTTSBeta4bit = "mlx-community/VyvoTTS-EN-Beta-4bit"

  /// Orpheus / LlamaTTS (3B params, bfloat16).
  /// High-quality generative TTS based on Llama architecture.
  case orpheusTTS = "mlx-community/orpheus-3b-0.1-ft-bf16"

  /// Soprano TTS (80M params, bfloat16).
  /// Lightweight, fast TTS model for Apple Silicon.
  case sopranoTTS = "mlx-community/Soprano-80M-bf16"

  /// MarvisTTS (250M params, 8-bit quantized).
  /// Premium quality TTS with speaker control and voice design.
  case marvisTTS = "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit"

  /// PocketTTS (small, multi-voice).
  /// Compact TTS model for on-device synthesis.
  case pocketTTS = "mlx-community/pocket-tts"

  /// Qwen3-TTS 12Hz 1.7B Base (bfloat16).
  /// Base conditional generation model supporting x-vector speaker embedding
  /// (from reference audio) and in-context voice cloning (ICL). Ships the
  /// ECAPA-TDNN speaker encoder.
  case qwen3TTS12Hz1_7BBaseBF16 = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"

  /// Qwen3-TTS 12Hz 1.7B VoiceDesign (bfloat16).
  /// Text-described voice generation (instruct-style prompt); no speaker encoder.
  case qwen3TTS12Hz1_7BVoiceDesignBF16 = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"

  /// Qwen3-TTS 12Hz 1.7B CustomVoice (bfloat16).
  /// Predefined named-speaker generation; no speaker encoder.
  case qwen3TTS12Hz1_7BCustomVoiceBF16 = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"

  // MARK: - Audio Codecs (P2 — Extended)

  /// DAC VAE (watermarked) neural audio codec — MLX port of Facebook's DACVAE.
  /// Continuous-latent VAE-style codec with embedded watermarking support.
  /// Used by: SAM-Audio and generative models requiring continuous latent representations.
  case dacVAEWatermarked = "mlx-community/dacvae-watermarked"

  /// Encodec 24 kHz (float32) neural audio codec — Meta's EnCodec at 24 kHz.
  /// Used by: Vocos vocoder (`encodec_24khz` variant) as the underlying codec backend.
  case encodec24kHz = "mlx-community/encodec-24khz-float32"

  /// Encodec 48 kHz (float32) neural audio codec — Meta's EnCodec at 48 kHz.
  /// Used by: Vocos vocoder (`encodec_48khz` variant) as the underlying codec backend.
  case encodec48kHz = "mlx-community/encodec-48khz-float32"

  // MARK: - ASR Models (P2 — Extended)

  /// GLM-ASR Nano (4-bit quantized) automatic speech recognition model.
  /// Compact, quantized speech-to-text model based on the GLM architecture.
  /// Used by: MLXAudioSTT for on-device transcription.
  case glmASRNano2512_4bit = "mlx-community/GLM-ASR-Nano-2512-4bit"

  /// Qwen3 ASR 0.6B (4-bit quantized) automatic speech recognition model.
  /// Compact, quantized speech-to-text model based on the Qwen3 architecture.
  /// Used by: MLXAudioSTT for on-device transcription.
  case qwen3ASR_0_6B_4bit = "mlx-community/Qwen3-ASR-0.6B-4bit"

  /// Human-readable display name for the model variant.
  public var displayName: String {
    switch self {
    case .snac24kHz:
      return "SNAC 24 kHz Audio Codec"
    case .mimiPyTorchBF16:
      return "Mimi Audio Codec (PyTorch BF16)"
    case .vyvoTTSBeta4bit:
      return "VyvoTTS / Qwen3 TTS (4-bit)"
    case .orpheusTTS:
      return "Orpheus TTS (LlamaTTS, BF16)"
    case .sopranoTTS:
      return "Soprano TTS (80M, BF16)"
    case .marvisTTS:
      return "MarvisTTS (250M, 8-bit)"
    case .pocketTTS:
      return "PocketTTS (Multi-voice)"
    case .qwen3TTS12Hz1_7BBaseBF16:
      return "Qwen3-TTS 12Hz 1.7B Base (BF16)"
    case .qwen3TTS12Hz1_7BVoiceDesignBF16:
      return "Qwen3-TTS 12Hz 1.7B VoiceDesign (BF16)"
    case .qwen3TTS12Hz1_7BCustomVoiceBF16:
      return "Qwen3-TTS 12Hz 1.7B CustomVoice (BF16)"
    case .dacVAEWatermarked:
      return "DAC VAE Audio Codec"
    case .encodec24kHz:
      return "Encodec 24 kHz Audio Codec (float32)"
    case .encodec48kHz:
      return "Encodec 48 kHz Audio Codec (float32)"
    case .glmASRNano2512_4bit:
      return "GLM-ASR Nano (4-bit)"
    case .qwen3ASR_0_6B_4bit:
      return "Qwen3 ASR 0.6B (4-bit)"
    }
  }

  /// The Acervo component ID for this model variant.
  ///
  /// Used to look up, download, and check availability of this model
  /// via the SwiftAcervo Component Registry.
  public var componentId: String {
    switch self {
    case .snac24kHz:
      return "snac-24khz"
    case .mimiPyTorchBF16:
      return "mimi-pytorch-bf16"
    case .vyvoTTSBeta4bit:
      return "vyvo-tts-beta-4bit"
    case .orpheusTTS:
      return "orpheus-tts-3b"
    case .sopranoTTS:
      return "soprano-tts-80m"
    case .marvisTTS:
      return "marvis-tts-250m-8bit"
    case .pocketTTS:
      return "pocket-tts"
    // Qwen3-TTS variants resolve to `Acervo.slugify(rawValue)`, which matches the
    // CDN slug under which the manifest is published at <CDN_BASE>/models/<slug>/manifest.json.
    case .qwen3TTS12Hz1_7BBaseBF16:
      return Acervo.slugify(rawValue)
    case .qwen3TTS12Hz1_7BVoiceDesignBF16:
      return Acervo.slugify(rawValue)
    case .qwen3TTS12Hz1_7BCustomVoiceBF16:
      return Acervo.slugify(rawValue)
    case .dacVAEWatermarked:
      return "dac-vae"
    case .encodec24kHz:
      return "encodec-24khz"
    case .encodec48kHz:
      return "encodec-48khz"
    case .glmASRNano2512_4bit:
      return "glm-asr"
    case .qwen3ASR_0_6B_4bit:
      return "qwen3-asr"
    }
  }

  /// The corresponding Acervo component type.
  ///
  /// Codecs are decoders (latent-to-audio conversion).
  /// TTS models are language models (autoregressive generative models).
  public var componentType: ComponentType {
    switch self {
    case .snac24kHz, .mimiPyTorchBF16, .dacVAEWatermarked, .encodec24kHz, .encodec48kHz:
      return .decoder
    case .vyvoTTSBeta4bit, .orpheusTTS, .sopranoTTS, .marvisTTS, .pocketTTS,
         .qwen3TTS12Hz1_7BBaseBF16, .qwen3TTS12Hz1_7BVoiceDesignBF16,
         .qwen3TTS12Hz1_7BCustomVoiceBF16:
      return .languageModel
    case .glmASRNano2512_4bit:
      return .encoder
    case .qwen3ASR_0_6B_4bit:
      return .encoder
    }
  }
}

// MARK: - Acervo Component Registration

/// Required files for the SNAC 24 kHz model variant.
///
/// These files are declared so that `Acervo.ensureComponentReady()` knows exactly
/// what to download before any codec operation is attempted.
private let snac24kHzRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
]

/// Required files for the Mimi PyTorch BF16 model variant.
///
/// Single-file model: only the tokenizer checkpoint is required.
private let mimiPyTorchBF16RequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "tokenizer-e351c8d8-checkpoint125.safetensors"),
]

/// Required files for the DAC VAE (Watermarked) model variant.
///
/// Continuous-latent VAE codec: config plus weight file.
private let dacVAEWatermarkedRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
]

/// Required files shared by all Encodec model variants (24 kHz and 48 kHz).
///
/// Both repos ship the same three-file layout: config, weight file, and sharded-weight index.
private let encodecRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "model.safetensors.index.json"),
]

// MARK: - P2 ASR Model Files

/// Required files for the GLM-ASR Nano (4-bit quantized) model.
///
/// Swift-runtime files only; Python reference scripts shipped in the repo are excluded.
private let glmASRNano2512_4bitRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "model.safetensors.index.json"),
  ComponentFile(relativePath: "tokenizer.json"),
  ComponentFile(relativePath: "tokenizer_config.json"),
]

/// Required files for the Qwen3 ASR 0.6B (4-bit quantized) model.
///
/// tokenizer.json is NOT listed; the Swift loader auto-generates it at runtime
/// from vocab.json + merges.txt when missing.
private let qwen3ASR_0_6B_4bitRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "model.safetensors.index.json"),
  ComponentFile(relativePath: "chat_template.json"),
  ComponentFile(relativePath: "generation_config.json"),
  ComponentFile(relativePath: "merges.txt"),
  ComponentFile(relativePath: "preprocessor_config.json"),
  ComponentFile(relativePath: "tokenizer_config.json"),
  ComponentFile(relativePath: "vocab.json"),
]

// MARK: - P2 TTS Model Files

/// Required files for VyvoTTS / Qwen3 TTS (4-bit quantized variant).
///
/// Lightweight multi-language TTS with quantized weights for faster inference.
private let vyvoTTSBeta4bitRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "tokenizer.json"),
]

/// Required files for Orpheus / LlamaTTS (3B params, bfloat16).
///
/// Generative TTS based on Llama architecture with high-quality synthesis.
private let orpheusTTSRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
]

/// Required files for Soprano TTS (80M params, bfloat16).
///
/// Lightweight model optimized for Apple Silicon with single-file weight distribution.
private let sopranoTTSRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "tokenizer.json"),
]

/// Required files for MarvisTTS (250M params, 8-bit quantized).
///
/// Premium quality TTS with speaker control, voice design, and multi-speaker synthesis.
private let marvisTTSRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "tokenizer.json"),
]

/// Required files for PocketTTS (small, multi-voice).
///
/// Compact TTS model for on-device synthesis with multiple voice options.
private let pocketTTSRequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "tokenizer.json"),
]

// MARK: - Qwen3-TTS 12Hz 1.7B Variants (Base / VoiceDesign / CustomVoice)
//
// These three repos share a file layout:
//   - Top-level: config.json, vocab.json, merges.txt, tokenizer_config.json, model.safetensors
//   - speech_tokenizer/: config.json, model.safetensors
// tokenizer.json is NOT shipped; Qwen3TTSModel.fromPretrained generates it on first load
// from vocab.json + merges.txt + tokenizer_config.json.
// Speaker encoder weights (Base variant only) are bundled inside the top-level model.safetensors.

/// Required files for Qwen3-TTS 12Hz 1.7B Base (bfloat16).
private let qwen3TTS12Hz1_7BBaseBF16RequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "vocab.json"),
  ComponentFile(relativePath: "merges.txt"),
  ComponentFile(relativePath: "tokenizer_config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "speech_tokenizer/config.json"),
  ComponentFile(relativePath: "speech_tokenizer/model.safetensors"),
]

/// Required files for Qwen3-TTS 12Hz 1.7B VoiceDesign (bfloat16).
private let qwen3TTS12Hz1_7BVoiceDesignBF16RequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "vocab.json"),
  ComponentFile(relativePath: "merges.txt"),
  ComponentFile(relativePath: "tokenizer_config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "speech_tokenizer/config.json"),
  ComponentFile(relativePath: "speech_tokenizer/model.safetensors"),
]

/// Required files for Qwen3-TTS 12Hz 1.7B CustomVoice (bfloat16).
private let qwen3TTS12Hz1_7BCustomVoiceBF16RequiredFiles: [ComponentFile] = [
  ComponentFile(relativePath: "config.json"),
  ComponentFile(relativePath: "vocab.json"),
  ComponentFile(relativePath: "merges.txt"),
  ComponentFile(relativePath: "tokenizer_config.json"),
  ComponentFile(relativePath: "model.safetensors"),
  ComponentFile(relativePath: "speech_tokenizer/config.json"),
  ComponentFile(relativePath: "speech_tokenizer/model.safetensors"),
]

/// All audio model component descriptors (P1 + P2).
///
/// P1 models: Stable codec models (SNAC, Mimi) hard-coded in applications.
/// P2 models: Extended TTS models for text-to-speech synthesis.
///
/// Registered at module initialization so the Acervo Component Registry
/// is populated before any model loading or download is attempted.
private let audioComponentDescriptors: [ComponentDescriptor] = [
  // MARK: - P1 Codecs (Stable)

  ComponentDescriptor(
    id: AudioModelRepo.snac24kHz.componentId,
    type: .decoder,
    displayName: "SNAC 24 kHz Audio Codec",
    repoId: AudioModelRepo.snac24kHz.rawValue,
    files: snac24kHzRequiredFiles,
    estimatedSizeBytes: 158_809_902,
    minimumMemoryBytes: 200_000_000,
    metadata: [
      "sampleRate": "24000",
      "bitrate": "0.98 kbps",
      "rvqLevels": "3",
      "modelType": "codec",
      "stage": "P1",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.mimiPyTorchBF16.componentId,
    type: .decoder,
    displayName: "Mimi Audio Codec (PyTorch BF16)",
    repoId: AudioModelRepo.mimiPyTorchBF16.rawValue,
    files: mimiPyTorchBF16RequiredFiles,
    estimatedSizeBytes: 403_931_136,
    minimumMemoryBytes: 500_000_000,
    metadata: [
      "sampleRate": "24000",
      "numCodebooks": "32",
      "modelType": "codec",
      "stage": "P1",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.dacVAEWatermarked.componentId,
    type: .decoder,
    displayName: "DAC VAE Audio Codec",
    repoId: AudioModelRepo.dacVAEWatermarked.rawValue,
    files: dacVAEWatermarkedRequiredFiles,
    estimatedSizeBytes: 200_000_000,
    minimumMemoryBytes: 500_000_000,
    metadata: [
      "modelType": "codec",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.encodec24kHz.componentId,
    type: .decoder,
    displayName: "Encodec 24 kHz Audio Codec (float32)",
    repoId: AudioModelRepo.encodec24kHz.rawValue,
    files: encodecRequiredFiles,
    estimatedSizeBytes: 80_000_000,
    minimumMemoryBytes: 200_000_000,
    metadata: [
      "modelType": "codec",
      "sampleRate": "24000",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.encodec48kHz.componentId,
    type: .decoder,
    displayName: "Encodec 48 kHz Audio Codec (float32)",
    repoId: AudioModelRepo.encodec48kHz.rawValue,
    files: encodecRequiredFiles,
    estimatedSizeBytes: 80_000_000,
    minimumMemoryBytes: 200_000_000,
    metadata: [
      "modelType": "codec",
      "sampleRate": "48000",
      "stage": "P2",
    ]
  ),

  // MARK: - P2 ASR Models (Extended)

  ComponentDescriptor(
    id: AudioModelRepo.glmASRNano2512_4bit.componentId,
    type: .encoder,
    displayName: "GLM-ASR Nano (4-bit)",
    repoId: AudioModelRepo.glmASRNano2512_4bit.rawValue,
    files: glmASRNano2512_4bitRequiredFiles,
    estimatedSizeBytes: 600_000_000,
    minimumMemoryBytes: 1_200_000_000,
    metadata: [
      "modelType": "asr",
      "quantization": "4-bit",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.qwen3ASR_0_6B_4bit.componentId,
    type: .encoder,
    displayName: "Qwen3 ASR 0.6B (4-bit)",
    repoId: AudioModelRepo.qwen3ASR_0_6B_4bit.rawValue,
    files: qwen3ASR_0_6B_4bitRequiredFiles,
    estimatedSizeBytes: 700_000_000,
    minimumMemoryBytes: 1_500_000_000,
    metadata: [
      "modelType": "asr",
      "params": "0.6B",
      "quantization": "4-bit",
      "stage": "P2",
    ]
  ),

  // MARK: - P2 TTS Models (Extended)

  ComponentDescriptor(
    id: AudioModelRepo.vyvoTTSBeta4bit.componentId,
    type: .languageModel,
    displayName: "VyvoTTS / Qwen3 TTS (4-bit)",
    repoId: AudioModelRepo.vyvoTTSBeta4bit.rawValue,
    files: vyvoTTSBeta4bitRequiredFiles,
    estimatedSizeBytes: 1_200_000_000,
    minimumMemoryBytes: 2_000_000_000,
    metadata: [
      "sampleRate": "22050",
      "quantization": "4-bit",
      "languages": "multi",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.orpheusTTS.componentId,
    type: .languageModel,
    displayName: "Orpheus TTS (LlamaTTS, BF16)",
    repoId: AudioModelRepo.orpheusTTS.rawValue,
    files: orpheusTTSRequiredFiles,
    estimatedSizeBytes: 6_500_000_000,
    minimumMemoryBytes: 8_000_000_000,
    metadata: [
      "sampleRate": "22050",
      "params": "3B",
      "dtype": "bfloat16",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.sopranoTTS.componentId,
    type: .languageModel,
    displayName: "Soprano TTS (80M, BF16)",
    repoId: AudioModelRepo.sopranoTTS.rawValue,
    files: sopranoTTSRequiredFiles,
    estimatedSizeBytes: 350_000_000,
    minimumMemoryBytes: 1_000_000_000,
    metadata: [
      "sampleRate": "22050",
      "params": "80M",
      "dtype": "bfloat16",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.marvisTTS.componentId,
    type: .languageModel,
    displayName: "MarvisTTS (250M, 8-bit)",
    repoId: AudioModelRepo.marvisTTS.rawValue,
    files: marvisTTSRequiredFiles,
    estimatedSizeBytes: 1_000_000_000,
    minimumMemoryBytes: 2_500_000_000,
    metadata: [
      "sampleRate": "22050",
      "params": "250M",
      "quantization": "8-bit",
      "speakers": "multi",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.pocketTTS.componentId,
    type: .languageModel,
    displayName: "PocketTTS (Multi-voice)",
    repoId: AudioModelRepo.pocketTTS.rawValue,
    files: pocketTTSRequiredFiles,
    estimatedSizeBytes: 600_000_000,
    minimumMemoryBytes: 1_500_000_000,
    metadata: [
      "sampleRate": "22050",
      "voices": "multi",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),

  // MARK: - Qwen3-TTS 12Hz 1.7B Variants (Base / VoiceDesign / CustomVoice)

  ComponentDescriptor(
    id: AudioModelRepo.qwen3TTS12Hz1_7BBaseBF16.componentId,
    type: .languageModel,
    displayName: "Qwen3-TTS 12Hz 1.7B Base (BF16)",
    repoId: AudioModelRepo.qwen3TTS12Hz1_7BBaseBF16.rawValue,
    files: qwen3TTS12Hz1_7BBaseBF16RequiredFiles,
    estimatedSizeBytes: 3_500_000_000,
    minimumMemoryBytes: 6_000_000_000,
    metadata: [
      "sampleRate": "24000",
      "codecFrameRate": "12",
      "params": "1.7B",
      "dtype": "bfloat16",
      "ttsModelType": "base",
      "voiceSource": "x-vector-from-ref-audio",
      "hasSpeakerEncoder": "true",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.qwen3TTS12Hz1_7BVoiceDesignBF16.componentId,
    type: .languageModel,
    displayName: "Qwen3-TTS 12Hz 1.7B VoiceDesign (BF16)",
    repoId: AudioModelRepo.qwen3TTS12Hz1_7BVoiceDesignBF16.rawValue,
    files: qwen3TTS12Hz1_7BVoiceDesignBF16RequiredFiles,
    estimatedSizeBytes: 3_500_000_000,
    minimumMemoryBytes: 6_000_000_000,
    metadata: [
      "sampleRate": "24000",
      "codecFrameRate": "12",
      "params": "1.7B",
      "dtype": "bfloat16",
      "ttsModelType": "voice_design",
      "voiceSource": "text-description",
      "hasSpeakerEncoder": "false",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),
  ComponentDescriptor(
    id: AudioModelRepo.qwen3TTS12Hz1_7BCustomVoiceBF16.componentId,
    type: .languageModel,
    displayName: "Qwen3-TTS 12Hz 1.7B CustomVoice (BF16)",
    repoId: AudioModelRepo.qwen3TTS12Hz1_7BCustomVoiceBF16.rawValue,
    files: qwen3TTS12Hz1_7BCustomVoiceBF16RequiredFiles,
    estimatedSizeBytes: 3_500_000_000,
    minimumMemoryBytes: 6_000_000_000,
    metadata: [
      "sampleRate": "24000",
      "codecFrameRate": "12",
      "params": "1.7B",
      "dtype": "bfloat16",
      "ttsModelType": "custom_voice",
      "voiceSource": "predefined-named-speakers",
      "hasSpeakerEncoder": "false",
      "modelType": "tts",
      "stage": "P2",
    ]
  ),
]

/// Module-level registration trigger.
///
/// This `let` is evaluated once (lazily) on first access, registering all
/// P1 (codecs: SNAC, Mimi) and P2 (TTS: VyvoTTS, Orpheus, Soprano, MarvisTTS, PocketTTS)
/// audio component descriptors with the SwiftAcervo Component Registry.
/// Called automatically by the AudioModelManager or consumers that need
/// model availability checks.
private let _registerAudioComponents: Void = {
  Acervo.register(audioComponentDescriptors)
}()

// MARK: - Model Loading Strategy

/// # Model Loading in mlx-audio-swift
///
/// ## P1 Models (Priority 1: Stable Codecs)
/// - **Models**: SNAC (24 kHz), Mimi (PyTorch BF16)
/// - **Source**: Acervo CDN only (NO HuggingFace fallback)
/// - **Loading**: v2 Acervo API (`withComponentAccess()`)
/// - **Why**: Hard-coded in apps, consistent requirements, integrity critical
/// - **Error**: If not on Acervo CDN, loading fails explicitly (no silent fallback)
///
/// ## P2 Models (Priority 2: Extended TTS)
/// - **Models**: VyvoTTS, Orpheus, Soprano, MarvisTTS, PocketTTS
/// - **Source**: Acervo CDN (if registered) OR HuggingFace (fallback)
/// - **Loading**: v1 API (`ensureModelReady()`) for Acervo; direct Acervo CDN download
/// - **Why**: More flexible, user-specifiable variants, gradual Acervo migration
/// - **Note**: P2 models are now registered as ComponentDescriptors but haven't removed HF fallback yet
///
/// ## Unknown/Custom Models
/// - **Source**: HuggingFace only (direct download)
/// - **Loading**: Standard Acervo API
/// - **Why**: Support user-specified custom models not in registry
///
/// ## Migration Path
/// 1. P1 models ✅ COMPLETE: Full Acervo-only via v2 API
/// 2. P2 models 🚧 IN PROGRESS: Registered but still use HF fallback
/// 3. P2 models FUTURE: Remove HF fallback, require Acervo registration

// MARK: - Telemetry storage (Sortie 2 — OPERATION SILENT STETHOSCOPE)

/// File-private actor that holds the optional public-telemetry reporter
/// for the `AudioModelManager` namespace.
///
/// `AudioModelManager` is a `public enum` with only `static` members, so
/// the canonical per-instance `private var telemetry: ...?` storage from
/// `MLXAudioTelemetryReporter.swift`'s doc comment cannot live on `self`.
/// We instead hold the reporter inside a single file-private actor and
/// expose the canonical `setTelemetry(_:)` / `emit(_:)` shape through
/// `static` wrappers on `AudioModelManager`.
///
/// The `@autoclosure` deferral semantics of the canonical helper are
/// preserved: payload-construction (e.g. `MTLDevice.currentAllocatedSize`
/// sampling, error-string formatting) only runs after we have read a
/// non-`nil` reporter out of the actor. With no reporter attached the
/// `event()` autoclosure is never invoked, satisfying invariant 6 of
/// REQUIREMENTS-telemetry.md §6.
private actor _AudioModelManagerTelemetryStorage {
  static let shared = _AudioModelManagerTelemetryStorage()

  private var telemetry: (any MLXAudioTelemetryReporter)?

  private init() {
    self.telemetry = nil
  }

  func set(_ reporter: (any MLXAudioTelemetryReporter)?) {
    self.telemetry = reporter
  }

  func current() -> (any MLXAudioTelemetryReporter)? {
    telemetry
  }
}

// MARK: - AudioModelManager

/// Manager for audio model lifecycle and Acervo component integration.
///
/// Provides convenient methods to:
/// - Ensure component readiness (downloads if needed)
/// - Check if a model is available locally
/// - Get component metadata
/// - Load models with ComponentAccess (v2 Acervo API)
///
/// All Acervo component registration happens at module init via the
/// lazy `_registerAudioComponents` initializer.
///
/// The v2 API (`withComponentAccess()`) provides:
/// - Opaque ComponentHandle (no file paths exposed)
/// - Integrity verification via checksums
/// - Prevents direct file system access for model files
public enum AudioModelManager {
  // MARK: - Public Telemetry API (Sortie 2 — OPERATION SILENT STETHOSCOPE)

  /// Attach (or detach) a vendor-neutral telemetry reporter.
  ///
  /// Pass `nil` (the default state) to silence the namespace; with no
  /// reporter attached every emission site short-circuits before any
  /// payload construction runs (Metal sampling, error-string
  /// formatting, etc.) — see invariant 3 / 6 of
  /// `REQUIREMENTS-telemetry.md §6` and the canonical `emit(_:)`
  /// snippet documented in `MLXAudioTelemetryReporter.swift`.
  ///
  /// `AudioModelManager` is a `public enum` with only `static` members,
  /// so storage lives in a file-private actor
  /// (`_AudioModelManagerTelemetryStorage`). The setter is `async`
  /// because it forwards to that actor; that matches the
  /// `actor`-friendly setter shape recommended by the canonical
  /// pattern.
  public static func setTelemetry(_ reporter: (any MLXAudioTelemetryReporter)?) async {
    await _AudioModelManagerTelemetryStorage.shared.set(reporter)
  }

  // MARK: - Internal Telemetry Helpers

  /// Canonical per-namespace `emit(_:)` helper for the public telemetry
  /// surface. Adapted from the 4-line snippet documented in
  /// `MLXAudioTelemetryReporter.swift` to the static-namespace shape:
  /// the actor read replaces the per-instance `guard let telemetry`
  /// check, but the `@autoclosure` deferral semantics are preserved.
  ///
  /// The `@autoclosure` is load-bearing — payload construction only
  /// runs when `reporter` is non-`nil`, so any expensive sampling
  /// inside the call site (e.g. `sampleMetalAllocatedMB()`,
  /// `String(describing: error)`) is elided whenever telemetry is
  /// detached.
  private static func emit(_ event: @autoclosure () -> MLXAudioTelemetryEvent) async {
    guard let reporter = await _AudioModelManagerTelemetryStorage.shared.current() else { return }
    await reporter.capture(event())
  }

  /// Sample the current Metal device's allocated buffer size in MB.
  ///
  /// Defined as a private helper so the body only references
  /// `MTLDevice` / `currentAllocatedSize` from a single site that is
  /// itself only ever invoked from inside an `emit(...)` argument
  /// list. The grep guard (REQUIREMENTS §6 invariant 6) requires every
  /// Metal sampling site to be reachable only via an `emit(...)` call;
  /// concentrating the sampling here keeps that surface area small and
  /// auditable.
  ///
  /// Returns `0.0` when no system default Metal device is available
  /// (e.g. on a hypothetical headless / non-Metal host); the caller is
  /// responsible for treating this as a best-effort signal, not a
  /// strict invariant.
  private static func sampleMetalAllocatedMB() -> Double {
    guard let device = MTLCreateSystemDefaultDevice() else { return 0.0 }
    return Double(device.currentAllocatedSize) / (1024.0 * 1024.0)
  }

  /// Map a `ComponentDescriptor`'s `estimatedSizeBytes` to an MB
  /// `Double`. `nil` if the descriptor is `nil` (we still emit, but
  /// with `0.0` so the schema stays primitive — see
  /// `MLXAudioTelemetryEvent.modelDownloadComplete` /
  /// `modelLoadComplete`, both of which require `Double`, not
  /// `Double?`).
  private static func sizeMB(for descriptor: ComponentDescriptor?) -> Double {
    guard let descriptor else { return 0.0 }
    return Double(descriptor.estimatedSizeBytes) / (1024.0 * 1024.0)
  }

  /// Trigger lazy registration of all P1 and P2 audio components.
  ///
  /// This is called automatically on first use, but can be invoked
  /// explicitly to ensure early registration before any model loading.
  /// Registration includes both codec models (P1) and TTS models (P2).
  public static func ensureComponentsRegistered() {
    _ = _registerAudioComponents
  }

  /// Look up a registered audio model by its HuggingFace repo ID.
  ///
  /// - Parameter modelId: HuggingFace repo ID (e.g., `"mlx-community/snac_24khz"`)
  /// - Returns: The corresponding `AudioModelRepo`, or `nil` if not registered.
  public static func repo(for modelId: String) -> AudioModelRepo? {
    AudioModelRepo.allCases.first { $0.rawValue == modelId }
  }

  /// Ensure a specific audio model component is ready for use.
  ///
  /// Downloads missing files from HuggingFace via SwiftAcervo if needed.
  /// Verification includes checksum validation for data integrity.
  ///
  /// - Parameters:
  ///   - modelRepo: The audio model variant to prepare.
  ///   - progress: Optional callback for download progress updates.
  /// - Throws: `AcervoError` if download or verification fails.
  public static func ensureModelReady(
    _ modelRepo: AudioModelRepo,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
  ) async throws {
    // Trigger registration if not already done
    ensureComponentsRegistered()

    // Public telemetry (Sortie 2): emit a download lifecycle pair
    // around the Acervo readiness call. `cacheHit` is best-effort —
    // we sample `Acervo.isComponentReady` *before* the call so a
    // pre-existing local cache hits as `true` and a fresh download
    // hits as `false`. We also detect cacheHit by whether
    // `ensureComponentReady` had any work to do (proxy: was it ready
    // before the call?). The reporter pays nothing when no telemetry
    // is attached because the canonical `emit(_:)` helper short-
    // circuits before any payload work runs.
    let descriptor = Acervo.component(modelRepo.componentId)
    let estimatedSizeMB: Double? = descriptor.map {
      Double($0.estimatedSizeBytes) / (1024.0 * 1024.0)
    }
    let wasReadyBefore = Acervo.isComponentReady(modelRepo.componentId)
    await emit(.modelDownloadStart(repo: modelRepo.rawValue, sizeMB: estimatedSizeMB))

    do {
      // S10 Sortie 10: ModelResolver.resolve interval (Level 2 = .operations).
      // Two-layer gate: `#if MLXAUDIO_TELEMETRY_FULL` strips at lower compile
      // ceilings, `if Telemetry.level >= .operations` strips when an env-var
      // floor keeps us at .lifecycle. The wrapped Acervo.ensureComponentReady
      // call is also wrapped below as the per-component "Acervo.download"
      // interval; both intervals share the modelResolver subsystem so
      // Instruments groups them under one lane.
      #if MLXAUDIO_TELEMETRY_FULL
      if Telemetry.level >= .operations {
        try await Telemetry.emitIntervalAsync(
          name: "ModelResolver.resolve",
          family: .modelResolver,
          message: modelRepo.rawValue
        ) {
          try await Telemetry.emitIntervalAsync(
            name: "Acervo.download",
            family: .modelResolver,
            message: modelRepo.componentId
          ) {
            try await Acervo.ensureComponentReady(
              modelRepo.componentId,
              progress: progress
            )
          }
        }
      } else {
        try await Acervo.ensureComponentReady(
          modelRepo.componentId,
          progress: progress
        )
      }
      #else
      // Use Acervo to ensure component is downloaded and ready
      try await Acervo.ensureComponentReady(
        modelRepo.componentId,
        progress: progress
      )
      #endif
    } catch {
      await emit(.modelDownloadError(repo: modelRepo.rawValue, error: String(describing: error)))
      throw error
    }

    await emit(
      .modelDownloadComplete(
        repo: modelRepo.rawValue,
        sizeMB: estimatedSizeMB ?? 0.0,
        cacheHit: wasReadyBefore
      )
    )
  }

  /// Get the local directory path for a model if it's cached.
  ///
  /// - Parameter modelRepo: The audio model variant to locate.
  /// - Returns: Local directory URL, or `nil` if not cached.
  public static func modelDirectory(
    for modelRepo: AudioModelRepo
  ) -> URL? {
    try? Acervo.modelDirectory(for: modelRepo.rawValue)
  }

  /// Get the Acervo component descriptor for a model.
  ///
  /// - Parameter modelRepo: The audio model variant to describe.
  /// - Returns: Component descriptor with metadata, or `nil` if unregistered.
  public static func component(
    for modelRepo: AudioModelRepo
  ) -> ComponentDescriptor? {
    Acervo.component(modelRepo.componentId)
  }

  /// Load an audio model using Acervo (v1 API).
  ///
  /// This method ensures the component is downloaded and ready, then provides
  /// the model directory for loading via a closure. Currently uses v1 API
  /// (`ensureComponentReady()` + `modelDirectory()`).
  ///
  /// Future: v2 API with ComponentAccess will provide opaque handles with
  /// integrity verification and automatic resource cleanup.
  ///
  /// Example usage:
  /// ```swift
  /// let audio = try await AudioModelManager.loadWithAcervo(.snac24kHz) { modelDir in
  ///     let weights = try loadArrays(url: modelDir.appendingPathComponent("model.safetensors"))
  ///     return weights
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - modelRepo: The audio model to load (AudioModelRepo)
  ///   - progress: Optional callback for download progress
  ///   - body: Closure that receives the model directory URL
  /// - Returns: The return value of `body`
  /// - Throws: AcervoError if the component is not available or download fails
  public static func loadWithAcervo<R>(
    _ modelRepo: AudioModelRepo,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    _ body: @escaping (URL) async throws -> R
  ) async throws -> R {
    // Ensure registration and readiness — `ensureModelReady` emits its
    // own `modelDownloadStart` / `modelDownloadComplete` /
    // `modelDownloadError` events, so we do not double-emit them
    // here. This wrapper owns the *load* lifecycle pair only.
    ensureComponentsRegistered()
    try await ensureModelReady(modelRepo, progress: progress)

    // Get model directory and execute body
    let modelDir = try Acervo.modelDirectory(for: modelRepo.rawValue)

    let descriptor = Acervo.component(modelRepo.componentId)
    let modelType = descriptor?.metadata["modelType"] ?? "unknown"
    await emit(.modelLoadStart(repo: modelRepo.rawValue, modelType: modelType))

    let result: R
    do {
      result = try await body(modelDir)
    } catch {
      await emit(.modelLoadError(repo: modelRepo.rawValue, error: String(describing: error)))
      throw error
    }

    await emit(
      .modelLoadComplete(
        repo: modelRepo.rawValue,
        modelType: modelType,
        sizeMB: sizeMB(for: descriptor),
        metalAllocatedMB: sampleMetalAllocatedMB()
      )
    )
    return result
  }

  /// Strict, descriptor-required loader that funnels every codec/LM weight load
  /// through the Acervo Component Registry (v2 API).
  ///
  /// Entry point for all P1/P2 model load paths in mlx-audio-swift. The component
  /// MUST be present in the Component Registry (registered via `ComponentDescriptor`).
  /// No HuggingFace fallback, no legacy HF-discovery branch.
  ///
  /// Flow:
  /// 1. Triggers lazy registration of all audio component descriptors.
  /// 2. Verifies the component exists in the registry; throws
  ///    `AcervoError.componentNotRegistered` if not.
  /// 3. Ensures the component is downloaded + verified via
  ///    `Acervo.ensureComponentReady`.
  /// 4. Resolves the component's on-disk directory inside a
  ///    `AcervoManager.shared.withComponentAccess` scope (which performs
  ///    integrity verification of declared files).
  /// 5. Invokes the caller's `load` closure with the resolved directory URL.
  ///
  /// `load` is synchronous so the entire read happens inside the managed-access
  /// scope (per REQUIREMENTS.md:86: "File handles to critical codec weights must
  /// live inside the managed-access scope so locking and SHA verification cannot
  /// be bypassed"). After `ensureComponentReady` has returned, the actual
  /// weight-load work (MLX `loadArrays`, JSON parsing) is CPU-bound and sync.
  ///
  /// - Parameters:
  ///   - componentId: The Acervo component ID (must be a registered
  ///                  `ComponentDescriptor`).
  ///   - load: Closure invoked with the on-disk directory URL for the resolved
  ///           component after integrity verification has succeeded.
  /// - Returns: Whatever the `load` closure returns.
  /// - Throws: `AcervoError.componentNotRegistered(componentId)` if the id is
  ///           not in the Component Registry; or any error thrown by
  ///           `Acervo.ensureComponentReady`, `withComponentAccess`,
  ///           `Acervo.modelDirectory(for:)`, or the closure itself.
  public static func loadWithAcervoStrict<T>(
    componentId: String,
    load: @Sendable (URL) throws -> T
  ) async throws -> T {
    _ = _registerAudioComponents

    guard let descriptor = Acervo.component(componentId) else {
      // Registry lookup failure is the load on-ramp; treat as a load
      // error with `componentId` as the repo identifier (no
      // `repoId` known yet — we never had a descriptor).
      await emit(
        .modelLoadError(
          repo: componentId,
          error: String(describing: AcervoError.componentNotRegistered(componentId))
        )
      )
      throw AcervoError.componentNotRegistered(componentId)
    }

    let resolvedRepo = descriptor.repoId
    let estimatedSizeMB = Double(descriptor.estimatedSizeBytes) / (1024.0 * 1024.0)
    let wasReadyBefore = Acervo.isComponentReady(componentId)
    let modelType = descriptor.metadata["modelType"] ?? "unknown"

    await emit(.modelDownloadStart(repo: resolvedRepo, sizeMB: estimatedSizeMB))

    do {
      // S10 Sortie 10: Acervo.download per-component interval (Level 2 =
      // .operations). Wraps the network/disk download phase only; the
      // synchronous `load` closure that follows runs the model construction
      // and weight load — those are wrapped at their own call sites in each
      // model family.
      #if MLXAUDIO_TELEMETRY_FULL
      if Telemetry.level >= .operations {
        try await Telemetry.emitIntervalAsync(
          name: "Acervo.download",
          family: .modelResolver,
          message: componentId
        ) {
          try await Acervo.ensureComponentReady(componentId)
        }
      } else {
        try await Acervo.ensureComponentReady(componentId)
      }
      #else
      try await Acervo.ensureComponentReady(componentId)
      #endif
    } catch {
      await emit(.modelDownloadError(repo: resolvedRepo, error: String(describing: error)))
      throw error
    }

    await emit(
      .modelDownloadComplete(
        repo: resolvedRepo,
        sizeMB: estimatedSizeMB,
        cacheHit: wasReadyBefore
      )
    )

    await emit(.modelLoadStart(repo: resolvedRepo, modelType: modelType))

    // REQUIREMENTS.md:86 — `load` runs inside `withComponentAccess` so locking
    // and SHA verification cannot be bypassed. SwiftAcervo's `perform:` closure
    // is synchronous, which is fine: after `ensureComponentReady` has returned,
    // the actual weight-load work (e.g., MLX `loadArrays`) is CPU-bound and sync.
    //
    // SwiftAcervo's `withComponentAccess<T: Sendable>` requires a Sendable return
    // type. Many MLX model classes are not (nor need to be) Sendable — they are
    // constructed once and handed back to the caller, never shared across
    // actors. We launder the result through an `@unchecked Sendable` box so
    // callers can return any T without marking their model types Sendable.
    let box: _LoadBox<T>
    do {
      box = try await AcervoManager.shared.withComponentAccess(componentId) { @Sendable _ in
        let modelDir = try Acervo.modelDirectory(for: descriptor.repoId)
        return _LoadBox(value: try load(modelDir))
      }
    } catch {
      await emit(.modelLoadError(repo: resolvedRepo, error: String(describing: error)))
      throw error
    }

    await emit(
      .modelLoadComplete(
        repo: resolvedRepo,
        modelType: modelType,
        sizeMB: estimatedSizeMB,
        metalAllocatedMB: sampleMetalAllocatedMB()
      )
    )
    return box.value
  }
}

/// Internal @unchecked Sendable box used by `loadWithAcervoStrict` to launder
/// non-Sendable model types through SwiftAcervo's `withComponentAccess<T: Sendable>`.
/// The boxed value is constructed once inside the managed-access scope, handed
/// back to the caller, and never shared — the unchecked annotation is safe.
private struct _LoadBox<V>: @unchecked Sendable {
  let value: V
}

// MARK: - AudioModelManager Extensions for Codec-Specific Repos

extension AudioModelManager {
  /// Load an audio model using Acervo for models with their own repo enums.
  /// This overload accepts SNACModelRepo and similar specialized repo enums.
  ///
  /// - Parameters:
  ///   - modelRepo: The model repo (SNACModelRepo, MimiModelRepo, etc.)
  ///   - progress: Optional callback for download progress
  ///   - body: Closure that receives the model directory URL
  /// - Returns: The return value of `body`
  /// - Throws: AcervoError if the component is not available or download fails
  public static func loadWithAcervoGeneric<R, T: RawRepresentable>(
    _ modelRepo: T,
    componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    _ body: @escaping (URL) async throws -> R
  ) async throws -> R where T.RawValue == String {
    ensureComponentsRegistered()

    let descriptor = Acervo.component(componentId)
    let estimatedSizeMB: Double? = descriptor.map {
      Double($0.estimatedSizeBytes) / (1024.0 * 1024.0)
    }
    let modelType = descriptor?.metadata["modelType"] ?? "unknown"
    let resolvedRepo = modelRepo.rawValue
    let wasReadyBefore = Acervo.isComponentReady(componentId)

    // Ensure component is ready — emit the download lifecycle pair
    // around it.
    await emit(.modelDownloadStart(repo: resolvedRepo, sizeMB: estimatedSizeMB))
    do {
      try await Acervo.ensureComponentReady(componentId, progress: progress)
    } catch {
      await emit(.modelDownloadError(repo: resolvedRepo, error: String(describing: error)))
      throw error
    }
    await emit(
      .modelDownloadComplete(
        repo: resolvedRepo,
        sizeMB: estimatedSizeMB ?? 0.0,
        cacheHit: wasReadyBefore
      )
    )

    // Get model directory and execute body — emit the load lifecycle
    // pair around the user's closure.
    let modelDir = try Acervo.modelDirectory(for: modelRepo.rawValue)
    await emit(.modelLoadStart(repo: resolvedRepo, modelType: modelType))
    let result: R
    do {
      result = try await body(modelDir)
    } catch {
      await emit(.modelLoadError(repo: resolvedRepo, error: String(describing: error)))
      throw error
    }
    await emit(
      .modelLoadComplete(
        repo: resolvedRepo,
        modelType: modelType,
        sizeMB: sizeMB(for: descriptor),
        metalAllocatedMB: sampleMetalAllocatedMB()
      )
    )
    return result
  }
}

// MARK: - Extension: AudioModelRepo convenience

extension AudioModelRepo {
  /// Ensure this model is ready via AudioModelManager.
  public func ensureReady(
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
  ) async throws {
    try await AudioModelManager.ensureModelReady(self, progress: progress)
  }

  /// Check if this model is available locally.
  public var isAvailable: Bool {
    Acervo.isComponentReady(componentId)
  }

  /// Get the local directory for this model if cached.
  public var localDirectory: URL? {
    AudioModelManager.modelDirectory(for: self)
  }
}
