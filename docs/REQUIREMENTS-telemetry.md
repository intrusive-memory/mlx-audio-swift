# Telemetry Requirements for mlx-audio-swift

**Status**: Draft — requirements for implementing telemetry using Produciesta's vendor-neutral adapter pattern

**Related**: See `/Users/stovak/Projects/Produciesta/Docs/TELEMETRY_IMPL_PATTERN.md` for the implementation pattern

---

## Overview

mlx-audio-swift will expose lifecycle events through a **vendor-neutral telemetry API** that allows hosts (like Produciesta) to observe:
- Model loading, caching, and unloading (via SwiftAcervo + AudioModelManager)
- TTS generation (text → audio via SpeechGenerationModel implementations)
- STT transcription (audio → text via ASR models)
- Audio codec operations (encode/decode via Vocos, Encodec, SNAC, Mimi, DACVAE)
- Audio I/O operations (WAV loading/saving)
- Metal memory allocation patterns
- Error conditions at every public boundary

The pattern is **library-agnostic**: mlx-audio-swift defines only an event enum and a reporter protocol. The host (Produciesta) creates an adapter that conforms to the reporter and forwards events to its central sink. **mlx-audio-swift never depends on the host.**

---

## 1. Public API Surface

### 1.1 Event Enum

```swift
// Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift
import Foundation

public enum MLXAudioTelemetryEvent: Sendable {
    // MARK: - Model Lifecycle
    
    /// Model download started from HuggingFace/Acervo
    case modelDownloadStart(repo: String, sizeMB: Double?)
    
    /// Model download completed successfully
    case modelDownloadComplete(repo: String, sizeMB: Double, cacheHit: Bool)
    
    /// Model loading into memory started
    case modelLoadStart(repo: String, modelType: String)
    
    /// Model loaded successfully into memory
    case modelLoadComplete(repo: String, modelType: String, sizeMB: Double, metalAllocatedMB: Double)
    
    /// Model unload started
    case modelUnloadStart(repo: String, loadedSizeMB: Double)
    
    /// Model unloaded; memory freed
    case modelUnloadComplete(repo: String, freedMB: Double)
    
    // MARK: - TTS Generation
    
    /// TTS generation started
    case ttsGenerationStart(model: String, textLength: Int, voiceType: String?)
    
    /// TTS generation progress (streaming models only)
    case ttsGenerationProgress(model: String, fractionComplete: Double, generatedSamples: Int)
    
    /// TTS generation completed
    case ttsGenerationComplete(model: String, durationSeconds: Double, audioSamples: Int, sampleRate: Int)
    
    // MARK: - STT Transcription
    
    /// STT transcription started
    case sttTranscriptionStart(model: String, audioSamples: Int, sampleRate: Int)
    
    /// STT transcription completed
    case sttTranscriptionComplete(model: String, durationSeconds: Double, textLength: Int)
    
    // MARK: - Audio Codec Operations
    
    /// Codec encode operation started
    case codecEncodeStart(codec: String, inputSamples: Int)
    
    /// Codec encode operation completed
    case codecEncodeComplete(codec: String, durationSeconds: Double, compressionRatio: Double)
    
    /// Codec decode operation started
    case codecDecodeStart(codec: String, codedFrames: Int)
    
    /// Codec decode operation completed
    case codecDecodeComplete(codec: String, durationSeconds: Double, outputSamples: Int)
    
    // MARK: - Audio I/O
    
    /// Audio file loading started
    case audioLoadStart(path: String, fileSizeMB: Double)
    
    /// Audio file loaded successfully
    case audioLoadComplete(path: String, samples: Int, sampleRate: Int, durationSeconds: Double)
    
    /// Audio file saving started
    case audioSaveStart(path: String, samples: Int, sampleRate: Int)
    
    /// Audio file saved successfully
    case audioSaveComplete(path: String, fileSizeMB: Double)
    
    // MARK: - Memory Management
    
    /// Metal buffer allocation detected
    case metalBufferAllocated(allocatedMB: Double, peakMB: Double)
    
    /// Metal buffer deallocation detected
    case metalBufferDeallocated(freedMB: Double, remainingMB: Double)
    
    /// Wired memory manager state snapshot
    case wiredMemoryState(wiredMB: Double, committedMB: Double)
    
    /// Audio buffer cache growth (e.g., AudioPlayerManager internal cache)
    case audioBufferCacheGrowth(entriesCount: Int, totalMB: Double)
    
    // MARK: - Errors
    
    /// Error thrown during model download
    case modelDownloadError(repo: String, error: String)
    
    /// Error thrown during model load
    case modelLoadError(repo: String, error: String)
    
    /// Error thrown during TTS generation
    case ttsGenerationError(model: String, phase: String, error: String)
    
    /// Error thrown during STT transcription
    case sttTranscriptionError(model: String, phase: String, error: String)
    
    /// Error thrown during codec operation
    case codecError(codec: String, operation: String, error: String)
    
    /// Error thrown during audio I/O
    case audioIOError(path: String, operation: String, error: String)
}
```

