# Test Analysis Report

**Repository**: mlx-audio-swift
**Branch**: development @ 67e9a5a
**Date**: 2026-04-30
**Test scheme**: MLXAudio-Package
**Tests considered**: 59 test suites, ~405 `@Test` functions across 25 files (12,651 lines of test code)
**Coverage measurement**: ran the 18-suite `make test` block with `-enableCodeCoverage YES`; parsed xccov JSON

`make lint` ran cleanly (exit 0, 64 warnings, 0 serious, no diff).

## Executive summary

| Pass | Findings | Highest priority item |
|------|----------|------------------------|
| 1. High-repetition tests | 4 patterns, ~22 tests | 4 dialect-override tests at `MLXAudioTTSTests.swift:1302-1387` are copy-pasted and re-implement production logic — table-driven helper |
| 2. Superfluous tests | 6 | `testSNACComponentType` / `testMimiComponentType` are pure tautologies (`let x = "decoder"; #expect(x == "decoder")`) |
| 3. Coverage gaps | ~19 CI-safe suites unwired + 2 utility files | `make test` and `tests.yaml` run only 18 of ~37 suites the project itself documents as CI-safe — a large band of unit-test value sits dark |
| 4. Flaky-in-CI predictions | 0 in CI, 1 minor in local-only | Suite is unusually clean — no `Thread.sleep`, no network, no shared mutable state |
| 5. Performance gating | 0 | No `measure { … }` blocks anywhere; long-running tests (KV cache, weight round-trip, generation) are properly gated behind `MLXAUDIO_NIGHTLY_RUN` / `MLXAUDIO_NETWORK_TESTS` |

The single most impactful change is fixing the **CI test-suite gap**: 19 suites (≈140 tests) are written, marked CI-safe in `CLAUDE.md`, and verifiably download nothing — but neither `make test` nor `.github/workflows/tests.yaml` runs them. Once they're wired up, real coverage of helper code (UnigramTokenizer, AudioUtils, MLXAudioCoreDSP, ModelUtils, ICL prep, weight sanitization, language config dimension) jumps significantly without changing a line of source code. The repetition/tautology findings are smaller cleanup items that can be batched after the CI gap is closed.

## Pass 1 — High-repetition tests

### Copy-paste assertion blocks

- **`Tests/MLXAudioTTSTests.swift:1302-1387`** — `testDialectOverrideEricChinese`, `testDialectOverrideEricEnglish`, `testDialectOverrideDylanAuto`, `testDialectOverrideSerena`. Four tests share an identical 14-line body that decodes the same JSON, then **re-implements** the dialect-override `if-let` chain inline before asserting. The only thing varying across the four tests is the `(speaker, language, expected)` triple. Two problems: (a) classic copy-paste, (b) the test asserts on its own re-implementation rather than calling the production `prepareBaseInputs` path — if the production logic changes shape, these still pass.
  - **Action**: collapse into one parameterized swift-testing case with `@Test(arguments: [(speaker, lang, expected)])`, and call the production function directly instead of re-deriving the result.

- **`Tests/MLXAudioCodecsTests.swift:962-1046`** — `testSNACComponentRegistration`/`testMimiComponentRegistration`, `…Metadata`, `…RepositoryId`, `…Type` (4 paired tests, plus the joint `testBothComponentsCanBeRegisteredTogether`). Each pair shares a structurally identical body, varying only by codec.
  - **Action**: parameterize over `[SNAC, Mimi]`. (Lower priority than the dialect tests — these are short and harmless, but eight tests collapse to four.)

- **`Tests/MLXAudioTTSTests.swift:492-513`** — `testResolveLanguageEnglishISO`, `…ChineseISO`, `…JapaneseISO`, `…KoreanISO`. Four 4-line tests asserting one ISO code each. The very next test, `testResolveLanguageAllISO` (`:516-554`), iterates a 30-entry dictionary that **already includes** `en`, `zh`, `ja`, `ko`. The four singles add no signal beyond the table-driven test.
  - **Action**: delete the four singles; keep `testResolveLanguageAllISO`. (Cross-listed under Pass 2.)

- **`Tests/MLXAudioTTSTests.swift:582-591`** — `testResolveLanguageFullNamePassthrough` / `testResolveLanguageChineseFullName`. A redundant pair: both assert that a full language name passes through. One example suffices, or fold both into a parameterized test that also covers the case-insensitivity siblings at `:618` and `:624`.
  - **Action**: collapse to one parameterized test covering passthrough + case-insensitive variants.

### High-iteration loops

No findings. No `for _ in 0..<N` with `N ≥ 1000`, no fossilized stress loops.

## Pass 2 — Superfluous tests

