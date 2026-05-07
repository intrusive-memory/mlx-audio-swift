# Sortie 14 — Verbose: Codec Per-Step + KV Cache Grow Events — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-5 Verbose Instrumentation
**Sortie**: 14 of 15
**Branch**: `mission/leak-bloodhound/01`
**Commit**: (see end of file)

---

## Audit Output (Task 1 — Q5 Resolution: Which Codecs are Iterative?)

### Summary

Open Question Q5 from `EXECUTION_PLAN.md` asked: "which codecs are iterative?"

After auditing all five codec classes, only **Mimi** has a true autoregressive,
per-step decode loop. All other codecs are single-shot or data-parallel chunked.

### Per-Codec Findings

| Codec | Iterative? | Loop location | Event label |
|-------|-----------|---------------|-------------|
| **Mimi** | YES | `Sources/MLXAudioCodecs/Mimi/Mimi.swift` — `MimiStreamingDecoder.decodeFrames(_:)`, `for t in 0..<T { ... mimi.decodeStep(mid) }` | `"Mimi.decodeStep"` |
| **SNAC** | NO — single-shot | `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` — `decode(_:)` calls `quantizer.fromCodes()` + `decoder()` in one shot. No inner loop producing one step at a time. | (none — S11 outer interval is sufficient) |
| **Encodec** | NO — data-parallel chunked | `Sources/MLXAudioCodecs/Encodec/Encodec.swift` — `_encodecDecodeImpl` has `for i in 0..<audioCodes.shape[0]` only when `chunkLength != nil`. This is chunk-based overlap-add reconstruction, not autoregressive token-by-token generation. | (none) |
| **DACVAE** | NO — data-parallel chunked | `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` — `decodeChunked(_:chunkSize:)` has `while start < totalFrames` but again this is a memory-efficiency batch loop, not autoregressive decode. Standard `_dacDecodeImpl` is single-shot. | (none) |
| **Vocos** | NO — single-shot | `Sources/MLXAudioCodecs/Vocos/Vocos.swift` — `decode(_:bandwidthId:)` calls `backbone(features)` + `head(x)` in one shot. The ISTFT head's `performISTFT` has an internal `for i in 0..<numFrames` loop but this is a CPU-side overlap-add on the result of one MLX forward pass — not a per-step decode. | (none) |

### Why Mimi is Iterative

`MimiStreamingDecoder.decodeFrames(_:)` is explicitly streaming: it loops over each
time step `t` in the input token sequence and calls `mimi.decodeStep(mid)` per step.
`decodeStep` runs: `quantizer.decode` → `upsample.step` → `decoder_transformer` (with
KV cache update) → `decoder.step`. Each call produces one frame of audio. This is
the canonical per-step decode pattern: state advances, KV cache grows, and one output
frame is produced per iteration.

---

## Per-Step Signpost Implementation (Task 2)

### Change

`Sources/MLXAudioCodecs/Mimi/Mimi.swift`, inside `MimiStreamingDecoder.decodeFrames`:

```swift
for t in 0 ..< T {
    let left = split(tok, indices: [t], axis: 2)
    let mid = split(left[1], indices: [1], axis: 2)[0]
    pcs.append(mimi.decodeStep(mid))
    // S14: per-decode-step signpost (Level 4 = .verbose).
    #if MLXAUDIO_TELEMETRY_FULL
    if Telemetry.level >= .verbose {
        Telemetry.emitEvent(family: .codecs, name: "Mimi.decodeStep", tokenIndex: t)
    }
    #endif
}
```

- Family: `.codecs` (subsystem `MLXAudio.codecs`).
- Event label: `"Mimi.decodeStep"`.
- Gate: `#if MLXAUDIO_TELEMETRY_FULL` + `if Telemetry.level >= .verbose` — strips in
  release builds exactly like the S13 TTS/ASR per-token signposts.

---

## KV Cache Grow Event Implementation (Task 3)

### Approach: (b) Call-site instrumentation in Mimi's own Transformer

**Why this is the only feasible approach**: All KV cache `update()` call sites in
TTS/ASR families (Qwen3TTS, LlamaTTS, SopranoTTS, PocketTTS, MarvisTTS, Qwen3ASR,
GLMASR) are inside `MLXLMCommon` — an external Swift package. `KVCacheSimple` is
`public class` (not `open`), so it cannot be subclassed cross-module, and we cannot
modify the external package without forking swift-mlx-lm. This is an **API gap** for
all LLM-family grow events.

**Mimi is the exception**: Mimi's transformer is in
`Sources/MLXAudioCodecs/Mimi/Transformer.swift` — our own code.
`Attention.callAsFunction` directly calls `cache.update(keys: k, values: v)` at
line 156. We can instrument this call site.

### Grow Detection Logic

A capacity grow in `KVCacheSimple.update()` occurs when the pre-call offset has
reached the end of the currently-allocated slab (or the slab is nil on first call).
`KVCacheSimple` exposes two public properties we can read: `offset: Int` and
`step: Int` (default 256). The condition `offset == 0 || (offset % step == 0)` is
true exactly when the next `update()` will allocate a new zero-block and concatenate.

