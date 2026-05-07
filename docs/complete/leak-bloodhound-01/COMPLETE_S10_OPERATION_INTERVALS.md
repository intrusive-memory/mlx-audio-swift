# COMPLETE — Sortie 10: Operation Intervals (resolve / download / loadWeights)

**Mission**: OPERATION LEAK BLOODHOUND
**Sortie**: S10 (WU-3 first half)
**Branch**: `mission/leak-bloodhound/01`
**Predecessor**: S9 (`8c195ab`)
**Status**: COMPLETE

---

## Audit Output — Wrapped Call Sites

All sites are gated by **both** `#if MLXAUDIO_TELEMETRY_FULL` (compile-time
ceiling, only `.debug` configurations) and `if Telemetry.level >= .operations`
(runtime floor) per the requirements §4 two-layer model. The release ceiling is
`.lifecycle`, so every wrap below strips entirely from release binaries.

### ModelResolver.resolve (1 site)

| Location | Subsystem | Notes |
|----------|-----------|-------|
| `Sources/MLXAudioCore/AudioModelManager.swift` — `AudioModelManager.ensureModelReady(_:progress:)` | `MLXAudio.modelResolver` | Top-level resolve interval; wraps the `Acervo.ensureComponentReady` call inside a nested `Acervo.download` interval so Instruments shows "resolve includes download" in the lane. Message = `modelRepo.rawValue` (HF repo id). |

### Acervo.download per component (2 sites)

| Location | Subsystem | Notes |
|----------|-----------|-------|
| `Sources/MLXAudioCore/AudioModelManager.swift` — `ensureModelReady` (nested under `ModelResolver.resolve`) | `MLXAudio.modelResolver` | Per-component download interval. Message = `componentId`. |
| `Sources/MLXAudioCore/AudioModelManager.swift` — `loadWithAcervoStrict(componentId:load:)` | `MLXAudio.modelResolver` | Per-component download interval emitted from the strict v2 loader path used by every TTS/codec/STT `fromPretrained` in this codebase. Message = `componentId`. |

> **Note on "per file"**: This codebase invokes Acervo at the *component* granularity (`Acervo.ensureComponentReady(componentId)`), not per individual file. Each component download is the closest analogue to "Acervo.download per file" available without modifying the SwiftAcervo dependency. The two interval sites cover both call paths into Acervo from this package.

### loadWeights per family (15 sites)

| Family | Site | Subsystem | Message |
|--------|------|-----------|---------|
| **Qwen3TTS — talker** | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` (`fromPretrained` closure, talker `update`) | `MLXAudio.qwen3TTS` | `"talker"` |
| **Qwen3TTS — speakerEncoder** | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` (`fromPretrained` closure, speaker encoder `update`) | `MLXAudio.qwen3TTS` | `"speakerEncoder"` |
| **Qwen3TTS — speechTokenizer** | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` (`loadSpeechTokenizer` `update`) | `MLXAudio.qwen3TTS` | `"speechTokenizer"` |
| **Qwen3 (LM)** | `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` (`fromPretrained` closure `update`) | `MLXAudio.core` | componentId |
| **LlamaTTS** | `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` (`fromPretrained` closure `update`) | `MLXAudio.llamaTTS` | `"orpheus-tts-3b"` |
| **SopranoTTS** | `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` (`fromPretrained` closure `update`) | `MLXAudio.sopranoTTS` | `"soprano-tts-80m"` |
| **PocketTTS** | `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` (`fromPretrained` closure `update`) | `MLXAudio.pocketTTS` | `"pocket-tts"` |
| **MarvisTTS** | `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` (`fromPretrained` `update`) | `MLXAudio.marvisTTS` | repoId |
| **Qwen3ASR** | `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` (`fromPretrained` closure `update`) | `MLXAudio.qwen3ASR` | `"qwen3-asr"` |
| **Qwen3ASR — ForcedAligner** | `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` (`fromPretrained` closure `update`) | `MLXAudio.qwen3ASR` | `"qwen3-asr-forced-aligner"` |
| **GLMASR** | `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` (`fromPretrained` closure `update`) | `MLXAudio.glmASR` | `"glm-asr"` |
| **SNAC** | `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` (`fromPretrained` closure `update`) | `MLXAudio.codecs` | `"snac-24khz"` |
| **Mimi** | `Sources/MLXAudioCodecs/Mimi/Mimi.swift` (`fromPretrained` closure `update`) | `MLXAudio.codecs` | `"mimi-pytorch-bf16"` |
| **Encodec** (also covers Vocos via composition — Vocos's `fromPretrained` flows through `Encodec.fromPretrained`) | `Sources/MLXAudioCodecs/Encodec/Encodec.swift` (`fromPretrained` closure `update`) | `MLXAudio.codecs` | componentId |
| **DACVAE** | `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` (`fromPretrained` closure `update`) | `MLXAudio.codecs` | `"dac-vae"` |

### Vocos (composed)

Vocos has no standalone `update(parameters:)` call site — its `fromPretrained` route loads weights through `Encodec.fromPretrained`. The Encodec wrap above covers the Vocos load path entirely.

### Counts summary

| Category | New `Telemetry.emitInterval` / `emitIntervalAsync` call sites |
|----------|----:|
| `ModelResolver.resolve` | 1 |
| `Acervo.download` (per component) | 2 |
| `loadWeights` (per family) | 15 |
| **Total new operation-interval call sites in `Sources/`** | **18** |

`grep -E "^\+.*Telemetry\.emitInterval" git diff -- Sources/ | grep -v IntervalEmitter.swift | wc -l` → **18**

That's well above the ≥ 14 threshold from EXECUTION_PLAN S10's exit criterion. Each call site goes through `Telemetry.emitInterval` / `Telemetry.emitIntervalAsync`, both of which call `OSSignposter.beginInterval` / `endInterval` exactly once internally, so 18 source-level instrumented call sites = 18 Instruments os_signpost intervals at runtime under `.operations` level.

---

## TestSignposterRecorder (Open Question Q4 resolution)

### The protocol seam

Production code emits operation intervals via two helpers in
`Sources/MLXAudioCore/Telemetry/IntervalEmitter.swift`:

```swift
public static func emitInterval<T>(
    name: StaticString,
    family: Family,           // or signposter:OSSignposter overload
    message: String = "",
    body: () throws -> T
) rethrows -> T
```

Both helpers always emit `OSSignposter.beginInterval(...)` / `endInterval(...)`
(so Instruments traces continue to work). When a `TelemetryIntervalRecorder`
is installed via `Telemetry._installIntervalRecorder(_:)`, every begin/end
pair is *also* forwarded to the recorder.

The protocol itself (`internal`, gated under `#if MLXAUDIO_TELEMETRY_FULL`):

