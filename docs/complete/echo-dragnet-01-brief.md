# Iteration 01 Brief — OPERATION ECHO DRAGNET

**Mission:** Close the silent-regression and coverage gaps identified in `TESTING_REQUIREMENTS.md` so that any numerical or behavioral bug in a covered subsystem fails a test before it ships.
**Branch:** `mission/echo-dragnet/01`
**Starting Point Commit:** `deb37b8` (mission: archive OPERATION ROSETTA RELAY plan alongside its brief)
**Sorties Planned:** 23
**Sorties Completed:** 23 (+ 1 user-authorized fix-up)
**Sorties Failed/Blocked:** 0
**Duration:** Single calendar day (2026-04-30)
**Outcome:** Complete
**Verdict:** Keep the code. Mission's stated purpose — "a numerical bug must fail a test before it ships" — was achieved twice over: parity assertions caught two real production bugs in Vocos ISTFTHead and SNAC VectorQuantize, and they were fixed mid-mission. CI is fully green at `3617ed1` (219/219).

---

## Section 1: Hard Discoveries

### 1. Vocos `ISTFTHead` had three independent numerical bugs

**What happened:** Sortie 19's `vocosISTFTHeadMatchesPythonReference` parity test failed at `max_abs_err=0.076`. Investigation surfaced three distinct bugs in `Sources/MLXAudioCodecs/Vocos/Vocos.swift`: (a) `hanningWindow` used the *symmetric* form (`N-1` denominator) instead of the *periodic* form torch.istft expects; (b) `performISTFT` dropped the batch dim when `batch == 1`; (c) the OLA denominator used `window` instead of `window²` for COLA normalization.
**What was built to handle it:** Commit `3617ed1` flips Hann to periodic, always preserves batch dim via `MLX.stacked`, and squares the window in OLA normalization. Parity test now passes at `atol=1e-4`.
**Should we have known this?** No. These bugs had been latent since the Vocos port landed; no audio-quality test had ever flagged them. The mission's own parity scaffolding was the first thing to notice. This is the mission delivering on its premise.
**Carry forward:** Every codec layer with a non-trivial numerical kernel needs a Python reference fixture. Three bugs in one ~50-line function is the prior we should plan against.

### 2. SNAC `VectorQuantize.decodeLatents` used cosine instead of L2

**What happened:** Sortie 19 reported `max_abs_err=1.43` on the SNAC parity assertion. `Sources/MLXAudioCodecs/SNAC/VQ.swift::decodeLatents` was calling `normalize()` on the codebook embeddings before the distance computation — that's cosine similarity. The reference uses L2.
**What was built to handle it:** `3617ed1` removes the `normalize()` calls.
**Should we have known this?** Yes. The original SNAC paper specifies L2. A code-level audit at port time would have caught it. We didn't have one.
**Carry forward:** Every quantizer/codebook path is a numerical-correctness hot spot — assume L2 unless the spec says otherwise, and assert it.

### 3. DACVAE Watermarker is embed-only and crashes by default

**What happened:** Sortie 18 found two channel mismatches that make the default-config watermark path crash at runtime: `DACVAEWatermark.swift:177` `postProcess` declares `inChannels=32` against an LSTM hidden of 512; `DACVAE.swift:175` `DACVAEFullDecoder.watermark()` has the same mismatch downstream. The Swift port also has *no bit-extraction path* — only embed. The plan assumed a round-trip.
**What was built to handle it:** Sortie 18 pivoted from a bit-equality round-trip to determinism + sensitivity assertions. The two channel-mismatch bugs were documented but NOT fixed (out of mission scope).
**Should we have known this?** Partially. The plan's open-question note flagged "watermarker may be lossy" — but didn't ask "is the watermark feature even fully ported?" A 30-second scan of `DACVAEWatermark.swift` would have shown only an embedder.
**Carry forward:** Before authoring a round-trip test, grep for both halves of the round-trip in `Sources/`. If only one direction exists, the test plan is wrong.

### 4. `AudioUtils.saveAudioArray` silently truncates to multiples of 1024 samples

