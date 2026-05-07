# COMPLETE — Sortie 12: MLX Memory Snapshots & Per-Op Deltas

**Mission**: OPERATION LEAK BLOODHOUND
**Sortie**: S12 (WU-4)
**Branch**: `mission/leak-bloodhound/01`
**Predecessor**: S11 (`767481a`)
**Status**: COMPLETE

---

## How `Telemetry.emitInterval` / `emitIntervalAsync` Were Extended

Both helpers in `Sources/MLXAudioCore/Telemetry/IntervalEmitter.swift` were
extended with a single seam: read `MLX.Memory.activeMemory` before invoking
the closure body and again after (in the `defer` block), compute `delta`, and:

1. **Emit a signpost event** via `signposter.emitEvent(name, id: id, "memory before:\(memBefore) after:\(memAfter) delta:\(delta)")` so Instruments shows the memory metadata on the same interval lane.
2. **Notify the test recorder** synchronously via `TelemetryIntervalRecorder.recordMemoryDelta(name:before:after:delta:)` (new protocol method, default no-op so existing recorders compile without changes).
3. **Forward to CounterStore** via a fire-and-forget `Task.detached(priority: .background) { await CounterStore.shared.recordPerOpDelta(opName: nameString, delta: delta) }`.

All three actions are gated by `if Telemetry.level >= .memory` inside the
`#if MLXAUDIO_TELEMETRY_FULL` block, so they strip in release builds and are
no-ops at `Telemetry.level < .memory`.

The memory reads bracket the body correctly:
- `memBefore` is read BEFORE `body()` / `try await body()` — before any suspension.
- `memAfter` is read in `defer` AFTER body completion — correct even for async bodies.

Because both helpers (`emitInterval` and `emitIntervalAsync`) share this
pattern, all 34 Level-2 call sites from S10/S11 get memory-delta capture for
free with no per-site changes.

---

## New Field on `TelemetrySnapshot`

**Field**: `public let perOpDeltas: [String: Int]`

**Location**: `Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift`

**Additive, non-breaking**: The existing `public init(liveCounts:mlxActiveBytes:mlxPeakBytes:timestamp:)` was updated with a new `perOpDeltas` parameter that **defaults to `[:]`**. All existing call sites that don't pass it remain source-compatible. The field is appended after the existing fields in the init signature to minimise visual disruption.

Existing fields and their init positions are unchanged:
```swift
public init(
    liveCounts: [String: Int],
    mlxActiveBytes: Int,
    mlxPeakBytes: Int,
    perOpDeltas: [String: Int] = [:],  // ← NEW, default [:] preserves compat
    timestamp: Date
)
```

---

## Per-Op Delta Keying Scheme

**Decision**: **Option A — keys equal the interval name** (identical to the
`name` argument passed to `Telemetry.emitInterval` / `emitIntervalAsync`).

**Rationale**: No transformation required; keys in `perOpDeltas` exactly match
what Instruments displays in the os_signpost track, making correlation trivial.

**Canonical keys from S10/S11** (exhaustive list):

| Key | Source (interval name) | Family |
|-----|------------------------|--------|
| `"ModelResolver.resolve"` | AudioModelManager.ensureModelReady | modelResolver |
| `"Acervo.download"` | AudioModelManager download sites | modelResolver |
| `"Qwen3TTS.loadWeights.talker"` | Qwen3TTS fromPretrained | qwen3TTS |
| `"Qwen3TTS.loadWeights.speakerEncoder"` | Qwen3TTS fromPretrained | qwen3TTS |
| `"Qwen3TTS.loadWeights.speechTokenizer"` | Qwen3TTS loadSpeechTokenizer | qwen3TTS |
| `"Qwen3.loadWeights"` | Qwen3 fromPretrained | core |
| `"LlamaTTS.loadWeights"` | LlamaTTS fromPretrained | llamaTTS |
| `"SopranoTTS.loadWeights"` | SopranoTTS fromPretrained | sopranoTTS |
| `"PocketTTS.loadWeights"` | PocketTTS fromPretrained | pocketTTS |
| `"MarvisTTS.loadWeights"` | MarvisTTS fromPretrained | marvisTTS |
| `"Qwen3ASR.loadWeights"` | Qwen3ASR fromPretrained | qwen3ASR |
| `"Qwen3ASR.loadWeights.forcedAligner"` | Qwen3ForcedAligner fromPretrained | qwen3ASR |
| `"GLMASR.loadWeights"` | GLMASR fromPretrained | glmASR |
| `"SNAC.loadWeights"` | SNACDecoder fromPretrained | codecs |
| `"Mimi.loadWeights"` | Mimi fromPretrained | codecs |
| `"Encodec.loadWeights"` | Encodec fromPretrained | codecs |
| `"DACVAE.loadWeights"` | DACVAE fromPretrained | codecs |
| `"Qwen3TTS.generate"` | Qwen3TTS.generate | qwen3TTS |
| `"LlamaTTS.generate"` | LlamaTTS.generate | llamaTTS |
| `"SopranoTTS.generate"` | SopranoTTS.generate | sopranoTTS |
| `"PocketTTS.generate"` | PocketTTS.generate | pocketTTS |
| `"MarvisTTS.generate"` | MarvisTTS.generate | marvisTTS |
| `"Qwen3ASR.generate"` | Qwen3ASR.generate | qwen3ASR |
| `"GLMASR.generate"` | GLMASR.generate | glmASR |
| `"SNAC.encode"` | SNAC.encode | codecs |
| `"SNAC.decode"` | SNAC.decode | codecs |
| `"Mimi.encode"` | Mimi.encode | codecs |
| `"Mimi.decode"` | Mimi.decode | codecs |
| `"Encodec.encode"` | Encodec.encode | codecs |
| `"Encodec.decode"` | Encodec.decode | codecs |
| `"DAC.encode"` | DACVAE.encode | codecs |
| `"DAC.decode"` | DACVAE.decode | codecs |
| `"Vocos.decode"` | Vocos.decode | codecs |