```swift
internal protocol TelemetryIntervalRecorder: AnyObject, Sendable {
    func recordBegin(name: String, subsystem: String, message: String)
    func recordEnd(name: String, subsystem: String, message: String)
}
```

The injection point is a static `internal nonisolated(unsafe)` property
`Telemetry._intervalRecorder`, with paired install/uninstall helpers that
return the previous value so tests can restore state on teardown.

### Where the production-code seam lives

- **Helper definitions**: `Sources/MLXAudioCore/Telemetry/IntervalEmitter.swift` (new file).
- **Production call sites**: All 18 sites listed in the table above call
  `Telemetry.emitInterval(...)` / `Telemetry.emitIntervalAsync(...)`. They
  do not reference the recorder directly — only the helpers do.
- **Test seam**: `internal` symbols accessed by the test target via
  `@testable import MLXAudioCore` in `Tests/TelemetryOperationsTests.swift`.

### How the recorder slots in for tests

`Tests/TelemetryOperationsTests.swift` defines a nested `TestSignposterRecorder`
struct (a class — `final class TestSignposterRecorder: @unchecked Sendable, TelemetryIntervalRecorder`).
It accumulates `Event` values into an internal array, guarded by `NSLock`.

The test installs the recorder, runs ONE weight-loading call path (a
synthetic `MLXNN.Linear` whose weights are loaded via `Telemetry.emitInterval`
on the codecs subsystem), and asserts the recorder observed exactly one
`.begin` and one `.end` event with the expected `name`, `subsystem`, and
`message`. **Per Q4, the recorder is the source of truth — not live env-var
resolution.**

### Why the env-var test uses `_installLevelOverride`, not `setenv`

