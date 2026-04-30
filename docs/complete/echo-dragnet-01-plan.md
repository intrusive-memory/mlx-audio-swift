---
title: "mlx-audio-swift — Test Coverage Hardening"
source: "TESTING_REQUIREMENTS.md (audit dated 2026-04-30, development branch)"
generated: 2026-04-30
refined: 2026-04-30
status: "EXECUTING"
feature_name: OPERATION ECHO DRAGNET
iteration: 1
starting_point_commit: deb37b83c86550e9227a8379fcccea59c7599f8d
mission_branch: mission/echo-dragnet/01
---

# EXECUTION_PLAN.md — mlx-audio-swift Test Coverage Hardening

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure. Maps to agentic cycles, not time.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Summary

Close the silent-regression and coverage gaps identified in `TESTING_REQUIREMENTS.md`. Five Critical findings (C1–C5) and eight Important findings (I1–I8) decompose into test-and-infrastructure work across the core utilities, codecs, TTS/STT model families, and CI. The ground truth contract: **a numerical or behavioral bug in any covered subsystem must fail a test before it ships.**

**Source**: `TESTING_REQUIREMENTS.md`
**Target branch**: `development`
**Acceptance test (load-bearing)**:
- All new CI-safe suites green via `make test`.
- Nightly local-only workflow green at least once with mlx-models-v2 cache.
- At least one numeric-parity assertion (`MLX.allclose(swift_out, python_ref, atol: 1e-4)`) per layer family listed in C1.

Out of scope (per requirements doc): subjective audio E2E tests, performance benchmarks, iOS-specific test targets.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| parity-fixtures | `Tests/media/parity/` | 2 | 0 | none |
| thin-model-coverage | `Tests/` | 4 | 0 | none |
| marvis-coverage | `Tests/`, `Sources/MLXAudioTTS/Models/Marvis/` | 2 | 0 | none |
| ci-infrastructure | `.github/workflows/`, `Tests/` | 3 | 0 | none |
| core-utilities-misc | `Tests/`, `Sources/MLXAudioCore/` | 4 | 0 | none |
| core-utilities-dsp | `Tests/`, `Sources/MLXAudioCore/` | 1 | 1 | parity-fixtures |
| codec-layer-tests | `Tests/MLXAudioCodecsTests.swift`, `Tests/Mimi*` | 3 | 1 | parity-fixtures |
| tokenizer-roundtrip | `Tests/`, `Tests/media/parity/tokenizer/` | 1 | 1 | parity-fixtures |
| deterministic-generation | `Tests/` | 3 | 2 | thin-model-coverage, marvis-coverage |

Layers gate dispatch: Layer 1 sorties require all Layer 0 work units to be COMPLETED; Layer 2 requires all Layer 0 + Layer 1.

---

## Sortie Definitions

> Sorties are ordered by priority within each layer. **Priority** is computed as `(dependency_depth × 3) + (foundation × 2) + (risk × 1) + (complexity × 0.5)`. Higher score = dispatch earlier.

### Sortie 1: Parity fixture Python pipeline + 6 fixture sets

**Work unit**: parity-fixtures (Layer 0)
**Priority**: 21.5 — blocks 5 L1 sorties (DSP parity, codec parity, Mimi layers, watermarker, tokenizer); foundational; numerical-correctness risk.
**Agent constraint**: SUB-AGENT ELIGIBLE — runs `python3` only, no `xcodebuild`.

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:
1. Create directory `Tests/media/parity/` with subdirs `dsp/`, `vocos_istft_head/`, `encodec_quantizer/`, `dacvae_encoder_block/`, `snac_vq/`, `mimi_rvq/`.
2. Author `Tests/media/parity/_generate.py` (Python 3.11+, requires `torch`, `numpy`, `safetensors`) that emits `input.safetensors`, `weights.safetensors`, `expected.safetensors` per layer family using the original PyTorch reference impls.
3. Generate canonical fixtures for the six layer families above (one input shape each). Commit the resulting `*.safetensors` files (target ≤ 5 MB combined; use float32 small inputs).
4. Author `Tests/media/parity/README.md` documenting how to regenerate fixtures and why parity tests exist.

**Exit criteria**:
- [ ] `python3 Tests/media/parity/_generate.py --all` exits 0 and writes 6 fixture sets (one per subdir).
- [ ] All 6 subdirs contain `input.safetensors`, `weights.safetensors`, `expected.safetensors`.
- [ ] `du -sb Tests/media/parity/` reports ≤ 5_242_880 bytes.
- [ ] `Tests/media/parity/README.md` exists and includes a regenerate-command code block.

---

### Sortie 2: Swift parity fixture loader + smoke test

**Work unit**: parity-fixtures (Layer 0)
**Priority**: 17.0 — blocks all L1 parity-using sorties (12, 17–20).
**Agent constraint**: SUPERVISING AGENT ONLY (xcodebuild verification).

**Entry criteria**:
- [ ] Sortie 1 COMPLETED — fixtures exist on disk.

