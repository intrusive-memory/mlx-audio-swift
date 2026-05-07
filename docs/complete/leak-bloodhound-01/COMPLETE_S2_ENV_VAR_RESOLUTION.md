# Sortie 2 — Env-Var Resolution & Level Clamping — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-1 Telemetry Foundation
**Sortie**: 2 of 15
**Branch**: `mission/leak-bloodhound/01`
**Iteration**: 1

---

## Summary

Wired `Telemetry.level` and `Telemetry.ceiling` to do real work:

- `Telemetry.ceiling` now resolves to `.verbose` under
  `#if MLXAUDIO_TELEMETRY_FULL` (debug + tests) and `.lifecycle` otherwise.
- `Telemetry.level` reads `MLXAUDIO_TELEMETRY` from
  `ProcessInfo.processInfo.environment`, parses to a `Level`
  (`off|lifecycle|operations|memory|verbose`, case-insensitive,
  whitespace-tolerant), defaults to `.lifecycle` when unset or
  unparseable, and clamps to `ceiling`.
- When the requested level exceeds the ceiling, a single warning is
  emitted on the dedicated `MLXAudio.Telemetry` `os.Logger`. The
  resolved value is cached via Swift's static-`let` initialization,
  which is thread-safe and runs at most once per process — that is the
  one-shot warning guarantee.
- Implementation factors the parse + clamp logic into a pure resolver
  (`Telemetry.resolveLevel(rawValue:ceiling:warn:)`) so unit tests
  exercise every parse / clamp / warning path without touching the
  process-wide cache.

Per the sergeant brief, only what S2 needs is shipped:

- A single `Logger` with subsystem `"MLXAudio.Telemetry"`,
  category `"telemetry"`, declared internal-to-module as
  `Telemetry.warningLogger` so it can be reused by a future
  `MLXAudioLogging` namespace in S3 without conflict.
- The full per-subsystem logger map and `OSSignposter` instances
  (S3) are NOT pre-implemented.
- `CounterStore` (S4) is NOT pre-implemented.

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioCore/Telemetry/Telemetry.swift` | MODIFIED — replaced S1 placeholder accessors with real `#if MLXAUDIO_TELEMETRY_FULL`-gated `ceiling`, env-var-driven cached `level`, pure `resolveLevel` + `parseLevel` helpers, and the dedicated `warningLogger` (`subsystem: "MLXAudio.Telemetry"`). |
| `Tests/TelemetryConfigTests.swift` | NEW — 16 Swift Testing tests covering `parseLevel` (nil / empty / valid case-insensitive / whitespace / unknown), `resolveLevel` (defaults / valid names under full ceiling / clamp & warn / no-warn at-or-below ceiling / one-shot per call), and the public `Telemetry.level` / `Telemetry.ceiling` accessors. |
| `COMPLETE_S2_ENV_VAR_RESOLUTION.md` | NEW — this file. |

No `Package.swift` edits were needed: S1 already wired
`MLXAUDIO_TELEMETRY_FULL` into the `MLXAudioCore` and `MLXAudioTests`
targets under `.debug`, which is exactly what S2 consumes.

---

## Exit Criteria — Verification Evidence

### 1. `xcodebuild test -only-testing:MLXAudioTests/TelemetryConfigTests` exits 0

Tail:

```
􁁛 Test "parseLevel: every valid name parses, case-insensitive" passed after 0.001 seconds.
􁁛 Test "resolveLevel: env set to garbage → .lifecycle (no warn)" passed after 0.001 seconds.
􁁛 Test "resolveLevel: each over-ceiling level warns exactly once per call" passed after 0.001 seconds.
􁁛 Test "resolveLevel: requested == ceiling does NOT warn" passed after 0.001 seconds.
􁁛 Test "parseLevel: empty / whitespace → nil" passed after 0.001 seconds.
􁁛 Test "parseLevel: leading/trailing whitespace tolerated" passed after 0.001 seconds.
􁁛 Test "parseLevel: unknown name → nil" passed after 0.001 seconds.
􁁛 Test "Telemetry.ceiling matches MLXAUDIO_TELEMETRY_FULL build flag" passed after 0.001 seconds.
􁁛 Test "ResolvedLevel singleton survives many reads without re-firing" passed after 0.001 seconds.
􁁛 Test "resolveLevel: requested > ceiling clamps and warns once" passed after 0.001 seconds.
􁁛 Test "parseLevel: nil → nil (signals default)" passed after 0.001 seconds.
􁁛 Test "resolveLevel: requested below ceiling does not warn" passed after 0.001 seconds.
􁁛 Test "Telemetry.level returns a Level <= ceiling" passed after 0.001 seconds.
􁁛 Suite "TelemetryConfigTests" passed after 0.001 seconds.
􁁛 Test run with 16 tests in 1 suite passed after 0.001 seconds.

** TEST SUCCEEDED **
```