`Telemetry.level` is cached at first read via the process-singleton
`ResolvedLevel.shared` initializer (Swift's static-let one-shot semantics),
which guarantees env-var resolution runs at most once per process. Mutating
the environment with `setenv` from a test would have no effect on the cached
value — and on the very first read could even burn the one-shot clamp warning.

The S10 patch adds a test-only `Telemetry._installLevelOverride(_:)` seam
gated under `#if MLXAUDIO_TELEMETRY_FULL` (so it cannot leak into release
builds). Tests use this seam to deterministically exercise level-gated code
paths without env-var-resolution-timing fragility. This is documented in
`testLevelResolvesFromEnv`'s leading doc comment.

### Production API surface unchanged

Host apps see no new public symbols beyond:

- `Telemetry.Family` (public enum used to select a signposter without
  exposing the internal `OSSignposter` instances)
- `Telemetry.emitInterval(name:family:message:body:)` /
  `Telemetry.emitIntervalAsync(name:family:message:body:)` — the helpers
  themselves are public so sibling targets in this package can use them.
- `Telemetry.emitInterval(name:signposter:subsystem:message:body:)` and
  the matching async overload — also public, but takes an `OSSignposter`
  argument that callers outside MLXAudio cannot construct on the internal
  `MLXAudioLogging.*Signposter` instances.

`TelemetryIntervalRecorder`, `_intervalRecorder`, `_installIntervalRecorder`,
`_levelOverride`, and `_installLevelOverride` are **all `internal` and gated
under `#if MLXAUDIO_TELEMETRY_FULL`**. Release builds have none of them.

---

## Files Created / Modified

### Created

- `Sources/MLXAudioCore/Telemetry/IntervalEmitter.swift` — `Telemetry.Family`
  enum, `emitInterval` / `emitIntervalAsync` helpers, `TelemetryIntervalRecorder`
  protocol, test-only `_intervalRecorder` and `_levelOverride` seams.
- `Tests/TelemetryOperationsTests.swift` — Suite "TelemetryOperationsTests"
  with 4 tests: `testLevelResolvesFromEnv`, `testInstrumentedCallEmitsInterval`,
  `testLevelGateShortCircuits`, `testFamilySubsystemStringsMatchLogging`.
- `COMPLETE_S10_OPERATION_INTERVALS.md` — this document.

### Modified

- `Package.swift` — added `.define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug))`
  to `MLXAudioCodecs`, `MLXAudioTTS`, `MLXAudioSTT`. Without this,
  `#if MLXAUDIO_TELEMETRY_FULL` would always be false in those targets and
  the operation-interval wraps would strip out unconditionally — defeating
  S10's purpose. (`MLXAudioCore` and the test target already had the
  define from S1; `MLXAudioSTS`/`MLXAudioUI` don't host any operation-level
  call sites, so they were left alone.)
- `Sources/MLXAudioCore/Telemetry/Telemetry.swift` — `Telemetry.level`
  accessor consults `_levelOverride` first when `MLXAUDIO_TELEMETRY_FULL`
  is defined.
- `Sources/MLXAudioCore/AudioModelManager.swift` — `ensureModelReady` and
  `loadWithAcervoStrict` wrapped in operation-level intervals.
- `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` — talker, speaker
  encoder, and speech-tokenizer `update(parameters:)` wraps.
- `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` — wrap.
- `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` — wrap.
- `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` — wrap.
- `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` — wrap.
- `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` — wrap.
- `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` — wrap.
- `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` — wrap.
- `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` — wrap.
- `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` — wrap.
- `Sources/MLXAudioCodecs/Mimi/Mimi.swift` — wrap.
- `Sources/MLXAudioCodecs/Encodec/Encodec.swift` — wrap.
- `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` — wrap.

---

## Verification Evidence

### TelemetryOperationsTests (only)

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryOperationsTests \
    CODE_SIGNING_ALLOWED=NO
...
􀟈 Suite "TelemetryOperationsTests" started.
􀟈 Test "Telemetry.level resolves to .operations under override (Q4)" started.
􁁛 Test "Telemetry.level resolves to .operations under override (Q4)" passed after 0.001 seconds.
􀟈 Test "instrumented loadWeights emits exactly one begin/end pair" started.
􁁛 Test "instrumented loadWeights emits exactly one begin/end pair" passed after 0.024 seconds.
􀟈 Test "level < .operations skips the wrap (no events recorded)" started.
􁁛 Test "level < .operations skips the wrap (no events recorded)" passed after 0.001 seconds.
􀟈 Test "Family.subsystem strings match MLXAudioLogging subsystems" started.
􁁛 Test "Family.subsystem strings match MLXAudioLogging subsystems" passed after 0.001 seconds.
􁁛 Suite "TelemetryOperationsTests" passed after 0.024 seconds.
􁁛 Test run with 4 tests in 1 suite passed after 0.025 seconds.

** TEST SUCCEEDED **
```

### Full CI-safe block from `CLAUDE.md`

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    -only-testing:MLXAudioTests/EncodecTests \
    -only-testing:MLXAudioTests/DACVAETests \
    -only-testing:MLXAudioTests/GLMASRModuleSetupTests \
    ...  (every CI-safe suite from CLAUDE.md)
    CODE_SIGNING_ALLOWED=NO
...
􁁛 Test run with 326 tests in 38 suites passed after 14.721 seconds.
** TEST SUCCEEDED **
```

(Note: pass count is 326 tests / 38 suites for the CLAUDE.md-listed CI-safe
suites. Adding `-only-testing:MLXAudioTests/TelemetryOperationsTests` brings
it to 330 tests / 39 suites.)

---

## Exact Verification Commands

```bash
# Sortie 10's own tests (CI-safe)
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryOperationsTests \
    CODE_SIGNING_ALLOWED=NO

# Full CI-safe block from CLAUDE.md
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
```

Both invocations exit 0.