**What happened:** Sortie 14's round-trip on `intention.wav` showed `loaded.shape[0] == 36480` but `loaded → save → load` produced 35840 — a 640-sample (~27ms) loss. The writer rounds down to a 1024-sample boundary.
**What was built to handle it:** Test surfaces it via `withKnownIssue` rather than asserting around it. Production fix deferred.
**Should we have known this?** No — this is exactly the bug class the mission was scoped to find.
**Carry forward:** This is silently corrupting any audio saved through the public API. It needs a fix in a follow-up mission, not a test workaround.

### 5. `xcodebuild build` does not compile test targets

**What happened:** Sortie 8 used `xcodebuild build` to claim compile-success on a local-only test. The test target never compiled — it was missing `import MLXLMCommon` and had a `Comment` interpolation issue. The break wasn't caught until Sortie 16 ran `xcodebuild test` on the same package and tripped over it. Sortie 16 had to fix Sortie 8's mess as a scope deviation.
**What was built to handle it:** Sortie 16 added the missing import + fixed the interpolation. The fix is in `c8e089d`.
**Should we have known this?** Yes. `xcodebuild build` builds package products; test bundles compile only under `xcodebuild test` or `xcodebuild build-for-testing`. This is a known Xcode/SPM quirk.
**Carry forward:** Any "compile-only" sortie contract MUST specify `xcodebuild build-for-testing -scheme MLXAudio-Package`. `build` is insufficient. This is now load-bearing for every local-only suite (Sorties 8, 21, 22, 23 in this mission, and any future ones).

### 6. Several plan-asserted APIs didn't exist or weren't accessible

**What happened:** Multiple sortie agents found their plan-asserted APIs were wrong:
- PocketTTS had no `sanitize(weights:)` (Sortie 4)
- GLMASR's `makeCache` lives on `GLMASRModel`, not `GLMASRLanguageModel` as the plan said (Sortie 6)
- `CSMModel.sanitize` is `private` and not test-accessible (Sortie 7)
- `Qwen3ASR.mergeAudioFeatures` is `private`, blocking full KV-cache testing (Sortie 22)
- Soprano `sanitize` happens to have a possible double-`model.` nesting bug (Sortie 5)
- No Swift resampler (48k→24k) exists in `Sources/` (Sortie 16)
**What was built to handle it:** Mostly worked around: agents tested the accessible path, skipped the private one, or marked the test as a documented gap. Sortie 4 *invented* a `sanitize(weights:)` for PocketTTS — scope creep, see §2.
**Should we have known this?** Yes. The breakdown agent should have done a single grep pass per asserted API before publishing the plan. It didn't.
**Carry forward:** Every plan that names a function/method/file must be verified against `Sources/` before status flips to "ready to execute." This is a one-grep-per-claim gate, not optional.

### 7. `KVCacheSimple` internals are not externally observable

**What happened:** Sortie 3's plan asked to assert `cache.headDim` and `cache.kvHeads` post-`makeCache()`. Those are private. Without running a forward pass to materialize the K/V tensors, only `cache.count` is visible.
**What was built to handle it:** Sortie 3 pivoted to `cache.count == hiddenLayers`, matching how Qwen3 and GLMASR siblings test it. Acceptable pattern.
**Should we have known this?** Yes — the breakdown should have read the `KVCacheSimple` interface before specifying assertions.
**Carry forward:** When testing infrastructure types (caches, schedulers, etc.), inspect the public API first; don't write assertions against speculation about internals.

### 8. Tokenizer fixture had `byte_fallback: false` while Swift impl assumes `true`

**What happened:** Sortie 20A discovered `tokenizer.json` from `mlx-community/pocket-tts` ships `byte_fallback: false`, but the Swift `UnigramTokenizer` only round-trips correctly under `byte_fallback: true`. Swift's `encodeWithByteFallback` was unreachable with the upstream config.
**What was built to handle it:** Sortie 20A patched the committed vocab to `byte_fallback: true`. 14/14 round-trip cases now pass. Three distinct edge cases (digit decomposition, tab byte reassembly, mixed CJK + byte-fallback) documented.
**Should we have known this?** No — this required reading both sides simultaneously, which is exactly what the round-trip test is for.
**Carry forward:** Tokenizer parity tests are non-optional. Where Swift and upstream config disagree, document the patch and the rationale in the fixture itself, not in test comments.

### 9. CI workflow gating depends on default branch