**Accumulation**: Deltas are additive across calls. A repeated `Qwen3TTS.generate`
showing steadily growing `perOpDeltas["Qwen3TTS.generate"]` indicates a per-call
memory leak.

---

## Reset / Peak Semantics

**Confirmed in tests**:

| Behaviour | Test |
|-----------|------|
| `Telemetry.resetCounters()` zeroes `perOpDeltas` | `TelemetryMemoryTests.testPerOpDeltaResetClears` |
| `mlxPeakBytes` survives `resetCounters()` | `TelemetryMemoryTests.testPeakSurvivesReset` AND `TelemetryCounterStoreTests.testResetPreservesPeak` |
| `perOpDeltas` accumulates additively across calls | `TelemetryMemoryTests.testPerOpDeltaAccumulates` |
| Multiple keys accumulate independently | `TelemetryMemoryTests.testPerOpDeltaIndependentKeys` |
| No delta captured at `< .memory` level | `TelemetryMemoryTests.testNoCaptureBelowMemoryLevel` |
| Delta captured synchronously at `.memory` level | `TelemetryMemoryTests.testEmitIntervalCapturesDeltaAtMemoryLevel` |

---

## Verification Evidence

### TelemetryCounterStoreTests + TelemetryMemoryTests

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryCounterStoreTests \
    -only-testing:MLXAudioTests/TelemetryMemoryTests \
    CODE_SIGNING_ALLOWED=NO

Suite "TelemetryMemoryTests" started.
Suite "TelemetryCounterStoreTests" started.
Test "perOpDelta accumulates across multiple recordPerOpDelta calls" passed after 0.010 seconds.
Test "increment then decrement returns to zero" passed after 0.010 seconds.
Test "perOpDelta keys are tracked independently" passed after 0.001 seconds.
Test "multiple class labels are tracked independently" passed after 0.001 seconds.
Test "resetCounters clears perOpDeltas" passed after 0.001 seconds.
Test "reset zeroes liveCounts" passed after 0.001 seconds.
Test "mlxPeakBytes is monotonic and survives resetCounters" passed after 0.001 seconds.
Test "reset preserves mlxPeakBytes (monotonic across resets)" passed after 0.001 seconds.
Test "emitInterval records a perOpDelta entry at .memory level" passed after 0.001 seconds.
Test "snapshot updates mlxPeakBytes when activeMemory exceeds it" passed after 0.001 seconds.
Test "emitInterval does NOT record perOpDelta below .memory level" passed after 0.001 seconds.
Suite "TelemetryMemoryTests" passed after 0.011 seconds.
Test "snapshot is consistent under concurrent increment/decrement" passed after 0.001 seconds.
Test "snapshot under concurrent unbalanced increments matches submitted total" passed after 0.001 seconds.
Test "trackLifecycle enqueues an increment via detached Task" passed after 0.001 seconds.
Test "trackLifecycleEnd enqueues a decrement via detached Task" passed after 0.001 seconds.
Test "snapshot fields are populated and well-formed" passed after 0.001 seconds.
Suite "TelemetryCounterStoreTests" passed after 0.013 seconds.
Test run with 16 tests in 2 suites passed after 0.014 seconds.
** TEST SUCCEEDED **
```

### Full CI-safe block from `CLAUDE.md`

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    -only-testing:MLXAudioTests/EncodecTests \
    ... (all CI-safe suites from CLAUDE.md) ...
    CODE_SIGNING_ALLOWED=NO

Test run with 326 tests in 38 suites passed after 10.729 seconds.
** TEST SUCCEEDED **
```

---

## Files Created / Modified

### Created