- **`Tests/MLXAudioCodecsTests.swift:1014-1022`** — `testSNACComponentType`. Body: `let componentType = "decoder"; #expect(componentType == "decoder", …)`. The local variable is a hand-typed string literal, then asserted to equal the same literal. This is a textbook tautology — auto-passes forever, tests nothing about production code.
  - **Action**: delete (or rewrite to actually read the registered descriptor's `type` and assert that, if there's a code path worth covering).

- **`Tests/MLXAudioCodecsTests.swift:1024-1032`** — `testMimiComponentType`. Same shape as the SNAC test above, same problem.
  - **Action**: delete.

- **`Tests/MLXAudioTTSTests.swift:492-513`** — Four singleton ISO-code tests subsumed by `testResolveLanguageAllISO` six lines later (see Pass 1 above).
  - **Action**: delete.

- **`Tests/MLXAudioTTSTests.swift:582-591`** — `testResolveLanguageFullNamePassthrough` / `testResolveLanguageChineseFullName`: see Pass 1.
  - **Action**: collapse, or delete one.

- **`Tests/MLXAudioTTSTests.swift:1302-1387`** (the four `testDialectOverride*` tests) — superfluous in the strong sense that they assert on a re-implementation of the production logic in their own bodies. Even after refactoring per Pass 1, the rewrite needs to *call the production function* rather than re-derive the answer.
  - **Action**: rewrite to invoke `Qwen3TTSModel.prepareBaseInputs` (or whatever the production entry point is) and assert on its observable output. If the public API doesn't expose the dialect-resolved language, this is also a Pass 3 (coverage) signal that the helper should be made testable.

- No findings of: unconditional `XCTSkip`, `version`-string assertions, `#expect(true)`, framework re-tests, env-var-gated dead tests. The skip patterns that exist (`MLXAUDIO_NETWORK_TESTS`, `MLXAUDIO_NIGHTLY_RUN`) are explicit, well-commented, and exercised by nightly CI.

## Pass 3 — Coverage gaps

Coverage was measured by running the Makefile's 18-suite `CI_TESTS` block with `-enableCodeCoverage YES` and parsing `xccov view --report --json`. Generated, vendored, and tiny (<30-line) files were filtered out.

Overall: **24.3 %** line coverage on `MLXAudio` (4,819 / 19,868). That number is misleading on its own — it includes large model files (`Soprano.swift`, `Qwen3.swift`, `LlamaTTS.swift`, `MarvisTTSModel.swift`, `GLMASR.swift`, `Mimi.swift`, `PocketTTSModel.swift`, `CSMModel.swift`, etc.) that are intentionally only covered by local-only / nightly suites. Excluding those, the actionable gaps split cleanly into two buckets.

### A. Suites that exist and are CI-safe but **are not wired into `make test` / `tests.yaml`**

This is the largest finding in the report. `CLAUDE.md` documents a 35-suite `xcodebuild test` command labelled "Run unit tests (no model downloads) after code changes to verify nothing is broken" — but `Makefile`'s `CI_TESTS` and `.github/workflows/tests.yaml` only run **18** of those. The following 19 suites are written, exist on disk, contain only zero-download unit tests (verified by grepping each for `fromPretrained` / `Acervo` / `ensureComponentReady` / `loadModel` — all 0), and pass locally — yet never run on a PR:

