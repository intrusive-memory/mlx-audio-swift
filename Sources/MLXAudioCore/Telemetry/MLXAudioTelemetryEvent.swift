//
//  MLXAudioTelemetryEvent.swift
//  MLXAudioCore
//
//  Sortie 1 of OPERATION SILENT STETHOSCOPE — public, vendor-neutral
//  telemetry event vocabulary for mlx-audio-swift.
//
//  This file is intentionally additive to the existing internal
//  telemetry under `Sources/MLXAudioCore/Telemetry/` (CounterStore,
//  Telemetry, IntervalEmitter, etc.). The internal telemetry remains
//  the in-process leak-detection / signpost surface. The public
//  surface defined here is what hosts (e.g. Produciesta) observe via
//  the `MLXAudioTelemetryReporter` protocol.
//
//  Vocabulary is frozen by REQUIREMENTS-telemetry.md §1.1. Adding a
//  case is a minor version bump; renaming or reshaping a case is a
//  major version bump.
//
//  Invariants (REQUIREMENTS §6):
//    1. Library never imports Produciesta or any host.
//    2. No new dependencies (no swift-log / Logging / OSLog here).
//    3. Default is silent — `nil` reporter has zero runtime cost.
//    4. One enum, one protocol, one library.
//
//  All payloads are primitive `Sendable` types. Error payloads are
//  always `String` — the library never leaks `Error` types across the
//  telemetry boundary so that adapter authors can rely on a fully
//  vendor-neutral surface.
//

import Foundation

/// Vendor-neutral lifecycle events emitted by mlx-audio-swift.
///
/// Hosts observe these events by attaching an
/// ``MLXAudioTelemetryReporter`` via each component's
/// `setTelemetry(_:)` setter (or via the defaulted `telemetry:`
/// parameter on free / static functions like
/// `AudioUtils.loadAudioArray(_:telemetry:)`).
///
/// Every case carries only primitive, `Sendable` payloads (`String`,
/// `Int`, `Double`, `Bool`, `UInt64`). No `Error` types are exposed —
/// error payloads are pre-formatted `String` values so adapter
/// implementations are fully decoupled from MLXAudio's internal error
/// hierarchy.
///
/// Adapter implementations should `switch` exhaustively over this enum
/// (no `default:` cases). New cases are introduced as minor version
/// bumps and will surface as compile-time gaps in adapters — that is
/// the intended design.
public enum MLXAudioTelemetryEvent: Sendable {

    // MARK: - Model Lifecycle

    /// Model download started from HuggingFace / Acervo.
    ///
    /// `sizeMB` is `nil` when the size is not known up front (e.g. the
    /// hub manifest has not yet been fetched).
    case modelDownloadStart(repo: String, sizeMB: Double?)

    /// Model download completed successfully.
    ///
    /// `cacheHit` is `true` when the resolver short-circuited because
    /// the artifact was already present in the shared cache — no bytes
    /// were transferred.
    case modelDownloadComplete(repo: String, sizeMB: Double, cacheHit: Bool)

    /// Error thrown during model download.
    ///
    /// `error` is a pre-formatted `String` description (no `Error`
    /// type leaks across the telemetry boundary).
    case modelDownloadError(repo: String, error: String)

    /// Model loading into memory started.
    case modelLoadStart(repo: String, modelType: String)

    /// Model loaded successfully into memory.
    ///
    /// `sizeMB` is the model's serialized weight size; `metalAllocatedMB`
    /// is sampled from `MTLDevice.currentAllocatedSize` immediately
    /// after the load completes.
    case modelLoadComplete(repo: String, modelType: String, sizeMB: Double, metalAllocatedMB: Double)

    /// Error thrown during model load.
    case modelLoadError(repo: String, error: String)

    /// Model unload started.
    case modelUnloadStart(repo: String, loadedSizeMB: Double)

    /// Model unloaded; memory freed.
    case modelUnloadComplete(repo: String, freedMB: Double)

    // MARK: - TTS Generation