**Rules:**
- Every case carries only primitive, `Sendable` payloads (no retained buffers/contexts)
- `error` payloads are `String` (formatted via `String(describing:)` lazily, only when reporter is attached)
- Adding a case is a **minor** version bump; removing/reshaping is **major**
- Includes error side-channel for every public throw site (errors still throw; events are informational)

### 1.2 Reporter Protocol

```swift
// Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift

public protocol MLXAudioTelemetryReporter: Sendable {
    func capture(_ event: MLXAudioTelemetryEvent) async
}

public struct NoopMLXAudioTelemetryReporter: MLXAudioTelemetryReporter {
    public init() {}
    public func capture(_ event: MLXAudioTelemetryEvent) async {}
}
```

**Rules:**
- `Sendable`-bound, exactly **one method**, named `capture`
- `async` (allows reporters to write to disk / hop actors without blocking)
- **Non-throwing** (telemetry can never fail the workload)
- Ships a `Noop…` type for tests and for hosts that want to satisfy non-optional APIs

### 1.3 Injection Points

#### For Stateful APIs (AudioModelManager, TTS models, STT models)

```swift
public actor AudioModelManager {
    private var telemetry: (any MLXAudioTelemetryReporter)? = nil
    
    public func setTelemetry(_ reporter: (any MLXAudioTelemetryReporter)?) {
        self.telemetry = reporter
    }
}

public class SomeModelImpl: SpeechGenerationModel {
    private var telemetry: (any MLXAudioTelemetryReporter)? = nil
    
    public func setTelemetry(_ reporter: (any MLXAudioTelemetryReporter)?) {
        self.telemetry = reporter
    }
}
```

#### For Static/Free Functions (AudioUtils, DSP)

```swift
public static func loadAudioArray(
    _ path: String,
    telemetry: (any MLXAudioTelemetryReporter)? = nil
) throws -> (MLXArray, Int)

public static func saveAudioArray(
    _ path: String,
    audio: MLXArray,
    sampleRate: Int,
    telemetry: (any MLXAudioTelemetryReporter)? = nil
) throws
```

**Rules:**
- Default is `nil` — library with no reporter must have **zero runtime cost**
- Use setter-after-construct (`setTelemetry`), not `init` parameters (keeps init signatures stable)
- For static/free functions, add defaulted `telemetry:` parameter (existing call sites unchanged)

---

## 2. Instrumentation Points

### 2.1 AudioModelManager (Model Lifecycle)

**Location**: `Sources/MLXAudioCore/AudioModelManager.swift`

**Events to emit:**
- `modelDownloadStart` — when calling `Acervo.download(component:)` or HuggingFace hub fetch
- `modelDownloadComplete` — after successful download (include `cacheHit: true` if already local)
- `modelDownloadError` — if download throws
- `modelLoadStart` — before loading weights into MLX arrays
- `modelLoadComplete` — after model is ready for inference (capture model size + Metal allocation)
- `modelLoadError` — if load throws
- `modelUnloadStart` — when unloading model from memory
- `modelUnloadComplete` — after model is released (capture freed memory)

**Pattern:**
```swift
private func emit(_ event: @autoclosure () -> MLXAudioTelemetryEvent) async {
    guard let telemetry else { return }
    await telemetry.capture(event())
}
```

Use `@autoclosure` so payload construction (snapshotting Metal memory, formatting strings) runs **only** when reporter is attached.

### 2.2 TTS Models (SpeechGenerationModel implementations)

**Locations:**
- `Sources/MLXAudioTTS/Models/Qwen3TTS/*.swift`
- `Sources/MLXAudioTTS/Models/Soprano/*.swift`
- `Sources/MLXAudioTTS/Models/Llama/*.swift`
- `Sources/MLXAudioTTS/Models/PocketTTS/*.swift`
- `Sources/MLXAudioTTS/Models/Marvis/*.swift`

