# Sortie 15 — Telemetry Docs (README + DocC + TELEMETRY_USAGE.md + cross-links) — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-6 Documentation & Examples
**Sortie**: 15 of 15 (FINAL SORTIE)
**Branch**: `mission/leak-bloodhound/01`
**Predecessor**: S14 (`6e584b7`)

---

## Summary of Every Doc File Created or Modified

| Path | Change |
|------|--------|
| `README.md` | MODIFIED — added `## Telemetry` section (levels, compile flag, env var, leak-detection example, further-reading pointer to TELEMETRY_USAGE.md). |
| `docs/TELEMETRY_USAGE.md` | NEW — full walkthrough with three concrete examples (see below). |
| `Sources/MLXAudioCore/MLXAudioCore.docc/Telemetry.md` | NEW — DocC article (catalog directory created). |
| `AGENTS.md` | MODIFIED — added `## Telemetry` section with cross-links to TELEMETRY_USAGE.md and TELEMETRY_REQUIREMENTS.md. |
| `CLAUDE.md` | MODIFIED — added `## References` section with cross-link to TELEMETRY_USAGE.md. |
| `COMPLETE_S15_DOCUMENTATION.md` | NEW — this file. |

No source files in `Sources/` or `Tests/` were modified.

---

## README "Telemetry" Section (verbatim diff)

The following section was inserted immediately before `## Requirements` in `README.md`:

```markdown
## Telemetry

`MLXAudio` ships an in-process telemetry surface for finding memory leaks and
profiling generation hot paths. It is opt-in: the production ceiling is
`.lifecycle` and the env var defaults to `.lifecycle`.

### Levels

- `.off` — no instrumentation
- `.lifecycle` — paired init/deinit counters on every long-lived object (default)
- `.operations` — Level 1 + interval signposts on resolve / download / load /
  generate / encode / decode (requires debug build)
- `.memory` — Level 2 + MLX active-memory deltas attached to every interval
- `.verbose` — Level 3 + per-token / per-codec-step / KV-grow point events

### Compile flag

`MLXAUDIO_TELEMETRY_FULL` is defined in `.debug` builds (via `Package.swift`).
Levels above `.lifecycle` strip out at compile time in release builds — they
cannot ship in production regardless of env-var settings.

### Env var

Set `MLXAUDIO_TELEMETRY` to one of `off|lifecycle|operations|memory|verbose`
(case-insensitive) to override the default level at runtime. If the requested
level exceeds the compiled ceiling, the library clamps to the ceiling and emits
a one-shot warning on the `MLXAudio.Telemetry` os.Logger subsystem.

### Leak-detection example

[... canonical XCTest pattern — see README.md for full code block ...]

For per-op memory pinpointing, run the same test under
`MLXAUDIO_TELEMETRY=memory` to populate `snapshot().perOpDeltas`. For visual
inspection, run under Instruments with the os_signpost track and filter on
subsystems prefixed with `MLXAudio.` (10 subsystems, one per model family).

### Further reading

See `docs/TELEMETRY_USAGE.md` for full walkthroughs: leak detection (Level 1),
per-op memory pinpointing (Level 3), and Instruments trace capture (Level 2)
including manual os_signpost track configuration.
```

---

## `docs/TELEMETRY_USAGE.md` — Outline of Three Examples

### Example 1 — Leak Detection (Level 1)

Step-by-step: `resetCounters()` → baseline snapshot → autoreleasepool loop →
drain fire-and-forget Tasks → assert delta == 0. Worked example for
`Qwen3TTSModel` with the `"Qwen3TTS.Model"` counter key. Counter key reference
table (18 keys). Explains both instrumentation idioms (in-class vs sentinel).
CI-safe and per-family run commands.

### Example 2 — Per-Op Memory Pinpointing (Level 3, `MLXAUDIO_TELEMETRY=memory`)

How to enable Level 3 (env var + debug build requirement). How to read
`TelemetrySnapshot.perOpDeltas` — sorted print example, healthy vs leaking
output side-by-side. Canonical per-op key reference (all 33 keys from S12).
Reset semantics (perOpDeltas reset; mlxPeakBytes is monotonic).

### Example 3 — Instruments Trace Capture (Level 2 with os_signpost)

How to enable Level 2. Manual Instruments configuration (no .tracetemplate
required): step-by-step from Product → Profile to adding the os_signpost
instrument, filtering on the 10 `MLXAudio.*` subsystem identifiers, recording,
and reading the timeline. How to identify healthy vs leaking KV cache "Lifetime"
bars. Level 4 drilldown: per-token point events and all 8 event labels.

**No `.tracetemplate` was included**: Instruments `.tracetemplate` files are
binary plists that cannot be hand-crafted. Manual configuration (as documented
above) is the recommended approach per EXECUTION_PLAN.md task 4's "otherwise
document how to configure the os_signpost track manually" fallback.

---

## DocC Article — File Path and Convention

**File created**: `Sources/MLXAudioCore/MLXAudioCore.docc/Telemetry.md`
**Catalog directory created**: `Sources/MLXAudioCore/MLXAudioCore.docc/`