Total: 16 / 16 tests pass.

### 2. Full CI-safe `xcodebuild test` block exits 0

Tail:

```
􁁛 Test testGenerateRoutesToICL() passed after 2.162 seconds.
􁁛 Test testGenerateRoutesToBaseWhenRefAudioMissing() passed after 2.159 seconds.
􁁛 Test testGenerateICLMethodSignature() passed after 2.159 seconds.
􁁛 Suite Qwen3TTSGenerateICLTests passed after 6.106 seconds.
􁁛 Test testEncodecModel() passed after 9.393 seconds.
􁁛 Suite EncodecTests passed after 9.402 seconds.
􁁛 Test run with 326 tests in 38 suites passed after 9.410 seconds.

** TEST SUCCEEDED **
```

Total: 326 / 326 tests pass across 38 suites. No regressions.

(S1 reported "326 tests in 38 suites"; S2 keeps that count steady — the
new 16 `TelemetryConfigTests` tests run only under their own
`-only-testing` invocation since they're not yet in the CI-safe list.
That's intentional: the assignment says "Add unit-test target
`MLXAudioTests/TelemetryConfigTests`" and verifies it via the dedicated
`-only-testing` command in the exit criteria; promotion into the main
CI-safe list belongs to a later sortie that updates `CLAUDE.md`.)

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) Targeted: TelemetryConfigTests must pass
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryConfigTests \
  CODE_SIGNING_ALLOWED=NO

# 2) Full CI-safe test block (from CLAUDE.md) must end with ** TEST SUCCEEDED **
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

## Design Notes

### Why a pure resolver + a static-`let` cache

The task brief required two things that pull in opposite directions:

1. *"Resolution must be cached so the warning fires at most once per process."*
2. *"Add unit-test target … covering: default = `.lifecycle`, valid env
   var values, invalid env var falls back to `.lifecycle`, clamp-to-
   ceiling emits a warning exactly once."*

Caching at module scope means the very first read of `Telemetry.level`
in a unit-test process locks in whatever
`ProcessInfo.processInfo.environment["MLXAUDIO_TELEMETRY"]` was set to
when the process launched. We can't mutate the process environment
between tests in any reliable way under Swift Testing / XCTest, so we
can't drive `Telemetry.level` through every parse path from the public
accessor.

Solution: factor the parse + clamp + warn logic into a pure function
`Telemetry.resolveLevel(rawValue:ceiling:warn:)` and let tests call it
directly. The cached singleton (`ResolvedLevel.shared`) wraps the same
function with the real `ProcessInfo` env and the real
`Telemetry.warningLogger`. Swift's static `let` initialization
guarantees the wrapper runs at most once and is thread-safe — that's
where the "warn at most once per process" semantic comes from.

### Why no public `MLXAudioLogging` namespace yet

The brief says explicitly: *"the full S3 map (per-subsystem logger map)
lands in a later sortie under the top-level enum `MLXAudioLogging` —
for now, just declare what S2 needs (one Logger with subsystem
`"MLXAudio.Telemetry"`). Do NOT pre-implement the full S3 map."*

So `Telemetry.warningLogger` is internal-to-module. S3 will introduce
the public `MLXAudioLogging` enum and is free to either (a) add a
`MLXAudioLogging.telemetry` accessor that returns the same logger or
(b) re-declare it cleanly. Either path is forward-compatible.

### Sendable / Swift 6 concurrency

- `Telemetry.warningLogger` is a `let` of `Logger` (`Sendable` since
  Apple frameworks ship `Sendable` conformance for `os.Logger`).
- `ResolvedLevel.shared` is a `let` of a struct holding `Sendable`
  fields; the struct conforms to `Sendable` implicitly.
- `Telemetry.resolveLevel(...)` is a pure function — no shared mutable
  state, safe to call from any isolation context.

The test target uses `@testable import MLXAudioCore` to reach the
internal `parseLevel` / `resolveLevel` helpers, matching the convention
used by every other test file in `Tests/`.

---

## Out of Scope (per sergeant rules)

- Did NOT start Sortie 3 (per-subsystem `MLXAudioLogging` map and
  `OSSignposter` instances).
- Did NOT start Sortie 4 (counter store actor / `snapshot` / `resetCounters`).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT touch `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
- Did NOT promote `TelemetryConfigTests` into the CI-safe `-only-testing`
  list in `CLAUDE.md`. That's a separate documentation edit and was
  not in the S2 task list; it falls naturally out of S3 / S4 when
  more telemetry test suites land together.