**Tasks**:
1. Add `Tests/Helpers/ParityFixtureLoader.swift` exposing `loadFixture(_ name: String) -> (input: MLXArray, weights: [String: MLXArray], expected: MLXArray)`. Reuse any existing safetensors loader in `Sources/MLXAudioCore/` if one exists; otherwise add a minimal `safetensors`-compatible loader inside the helper file (mark `internal`).
2. Add `Tests/ParityFixtureLoaderSmokeTests.swift` with a single test that loads `dsp` fixture and asserts `input.shape.count > 0 && weights.count >= 1 && expected.shape.count > 0`.
3. Wire `ParityFixtureLoaderSmokeTests` into the CI-safe test list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/ParityFixtureLoaderSmokeTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] `grep -c ParityFixtureLoaderSmokeTests CLAUDE.md` returns ≥ 1.

---

### Sortie 3: LlamaTTS module-setup tests (CI-safe)

**Work unit**: thin-model-coverage (Layer 0)
**Priority**: 12.0 — unblocks all 3 Layer 2 sorties (deterministic, KV cache, weight RT).
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/LlamaTTSModuleSetupTests.swift` with `@Suite("LlamaTTSModuleSetupTests")`.
2. Add `llamaConfigDecodesFromJSON` — assert config decodes from `Tests/media/configs/llama_tts.json` (commit a real upstream config under `Tests/media/configs/`).
3. Add `llamaSanitizeStripsExpectedPrefixes` — synthetic `[String: MLXArray]` with raw upstream key names; assert sanitize transforms them.
4. Add `llamaMakeCacheReturnsExpectedShape` — instantiate model with config (no weights) and assert `makeCache()` shape matches config dimensions.
5. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/LlamaTTSModuleSetupTests` exits 0.
- [ ] No model download triggered (run with empty `~/Library/SharedModels` and verify directory is still empty afterward).
- [ ] `grep -c LlamaTTSModuleSetupTests CLAUDE.md` ≥ 1.

---

### Sortie 4: PocketTTS module-setup tests (CI-safe)

**Work unit**: thin-model-coverage (Layer 0)
**Priority**: 12.0 — unblocks all Layer 2.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/PocketTTSModuleSetupTests.swift`.
2. Add config-decode tests for `FlowLM`, `Conditioners`, `MimiAdapter` from JSON fixtures (`Tests/media/configs/pockettts_flowlm.json`, `pockettts_conditioners.json`, `pockettts_mimi_adapter.json`).
3. Add `sanitize` one-way test for `Model` weight transformation.
4. Add `makeCache` test for the top-level model.
5. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/PocketTTSModuleSetupTests` exits 0.
- [ ] No model download triggered (verify by empty `~/Library/SharedModels`).
- [ ] `grep -c PocketTTSModuleSetupTests CLAUDE.md` ≥ 1.

---

### Sortie 5: Soprano module-setup tests (CI-safe)

**Work unit**: thin-model-coverage (Layer 0)
**Priority**: 12.0 — unblocks all Layer 2.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/SopranoModuleSetupTests.swift`.
2. Add Soprano config-decode test from `Tests/media/configs/soprano.json` fixture.
3. Add `sanitize` one-way transformation test.
4. Add `SopranoDecoder` instantiation + output-shape test (random init weights, fixed input shape).
5. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/SopranoModuleSetupTests` exits 0.
- [ ] No model download triggered.
- [ ] `grep -c SopranoModuleSetupTests CLAUDE.md` ≥ 1.

---

### Sortie 6: GLMASR LM/Model module-setup tests (CI-safe)

**Work unit**: thin-model-coverage (Layer 0)
**Priority**: 12.0 — unblocks all Layer 2.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/GLMASRModelTests.swift` with `@Suite("GLMASRModelTests")`.
2. Add config-decode test for `GLMASRLanguageModel` (`Sources/MLXAudioSTT/.../GLMASR.swift:212`).
3. Add `sanitize` one-way test for `GLMASRModel` (`:292`) covering known upstream key remapping.
4. Add `makeCache` test for `GLMASRLanguageModel`.
5. Wire into the CI-safe list in `CLAUDE.md` (alongside existing `GLMASRModuleSetupTests`).

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/GLMASRModelTests` exits 0.
- [ ] No model download triggered.
- [ ] `grep -c GLMASRModelTests CLAUDE.md` ≥ 1.

---

### Sortie 7: Marvis TTS module-setup tests (CI-safe)

**Work unit**: marvis-coverage (Layer 0)
**Priority**: 6.0 — unblocks Sortie 21 (deterministic generation).
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/MarvisTTSTests.swift` with `@Suite("MarvisTTSModuleSetupTests")`.
2. Add `marvisCSMConfigDecodesFromJSON` — assert `CSMModel` config decodes from `Tests/media/configs/marvis_csm.json`.
3. Add `marvisCSMLlamaConfigDecodesFromJSON` — same pattern for `CSMLlamaModel`.
4. Add `marvisSanitizeStripsExpectedPrefixes` — synthetic `[String: MLXArray]` with raw upstream key names; assert sanitize transforms them.
5. Add `marvisMakeCacheReturnsExpectedShape` — instantiate model with config (no weights) and assert `makeCache()` shape matches config dimensions.
6. Wire `MarvisTTSModuleSetupTests` into the CI-safe test list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/MarvisTTSModuleSetupTests` exits 0.
- [ ] Suite is listed in `CLAUDE.md` Build Commands block (`grep -c MarvisTTSModuleSetupTests CLAUDE.md` ≥ 1).
- [ ] No model download triggered (verify by running with empty `~/Library/SharedModels`).