### Change

`Sources/MLXAudioCodecs/Mimi/Transformer.swift`, inside `Attention.callAsFunction`,
before and after the existing `cache.update()` call:

```swift
#if MLXAUDIO_TELEMETRY_FULL
let kvCacheGrowObserved: Bool = {
    guard let simple = cache as? KVCacheSimple else { return false }
    let prev = simple.offset
    return prev == 0 || (prev % simple.step == 0)
}()
#endif
(k, v) = cache.update(keys: k, values: v)
#if MLXAUDIO_TELEMETRY_FULL
if kvCacheGrowObserved && Telemetry.level >= .verbose {
    Telemetry.emitEvent(family: .codecs, name: "Mimi.KVCache.grow", tokenIndex: cache.offset)
}
#endif
```

- Family: `.codecs` (Mimi's codec signposter).
- Event label: `"Mimi.KVCache.grow"`.
- Gate: `#if MLXAUDIO_TELEMETRY_FULL` + `if Telemetry.level >= .verbose` — strips in
  release builds.
- The event is emitted AFTER `cache.update()` so the new capacity is already in place;
  `tokenIndex` carries the new `cache.offset` as metadata.

### KV Cache Grow Audit vs S5's Audit List

The S5 audit listed 9 distinct KV cache families. Their grow-event coverage status:

| Family | Counter key | Source module | Grow event? | Reason |
|--------|-------------|---------------|:-----------:|--------|
| Mimi | `Mimi.KVCache` | `MLXAudioCodecs` (ours) | YES | `Attention.callAsFunction` instrumented |
| Qwen3TTS | `Qwen3TTS.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | `update()` inside external package |
| Qwen3 | `Qwen3.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | same |
| LlamaTTS | `LlamaTTS.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | same |
| SopranoTTS | `SopranoTTS.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | same |
| PocketTTS | `PocketTTS.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | same |
| MarvisTTS | `MarvisTTS.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | same |
| Qwen3ASR | `Qwen3ASR.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | same |
| GLMASR | `GLMASR.KVCache` | `MLXLMCommon` (external) | **NO — API gap** | same |

**Partial coverage is intentional and documented** — not a silently-missing feature.
Approach (c) (XCTSkipIf stub) was considered but not taken for the test, because we
DO have real grow-event coverage for Mimi. The test asserts Mimi grow events fire.
For the LLM families, the honest position is: "grow events cannot be observed without
forking swift-mlx-lm; lifecycle events (init/deinit) from S5 are the leak-detection
mechanism for those families."

---

## Tests Added (Task 4)

### File: `Tests/TelemetryVerboseTests.swift`

Two new tests added to the existing `.serialized` `TelemetryVerboseTests` suite:

#### `testCodecPerStepEmitsExpectedCount`

- Installs a `TestEventRecorder`, calls `Telemetry.emitEvent(family: .codecs, name:
  "Mimi.decodeStep", tokenIndex: t)` in a 7-step loop (N=7), asserts exactly 7 events
  with correct family/name/index are observed.
- Pattern mirrors S13's `testTTSPerTokenEmitsExpectedCount` — directly exercises the
  recorder seam, not the full streaming decoder (no model download, CI-safe).
- Q5 resolution documented inline in the test's doc comment.

#### `testKVCacheGrowEmitsEventOnResize`

- Constructs a minimal synthetic `Transformer` (dModel=16, 1 layer) with random weights
  using `TransformerConfig` — no model download.
- Installs `TestEventRecorder` + sets `_levelOverride(.verbose)` for the test duration.
- Calls `transformer(input, cache: cache)` once. Because `cache.offset == 0` at entry,
  the grow condition fires for each layer's cache during `Attention.callAsFunction`.
- Asserts `recorder.events.filter { $0.name == "Mimi.KVCache.grow" }` is non-empty and
  all grow events carry family `"codecs"`.
- Documents the LLM-family API gap inline in the test's doc comment.

---

## Verification Evidence

### Exit Criterion 1: TelemetryVerboseTests passes (5 tests)

```
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryVerboseTests \
  CODE_SIGNING_ALLOWED=NO

Suite "TelemetryVerboseTests" started.
Test "Telemetry.Level.verbose is the highest level; ..." passed after 0.001 seconds.
Test "emitEvent forwards exactly N events to the recorder for N token steps" passed after 0.001 seconds.
Test "Production gate pattern: level < .verbose skips emitEvent; ..." passed after 0.001 seconds.
Test "Mimi.decodeStep per-frame event: recorder observes exactly N events for N frames" passed after 0.001 seconds.
Test "Mimi.KVCache.grow event fires on first cache update (capacity = 0 → grows)" passed after 0.024 seconds.
Suite "TelemetryVerboseTests" passed after 0.025 seconds.
Test run with 5 tests in 1 suite passed after 0.026 seconds.
** TEST SUCCEEDED **
```

5/5 tests pass (3 from S13, 2 new from S14). ✓

### Exit Criterion 2: Full CI-safe block passes (326 tests, 38 suites)

```
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  [... all 38 CI-safe suites from CLAUDE.md ...] \
  CODE_SIGNING_ALLOWED=NO

Test run with 326 tests in 38 suites passed after 13.211 seconds.
** TEST SUCCEEDED **
```

326/326 tests pass. No regressions. ✓

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | MODIFIED — added per-step `Telemetry.emitEvent(family: .codecs, name: "Mimi.decodeStep", ...)` inside `MimiStreamingDecoder.decodeFrames` loop |
| `Sources/MLXAudioCodecs/Mimi/Transformer.swift` | MODIFIED — added grow-detection block around `cache.update()` in `Attention.callAsFunction`; emits `Telemetry.emitEvent(family: .codecs, name: "Mimi.KVCache.grow", ...)` |
| `Tests/TelemetryVerboseTests.swift` | MODIFIED — header updated; added `@testable import MLXAudioCodecs`; added `testCodecPerStepEmitsExpectedCount` and `testKVCacheGrowEmitsEventOnResize` |
| `COMPLETE_S14_VERBOSE_CODEC_AND_KV_GROW.md` | NEW — this file |

No other files were modified. `EXECUTION_PLAN.md`, `SUPERVISOR_STATE.md`, `Package.swift`,
all WU-1 telemetry sources/tests, and every other production file are unchanged per
sergeant rules.

---

## Exact Verification Commands

```sh
# 1) Targeted suite (new tests must pass)
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryVerboseTests \
  CODE_SIGNING_ALLOWED=NO

# 2) Full CI-safe block (no regressions)
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

# 3) Verify Mimi.decodeStep call site exists
grep -n 'Mimi.decodeStep' Sources/MLXAudioCodecs/Mimi/Mimi.swift

# 4) Verify Mimi.KVCache.grow call site exists
grep -n 'Mimi.KVCache.grow' Sources/MLXAudioCodecs/Mimi/Transformer.swift

# 5) Verify per-step signpost count (should have ≥1 new .verbose gate in codec sources)
grep -rn 'level >= .verbose' Sources/MLXAudioCodecs/ --include='*.swift'
```

---

## Design Notes

### Why only Mimi gets a per-step signpost

The per-step signpost requirement targets codecs that decode audio one step / chunk /
frame at a time in a loop. Only Mimi's `MimiStreamingDecoder.decodeFrames` qualifies.
SNAC, Encodec, and DACVAE have loops, but they are data-parallel batch chunking
(processing independent chunks of a large input) rather than autoregressive
step-by-step generation where the state (KV cache) accumulates. Vocos is a pure
single-shot vocoder.

The S11 outer `Mimi.decode` interval signpost already covers the non-streaming
`Mimi.decode(_:)` path. The per-step signpost covers the streaming path through
`MimiStreamingDecoder.decodeFrames`.

### Why the LLM-family KV cache grow events are an API gap

`KVCacheSimple.update()` is the canonical place where grows happen, but it is:
- Inside the `MLXLMCommon` Swift package (external dependency)
- In `public class KVCacheSimple: BaseKVCache` — `public`, not `open`
- Unreachable from our code without modifying the external package or forking

The sentinel approach from S5 (associated objects for lifecycle) works because it
hooks `deinit`, which fires for ALL Swift classes via libobjc regardless of access
level. There is no analogous "method interception" mechanism in Swift for `public`
(non-open) class methods — we cannot override `update()` cross-module.

The three approaches evaluated:

**(a) Polling on the sentinel** — would require the sentinel to observe `cache.offset`
on every access, but the sentinel has no hook into the call chain. Rejected.

**(b) Call-site instrumentation** — only feasible where the call is in OUR code.
Mimi's `Attention.callAsFunction` is the one call site within our codebase.
Implemented for Mimi. ALL other call sites are in `MLXLMCommon`. Partial (b).

**(c) Document + stub** — taken for LLM families. The `testKVCacheGrowEmitsEventOnResize`
test documents this gap inline; it does NOT skip — it tests the Mimi path and documents
the LLM gap in comments.

### Why `offset % step == 0` detects a grow

`KVCacheSimple.update()` allocates a new zero-block of size `nSteps * step` when
`(previous + keys.dim(2)) > currentKeys.dim(2)`. For the common case of 1 token per
step (`keys.dim(2) == 1`), this condition fires exactly at `offset == 0` (first call)
and at multiples of `step` (the slab is exhausted). The expression
`offset == 0 || (offset % step == 0)` captures both cases reliably.

Edge case: if `keys.dim(2) > 1` (multi-token prefill), a grow can also occur mid-slab.
The condition is conservative (may miss multi-token grows between slab boundaries)
but never fires a false-positive single-token grow. For Instruments-level debugging,
the existing S10/S11 `Mimi.decode` interval interval is sufficient for bulk operations;
the grow event is a diagnostic aid, not a correctness requirement.