    /// TTS generation started.
    ///
    /// `voiceType` is `nil` for models with no notion of selectable
    /// voice (single-voice TTS).
    case ttsGenerationStart(model: String, textLength: Int, voiceType: String?)

    /// TTS generation progress (streaming models only).
    ///
    /// Emit at coarse fraction-complete checkpoints, never inside the
    /// per-step decode loop body. `fractionComplete` is in `[0, 1]`.
    case ttsGenerationProgress(model: String, fractionComplete: Double, generatedSamples: Int)

    /// TTS generation completed.
    case ttsGenerationComplete(model: String, durationSeconds: Double, audioSamples: Int, sampleRate: Int)

    /// Error thrown during TTS generation.
    ///
    /// `phase` describes the failing stage (e.g. `"prepare_inputs"`,
    /// `"decode"`, `"vocoder"`).
    case ttsGenerationError(model: String, phase: String, error: String)

    // MARK: - STT Transcription

    /// STT transcription started.
    case sttTranscriptionStart(model: String, audioSamples: Int, sampleRate: Int)

    /// STT transcription completed.
    case sttTranscriptionComplete(model: String, durationSeconds: Double, textLength: Int)

    /// Error thrown during STT transcription.
    ///
    /// `phase` describes the failing stage (e.g. `"feature_extraction"`,
    /// `"decode"`, `"forced_align"`).
    case sttTranscriptionError(model: String, phase: String, error: String)

    // MARK: - Audio Codec Operations

    /// Codec encode operation started.
    case codecEncodeStart(codec: String, inputSamples: Int)

    /// Codec encode operation completed.
    ///
    /// `compressionRatio = inputBytes / outputBytes`.
    case codecEncodeComplete(codec: String, durationSeconds: Double, compressionRatio: Double)

    /// Codec decode operation started.
    case codecDecodeStart(codec: String, codedFrames: Int)

    /// Codec decode operation completed.
    case codecDecodeComplete(codec: String, durationSeconds: Double, outputSamples: Int)

    /// Error thrown during codec operation.
    ///
    /// `operation` is `"encode"` or `"decode"`.
    case codecError(codec: String, operation: String, error: String)

    // MARK: - Audio I/O

    /// Audio file loading started.
    case audioLoadStart(path: String, fileSizeMB: Double)

    /// Audio file loaded successfully.
    case audioLoadComplete(path: String, samples: Int, sampleRate: Int, durationSeconds: Double)

    /// Audio file saving started.
    case audioSaveStart(path: String, samples: Int, sampleRate: Int)

    /// Audio file saved successfully.
    case audioSaveComplete(path: String, fileSizeMB: Double)

    /// Error thrown during audio I/O.
    ///
    /// `operation` is `"load"` or `"save"`.
    case audioIOError(path: String, operation: String, error: String)

    // MARK: - Memory Management

    /// Metal buffer allocation detected.
    ///
    /// Emitted by the Metal sampler only when the delta vs. the
    /// previous sample exceeds the configured threshold (default
    /// 10 MB — see REQUIREMENTS §2.6). Sampled at coarse-grained
    /// boundaries (model load / unload), never inside hot loops.
    case metalBufferAllocated(allocatedMB: Double, peakMB: Double)

    /// Metal buffer deallocation detected.
    ///
    /// See ``metalBufferAllocated(allocatedMB:peakMB:)`` for sampling
    /// policy.
    case metalBufferDeallocated(freedMB: Double, remainingMB: Double)

    /// Wired memory manager state snapshot.
    ///
    /// Sampled at the existing coarse-grained boundaries already used
    /// by `WiredMemoryManager`; the library never introduces new
    /// sampling timers.
    case wiredMemoryState(wiredMB: Double, committedMB: Double)

    /// Audio buffer cache growth (e.g. `AudioPlayerManager` internal
    /// cache).
    ///
    /// Emitted on cache *insertion* paths only — never on cache hits
    /// and never inside per-frame playback loops.
    case audioBufferCacheGrowth(entriesCount: Int, totalMB: Double)
}
