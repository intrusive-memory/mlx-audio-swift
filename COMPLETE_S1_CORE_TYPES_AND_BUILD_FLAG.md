# Sortie 1 — Core Types & Build Flag — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-1 Telemetry Foundation
**Sortie**: 1 of 15
**Branch**: `mission/leak-bloodhound/01`
**Iteration**: 1

---

## Summary

Stood up the public scaffolding for the MLXAudio telemetry surface:

- Declared `Telemetry` enum with nested `Telemetry.Level` (Int-backed,
  `Comparable`, `Sendable`) covering `.off`, `.lifecycle`, `.operations`,
  `.memory`, `.verbose`.
- Stubbed `Telemetry.level` and `Telemetry.ceiling` to return the
  placeholder `.lifecycle` value. Real env-var resolution and
  `#if MLXAUDIO_TELEMETRY_FULL` gating are deliberately deferred to
  Sortie 2 per plan.
- Declared `TelemetrySnapshot` (`Sendable`) carrying `liveCounts`,
  `mlxActiveBytes`, `mlxPeakBytes`, and `timestamp`.
- Added the `MLXAUDIO_TELEMETRY_FULL` Swift define, gated on
  `.debug`, to both the `MLXAudioCore` target and the `MLXAudioTests`
  test target so test suites compile against the full ceiling.

No production callers are instrumented yet — this is pure scaffolding
for downstream sorties (S2 onward).

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioCore/Telemetry/Telemetry.swift` | NEW — declares `public enum Telemetry` and nested `public enum Level: Int, Comparable, Sendable`; stubs `level` / `ceiling` returning `.lifecycle`. |
| `Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift` | NEW — declares `public struct TelemetrySnapshot: Sendable` with `liveCounts`, `mlxActiveBytes`, `mlxPeakBytes`, `timestamp` and a public memberwise initializer. |
| `Package.swift` | MODIFIED — added `.define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug))` to `swiftSettings` for the `MLXAudioCore` target and the `MLXAudioTests` test target. |
| `COMPLETE_S1_CORE_TYPES_AND_BUILD_FLAG.md` | NEW — this file. |

---

## Exit Criteria — Verification Evidence

### 1. Source files exist

```sh
$ test -f Sources/MLXAudioCore/Telemetry/Telemetry.swift && echo OK
OK
$ test -f Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift && echo OK
OK
```

### 2. `MLXAUDIO_TELEMETRY_FULL` is present in Package.swift, gated on `.debug`, for both `MLXAudioCore` and the test target

```sh
$ grep -q 'MLXAUDIO_TELEMETRY_FULL' Package.swift && echo OK
OK
$ grep -nE 'MLXAUDIO_TELEMETRY_FULL' Package.swift
73:                .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
188:                .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
```

Line 73 sits inside the `MLXAudioCore` target's `swiftSettings`; line 188
sits inside the `MLXAudioTests` test target's `swiftSettings`. Both
`.when(configuration: .debug)` clamps match the requirements doc
Section 4 ("Debug builds → all levels available; Release builds → only
`.off` and `.lifecycle`").

### 3. `xcodebuild build` exits 0

Tail of build output:

```
RegisterExecutionPolicyException /.../Build/Products/Debug/mlx-audio-swift-tts (in target 'mlx-audio-swift-tts' from project 'MLXAudio')
    cd /Users/stovak/Projects/mlx-audio-swift
    builtin-RegisterExecutionPolicyException /.../Build/Products/Debug/mlx-audio-swift-tts

** BUILD SUCCEEDED **
```

### 4. CI-safe `xcodebuild test` block exits 0

Tail of test output:

```
􁁛 Test run with 326 tests in 38 suites passed after 14.717 seconds.
Test Suite 'MLXAudioTests.xctest' passed at 2026-05-06 21:33:50.373.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-05-06 21:33:50.373.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds

** TEST SUCCEEDED **
```

(The `Executed 0 tests` line is XCTest's bookkeeping; the project uses
Swift Testing — the authoritative line is `Test run with 326 tests in
38 suites passed`.)

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) Source files exist
test -f Sources/MLXAudioCore/Telemetry/Telemetry.swift
test -f Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift

# 2) Define present + gated on .debug
grep -q 'MLXAUDIO_TELEMETRY_FULL' Package.swift
grep -nE 'MLXAUDIO_TELEMETRY_FULL' Package.swift

# 3) Build (must end with ** BUILD SUCCEEDED **)
xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# 4) Full CI-safe test block (must end with ** TEST SUCCEEDED **)
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

---

## Notes for Sortie 2

- `Telemetry.level` and `Telemetry.ceiling` are intentionally stubbed to
  return `.lifecycle`. Sortie 2 will:
  - Resolve `ceiling` to `.verbose` under `#if MLXAUDIO_TELEMETRY_FULL`
    and `.lifecycle` otherwise.
  - Resolve `level` from `MLXAUDIO_TELEMETRY` env var with fallback to
    `.lifecycle`, clamp to ceiling, cache, emit a single warning on
    over-ceiling requests.
- The `MLXAUDIO_TELEMETRY_FULL` define is now wired in for both the
  library target and the test target — Sortie 2 can use it directly via
  `#if MLXAUDIO_TELEMETRY_FULL` without any further `Package.swift` edits.

---

## Out of Scope (per sergeant rules)

- Did NOT pre-implement env-var resolution or `#if` gating (Sortie 2).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT touch `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per
  `CLAUDE.md`.