---

### Sortie 8: Marvis TTS generation test (local-only)

**Work unit**: marvis-coverage (Layer 0)
**Priority**: 3.0 — local-only; nightly-only signal.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Add `@Suite("MarvisTTSGenerateTests")` to `Tests/MarvisTTSTests.swift` (or sibling file).
2. Add `testMarvisGenerate` mirroring `LlamaTTSTests.testLlamaTTSGenerate` (`MLXAudioTTSTests.swift:1875`) — fixed prompt, default voice, assert `audio.shape[0] >= 24000 && audio.shape.count == 1` (≥1 sec at 24 kHz, mono).
3. Use `csm` and `sesame` model keys via `TTSModelUtils` (`MLXAudioTTSTests.swift:52-53`).
4. Mark suite as local-only by NOT adding to CI-safe `CLAUDE.md` list — match the convention used for `Qwen3TTSTests`.
5. Update local-only suite documentation in `CLAUDE.md` Memory section.

**Exit criteria**:
- [ ] Suite compiles in CI build (i.e., `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` exits 0).
- [ ] Local run with mlx-models-v2 cache: `xcodebuild test -only-testing:MLXAudioTests/MarvisTTSGenerateTests` exits 0 and audio assertion passes.
- [ ] `grep -c MarvisTTSGenerateTests CLAUDE.md` ≥ 1 (under "local-only" section, NOT under CI-safe `make test` list).

---

### Sortie 9: Nightly local-only CI workflow

**Work unit**: ci-infrastructure (Layer 0)
**Priority**: 5.0 — establishes nightly pattern; depends on local-only suite list staying in sync.
**Agent constraint**: SUPERVISING AGENT ONLY (verifies `gh workflow run` and the guard script).

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `.github/workflows/nightly-tests.yaml` with `on.schedule: cron('0 6 * * *')` and `workflow_dispatch`.
2. Job: `runs-on: macos-26`, swift 6.2+, restore cache key `mlx-models-v2`, path `~/Library/SharedModels`.
3. Run all local-only suites via `xcodebuild test`: `SNACTests`, `MimiTests`, `Qwen3TTSTests`, `LlamaTTSTests`, `SopranoTTSTests`, `PocketTTSTests`, `Qwen3TTSVoiceDesignTests`, `Qwen3ASRTests`, `GLMASRTests`, plus `MarvisTTSGenerateTests` (added in Sortie 8).
4. Set `MLXAUDIO_NETWORK_TESTS=1` in the job env so the integration tests fixed in Sortie 11 also run.
5. Add `bin/check-local-only-suites.sh` guard that fails CI if the list of local-only suites in `CLAUDE.md` shrinks without a corresponding entry being added/replaced — wire into the existing `Code Quality` job in `.github/workflows/tests.yaml`.

**Exit criteria**:
- [ ] `gh workflow view nightly-tests.yaml` returns 0 and shows the workflow registered.
- [ ] First triggered run via `gh workflow run nightly-tests.yaml --ref development` completes without YAML parse errors; all jobs initialize and reach the `xcodebuild test` step (verify in Actions UI; documented test failures from missing models are acceptable on first run).
- [ ] `bin/check-local-only-suites.sh` exits 1 on a synthetic deletion test (delete one suite line from CLAUDE.md, run script, restore) and exits 0 on the unmodified tree.

---

### Sortie 10: ModelUtils weight-key transformation tests

**Work unit**: core-utilities-misc (Layer 0)
**Priority**: 5.0 — codifies weight-key transform pattern reused across model families.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/ModelUtilsTests.swift` with `@Suite("ModelUtilsTests")`.
2. Add weight-key transformation tests covering at least 3 transformations exercised by `ModelUtils.swift` (e.g., prefix strip, embedding-table rename, layer-norm key remapping).
3. Each test: input dict with raw keys → call transform → assert output keys + values match expected.
4. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/ModelUtilsTests` exits 0.
- [ ] Suite covers ≥ 3 distinct transformations (verify by `grep -c '@Test' Tests/ModelUtilsTests.swift` ≥ 3).
- [ ] `grep -c ModelUtilsTests CLAUDE.md` ≥ 1.

---

### Sortie 11: Fix integration tests that pass without network

**Work unit**: ci-infrastructure (Layer 0)
**Priority**: 3.0 — defends C2 (silent-pass anti-pattern); no transitive blockers.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Edit `Tests/AudioModelManagerIntegrationTests.swift` tests at lines ~182–348 (per audit citation).
2. Replace silent `print("Note: Download failed (expected in sandbox)")` catches with explicit gating on `MLXAUDIO_NETWORK_TESTS=1` env var.
3. When env var is unset: use `Test.disabled("requires MLXAUDIO_NETWORK_TESTS=1")` so the test reports as skipped, not passed.
4. When env var is set: assert hard — re-throw download exceptions and add post-conditions (`#expect(model.isLoaded)`).
5. Document the env var in `CLAUDE.md` (Build Commands section) and `AGENTS.md` if present.