| Suite | File | Tests | Production code covered |
|-------|------|-------|------------------------|
| `MLXAudioCoreDSPTests` | `MLXAudioCoreDSPTests.swift` | 7 | `Sources/MLXAudioCore/DSP.swift` |
| `ModelUtilsTests` | `ModelUtilsTests.swift` | 4 | `Sources/MLXAudio/Models/ModelUtils.swift` |
| `AudioUtilsTests` | `AudioUtilsTests.swift` | several | `Sources/MLXAudioCore/AudioUtils.swift` (currently 0 % covered, 250 lines) |
| `AudioIORoundTripTests` | `AudioIORoundTripTests.swift` | several | audio I/O helpers |
| `MimiLayerTests` | `MimiLayerTests.swift` | 5 | `Sources/MLXAudioCodecs/Mimi/MimiLayer.swift` |
| `SNACVQTests` | `SNACVQTests.swift` | several | `Sources/MLXAudioCodecs/SNAC/VQ.swift` (currently 0 % covered, 147 lines) |
| `DACVAEWatermarkerTests` | `DACVAEWatermarkerTests.swift` | 7 | DACVAE watermark code path |
| `ConvWeightedTests` | `ConvWeightedTests.swift` | several | weighted-conv helpers |
| `UnigramTokenizerRoundTripTests` | `UnigramTokenizerRoundTripTests.swift` | 5 | `Sources/MLXAudioTTS/.../UnigramTokenizer.swift` (currently 0 % covered, 232 lines) |
| `ParityFixtureLoaderSmokeTests` | `ParityFixtureLoaderSmokeTests.swift` | 1 | parity fixture loader |
| `LlamaTTSModuleSetupTests` | `LlamaTTSModuleSetupTests.swift` | 7 | LlamaTTS module registration |
| `PocketTTSModuleSetupTests` | `PocketTTSModuleSetupTests.swift` | 10 | PocketTTS registration |
| `SopranoModuleSetupTests` | `SopranoModuleSetupTests.swift` | 10 | Soprano registration |
| `GLMASRModelTests` | `GLMASRModelTests.swift` | 7 | GLMASR model construction |
| `Qwen3TTSSpeechTokenizerWeightTests` | inside `MLXAudioTTSTests.swift:283-489` | several | Qwen3-TTS speech tokenizer weight loading |
| `Qwen3TTSPrepareICLInputsTests` | inside `MLXAudioTTSTests.swift:3175-3579` | several | ICL input preparation (a published public surface) |
| `Qwen3TTSGenerateICLTests` | inside `MLXAudioTTSTests.swift:3579-3837` | several | ICL generation entry points (no actual generation, just routing) |
| `Qwen3TTSGenerateCustomVoiceTests` | inside `MLXAudioTTSTests.swift:1618-1770` | several | custom-voice routing/error paths |
| `Qwen3TTSConfigDimensionTests` | inside `MLXAudioTTSTests.swift:4648-4716` | 4 | config dimension consistency |

**Action**: extend `Makefile`'s `CI_TESTS` with these 19 suites, and update `.github/workflows/tests.yaml` to match (the workflow currently mirrors the Makefile by hand — a one-line `make test-ci` invocation in the workflow would keep them in lockstep going forward). This is one git-diff away from being done; the tests are already passing locally per `CLAUDE.md`'s documented run command.

`bin/check-local-only-suites.sh` has a parallel gap: it enforces 10 local-only suites but `CLAUDE.md` documents 13 (`DeterministicGenerationTests`, `KVCacheCorrectnessTests`, `WeightRoundTripTests` aren't in the script's `EXPECTED_SUITES` array). Worth fixing in the same PR.

### B. Production files where coverage is genuinely thin even given the local-only convention

Once the bigger model files (which are deliberately covered by local-only suites) are excluded, two non-model files stand out as **load-bearing-but-thin** even for the CI-safe band:

| File | Line coverage | Why it matters | Top uncovered |
|------|---------------|----------------|---------------|
| `Sources/MLXAudioCore/AudioUtils.swift` | 0 % (0/250) | Core utility surface used across ASR / TTS pipelines (chunking, audio conversion, preprocessing). Already has a written test (`AudioUtilsTests`) that doesn't run in CI — bucket A above. | All. |
| `Sources/MLXAudioCore/MLX+Extensions.swift` | 0 % (0/154) | Generic MLX helpers (likely shape, slicing, dtype helpers) used widely. No dedicated test suite exists. | All. |

For everything else — `Soprano.swift`, `Qwen3.swift`, `LlamaTTS.swift`, `Mimi.swift`, `MarvisTTSModel.swift`, `GLMASR.swift`, `PocketTTSModel.swift`, `UnigramTokenizer.swift`, `Layers.swift`, `Attention.swift`, `VQ.swift`, `SNACDecoder.swift`, `AudioPlayerManager.swift`, `AudioModelManager.swift`, etc. — the 0 % reading reflects "this is covered by local-only / nightly suites, not the CI-safe band". That's an architectural choice, not a defect. Most of these become covered as soon as bucket A is wired up (e.g., `UnigramTokenizer.swift` is tested by `UnigramTokenizerRoundTripTests`, `VQ.swift` by `SNACVQTests`, `Layers.swift` and `Attention.swift` by `MimiLayerTests` / codec parity tests).