**Convention used**: None of the three probed locations existed in the repo
before S15:

1. `Sources/MLXAudioCore/MLXAudioCore.docc/` — did not exist
2. `Sources/MLXAudioCore/Documentation.docc/` — did not exist
3. `Documentation.docc/` — did not exist

Per EXECUTION_PLAN.md Open Question Q (S15): "Probe in this order:
1. `Sources/MLXAudioCore/MLXAudioCore.docc/` (most likely Swift Package
convention)." The first probe location is the Swift Package Manager convention
for a target-scoped DocC catalog, so that path was chosen and created.

**Note on Package.swift**: The `Package.swift` target for `MLXAudioCore` does not
currently have a `.process()` resource rule for the `MLXAudioCore.docc` bundle.
Adding `.docC()` resource processing to the target would allow `swift package
generate-documentation` to build the DocC catalog. This is a non-breaking
additive change that can be made in a follow-up sortie. The article file is
readable as Markdown in the meantime and DocC link syntax (`Target/Symbol`) is
used throughout.

---

## AGENTS.md — New Lines (diff)

```diff
+## Telemetry
+
+The library ships an in-process telemetry surface for leak detection and
+performance tracing. Default level is `.lifecycle` (paired init/deinit counters
+on every long-lived object); higher levels require a debug build and an env-var
+override.
+
+- **Telemetry**: see [docs/TELEMETRY_USAGE.md](docs/TELEMETRY_USAGE.md) for level/env-var/Instruments examples.
+- Full specification: [docs/TELEMETRY_REQUIREMENTS.md](docs/TELEMETRY_REQUIREMENTS.md)
+- Test-side patterns: [Tests/MLXAudioTests/README.md](Tests/MLXAudioTests/README.md)
+
 ## App Group configuration (required)
```

---

## CLAUDE.md — New Lines (diff)

```diff
+## References
+
+- **Telemetry**: see [docs/TELEMETRY_USAGE.md](docs/TELEMETRY_USAGE.md) for level/env-var/Instruments examples.
+- Full telemetry specification: [docs/TELEMETRY_REQUIREMENTS.md](docs/TELEMETRY_REQUIREMENTS.md)
+
 ## Additional Rules for Claude
```

---

## Verification Evidence

### Exit criterion 1 — README.md has `## Telemetry`, env var, compile flag, leak-detection pattern

```sh
$ grep -q '## Telemetry' README.md && echo PASS
PASS

$ grep -q 'MLXAUDIO_TELEMETRY' README.md && echo PASS
PASS

$ grep -q 'MLXAUDIO_TELEMETRY_FULL' README.md && echo PASS
PASS

$ grep -q 'leaked\|leak' README.md && echo PASS
PASS
```

### Exit criterion 2 — `docs/TELEMETRY_USAGE.md` exists and references `TELEMETRY_REQUIREMENTS.md`

```sh
$ test -f docs/TELEMETRY_USAGE.md && echo PASS
PASS

$ grep -q 'TELEMETRY_REQUIREMENTS.md' docs/TELEMETRY_USAGE.md && echo PASS
PASS
```

### Exit criterion 3 — `AGENTS.md` and `CLAUDE.md` both reference `TELEMETRY_USAGE.md`

```sh
$ grep -q 'TELEMETRY_USAGE.md' AGENTS.md && echo PASS
PASS

$ grep -q 'TELEMETRY_USAGE.md' CLAUDE.md && echo PASS
PASS
```

### Exit criterion 4 — Full CI-safe test block exits 0

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    [... all 39 suites from CLAUDE.md ...] \
    CODE_SIGNING_ALLOWED=NO

...
Test run with 328 tests in 39 suites passed after 13.253 seconds.

** TEST SUCCEEDED **
```

All 4 exit criteria: PASS.

---

## Exact Verification Commands

```sh
# EC1: README section, env var, compile flag, leak pattern
grep -q '## Telemetry' README.md && echo "EC1a PASS"
grep -q 'MLXAUDIO_TELEMETRY' README.md && echo "EC1b PASS"
grep -q 'MLXAUDIO_TELEMETRY_FULL' README.md && echo "EC1c PASS"
grep -q 'leaked\|leak' README.md && echo "EC1d PASS"

# EC2: docs/TELEMETRY_USAGE.md
test -f docs/TELEMETRY_USAGE.md && echo "EC2a PASS"
grep -q 'TELEMETRY_REQUIREMENTS.md' docs/TELEMETRY_USAGE.md && echo "EC2b PASS"

# EC3: cross-links
grep -q 'TELEMETRY_USAGE.md' AGENTS.md && echo "EC3a PASS"
grep -q 'TELEMETRY_USAGE.md' CLAUDE.md && echo "EC3b PASS"

# EC4: full CI-safe test block
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
  -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## Out of Scope (per sergeant rules)

- Did NOT modify any source file in `Sources/`.
- Did NOT modify any test file in `Tests/`.
- Did NOT add a `.tracetemplate` (not feasible as a text artifact; manual
  Instruments configuration documented in `TELEMETRY_USAGE.md` instead, per
  EXECUTION_PLAN.md task 4's fallback clause).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT commit to `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