**Exit criteria**:
- [ ] Default `make test` run shows the three integration tests with `skipped` status (not `passed`); verify by parsing xcodebuild output for `skipped` count ≥ 3 in `AudioModelManagerIntegrationTests`.
- [ ] Local run with `MLXAUDIO_NETWORK_TESTS=1` and network available: `xcodebuild test -only-testing:MLXAudioTests/AudioModelManagerIntegrationTests` exits 0 with all three tests asserting `model.isLoaded == true`.
- [ ] Local run with `MLXAUDIO_NETWORK_TESTS=1` and network blocked (`hdiutil attach -nomount /dev/null` is not the right way; use a temporary firewall block or `sudo route add -host <hub host> 127.0.0.1`): suite fails with non-zero exit code.

---

### Sortie 12: ConvWeighted parity vs Conv1d composition

**Work unit**: core-utilities-misc (Layer 0)
**Priority**: 3.0 — single-file utility test.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/ConvWeightedTests.swift` with `@Suite("ConvWeightedTests")`.
2. Instantiate `ConvWeighted` with random weights `(weight_g, weight_v)`.
3. Instantiate plain `Conv1d` with composed weights `g * v / ||v||` (compute composition in test).
4. Feed identical fixed input through both; assert `MLX.allclose(out_weighted, out_plain, atol: 1e-5, rtol: 1e-5)`.
5. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/ConvWeightedTests` exits 0.
- [ ] `grep -c ConvWeightedTests CLAUDE.md` ≥ 1.

---

### Sortie 13: AudioUtils WAV codec round-trip

**Work unit**: core-utilities-misc (Layer 0)
**Priority**: 2.5 — unit test, no transitive impact.
**Agent constraint**: SUPERVISING AGENT ONLY.
**Open-question note**: Confirm AudioUtilsTests does not duplicate Sortie 14 (AudioIORoundTripTests) — diff `AudioUtils.swift` against `loadAudioArray`/`saveAudioArray` impls before authoring; if same code path, escalate to user for merge decision.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/AudioUtilsTests.swift` with `@Suite("AudioUtilsTests")`.
2. WAV write→read round-trip on synthetic int16 PCM samples (1024-sample sine wave at 24 kHz, mono); assert byte-exact equality on int16.
3. WAV write→read round-trip on synthetic float32 PCM samples (1024-sample sine wave at 24 kHz, mono); assert `MLX.allclose(atol: 1e-6)`.
4. Edge case: zero-length array → expect explicit error or empty output (document chosen behavior in test name).
5. Use `FileManager.default.temporaryDirectory` for scratch; clean up via `defer`.
6. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/AudioUtilsTests` exits 0.
- [ ] `grep -c AudioUtilsTests CLAUDE.md` ≥ 1.

---

### Sortie 14: AudioIO load/save round-trip via intention.wav

**Work unit**: core-utilities-misc (Layer 0)
**Priority**: 2.5 — uses already-checked-in `intention.wav` fixture.
**Agent constraint**: SUPERVISING AGENT ONLY.
**Open-question note**: See Sortie 13 — confirm no overlap before authoring.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Create `Tests/AudioIORoundTripTests.swift` with `@Suite("AudioIORoundTripTests")`.
2. Round-trip: `loadAudioArray(Tests/media/intention.wav)` → `saveAudioArray(<scratch tmp dir>)` → `loadAudioArray(<scratch>)`.
3. Assert sample-count equality; `MLX.allclose(atol: 1e-6)` for float32 path; byte-exact for int16 path.
4. Cover both 16-bit and 32-bit float paths if `AudioUtils.swift` supports both.
5. Use `FileManager.default.temporaryDirectory` for scratch; clean up via `defer`.
6. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/AudioIORoundTripTests` exits 0.
- [ ] `grep -c AudioIORoundTripTests CLAUDE.md` ≥ 1.

---

### Sortie 15: Trim debug-print noise from codec tests

**Work unit**: ci-infrastructure (Layer 0)
**Priority**: 1.5 — pure cleanup.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] First sortie of work unit — no prerequisites.

**Tasks**:
1. Audit `Tests/MLXAudioCodecsTests.swift` for `print(` statements (audit cites lines 386, 400, 418, 432).
2. Capture a baseline: run `make test` and save the full `xcodebuild` output as a file (e.g., `/tmp/test-baseline.txt`); record the test pass count.
3. Remove every `print(shape)` / debug-print that does not contribute to a test assertion.
4. Sweep `Tests/MLXAudioTTSTests.swift` and `Tests/MLXAudioSTTTests.swift` for the same anti-pattern; remove only ones that are clearly leftover debugging (no shape-asserting context).
5. Run `make test` post-change.

**Exit criteria**:
- [ ] `grep -n 'print(' Tests/MLXAudioCodecsTests.swift` returns no matches.
- [ ] Post-change `make test` exits 0.
- [ ] Post-change pass count ≥ baseline pass count; zero new test failures introduced (compare via `diff` of summary lines from baseline vs post-change output).
- [ ] Pre-change baseline output saved as a comment on the PR for the change.

---

### Sortie 16: MLXAudioCore DSP numeric-parity tests

**Work unit**: core-utilities-dsp (Layer 1)
**Priority**: 5.5 — first numeric-parity coverage; defends C1 in DSP layer.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] Sortie 1 (parity Python pipeline) COMPLETED.
- [ ] Sortie 2 (parity Swift loader) COMPLETED.

**Tasks**:
1. Extend `Tests/media/parity/_generate.py` to emit reference fixtures for: `melSpectrogram(sineWave_440Hz_1s_24kHz)`, FFT, STFT, iSTFT, hann window, resampling 48k→24k. Re-run `python3 Tests/media/parity/_generate.py --all`.
2. Create `Tests/MLXAudioCoreDSPTests.swift` with `@Suite("MLXAudioCoreDSPTests")`.
3. For each of the 6 DSP functions, load the corresponding fixture via `ParityFixtureLoader`, run the Swift implementation, assert `MLX.allclose(swift_out, expected, atol: 1e-4, rtol: 1e-4)`.
4. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/MLXAudioCoreDSPTests` exits 0 with all 6 parity assertions passing.
- [ ] `grep -c MLXAudioCoreDSPTests CLAUDE.md` ≥ 1.

---

### Sortie 17: Mimi codec layer-level unit tests

**Work unit**: codec-layer-tests (Layer 1)
**Priority**: 3.5 — high task count (5 layers + parity); medium complexity.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] Sortie 1 (parity fixtures) COMPLETED.
- [ ] Sortie 2 (parity Swift loader) COMPLETED.