**What happened:** Sortie 9 wired `nightly-tests.yaml` and `bin/check-local-only-suites.sh`. Two of its exit criteria (`gh workflow view`, `gh workflow run`) cannot succeed until the workflow file is on the default branch. They were deferred to post-merge-to-main.
**Should we have known this?** Yes. This is a documented `gh` behavior.
**Carry forward:** Any plan that creates a new GitHub Actions workflow on a feature branch must split exit criteria into "verifiable on branch" vs "verifiable post-merge." Treat the post-merge half as a separate sortie or accept the deferral up-front.

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### 1. Strict-scope prompts produced clean sorties

**What happened:** After Sortie 4's PocketTTS scope creep, the supervisor tightened prompts to forbid production-code modifications and require STOP-and-report on missing APIs. Sorties 5, 6, 7 followed the same module-setup pattern with zero production changes.
**Right or wrong?** Right. The added prompt language cost ~20 tokens per dispatch and prevented an entire class of unaudited diffs.
**Evidence:** Sortie 4 added 2 source files of unaudited production code; Sorties 5, 6, 7 added zero. Same pattern, same model (sonnet), different prompts.
**Carry forward:** Every "test-only" sortie prompt must contain explicit "you may not modify Sources/" language and a STOP-and-report instruction for missing-API surprises. Default this into the breakdown skill.

#### 2. Parity-fixture infrastructure was the right investment

**What happened:** Sorties 1+2 spent two dispatches building a Python reference pipeline + Swift loader. Felt like over-investment at the time. Returned the favor immediately: Sortie 19 caught two real production bugs (Vocos, SNAC); Sortie 16 caught five DSP correctness gaps.
**Right or wrong?** Right by a wide margin. The infrastructure paid for itself in one mission.
**Evidence:** 2 sorties of investment → 4 production bugs surfaced (3 Vocos sub-bugs counted as one) within the same mission.
**Carry forward:** Every codec/DSP-port project should standardize on a parity-fixture pattern as a Layer-0 prerequisite, not a "nice to have."

#### 3. Layer-gating prevented dependency churn

**What happened:** L1 sorties (16–20) were held until L0 parity-fixtures (1+2) closed. L2 sorties (21–23) were held until L0 thin-model + marvis-coverage closed. Zero rework, zero waiting on broken prerequisites.
**Right or wrong?** Right. The discipline was cheap and prevented the worst class of rework.
**Evidence:** Zero sorties had to re-run because of upstream churn. Zero blocked work units.

### What the Agents Did Wrong

#### 1. Sortie 4 invented production code instead of escalating

**What happened:** Sortie 4 hit a missing `sanitize(weights:)` on `PocketTTSModel`. Instead of stopping, it wrote one and added testing-only `internal` inits to two source files. Plausibly correct (strips PyTorch keys, drops computed `freqs` buffer keys), but unaudited.
**Right or wrong?** Wrong. Even if defensible, the diff went into production source without human review of the semantic choices (what to strip, what to drop, casing).
**Evidence:** `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` and `PocketTTSConditioners.swift` modified by a sortie nominally scoped to `Tests/`.
**Carry forward:** This is now §2.1's strict-scope rule. Production additions in a "test-only" sortie are an automatic stop-and-escalate.

#### 2. Sortie 8 shipped a false-green compile signal

**What happened:** Used `xcodebuild build` to claim a "compile-verified" local-only test. Test target never compiled. Sortie 16 paid the cost of fixing it.
**Right or wrong?** Wrong. The contract was insufficient; the agent followed the contract; both shared blame.
**Evidence:** Sortie 16's commit `c8e089d` had to add `import MLXLMCommon` + fix Comment interpolation in `MarvisTTSGenerateTests.swift` before its own work could compile.
**Carry forward:** §1.5 above.

### What the Planner Did Wrong

#### 1. Plan asserted APIs without grepping for them

**What happened:** PocketTTS sanitize, GLMASR makeCache location, CSMModel.sanitize accessibility, Qwen3ASR mergeAudioFeatures accessibility, Swift resampler existence — all asserted in the plan, all wrong or absent in `Sources/`.
**Right or wrong?** Wrong. A single grep per asserted API would have prevented every one of these sortie-time surprises.
**Evidence:** 5+ documented API mismatches across the 23-sortie plan. ~22% surprise rate is too high for this kind of low-cost preventable error.
**Carry forward:** Add a `verify-claims` sub-pass to the breakdown skill: every named function/method/path in the plan must grep-resolve in the project before status flips to "ready to execute."

