# Sortie 3 — Per-subsystem MLXAudioLogging Map (Logger + internal OSSignposter) — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-1 Telemetry Foundation
**Sortie**: 3 of 15
**Branch**: `mission/leak-bloodhound/01`
**Iteration**: 1

---

## Summary

Declared the canonical per-subsystem logging map for the MLXAudio telemetry
surface as `public enum MLXAudioLogging` in
`Sources/MLXAudioCore/Telemetry/Logging.swift`.

- 10 `public static let Logger` instances, one per canonical subsystem
  (`MLXAudio.core`, `MLXAudio.modelResolver`, `MLXAudio.qwen3TTS`,
  `MLXAudio.llamaTTS`, `MLXAudio.sopranoTTS`, `MLXAudio.pocketTTS`,
  `MLXAudio.marvisTTS`, `MLXAudio.qwen3ASR`, `MLXAudio.glmASR`,
  `MLXAudio.codecs`). Public so host apps can filter via `log` /
  Console.app.
- 10 `internal static let OSSignposter` instances, one per canonical
  subsystem. Internal — host apps should emit on their own subsystems,
  not ours (requirements §5).
- Each Logger/OSSignposter pair shares the identical subsystem string so
  Instruments groups them cleanly.
- An `internal static let subsystemTable` of
  `(subsystem: String, logger: Logger, signposter: OSSignposter)` tuples
  is the structural ground truth for test assertions (os.Logger and
  OSSignposter do not expose a readable `.subsystem` property).
- S2's `Telemetry.warningLogger` (subsystem `"MLXAudio.Telemetry"`)
  is left in `Telemetry.swift` as-is — it is an 11th internal-use logger
  distinct from the 10 canonical public loggers, and does not conflict.
- Added `Tests/TelemetryLoggingTests.swift` with 14 tests covering:
  exact table count (10), all canonical identifiers present, structural
  subsystem-match assertion, per-logger smoke tests (10 public loggers),
  and one bulk signposter accessibility test.

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioCore/Telemetry/Logging.swift` | NEW — `public enum MLXAudioLogging` with 10 public Logger + 10 internal OSSignposter + internal subsystemTable. |
| `Tests/TelemetryLoggingTests.swift` | NEW — 14 Swift Testing tests in `TelemetryLoggingTests` suite. |
| `COMPLETE_S3_LOGGER_SIGNPOSTER_SCAFFOLDING.md` | NEW — this file. |

No other files were modified. S2's `Telemetry.swift` and `TelemetryConfigTests.swift`
are unchanged. `Package.swift`, `EXECUTION_PLAN.md`, and `SUPERVISOR_STATE.md` are
unchanged per sergeant rules.

---

## Verification Evidence

### Exit criterion 1: `grep -c 'public static let'` ≥ 10

```
$ grep -c 'public static let' Sources/MLXAudioCore/Telemetry/Logging.swift
11
```

Result: 11 (10 Loggers + 1 subsystemTable). Passes (≥ 10). ✓

### Exit criterion 2: No public OSSignposter symbols

```
$ grep -E 'public[[:space:]]+(static[[:space:]]+let|let).*OSSignposter' \
    Sources/MLXAudioCore/Telemetry/Logging.swift
(no output)
$ echo "exit: $?"
exit: 1
```

The `! grep -E ...` check succeeds (no matches). ✓

### Exit criterion 3: TelemetryLoggingTests exits 0

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryLoggingTests CODE_SIGNING_ALLOWED=NO

...
  Test "MLXAudioLogging.qwen3TTS logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.codecs logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.marvisTTS logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.llamaTTS logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.core logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.sopranoTTS logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.modelResolver logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.glmASR logger is accessible" passed after 0.001 seconds.
  Test "MLXAudioLogging.pocketTTS logger is accessible" passed after 0.001 seconds.
  Test "each subsystem table entry pairs the correct Logger and OSSignposter" passed after 0.001 seconds.
  Test "MLXAudioLogging.qwen3ASR logger is accessible" passed after 0.001 seconds.
  Test "all 10 canonical subsystem identifiers are present" passed after 0.001 seconds.
  Test "subsystemTable contains exactly 10 canonical entries" passed after 0.001 seconds.
  Test "all 10 internal OSSignposter instances are accessible" passed after 0.001 seconds.
  Suite "TelemetryLoggingTests" passed after 0.001 seconds.
  Test run with 14 tests in 1 suite passed after 0.002 seconds.

** TEST SUCCEEDED **
```

14 / 14 tests pass. ✓

### Exit criterion 4: Full CI-safe test block

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    [... all 38 suites from CLAUDE.md ...] \
    CODE_SIGNING_ALLOWED=NO

...
  Test run with 326 tests in 38 suites passed after 8.942 seconds.

** TEST SUCCEEDED **
```

326 / 326 tests pass. No regressions. ✓

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) public static let count >= 10
grep -c 'public static let' Sources/MLXAudioCore/Telemetry/Logging.swift

# 2) no public OSSignposter symbols (expect: no matches / exit 1 on grep)
! grep -E 'public[[:space:]]+(static[[:space:]]+let|let).*OSSignposter' \
    Sources/MLXAudioCore/Telemetry/Logging.swift

# 3) TelemetryLoggingTests suite
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLoggingTests \
  CODE_SIGNING_ALLOWED=NO

# 4) Full CI-safe block (from CLAUDE.md)
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

### Why `internal static let subsystemTable`

`os.Logger` and `OSSignposter` do not expose a readable `.subsystem`
property (it's stored internally in the OS logging infrastructure, not
in the Swift wrapper). The only way to assert at test time that a Logger
and OSSignposter share the same subsystem is to record the subsystem
string alongside both instances at construction time. The
`subsystemTable` is an `internal` tuple array that does exactly this;
it's the structural source of truth for the Logger/OSSignposter pairing.

### The 11th logger: `Telemetry.warningLogger`

S2 ships a `static let warningLogger = Logger(subsystem: "MLXAudio.Telemetry", …)`
inside `Telemetry.swift`. This is an internal implementation detail for
the one-shot clamp warning. It is NOT one of the 10 canonical public
subsystems, and it does NOT appear in `MLXAudioLogging`. The `grep -c
'public static let'` check counts only public ones in `Logging.swift`
(returns 11 = 10 loggers + the subsystemTable), so there is no
confusion.

### Sendable

`os.Logger` is `Sendable` (Apple framework conformance). `OSSignposter`
is also `Sendable`. Both are stored as `static let` constants, which
Swift guarantees are initialized at most once and are safe to access
from any isolation context.

---

## Out of Scope (per sergeant rules)

- Did NOT start Sortie 4 (counter store actor / `snapshot` / `resetCounters`).
- Did NOT instrument any production code (lifecycle hooks land in S5+;
  operation intervals in S10+; verbose signposts in S13+).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT touch `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