**Tasks**:
1. Create `Tests/MimiLayerTests.swift` with `@Suite("MimiLayerTests")` mirroring the Encodec layer-test pattern (`MLXAudioCodecsTests.swift:537-553` style).
2. Add `Conv1d` (causal/streaming) shape test against `Sources/MLXAudioCodecs/Mimi/Conv.swift`.
3. Add `ResnetBlock` shape test against `Seanet.swift`.
4. Add `Transformer` block shape test against `Transformer.swift`.
5. Add `RVQ` shape test against `Quantization.swift`.
6. Add `mimiRVQMatchesPythonReference` numeric-parity assertion using the `mimi_rvq` fixture from Sortie 1; assert `MLX.allclose(atol: 1e-4, rtol: 1e-4)`.
7. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/MimiLayerTests` exits 0 with all 5 shape tests + 1 parity assertion passing.
- [ ] `grep -c MimiLayerTests CLAUDE.md` ≥ 1.

---

### Sortie 18: DACVAE Watermarker tests

**Work unit**: codec-layer-tests (Layer 1)
**Priority**: 3.0.
**Agent constraint**: SUPERVISING AGENT ONLY.
**Open-question note**: Watermarker may be lossy (BER-tolerant) rather than bit-exact. Default to bit-exact assertion; if test fails after correct implementation, downgrade to BER assertion (e.g., `bitErrorRate < 0.01`) and document the chosen tolerance with rationale in test comment.

**Entry criteria**:
- [ ] Sortie 1 (parity fixtures) COMPLETED — needed for any numeric-parity layer in the suite.
- [ ] Sortie 2 (parity Swift loader) COMPLETED.

**Tasks**:
1. Add `@Suite("DACVAEWatermarkerTests")` to `Tests/MLXAudioCodecsTests.swift` (or sibling file).
2. Instantiation + output-shape test for `DACVAEWatermarkEncoderBlock`.
3. Instantiation + output-shape test for `DACVAEWatermarkDecoderBlock`.
4. Full `DACVAEWatermarker` instantiation test.
5. Round-trip: embed a synthetic 32-bit payload → run extract → assert payload bit-equality (or `bitErrorRate < 0.01` if bit-exact assertion fails after correct impl).
6. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `xcodebuild test -only-testing:MLXAudioTests/DACVAEWatermarkerTests` exits 0.
- [ ] Round-trip assertion explicitly states either `==` or `bitErrorRate < <documented_threshold>` in source.
- [ ] `grep -c DACVAEWatermarkerTests CLAUDE.md` ≥ 1.

---

### Sortie 19: Codec numeric-parity assertions for existing layers

**Work unit**: codec-layer-tests (Layer 1)
**Priority**: 3.0 — defends C1 across Vocos/Encodec/DACVAE/SNAC.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] Sortie 1 (parity fixtures) COMPLETED.
- [ ] Sortie 2 (parity Swift loader) COMPLETED.

**Tasks**:
1. In `Tests/VocosTests.swift`, add `vocosISTFTHeadMatchesPythonReference` — load `vocos_istft_head` fixture, assert `MLX.allclose(atol: 1e-4, rtol: 1e-4)`.
2. In `Tests/EncodecTests.swift`, add `encodecQuantizerMatchesPythonReference` — load `encodec_quantizer` fixture, assert allclose.
3. In `Tests/DACVAETests.swift`, add `dacvaeEncoderBlockMatchesPythonReference` — load fixture, assert allclose.
4. Create `Tests/SNACVQTests.swift` with CI-safe `@Suite("SNACVQTests")` containing `snacVQMatchesPythonReference` using the `snac_vq` fixture (no model download — uses fixture weights).
5. Verify all four parity tests are in CI-safe lists in `CLAUDE.md` (the existing 3 suites already are; add `SNACVQTests`).

**Exit criteria**:
- [ ] All four parity tests pass: `xcodebuild test -only-testing:MLXAudioTests/VocosTests -only-testing:MLXAudioTests/EncodecTests -only-testing:MLXAudioTests/DACVAETests -only-testing:MLXAudioTests/SNACVQTests` exits 0.
- [ ] No model download triggered (fixtures self-contained — verify by empty `~/Library/SharedModels`).
- [ ] `grep -c SNACVQTests CLAUDE.md` ≥ 1.

---

### Sortie 20: UnigramTokenizer round-trip tests against Python reference

**Work unit**: tokenizer-roundtrip (Layer 1)
**Priority**: 3.0.
**Agent constraint**: PARTIAL SUB-AGENT ELIGIBLE — Python fixture authoring is sub-agent eligible; Swift test verification is supervising-only.

**Entry criteria**:
- [ ] Sortie 1 (parity fixtures) COMPLETED — reuses fixture-generation tooling style.
- [ ] Sortie 2 (parity Swift loader) COMPLETED.

**Tasks**:
1. Author `Tests/media/parity/tokenizer/_generate.py` — runs the upstream Python tokenizer over ~10 inputs (ASCII, CJK, emoji, byte-fallback edge cases) and emits `unigram_reference.json` with `[{"text": ..., "ids": [...]}]`.
2. Run the script and commit `Tests/media/parity/tokenizer/unigram_reference.json` (≤ 50 KB).
3. Create `Tests/UnigramTokenizerRoundTripTests.swift` with `@Suite("UnigramTokenizerRoundTripTests")`.
4. For each fixture entry: assert `tokenizer.encode(text) == referenceIds` AND `tokenizer.decode(referenceIds) == text`.
5. Cover byte-fallback explicitly (encode at `UnigramTokenizer.swift:207`, decode at `:246`).
6. Wire into the CI-safe list in `CLAUDE.md`.

**Exit criteria**:
- [ ] `python3 Tests/media/parity/tokenizer/_generate.py` exits 0 and produces `unigram_reference.json`.
- [ ] `du -sb Tests/media/parity/tokenizer/unigram_reference.json` reports ≤ 51_200 bytes.
- [ ] `xcodebuild test -only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests` exits 0 for all ~10 fixture inputs.
- [ ] `grep -c UnigramTokenizerRoundTripTests CLAUDE.md` ≥ 1.

---

### Sortie 21: Deterministic-seed generation tests

**Work unit**: deterministic-generation (Layer 2)
**Priority**: 4.5 — regression risk; signal-of-record for I4.
**Agent constraint**: SUPERVISING AGENT ONLY.

**Entry criteria**:
- [ ] Sorties 3, 4, 5, 6 (thin-model-coverage) ALL COMPLETED.
- [ ] Sorties 7, 8 (marvis-coverage) ALL COMPLETED.

**Tasks**:
1. Create `Tests/DeterministicGenerationTests.swift` with `@Suite("DeterministicGenerationTests")`.
2. For Qwen3TTS: `MLXRandom.seed(42)` + fixed prompt + `temperature: 0.6, topP: 0.8` → assert exact token-id sequence equals a checked-in expected sequence (commit the expected sequence as `Tests/media/deterministic/qwen3tts_seed42.json`).
3. Same pattern for LlamaTTS, PocketTTS, Soprano (one fixture each: `llama_seed42.json`, `pockettts_seed42.json`, `soprano_seed42.json`).
4. Mark suite as local-only (model downloads required); add `DeterministicGenerationTests` to the nightly workflow runlist (`.github/workflows/nightly-tests.yaml` from Sortie 9).
5. Document the suite in `CLAUDE.md` local-only section.

**Exit criteria**:
- [ ] All four model token-sequence assertions pass locally with mlx-models-v2 cache: `xcodebuild test -only-testing:MLXAudioTests/DeterministicGenerationTests` exits 0.
- [ ] Re-running the suite three times in a row produces zero diffs in test output (verify via `xcodebuild test ... > run1.txt; xcodebuild test ... > run2.txt; diff run1.txt run2.txt` → empty).
- [ ] `grep -c DeterministicGenerationTests .github/workflows/nightly-tests.yaml` ≥ 1.
- [ ] `grep -c DeterministicGenerationTests CLAUDE.md` ≥ 1.

---

### Sortie 22: KV cache correctness tests

**Work unit**: deterministic-generation (Layer 2)
**Priority**: 4.5 — silent-regression risk for autoregressive correctness.
**Agent constraint**: SUPERVISING AGENT ONLY.
**Open-question note**: Default to local-only + nightly. Promote to CI-safe ONLY if the supervising agent verifies that a synthetic small-config TTS+STT can run prefill+decode in <10 min wall time. Otherwise, register in nightly.

**Entry criteria**:
- [ ] Sorties 3, 4, 5, 6 (thin-model-coverage) ALL COMPLETED.

**Tasks**:
1. Create `Tests/KVCacheCorrectnessTests.swift` with `@Suite("KVCacheCorrectnessTests")`.
2. For one TTS model (LlamaTTS, smallest viable): run a single-shot forward over a fixed sequence to get `logits_singleshot`; run prefill+decode incrementally to get `logits_incremental`; assert `MLX.allclose(logits_singleshot, logits_incremental, atol: 1e-4, rtol: 1e-4)`.
3. Same pattern for one STT model (Qwen3ASR).
4. Decision: Default the suite to local-only and add to nightly workflow. If a small synthetic config (random init, small dim) runs in <10 min, ALSO add to CI-safe list with that synthetic config and document in suite header.
5. Document in `CLAUDE.md` (local-only OR CI-safe depending on decision in step 4).

**Exit criteria**:
- [ ] Both TTS and STT correctness assertions pass: `xcodebuild test -only-testing:MLXAudioTests/KVCacheCorrectnessTests` exits 0 (local with mlx-models-v2 cache, or CI if promoted).
- [ ] Suite is registered in EITHER nightly workflow (`grep KVCacheCorrectnessTests .github/workflows/nightly-tests.yaml`) OR CI-safe list (`grep KVCacheCorrectnessTests CLAUDE.md` AND in the `make test` block).
- [ ] Suite header comment documents whether it runs CI-safe or local-only and why.

---

### Sortie 23: Weight-loading round-trip tests

**Work unit**: deterministic-generation (Layer 2)
**Priority**: 3.0.
**Agent constraint**: SUPERVISING AGENT ONLY.
**Open-question note**: Same CI-safe vs local-only decision rule as Sortie 22.

**Entry criteria**:
- [ ] Sorties 3, 4, 5, 6 (thin-model-coverage) ALL COMPLETED.

**Tasks**:
1. Create `Tests/WeightRoundTripTests.swift` with `@Suite("WeightRoundTripTests")`.
2. For one TTS model (LlamaTTS): instantiate with weights → save weights to a scratch path via existing serialization helpers → reload into a fresh instance → assert all parameter `MLXArray`s equal byte-for-byte (or `MLX.allclose(atol: 0)`).
3. Same pattern for one STT model (Qwen3ASR).
4. Use `FileManager.default.temporaryDirectory` for scratch; clean up via `defer`.
5. Decision: Default to local-only + nightly. Promote to CI-safe only if synthetic small weights work in <10 min build time.
6. Document in `CLAUDE.md`.

**Exit criteria**:
- [ ] Both round-trip assertions pass: `xcodebuild test -only-testing:MLXAudioTests/WeightRoundTripTests` exits 0.
- [ ] Suite registered in EITHER nightly (`grep WeightRoundTripTests .github/workflows/nightly-tests.yaml`) OR CI-safe (`grep WeightRoundTripTests CLAUDE.md` in `make test` block).
- [ ] Suite header comment documents CI-safe vs local-only and why.

---

## Parallelism Structure

**Critical Path**: Sortie 1 → Sortie 2 → Sortie 16 (DSP parity) → end of L1 → Sortie 21 (deterministic gen) → mission complete. Length: 5 hops.

Note: Sortie 21 also depends on Layer 0 thin-model-coverage (3, 4, 5, 6) and marvis-coverage (7, 8), which run in parallel with the parity-fixtures critical path. The DSP-parity → deterministic-gen path is the longest dependency chain.

**Parallel Execution Groups**:

- **Group A — L0 Python authoring (sub-agent eligible)**:
  - Sortie 1 (Parity Python pipeline) — **SUB-AGENT ELIGIBLE** (no xcodebuild)

- **Group B — L0 module-setup tests (supervising agent, sequential xcodebuild)**:
  - Sortie 3 (LlamaTTS setup) — **SUPERVISING AGENT ONLY**
  - Sortie 4 (PocketTTS setup) — **SUPERVISING AGENT ONLY**
  - Sortie 5 (Soprano setup) — **SUPERVISING AGENT ONLY**
  - Sortie 6 (GLMASR setup) — **SUPERVISING AGENT ONLY**
  - Sortie 7 (Marvis setup) — **SUPERVISING AGENT ONLY**

- **Group C — L0 cleanup + utilities (supervising agent)**:
  - Sortie 9 (Nightly workflow), 10 (ModelUtils), 11 (Integration gating), 12 (ConvWeighted), 13 (AudioUtils), 14 (AudioIO), 15 (Print sweep), 8 (Marvis generate) — **SUPERVISING AGENT ONLY**

- **Group D — L1 (after Sortie 1+2)**:
  - Sortie 16 (DSP parity), 17 (Mimi layers), 18 (Watermarker), 19 (Codec parity), 20 (Unigram round-trip — Python authoring sub-agent eligible, verification supervising)

- **Group E — L2 (after L0+L1 complete)**:
  - Sortie 21 (Deterministic generation), 22 (KV cache), 23 (Weight RT) — **SUPERVISING AGENT ONLY**

**Agent Constraints**:
- **Supervising agent**: Handles all 22 sorties with `xcodebuild test` exit criteria. Verification serializes through this single agent because parallel `xcodebuild` invocations on the same project conflict on DerivedData/lockfile.
- **Sub-agents (up to 4)**: Eligible for Sortie 1 (Python pipeline) and the Python authoring sub-task within Sortie 20. All other work is supervising-only.

**Realistic parallelism on this plan**: ≈ 2 (1 supervisor + 1 sub-agent for Python pipelines). The plan has wide breadth at L0 but the critical path through `xcodebuild` dominates wall-clock time.

**Missed opportunities**: None significant. The verification model is fundamentally serial on a single Swift package. Splitting `xcodebuild test` invocations to run in parallel against separate clones of the repo would unlock further parallelism but is out of scope for this plan.

---

## Open Questions & Missing Documentation

### Auto-fixed during refinement

| Sortie | Issue Type | Fix Applied |
|--------|-----------|-------------|
| 8 (Marvis generate) | Vague exit criterion ("produces audio array") | Replaced with `audio.shape[0] >= 24000 && audio.shape.count == 1` |
| 9 (Nightly workflow) | Vague exit criterion ("documented failures, not workflow-syntax errors") | Replaced with "no YAML parse errors; all jobs initialize and reach `xcodebuild test` step" |
| 15 (Print sweep) | Manual baseline ("identical pass/fail counts in commit message") | Replaced with explicit baseline-save + post-change diff against saved baseline |

### Flagged for upfront agent decision (non-blocking — agent resolves at start of sortie)

| Sortie | Issue Type | Description | Recommendation |
|--------|-----------|-------------|----------------|
| 18 (DACVAE Watermarker) | Open question | Is the watermarker bit-exact or lossy? | Default to bit-exact assertion; if test fails after correct impl, downgrade to `bitErrorRate < 0.01` and document tolerance in test comment. |
| 22, 23 (KV cache, Weight RT) | Open question | "If small synthetic configs work, keep CI-safe; otherwise mark local-only" — conditional path. | Default to local-only + nightly. Promote to CI-safe only if synthetic small-config run completes in <10 min build time. |
| 2 (Parity Swift loader) | Missing doc | Sortie 1 mentioned "reuse existing weight-loading utilities in `Sources/MLXAudioCore`" — does a safetensors loader exist? | Agent runs `grep -rn 'safetensors' Sources/MLXAudioCore/` first. If absent, adds a minimal `internal` loader inside `ParityFixtureLoader.swift`. |
| 13, 14 (AudioUtils vs AudioIO round-trip) | Possible overlap | Both round-trip WAV at sample/byte level. Are they testing distinct code paths? | Agent diffs `AudioUtils.swift` against `loadAudioArray`/`saveAudioArray` impls before authoring. If same code path, escalate to user for merge decision. If distinct, keep both with note in suite header documenting the boundary. |
| 1, 16, 20 (multiple `_generate.py` scripts) | File organization | Three Python fixture-generation scripts. Share or independent? | Keep independent (each domain has different deps and audiences). Flag if duplication grows beyond 3 files. |

**No blocking open questions.** All flagged items are resolvable by the assigned sortie agent at the first action of their sortie. Plan is ready to execute.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 9 |
| Total sorties | 23 |
| Layer 0 sorties | 15 |
| Layer 1 sorties | 5 |
| Layer 2 sorties | 3 |
| Critical path | 5 sorties (1 → 2 → 16 → end of L1 → 21) |
| Effective parallelism | ≈ 2 (1 supervisor + 1 sub-agent for Python pipelines) |
| Sub-agent eligible sorties | 1 (Sortie 1) + partial (Sortie 20 Python sub-task) |
| Supervising-agent-only sorties | 22 |
| Source findings covered | C1, C2, C3, C4, C5, I1, I2, I3, I4, I5, I6, I7, I8, N2 |
| Out of scope | Subjective E2E, performance benchmarks, iOS test targets, N1, N3 |
| Auto-fixed during refine | 3 vague exit criteria; 2 sortie splits (Sortie 1 → 1+2; old Sortie 12 → 12+13+14) |
| Open questions flagged | 5 (all non-blocking, agent-resolvable at sortie start) |

### Refinement passes

| Pass | Status | Changes |
|------|--------|---------|
| 1. Atomicity & Testability | PASS | 1 sortie split (oversized: parity-fixtures); 1 sortie split into 3 (multi-concern: core utilities); 22 sorties confirmed right-sized |
| 2. Prioritization | PASS | Priority scores added to all 23 sorties; 1 layer adjustment (Audio I/O round-trip moved L1 → L0); within-layer ordering by priority |
| 3. Parallelism | PASS | Critical path identified (5 hops); 22 sorties marked supervising-only (xcodebuild constraint); 1 sortie + 1 partial marked sub-agent-eligible (Python work) |
| 4. Open Questions & Vague Criteria | PASS | 3 vague criteria auto-fixed; 5 issues flagged for agent decision (none blocking) |

**VERDICT**: Plan is ready to execute. Next step: `/mission-supervisor start`