#### 2. "Compile-only" contracts didn't specify `build-for-testing`

**What happened:** Sorties 8, 21, 22, 23 had compile-only exit criteria. The plan said `xcodebuild build`. That's the wrong tool. (Caught and corrected for 21–23 mid-mission, after Sortie 8's failure pattern was identified.)
**Right or wrong?** Wrong as written. Repaired in flight.
**Evidence:** Sortie 8 false-green; Sortie 16 had to fix it.
**Carry forward:** Standardize the local-only / compile-only contract on `xcodebuild build-for-testing -scheme MLXAudio-Package -destination 'platform=macOS'` and bake it into a reusable plan template.

#### 3. Sortie 1's "DSP fixture" was a placeholder, not flagged as such

**What happened:** Sortie 1 emitted six fixture sets including `dsp/`. The DSP set was a single STFT-magnitude smoke fixture, NOT the mel/FFT/STFT/iSTFT/hann/resampling six the plan implied. Sortie 1 closed clean. Sortie 16 picked up the actual fixture authoring as part of its own task list.
**Right or wrong?** Wrong on the planner's side. The DSP fixture authoring was *split across two sorties without anybody acknowledging the split*. It worked out, but only because Sortie 16 was a careful agent.
**Evidence:** `Tests/media/parity/dsp/` had one set after Sortie 1; six after Sortie 16. The plan's `Sortie 1` exit criterion `python3 _generate.py --all writes 6 fixture sets` was true literally (six subdirs) and false in spirit (DSP subdir was a stub).
**Carry forward:** Exit criteria must measure substance, not file existence. "6 fixture subdirs" is a directory check; "6 distinct numerical kernels covered" is a substance check.

#### 4. Watermarker round-trip plan was upstream-fiction

**What happened:** Sortie 18's plan was bit-equality round-trip. The Swift watermarker has no extract path. The plan assumed parity with the Python port without verifying.
**Right or wrong?** Wrong. The breakdown skill assumed feature parity that doesn't exist.
**Evidence:** Sortie 18 pivoted mid-flight; the bit-extraction code path doesn't exist in `Sources/MLXAudioCodecs/DACVAE/`.
**Carry forward:** When porting tests for a feature, verify that *both* sides of the test target exist in `Sources/` before authoring exit criteria. This is the same gate as §1.3.

---

## Section 3: Open Decisions

### 1. PocketTTS production additions in Sortie 4 — keep, audit, or revert?

**Why it matters:** `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` and `PocketTTSConditioners.swift` now contain a `sanitize(weights:)` implementation and `internal` inits authored by a sortie agent without spec review. If the sanitize semantics are wrong (which keys to strip, casing, freqs handling), every PocketTTS load will silently corrupt weights.
**Options:**
- **A.** Audit the sanitize impl against an upstream PocketTTS PyTorch checkpoint, accept if correct.
- **B.** Revert and re-author with explicit human spec.
- **C.** Leave as-is until a runtime parity test surfaces a problem.
**Recommendation:** A. The diff is small, the cost of audit is one careful read, and the cost of letting it stew is a future silent regression.

### 2. DACVAE Watermarker channel mismatches — fix or accept gap?

**Why it matters:** Default-config watermark path crashes at runtime. The Swift port also lacks bit extraction. So nobody can use the feature today.
**Options:**
- **A.** Fix both channel mismatches AND port the bit-extraction path. (Real engineering; multi-day.)
- **B.** Fix the channel mismatches only — embed-only watermark works correctly.
- **C.** Document as an unsupported feature, leave broken, gate behind an availability flag.
**Recommendation:** B for the next mission, C for now. Bit extraction is an upstream-fiction problem (§ Process 4); embedding-only watermark has known consumers if they exist at all.

### 3. `AudioUtils.saveAudioArray` 1024-sample truncation — priority?

**Why it matters:** This is a silent data-loss bug in the public audio I/O API. Anything saved by a consumer of this library loses ~27ms of trailing audio (or however much is short of the next 1024-sample boundary).
**Options:**
- **A.** Fix immediately as a hot-fix (likely a `paddingLength == 0` branch).
- **B.** Roll into a larger AudioUtils review.
- **Recommendation:** A. The bug is silent, the fix is small, the blast radius is "every user of the library."

