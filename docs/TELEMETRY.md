# MLXAudio Telemetry — Public API Reference

This document covers the **vendor-neutral, host-observable** telemetry surface introduced
in OPERATION SILENT STETHOSCOPE. It is distinct from the internal in-process counter
telemetry (leak detection, Instruments signposts) described in
[`docs/TELEMETRY_USAGE.md`](TELEMETRY_USAGE.md) and
[`docs/TELEMETRY_REQUIREMENTS.md`](TELEMETRY_REQUIREMENTS.md).

**Audience**: host developers integrating mlx-audio-swift who want to observe lifecycle
events (model loads, TTS generation, audio I/O, memory pressure) in their own telemetry
sink without any dependency on Apple's `os.Logger` or any third-party framework.

---

## Contents

1. [Overview](#overview)
2. [Event Vocabulary](#event-vocabulary)
   - [Model Lifecycle](#model-lifecycle)
   - [TTS Generation](#tts-generation)
   - [STT Transcription](#stt-transcription)
   - [Audio Codec Operations](#audio-codec-operations)
   - [Audio I/O](#audio-io)
   - [Memory Management](#memory-management)
   - [Errors](#errors)
3. [Reporter Protocol Contract](#reporter-protocol-contract)
4. [Injection Patterns](#injection-patterns)
   - [Setter pattern (stateful components)](#setter-pattern-stateful-components)
   - [Defaulted-parameter pattern (free/static functions)](#defaulted-parameter-pattern-freestatic-functions)
5. [Invariants](#invariants)
6. [Anti-Patterns](#anti-patterns)
7. [Usage Examples](#usage-examples)
   - [Attaching a reporter to a TTS model](#attaching-a-reporter-to-a-tts-model)
   - [Writing a MockMLXAudioTelemetryReporter for tests](#writing-a-mockmlxaudiotelemetryreporter-for-tests)
   - [Adding a new event case](#adding-a-new-event-case)
8. [Host Adapter](#host-adapter)
9. [Invariant Verification Greps](#invariant-verification-greps)

---

## Overview

mlx-audio-swift defines one enum (`MLXAudioTelemetryEvent`) and one protocol
(`MLXAudioTelemetryReporter`). Both live in `MLXAudioCore`. The library itself
never imports a host. Hosts implement the protocol and attach a reporter to any
component they wish to observe.

All emission sites use an `@autoclosure` helper so payload construction
(Metal memory snapshots, `String(describing:)` on errors, arithmetic for
compression ratios) is **elided entirely** when no reporter is attached. The
zero-overhead default is verified by the `EndToEndTelemetryTests` baseline test.

```
mlx-audio-swift                    host (e.g. Produciesta)
─────────────────────────────────  ──────────────────────────────────────
MLXAudioTelemetryEvent  (enum)  ←  switch event { ... }  → sink
MLXAudioTelemetryReporter (protocol) implemented by host adapter actor
```

---

## Event Vocabulary

Source of truth: `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift`

All payloads are primitive `Sendable` types (`String`, `Int`, `Double`, `Bool`).
No `Error` types cross the telemetry boundary — error payloads are pre-formatted
`String` values so adapters are fully decoupled from MLXAudio's internal error
hierarchy.

### Model Lifecycle

Emitted by `AudioModelManager` around HuggingFace/Acervo download and weight-loading
boundaries.

| Case | Payload fields | Notes |
|------|---------------|-------|
| `modelDownloadStart` | `repo: String`, `sizeMB: Double?` | `sizeMB` is `nil` when the hub manifest has not yet been fetched |
| `modelDownloadComplete` | `repo: String`, `sizeMB: Double`, `cacheHit: Bool` | `cacheHit: true` means no bytes were transferred |
| `modelDownloadError` | `repo: String`, `error: String` | Error payload is pre-formatted; no `Error` type leaks |
| `modelLoadStart` | `repo: String`, `modelType: String` | Emitted before weights are read into MLX arrays |
| `modelLoadComplete` | `repo: String`, `modelType: String`, `sizeMB: Double`, `metalAllocatedMB: Double` | `metalAllocatedMB` sampled from `MTLDevice.currentAllocatedSize` immediately after load |
| `modelLoadError` | `repo: String`, `error: String` | |
| `modelUnloadStart` | `repo: String`, `loadedSizeMB: Double` | |
| `modelUnloadComplete` | `repo: String`, `freedMB: Double` | |

### TTS Generation

Emitted by every `SpeechGenerationModel` implementation (Qwen3TTS, Soprano, LlamaTTS,
PocketTTS, Marvis TTS) at the public `generate*` boundaries.

| Case | Payload fields | Notes |
|------|---------------|-------|
| `ttsGenerationStart` | `model: String`, `textLength: Int`, `voiceType: String?` | `voiceType` is `nil` for single-voice models |
| `ttsGenerationProgress` | `model: String`, `fractionComplete: Double`, `generatedSamples: Int` | Streaming models only. Emitted at coarse fraction-complete checkpoints — never inside the per-step decode loop body. `fractionComplete` in `[0, 1]` |
| `ttsGenerationComplete` | `model: String`, `durationSeconds: Double`, `audioSamples: Int`, `sampleRate: Int` | Emitted after the final audio array materializes |
| `ttsGenerationError` | `model: String`, `phase: String`, `error: String` | `phase` describes the failing stage, e.g. `"prepare_inputs"`, `"decode"`, `"vocoder"` |

### STT Transcription

Emitted by every ASR implementation (GLM-ASR, Qwen3-ASR) at the public
transcribe/decode boundaries.

| Case | Payload fields | Notes |
|------|---------------|-------|
| `sttTranscriptionStart` | `model: String`, `audioSamples: Int`, `sampleRate: Int` | Emitted at the top of every public transcribe entry point |
| `sttTranscriptionComplete` | `model: String`, `durationSeconds: Double`, `textLength: Int` | |
| `sttTranscriptionError` | `model: String`, `phase: String`, `error: String` | `phase` describes the failing stage, e.g. `"feature_extraction"`, `"decode"`, `"forced_align"` |

### Audio Codec Operations

Emitted by every codec (Vocos, Encodec, SNAC, Mimi, DACVAE) at encode/decode
boundaries. Never emitted inside per-frame loops.

| Case | Payload fields | Notes |
|------|---------------|-------|
| `codecEncodeStart` | `codec: String`, `inputSamples: Int` | |
| `codecEncodeComplete` | `codec: String`, `durationSeconds: Double`, `compressionRatio: Double` | `compressionRatio = inputBytes / outputBytes` |
| `codecDecodeStart` | `codec: String`, `codedFrames: Int` | |
| `codecDecodeComplete` | `codec: String`, `durationSeconds: Double`, `outputSamples: Int` | |
| `codecError` | `codec: String`, `operation: String`, `error: String` | `operation` is `"encode"` or `"decode"` |

### Audio I/O

Emitted by `AudioUtils.loadAudioArray(from:telemetry:)` and
`AudioUtils.saveAudioArray(_:audio:sampleRate:telemetry:)`.

| Case | Payload fields | Notes |
|------|---------------|-------|
| `audioLoadStart` | `path: String`, `fileSizeMB: Double` | File size computed only when a reporter is attached |
| `audioLoadComplete` | `path: String`, `samples: Int`, `sampleRate: Int`, `durationSeconds: Double` | |
| `audioSaveStart` | `path: String`, `samples: Int`, `sampleRate: Int` | |
| `audioSaveComplete` | `path: String`, `fileSizeMB: Double` | |
| `audioIOError` | `path: String`, `operation: String`, `error: String` | `operation` is `"load"` or `"save"` |

### Memory Management

Emitted at coarse-grained model load/unload boundaries by
`WiredMemoryManager` and the Metal sampler (`MetalMemorySampler`).
Never emitted inside hot loops.

| Case | Payload fields | Notes |
|------|---------------|-------|
| `metalBufferAllocated` | `allocatedMB: Double`, `peakMB: Double` | Emitted only when the delta vs. previous sample exceeds the configured threshold (default: 10 MB) |
| `metalBufferDeallocated` | `freedMB: Double`, `remainingMB: Double` | Same 10 MB threshold applies |
| `wiredMemoryState` | `wiredMB: Double`, `committedMB: Double` | Sampled at existing `WiredMemoryManager` coarse-grained boundaries; no new sampling timers introduced |
| `audioBufferCacheGrowth` | `entriesCount: Int`, `totalMB: Double` | Emitted by `AudioPlayerManager` on cache insertion paths only — never on cache hits and never inside per-frame playback loops |

### Errors

Error cases are listed alongside each category above. Summary:

| Case | Category |
|------|----------|
| `modelDownloadError` | Model Lifecycle |
| `modelLoadError` | Model Lifecycle |
| `ttsGenerationError` | TTS Generation |
| `sttTranscriptionError` | STT Transcription |
| `codecError` | Audio Codec Operations |
| `audioIOError` | Audio I/O |

---

## Reporter Protocol Contract

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

Contract summary:

- **`Sendable`-bound** — safe to share across actor boundaries and `Task` contexts.
- **Exactly one method**: `capture(_:)`, named exactly that.
- **`async`** — reporters may write to disk, append to a file, or hop actors without
  blocking the workload that generated the event.
- **Non-throwing** — telemetry that can fail the workload is unusable. Reporters must
  swallow their own failures internally.
- **`NoopMLXAudioTelemetryReporter`** ships with the library for tests and for hosts that
  need to satisfy a non-optional reporter API without actually observing events.

The recommended library-side pattern for "no telemetry attached" is `nil` optional storage,
not `NoopMLXAudioTelemetryReporter`. The `Noop` type exists for use outside the library.

---

## Injection Patterns

### Setter pattern (stateful components)

Stateful components — `AudioModelManager`, every TTS model, every STT model, every
codec — store an optional reporter and expose a public setter. Using a setter-after-
construct (rather than an `init` parameter) keeps initializer signatures stable across
telemetry adoption.

```swift
// Storage and setter (same shape on every instrumented class):
public final class Qwen3TTSModel: Module, SpeechGenerationModel {
    private var telemetry: (any MLXAudioTelemetryReporter)? = nil

    public func setTelemetry(_ reporter: (any MLXAudioTelemetryReporter)?) {
        self.telemetry = reporter
    }
}
```

Every instrumented class also copies the canonical per-instance `emit(_:)` helper
verbatim. It is not extracted into a shared utility because `telemetry` is per-instance
state and `@autoclosure` must close over the instance.

```swift
// Canonical per-instance emit helper — copy verbatim into every instrumented class:
private func emit(_ event: @autoclosure () -> MLXAudioTelemetryEvent) async {
    guard let telemetry else { return }
    await telemetry.capture(event())
}
```

The `@autoclosure` is load-bearing: when `telemetry` is `nil`, the closure is never
invoked, so expensive payload work (Metal memory snapshots, `String(describing:)`
formatting, compression ratio arithmetic) is elided entirely — zero runtime cost.

Call sites pass the event inline; the autoclosure wraps it:

```swift
await emit(.modelLoadStart(repo: repo, modelType: modelType))
await emit(.modelLoadComplete(repo: repo, modelType: modelType, sizeMB: mb, metalAllocatedMB: metal))
```

### Defaulted-parameter pattern (free/static functions)

Free and static functions cannot store a reporter. Instead, they accept a defaulted
`telemetry:` parameter so existing call sites compile unchanged:

```swift
public func loadAudioArray(
    from url: URL,
    telemetry: (any MLXAudioTelemetryReporter)? = nil
) throws -> (Int, MLXArray)

public static func saveAudioArray(
    _ path: String,
    audio: MLXArray,
    sampleRate: Int,
    telemetry: (any MLXAudioTelemetryReporter)? = nil
) throws
```

Inside these functions the nil-check is inline rather than via the `emit` helper:

```swift
if let telemetry {
    let fileSizeMB = computeFileSizeMB(url)   // only runs when reporter attached
    Task { await telemetry.capture(.audioLoadStart(path: url.path, fileSizeMB: fileSizeMB)) }
}
```

---

## Invariants

These must hold at every emission site and can be verified by the grep commands
in [Invariant Verification Greps](#invariant-verification-greps).

1. **Library never imports Produciesta or any host.** The telemetry seam is one-way:
   the library emits; the host receives. No host symbol ever appears in `Sources/`.

2. **No new dependencies.** No `swift-log`, `Logging`, `OSLog`-only APIs, or
   cross-cutting frameworks are imported in `MLXAudioTelemetryEvent.swift` or
   `MLXAudioTelemetryReporter.swift`.

3. **Default is silent.** `nil` reporter → zero runtime cost. Payload closures
   (via `@autoclosure`) are never evaluated when no reporter is attached.

4. **One enum, one protocol, one library.** The vocabulary is not shared across
   Swift packages.

5. **Reporter is `async` non-throwing.** See [Reporter Protocol Contract](#reporter-protocol-contract).

6. **Every emission site uses `@autoclosure`.** Metal sampling, string formatting,
   and arithmetic in event payloads run only when a reporter is attached.

---

## Anti-Patterns

| Anti-pattern | Why it breaks | Do instead |
|---|---|---|
| Emitting inside per-step decode loops or per-frame playback loops | Turns a coarse telemetry hook into a hot-path overhead source; defeats invariant 3 | Emit only at coarse-grained boundaries (generation start/complete, model load/unload) |
| Sampling Metal state outside an `emit(...)` call | Metal sampling runs even when `telemetry` is `nil`, breaking invariant 3 | Place every `MTLDevice.currentAllocatedSize` read inside the `@autoclosure` body |
| Exposing `Error` types in event payloads | Couples adapter authors to MLXAudio's internal error hierarchy | Pre-format errors as `String(describing: error)` and pass the string |
| Shipping a host-specific reporter in this repository | Violates invariant 1; imports or references the host | Implement the reporter in the host repository; see [Host Adapter](#host-adapter) |
| Using `default:` in adapter `switch` statements | New event cases go silently undelivered when the library adds cases | Switch exhaustively — the compiler flags gaps, which is the intended design |
| Passing the reporter in `init` | Telemetry adoption becomes a breaking API change | Use the setter-after-construct pattern (`setTelemetry`) |
| Making `capture(_:)` `throws` | A full telemetry disk fails the audio workload | `async` non-throwing; reporters swallow their own failures |

---

## Usage Examples

### Attaching a reporter to a TTS model

```swift
import MLXAudioCore
import MLXAudioTTS

// 1. Create your model as usual.
let model = try await Qwen3TTSModel.fromPretrained("some-repo")

// 2. Attach a reporter (your host-side adapter).
await model.setTelemetry(myAdapter)

// 3. Generate — events flow to the adapter automatically.
let audio = try await model.generate(text: "Hello world", voice: nil)

// 4. Detach if no longer needed.
await model.setTelemetry(nil)
```

The same `setTelemetry(_:)` method exists on every instrumented component:
`AudioModelManager`, `Qwen3TTSModel`, `LlamaTTSModel`, `SopranoModel`,
`PocketTTSModel`, `MarvisTTSModel`, `GLMASRModel`, `Qwen3ASRModel`, `Vocos`,
`Encodec`, `SNACDecoder`, `Mimi`, `DACVAE`, and `AudioPlayerManager`.

### Writing a MockMLXAudioTelemetryReporter for tests

The library ships `Tests/MLXAudioTests/Telemetry/MockMLXAudioTelemetryReporter.swift`
as the shared test double for all instrumentation tests. Copy the actor pattern for
your own host-side tests:

```swift
import Foundation
import MLXAudioCore

/// Test-only reporter that records every captured event in order.
actor MockMLXAudioTelemetryReporter: MLXAudioTelemetryReporter {

    private var captured: [MLXAudioTelemetryEvent] = []

    init() {}

    func capture(_ event: MLXAudioTelemetryEvent) async {
        captured.append(event)
    }

    /// Return a snapshot copy of all recorded events.
    func events() -> [MLXAudioTelemetryEvent] {
        captured
    }

    func eventCount() -> Int {
        captured.count
    }

    func reset() {
        captured.removeAll(keepingCapacity: true)
    }
}
```

Usage in an XCTest / Swift Testing test:

```swift
@Test("Qwen3TTS emits start + complete events")
func testQwen3TTSTelemetry() async throws {
    let mock = MockMLXAudioTelemetryReporter()
    let model = Qwen3TTSModel(config: someConfig)
    await model.setTelemetry(mock)

    // Exercise the component (setup-only level, no model download required).
    // Real generation tests live in the local-only suite.

    let events = await mock.events()
    // Assert expected event sequence...
}
```

### Adding a new event case

**Adding a case is a minor version bump.** Adapter `switch` statements become
compile-time gaps (there is no `default:` arm by design), so adapter authors are
forced to handle the new case. Declare the new case with a doc comment and primitive
`Sendable` payloads:

```swift
// In MLXAudioTelemetryEvent.swift — add in the appropriate MARK section:

/// Brief description of what this event signals.
case myNewEvent(someField: String, anotherField: Double)
```

After adding the case, bump the library's minor version in `Package.swift`.

**Renaming or removing a case is a major version bump** because it breaks every
existing adapter. If you must rename, add the new case, mark the old one
`@available(*, deprecated, renamed: "myNewEvent")`, and remove it in the next
major release.

---

## Host Adapter

The reference adapter implementation lives in the Produciesta repository at
`Produciesta/ProduciestaCore/Telemetry/MLXAudioTelemetryAdapter.swift`. Do not
include host-specific adapter source in this repository.

The adapter is a Swift `actor` that conforms to `MLXAudioTelemetryReporter`, switches
exhaustively over `MLXAudioTelemetryEvent`, and forwards events to Produciesta's
`MemoryTelemetry` sink with host-vocabulary phase strings prefixed `mlx_audio_...`.
For implementation guidance, see the pattern doc at
`Produciesta/Docs/TELEMETRY_IMPL_PATTERN.md`.

---

## Invariant Verification Greps

Sortie 19 (integration verification) runs these commands as part of its exit criteria.
Run them locally after any change to the telemetry surface to verify no invariant has
been violated.

```sh
# Invariant 1: library never imports the host
grep -RIn "import .*Produciesta" Sources/

# Invariant 2: no new dependencies in the two public telemetry files
grep -RIn "import swift_log\|import Logging\|import OSLog" \
  Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift \
  Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift

# Invariant 6: autoclosure present in the canonical helper
grep -c "@autoclosure" \
  Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift

# Hot-loop guard: no await emit(...) inside for/while bodies in TTS/STT
grep -A2 -E '(for |while )' \
  Sources/MLXAudioTTS/**/*.swift \
  Sources/MLXAudioSTT/**/*.swift \
  | grep 'await emit('
# Expected output: empty (zero matches)
```

---

## Cross-references

- Internal counter telemetry (leak detection, Instruments signposts): [`docs/TELEMETRY_USAGE.md`](TELEMETRY_USAGE.md)
- Internal telemetry requirements and levels specification: [`docs/TELEMETRY_REQUIREMENTS.md`](TELEMETRY_REQUIREMENTS.md)
- Public API source: `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift`
- Reporter protocol source: `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift`
- Shared test double: `Tests/MLXAudioTests/Telemetry/MockMLXAudioTelemetryReporter.swift`