**Events to emit:**
- `ttsGenerationStart` — at top of `generate(text:voice:...)` or `generateStream(...)`
- `ttsGenerationProgress` — for streaming models, emit at configurable intervals (e.g., every 10% or every N samples)
- `ttsGenerationComplete` — after final audio array is returned (capture duration, sample count, sample rate)
- `ttsGenerationError` — if generation throws

**Hot-path rule:**
- Progress events should carry only primitives. Don't snapshot Metal state inside tight loops — sample once outside the loop.

### 2.3 STT Models (ASR implementations)

**Locations:**
- `Sources/MLXAudioSTT/Models/GLMASR/*.swift`
- `Sources/MLXAudioSTT/Models/Qwen3ASR/*.swift`

**Events to emit:**
- `sttTranscriptionStart` — at top of transcribe/decode method (capture input audio size)
- `sttTranscriptionComplete` — after transcription finishes (capture duration, output text length)
- `sttTranscriptionError` — if transcription throws

### 2.4 Audio Codecs (Vocos, Encodec, SNAC, Mimi, DACVAE)

**Locations:**
- `Sources/MLXAudioCodecs/Vocos/*.swift`
- `Sources/MLXAudioCodecs/Encodec/*.swift`
- `Sources/MLXAudioCodecs/SNAC/*.swift`
- `Sources/MLXAudioCodecs/Mimi/*.swift`
- `Sources/MLXAudioCodecs/DACVAE/*.swift`

**Events to emit:**
- `codecEncodeStart` — before encoding audio to codes
- `codecEncodeComplete` — after encoding (capture compression ratio: `inputBytes / outputBytes`)
- `codecDecodeStart` — before decoding codes to audio
- `codecDecodeComplete` — after decoding (capture output sample count)
- `codecError` — if encode/decode throws

### 2.5 Audio I/O (AudioUtils)

**Location**: `Sources/MLXAudioCore/AudioUtils.swift`

**Events to emit:**
- `audioLoadStart` — before reading WAV file (capture file size)
- `audioLoadComplete` — after successful load (capture samples, sample rate, duration)
- `audioSaveStart` — before writing WAV file
- `audioSaveComplete` — after successful save (capture output file size)
- `audioIOError` — if load/save throws

### 2.6 Memory Management (WiredMemoryManager, Metal device)

**Locations:**
- `Sources/MLXAudioCore/WiredMemoryManager.swift`
- Throughout model load/unload sites

**Events to emit:**
- `metalBufferAllocated` — when `MTLDevice.currentAllocatedSize` increases significantly (e.g., > 10 MB delta)
- `metalBufferDeallocated` — when `MTLDevice.currentAllocatedSize` decreases significantly
- `wiredMemoryState` — periodic snapshot of wired memory manager state
- `audioBufferCacheGrowth` — if AudioPlayerManager caches audio buffers internally, emit when cache grows

**Pattern:**
Sample Metal state at coarse-grained boundaries (model load/unload, generation start/end), not inside hot loops.

---

## 3. Host-Side Implementation (Produciesta)

### 3.1 Adapter

**Location**: `Produciesta/ProduciestaCore/Telemetry/MLXAudioTelemetryAdapter.swift`