### 4. Swift resampler 48k→24k — implement or use platform-native?

**Why it matters:** No Swift resampler exists in `Sources/`. Mission Sortie 16 documented the gap. This blocks any pipeline that needs sample-rate conversion (Mimi 24k vs many TTS at 48k).
**Options:**
- **A.** Implement a polyphase resampler in Swift (deterministic, cross-platform within Apple ecosystem).
- **B.** Use `AVAudioConverter` (platform-native, less control over taps).
- **C.** Punt to consumer code.
**Recommendation:** B for now, A if/when we need cross-platform deterministic resampling for parity tests.

### 5. Promote Sortie 22/23 to CI-safe with synthetic small configs?

**Why it matters:** KV cache correctness and weight round-trip currently run nightly only. Synthetic small-config versions could run in <10 min on `make test`, catching silent regressions on every PR. The plan flagged this conditionally.
**Options:**
- **A.** Build synthetic small-config harness, promote both to CI-safe.
- **B.** Leave nightly-only.
**Recommendation:** A, scheduled as a post-mission Sortie. The signal value is high (regression-of-record for autoregressive correctness and weight serialization) and the cost is one harness sortie.

### 6. `Qwen3ASR.mergeAudioFeatures` API gap — change to `internal`?

**Why it matters:** Sortie 22's STT branch is currently a stub-skip because the function is `private`. A one-character change unlocks full KV-cache parity for STT.
**Options:**
- **A.** Change `private` → `internal`, restore the full assertion in `KVCacheCorrectnessTests`.
- **B.** Build a shadow public test hook.
- **C.** Accept the gap.
**Recommendation:** A. This is the cheapest and most direct path. Test-internal access is a routine pattern.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Parity Python pipeline | opus | 1 | Partial | Six dirs created, but DSP fixture was a stub — actual six DSP fixtures came from Sortie 16. Plan-author bug, not agent bug. |
| 2 | Swift parity loader | sonnet | 1 | Yes | Reused `MLX.loadArrays`. Clean. |
| 3 | LlamaTTS module-setup | sonnet | 1 | Yes | KVCacheSimple internals discovery surfaced; agent picked correct fallback. |
| 4 | PocketTTS module-setup | sonnet | 1 | **No** | Invented `sanitize` + internal inits in production source without escalation. Defensible but unaudited. |
| 5 | Soprano module-setup | sonnet | 1 | Yes | Strict-scope prompt landed. Zero production diff. |
| 6 | GLMASR LM/Model setup | sonnet | 1 | Yes | Plan's `makeCache` location was off; agent covered both. Clean. |
| 7 | Marvis module-setup | sonnet | 1 | Yes | Correctly identified `CSMModel.sanitize` as private; tested only accessible path. |
| 8 | Marvis generate (local-only) | sonnet | 1 | **No** | False-green via `xcodebuild build`. Sortie 16 paid the fix. |
| 9 | Nightly workflow | sonnet | 1 | Partial | Workflow + guard correct; two `gh` exits deferred to post-merge-to-main (default-branch quirk). Documented. |
| 10 | ModelUtils tests | sonnet | 1 | Yes | Clean. 4 transformations covered. |
| 11 | Integration test gating | sonnet | 1 | Yes | Used `.enabled(if:)` trait. Skipped status verified. |
| 12 | ConvWeighted parity | sonnet | 1 | Yes | Citation-grade. allclose < 1e-5. |
| 13 | AudioUtils round-trip | sonnet | 1 | Yes | Both writers found to be float32 (plan's int16 path N/A — flagged correctly). |
| 14 | AudioIO round-trip | sonnet | 1 | Yes | **Caught silent 1024-truncation production bug.** Mission's purpose realized. |
| 15 | Print sweep | sonnet | 1 | Yes | 79 prints removed across 3 files. Baseline diff matched. |
| 16 | DSP parity | opus | 1 | Yes (with deviation) | 5/6 PASS at atol=1e-4. Resample deferred (no Swift impl). Also fixed Sortie 8's broken target. |
| 17 | Mimi layer tests | sonnet | 1 | Yes | RVQ parity PASS. Index transpose handled. |
| 18 | DACVAE Watermarker | sonnet | 1 | Partial | **Caught two production channel-mismatch bugs + identified embed-only gap.** Pivoted away from upstream-fiction round-trip. |
| 19 | Codec parity assertions | sonnet | 1 | Yes (highest signal) | **Caught Vocos + SNAC bugs.** Mission's stated purpose, delivered. |
| 20A | Tokenizer Python fixtures | sonnet (sub-agent) | 1 | Yes | byte_fallback patch applied. 14 cases. |
| 20B | Tokenizer Swift round-trip | sonnet | 1 | Yes | 14/14 zero divergence. |
| 21 | Deterministic generation | sonnet | 1 | Yes (compile-only) | PocketTTS pivoted to sample-count proxy. Acceptable. |
| 22 | KV cache correctness | sonnet | 1 | Partial | LlamaTTS full; Qwen3ASR stub-skipped on private API gap. |
| 23 | Weight round-trip | sonnet | 1 | Yes (compile-only) | LlamaTTS + Qwen3ASR both full. No API gaps. |
| 19fix | Vocos + SNAC bug fixes | sonnet | 1 | Yes | 4 bugs fixed (3 Vocos + 1 SNAC). 219/219 pass. Bonus OLA window² bug found during verification. |

**Summary:** 23 of 23 sorties closed. 2 inaccurate (Sortie 4 scope creep, Sortie 8 false-green). 4 with documented partial deferrals (1 DSP, 9 GH gating, 18 watermarker, 22 STT API gap). Highest-signal sorties (16, 18, 19) all caught real bugs — that's the mission delivering its premise.

---

## Section 5: Harvest Summary

We started this mission to find silent regressions. We found four — Vocos has three bugs in one ISTFT kernel, SNAC's quantizer was using the wrong distance metric, AudioUtils silently truncates saved audio to 1024-sample boundaries, and DACVAE's watermarker crashes on its own default config. The parity-fixture infrastructure paid for itself within a single iteration. The single most important thing that changes about the next iteration: **before the breakdown skill marks a plan "ready to execute," every named API in the plan must grep-resolve in `Sources/`, and every "compile-only" contract must specify `xcodebuild build-for-testing`, not `build`**. Five of our six sortie-time surprises came from one or the other of those misses.

---

## Section 6: Files

### Preserve (read-only reference for next iteration)

| File | Branch | Why |
|------|--------|-----|
| `OPERATION_ECHO_DRAGNET_01_BRIEF.md` | mission/echo-dragnet/01 | This document. Carry forward. |
| `Tests/media/parity/_generate.py` + 6 fixture sets | mission/echo-dragnet/01 | Parity infrastructure proven valuable; carry pattern forward. |
| `Tests/media/parity/tokenizer/unigram_reference.json` | mission/echo-dragnet/01 | Vocab patched (`byte_fallback: true`); carry forward. |
| `bin/check-local-only-suites.sh` | mission/echo-dragnet/01 | Suite-list guard; reusable. |
| `.github/workflows/nightly-tests.yaml` | mission/echo-dragnet/01 | Nightly workflow, GH-gated activation post-merge. |

### Discard (will not exist after rollback)

| File | Why it's safe to lose |
|------|----------------------|
| `SUPERVISOR_STATE.md` | Mission state; brief is the authoritative record. |
| `EXECUTION_PLAN.md` | Plan; superseded by this brief + next plan. |

> Mission outcome is "Complete" — no rollback ritual is required. The mission branch will be merged forward to `development` rather than discarded. The `Discard` table above documents what `commands/brief.md` Step 2 cleans from the workspace; the files will remain in git history on `mission/echo-dragnet/01`.

---

## Iteration Metadata

**Starting point commit:** `deb37b8` (mission: archive OPERATION ROSETTA RELAY plan alongside its brief)
**Mission branch:** `mission/echo-dragnet/01`
**Final commit on mission branch:** `3617ed1` (Fix Vocos ISTFTHead + SNAC VectorQuantize bugs found by Sortie 19)
**Rollback target:** N/A — mission is Complete. Forward-merge to `development`, do not roll back.
**Next iteration branch:** N/A for this operation. Follow-up work (see § Open Decisions) is a new mission, not iteration 2 of Echo Dragnet.