- `Tests/TelemetryMemoryTests.swift` — New suite "TelemetryMemoryTests" with 5 tests covering per-op delta accumulation, reset behavior, monotonic peak, memory capture at `.memory` level, and gating below `.memory` level.
- `COMPLETE_S12_MEMORY_SNAPSHOTS.md` — this document.

### Modified

| File | Change Summary |
|------|---------------|
| `Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift` | Added `public let perOpDeltas: [String: Int]` field with default `[:]` in `public init`. Additive, non-breaking. |
| `Sources/MLXAudioCore/Telemetry/CounterStore.swift` | Added `recordPerOpDelta(opName:delta:)` actor method; updated `snapshot()` to include `perOpDeltas`; added test-only helpers `_perOpDeltasForTesting()`, `_resetPerOpDeltasForTesting()`, `_batchRecordAndReadForTesting(_:)`, `_clearAndBatchRecordForTesting(_:)`. |
| `Sources/MLXAudioCore/Telemetry/IntervalEmitter.swift` | Added `import MLX`; extended `emitInterval` and `emitIntervalAsync` to capture `MLX.Memory.activeMemory` before/after body at `.memory` level, emit `signposter.emitEvent` with `before`/`after`/`delta` metadata, call `_intervalRecorder?.recordMemoryDelta(...)` synchronously, and fire-and-forget `CounterStore.shared.recordPerOpDelta`. Extended `TelemetryIntervalRecorder` protocol with `recordMemoryDelta(name:before:after:delta:)` (default no-op). |
| `Tests/TelemetryCounterStoreTests.swift` | Improved `drain()` helper from 2 to 5 yields per call to reduce pre-existing background-Task timing flakiness (not a new test, just a reliability fix). |

---

## Exact Verification Commands

```bash
# EC1: perOpDeltas in TelemetrySnapshot.swift
grep -q 'perOpDeltas' Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift

# EC2: TelemetryCounterStoreTests + TelemetryMemoryTests
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryCounterStoreTests \
    -only-testing:MLXAudioTests/TelemetryMemoryTests \
    CODE_SIGNING_ALLOWED=NO

# EC3 (full CI-safe block from CLAUDE.md):
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    -only-testing:MLXAudioTests/EncodecTests \
    -only-testing:MLXAudioTests/DACVAETests \
    -only-testing:MLXAudioTests/GLMASRModuleSetupTests \
    -only-testing:MLXAudioTests/GLMASRModelTests \
    -only-testing:MLXAudioTests/Qwen3ASRModuleSetupTests \
    -only-testing:MLXAudioTests/ForceAlignProcessorTests \
    -only-testing:MLXAudioTests/ForcedAlignResultTests \
    -only-testing:MLXAudioTests/Qwen3ASRHelperTests \
    -only-testing:MLXAudioTests/SplitAudioIntoChunksTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerEncodeTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerWeightTests \
    -only-testing:MLXAudioTests/Qwen3TTSLanguageTests \
    -only-testing:MLXAudioTests/Qwen3TTSConfigTests \
    -only-testing:MLXAudioTests/Qwen3TTSRoutingTests \
    -only-testing:MLXAudioTests/Qwen3TTSPrepareBaseInputsTests \
    -only-testing:MLXAudioTests/Qwen3TTSGenerateCustomVoiceTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderWeightTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeakerEmbeddingTests \
    -only-testing:MLXAudioTests/Qwen3TTSPrepareICLInputsTests \
    -only-testing:MLXAudioTests/Qwen3TTSGenerateICLTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderSmokeTests \
    -only-testing:MLXAudioTests/LlamaTTSModuleSetupTests \
    -only-testing:MLXAudioTests/ParityFixtureLoaderSmokeTests \
    -only-testing:MLXAudioTests/PocketTTSModuleSetupTests \
    -only-testing:MLXAudioTests/SopranoModuleSetupTests \
    -only-testing:MLXAudioTests/MarvisTTSModuleSetupTests \
    -only-testing:MLXAudioTests/MLXAudioCoreDSPTests \
    -only-testing:MLXAudioTests/ModelUtilsTests \
    -only-testing:MLXAudioTests/MimiLayerTests \
    -only-testing:MLXAudioTests/SNACVQTests \
    -only-testing:MLXAudioTests/DACVAEWatermarkerTests \
    -only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests \
    -only-testing:MLXAudioTests/ConvWeightedTests \
    -only-testing:MLXAudioTests/AudioUtilsTests \
    -only-testing:MLXAudioTests/AudioIORoundTripTests \
    CODE_SIGNING_ALLOWED=NO

# EC4: Signpost metadata verification (inspect IntervalEmitter.swift)
grep -c 'emitEvent\|recordMemoryDelta\|memBefore\|memAfter' \
    Sources/MLXAudioCore/Telemetry/IntervalEmitter.swift
# Expected: >= 8 occurrences
```

All commands exit 0.