```swift
import Foundation
import MLXAudioCore

actor MLXAudioTelemetryAdapter: MLXAudioTelemetryReporter {
    private let memoryTelemetry: MemoryTelemetry
    private var currentEpisode: Int
    
    init(memoryTelemetry: MemoryTelemetry, episode: Int) {
        self.memoryTelemetry = memoryTelemetry
        self.currentEpisode = episode
    }
    
    func updateEpisode(_ episode: Int) {
        self.currentEpisode = episode
    }
    
    func capture(_ event: MLXAudioTelemetryEvent) async {
        switch event {
        case .modelLoadStart(let repo, let modelType):
            await memoryTelemetry.capture(
                episode: currentEpisode,
                phase: "mlx_audio_model_load_start"
            )
        
        case .modelLoadComplete(let repo, let modelType, let sizeMB, let metalMB):
            await memoryTelemetry.capture(
                episode: currentEpisode,
                phase: "mlx_audio_model_loaded",
                audioBuffersMB: sizeMB
            )
        
        case .ttsGenerationStart(let model, let textLen, let voice):
            await memoryTelemetry.capture(
                episode: currentEpisode,
                phase: "mlx_audio_tts_start"
            )
        
        case .ttsGenerationComplete(let model, let dur, let samples, let rate):
            await memoryTelemetry.capture(
                episode: currentEpisode,
                phase: "mlx_audio_tts_complete"
            )
        
        case .metalBufferAllocated(let allocatedMB, let peakMB):
            await memoryTelemetry.capture(
                episode: currentEpisode,
                phase: "mlx_audio_metal_alloc"
            )
        
        case .ttsGenerationProgress:
            // Drop high-frequency progress events — not needed in sink
            break
        
        // ... exhaustive switch for all cases
        
        case .ttsGenerationError(let model, let phase, let error):
            await memoryTelemetry.capture(
                episode: currentEpisode,
                phase: "mlx_audio_error_\(phase)"
            )
        }
    }
}
```