**Action for B**: either add a small CI-safe test suite for `MLX+Extensions.swift` (it's pure utilities — should be cheap), or accept it as deliberately untested at the helper level and rely on indirect coverage from model tests.

## Pass 4 — Flaky-in-CI predictions

The CI-running portion of the suite is **unusually clean**. Specifically there are:

- **No** `Thread.sleep`, `usleep`, or `Task.sleep` calls anywhere in `Tests/`
- **No** wall-clock duration assertions
- **No** order-dependent shared state (`UserDefaults.standard`, mutable singletons, `.shared` instances)
- **No** real network or `URLSession` usage in CI tests; the network-touching path is gated behind `MLXAUDIO_NETWORK_TESTS=1` and exercised only by the nightly workflow
- **No** non-deterministic input baked into assertions (the only `random` / `UUID` / `Date` usages are scoped to per-test temp paths in `WeightRoundTripTests`, `AudioIORoundTripTests`, `AudioUtilsTests` — exactly the right pattern)
- **No** missing `@MainActor` / actor-isolation issues spotted in the patterns checked

### One minor finding (local-only, not CI)

- **`Tests/MLXAudioTTSTests.swift:1803, 1857, 1908, 1962, 2026, 2105, 2163, 2210, 2263, 3879, 3998, 4093, 4193, 4273`** — many local-only TTS audio-generation tests write to `FileManager.default.temporaryDirectory.appendingPathComponent("qwen3_test_output.wav")` (or similarly fixed names like `qwen3_tts_voicedesign_test_output.wav`, `qwen3_tts_base_test_output.wav`). swift-testing parallelises by default; if any two of these run concurrently and happen to choose the same fixed filename, they'll race on it.
  - **Why this isn't a CI issue today**: every test in this list is local-only / nightly (each one calls `Qwen3TTSModel.fromPretrained` / `Qwen3Model.fromPretrained` / similar). The nightly workflow runs them serially via `-only-testing` per-suite invocations.
  - **Smell**: filesystem race / fixed temp path
  - **Action**: drop a `UUID().uuidString` into the path (the same pattern `WeightRoundTripTests.swift:105` and `AudioUtilsTests.swift:71` already use). Cheap, defensive against future parallelism changes.

## Pass 5 — Performance test gating

**No findings.** The repo contains zero `measure { … }` / `measure(metrics:)` blocks. There are no benchmark suites disguised as correctness tests. Long-running suites (`DeterministicGenerationTests`, `KVCacheCorrectnessTests`, `WeightRoundTripTests`, `MarvisTTSGenerateTests`, the various `*TTSTests` audio-generation ones) are properly gated:

- Nightly-only via `MLXAUDIO_NIGHTLY_RUN=1` (`KVCacheCorrectnessTests`, `WeightRoundTripTests`)
- Local-only via the `bin/check-local-only-suites.sh` allowlist + nightly workflow (the model-loading suites)
- Network-only via `MLXAUDIO_NETWORK_TESTS=1` (`AudioModelManagerIntegrationTests`)

CI's `make test` block is fast (the coverage build for those 18 suites finishes in ~10 s of test execution on this machine). Nothing to move.

## Consolidated action items

### Delete (pure dead weight, no rewrite needed)
- `Tests/MLXAudioCodecsTests.swift:1014-1032` — `testSNACComponentType`, `testMimiComponentType` (tautologies)
- `Tests/MLXAudioTTSTests.swift:492-513` — `testResolveLanguage{English,Chinese,Japanese,Korean}ISO` (subsumed by `testResolveLanguageAllISO`)
- `Tests/MLXAudioTTSTests.swift:587-591` — `testResolveLanguageChineseFullName` (subsumed by sibling, or fold both into one parameterized passthrough test)

### Refactor (table-driven / parameterize)
- `Tests/MLXAudioTTSTests.swift:1302-1387` — collapse the four `testDialectOverride*` into one parameterized swift-testing case **and** stop re-implementing the production `if-let` chain in the test body — call the actual production function instead
- `Tests/MLXAudioCodecsTests.swift:962-1032` — parameterize the four `SNAC`/`Mimi` registration/metadata/repositoryId/type pairs over `[SNAC, Mimi]`
- `Tests/MLXAudioTTSTests.swift:582-624` — fold the FullName-passthrough + case-insensitive variants into one parameterized test

### Wire into CI (largest impact — already-written tests just don't run)
- Extend `Makefile`'s `CI_TESTS` and `.github/workflows/tests.yaml` to include the 19 CI-safe suites listed in Pass 3-A. Best implementation: have the workflow call `make test` so the Makefile is the single source of truth.
- Update `bin/check-local-only-suites.sh`'s `EXPECTED_SUITES` array to add `DeterministicGenerationTests`, `KVCacheCorrectnessTests`, `WeightRoundTripTests` (currently documented as local-only in `CLAUDE.md` but not enforced by the script).

### Add tests for
- `Sources/MLXAudioCore/MLX+Extensions.swift` (154 lines, 0 % covered, no dedicated suite). Cheap to write, given the suite is pure helpers.
- Consider whether `AudioUtilsTests` exercises `Sources/MLXAudioCore/AudioUtils.swift` thoroughly enough — once it's running in CI, re-measure coverage on that file specifically and grow the test if 0 % → 30 % rather than 0 % → 80 %+.

### Defensive cleanup (very low priority)
- Replace the fixed temp-file paths in the local-only TTS audio-generation tests with `UUID().uuidString` per the pattern in `WeightRoundTripTests.swift:105`. ~14 single-line edits.