**Rules:**
- Actor (holds mutable `currentEpisode` run-context)
- **Switch exhaustively** — new library event cases become compile errors (that's the feature)
- Phase strings prefixed `mlx_audio_…` to avoid collision with other libraries' phases
- Drop or aggregate noisy cases (progress events) here, not in the library

### 3.2 Wiring in GenerationOrchestrator

**Location**: `Produciesta/ProduciestaCore/GenerationOrchestrator.swift`

```swift
// In orchestrator init or setup:
var mlxAudioAdapter: MLXAudioTelemetryAdapter?

if options.telemetry {
    mlxAudioAdapter = MLXAudioTelemetryAdapter(
        memoryTelemetry: memoryTelemetry,
        episode: 0
    )
}

// Inject into mlx-audio-swift components:
// (Depends on how Produciesta accesses mlx-audio-swift models)
// Example pattern:
await someModelManager.setTelemetry(mlxAudioAdapter)
await audioUtils.setTelemetry(mlxAudioAdapter)

// Per-run: update context on adapter
for episode in episodes {
    await mlxAudioAdapter?.updateEpisode(episode.number)
    // ... rest of generation pipeline
}
```

---

## 4. Testing Strategy

### 4.1 Library-Side Tests (in mlx-audio-swift)

**Location**: `Tests/MLXAudioTests/TelemetryTests.swift`

```swift
import XCTest
@testable import MLXAudioCore

actor MockMLXAudioTelemetryReporter: MLXAudioTelemetryReporter {
    var events: [MLXAudioTelemetryEvent] = []
    
    func capture(_ event: MLXAudioTelemetryEvent) async {
        events.append(event)
    }
}

final class TelemetryTests: XCTestCase {
    func testModelLoadEmitsTelemetry() async throws {
        let mock = MockMLXAudioTelemetryReporter()
        let manager = AudioModelManager()
        await manager.setTelemetry(mock)
        
        try await manager.loadModel(repo: "test-repo")
        
        let events = await mock.events
        XCTAssertEqual(events.count, 2)
        // Assert first is .modelLoadStart, second is .modelLoadComplete
    }
    
    func testNilReporterHasZeroOverhead() async throws {
        // Baseline test: with nil reporter, no events leak into logs
        let manager = AudioModelManager()
        // Don't set telemetry (nil by default)
        
        try await manager.loadModel(repo: "test-repo")
        
        // Assert no side effects (no prints, no logs, no performance degradation)
        // Use XCTAssertNoDifference on wall-clock vs. baseline
    }
}
```

### 4.2 Host-Side Tests (in Produciesta)

**Location**: `Produciesta/Tests/TelemetryTests.swift`

```swift
func testMLXAudioAdapterMapsEventsToSink() async throws {
    let sink = MemoryTelemetry(enabled: true, projectURL: tempDir)
    let adapter = MLXAudioTelemetryAdapter(memoryTelemetry: sink, episode: 1)
    
    await adapter.capture(.modelLoadStart(repo: "test", modelType: "tts"))
    await adapter.capture(.modelLoadComplete(repo: "test", modelType: "tts", sizeMB: 100, metalAllocatedMB: 50))
    
    // Assert sink recorded two snapshots with correct phase strings:
    // "mlx_audio_model_load_start", "mlx_audio_model_loaded"
}

func testEndToEndTelemetryWithMLXAudio() async throws {
    // Integration test: run GenerationOrchestrator with --telemetry
    // Assert JSONL contains "mlx_audio_model_loaded", "mlx_audio_tts_start", "mlx_audio_tts_complete"
}
```

---

## 5. Adoption Checklist

- [ ] Add `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift` (enum with ~30 cases)
- [ ] Add `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift` (protocol + Noop impl)
- [ ] Add `setTelemetry(_:)` method to:
  - [ ] `AudioModelManager`
  - [ ] All TTS model implementations (Qwen3TTS, Soprano, Llama, PocketTTS, Marvis)
  - [ ] All STT model implementations (GLMASR, Qwen3ASR)
- [ ] Add `telemetry:` parameter to static functions:
  - [ ] `AudioUtils.loadAudioArray`
  - [ ] `AudioUtils.saveAudioArray`
- [ ] Instrument codec classes (add `telemetry` property + injection):
  - [ ] Vocos
  - [ ] Encodec
  - [ ] SNAC
  - [ ] Mimi
  - [ ] DACVAE
- [ ] Wire up emission at all lifecycle points:
  - [ ] Model download/load/unload
  - [ ] TTS generation start/progress/complete/error
  - [ ] STT transcription start/complete/error
  - [ ] Codec encode/decode start/complete/error
  - [ ] Audio I/O load/save start/complete/error
  - [ ] Metal buffer allocation/deallocation
- [ ] Add library-side tests:
  - [ ] `MockMLXAudioTelemetryReporter` test for each instrumentation point
  - [ ] Baseline test asserting nil reporter has zero overhead
- [ ] In Produciesta:
  - [ ] Add `ProduciestaCore/Telemetry/MLXAudioTelemetryAdapter.swift`
  - [ ] Wire adapter in `GenerationOrchestrator` (build when `--telemetry`, inject, update episode per run)
  - [ ] Add adapter unit tests (event → sink phase mapping)
  - [ ] Add integration test (end-to-end telemetry with mlx-audio-swift)
- [ ] Update documentation:
  - [ ] Add mlx-audio-swift to `Produciesta/MULTI_REPO_TELEMETRY.md` tracking table
  - [ ] Document event vocabulary in `mlx-audio-swift/docs/TELEMETRY.md`

---

## 6. Invariants (Do Not Violate)

1. **Library never imports Produciesta** — not even for `Sendable` helpers
2. **No new dependencies** — no `swift-log`, `OSLog`-only APIs, or cross-cutting frameworks
3. **Default is silent** — nil reporter → zero runtime cost (verify with baseline test)
4. **One enum, one protocol, one library** — don't share across packages
5. **Reporter is `async`-non-throwing** — telemetry that can fail the workload is unusable
6. **Switch exhaustively in adapter** — no `default:` cases; new events produce compile errors
7. **Phase strings owned by adapter** — library never picks sink vocabulary

---

## 7. Anti-Patterns to Avoid

| Anti-pattern | Why it breaks | Do instead |
|---|---|---|
| Library imports Produciesta | Couples consumers to host's logging stack | Library defines protocol; host writes adapter |
| Reporter passed in `init` | Adopting telemetry becomes breaking change | Setter-after-construct (`setTelemetry`) |
| Library samples/throttles internally | Locks host into sampling policy | Library always emits; adapter throttles |
| `default:` in adapter switch | New events go silently undelivered | Exhaustive switch — compiler flags gaps |
| Reporter is `throws` | Workload fails when telemetry disk fills | `async` non-throwing; reporter swallows failures |
| Library logs via `print`/`os_log` with nil reporter | "Zero overhead" claim is a lie | Single nil-check at emission site |

---

## 8. Reference Implementations

- **Pattern doc**: `/Users/stovak/Projects/Produciesta/Docs/TELEMETRY_IMPL_PATTERN.md`
- **Library-side example**: `SwiftSecuencia/Sources/SwiftSecuencia/Telemetry/`
- **Adapter example**: `Produciesta/ProduciestaCore/Telemetry/SecuenciaTelemetryAdapter.swift`
- **Sink**: `Produciesta/ProduciestaCore/MemoryTelemetry.swift`
- **Multi-repo coordination**: `Produciesta/MULTI_REPO_TELEMETRY.md`

---

**Last Updated**: 2026-05-07  
**Author**: Claude Code  
**Status**: Ready for implementation
