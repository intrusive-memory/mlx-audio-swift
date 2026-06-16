---
feature_name: OPERATION SEAMSTRESS BELLOWS
iteration: 1
state: completed
---

# Iteration 01 Brief — OPERATION SEAMSTRESS BELLOWS

**Mission:** Add silent breath seams to the Qwen3-TTS pipeline — caller-supplied unicode-scalar offsets split a line into re-seeded sub-utterances whose waveforms are concatenated, with no model/weight/config/tokenizer/codec changes.
**Branch:** mission/seamstress-bellows/01
**Starting Point Commit:** 7f6493b
**Sorties Planned:** 5
**Sorties Completed:** 5
**Sorties Failed/Blocked:** 0
**Duration:** ~21 min active agent time; 61× relative cost (opus×1, sonnet×3, haiku×1)
**Outcome:** Complete
**Verdict:** `KEEP` — clean execution: 5/5 sorties first-attempt, source-compatible API, empty-path regression proven, zero CI-unsafe tests added.
**Tests pruned:** 0
**Tests flagged for review:** 0

---

## Section 1: Hard Discoveries

### 1. `Qwen3TTSModel.generate` cannot gain a parameter without breaking a protocol conformance
**What happened:** The plan said "add `breathOffsets` to the public `generate` signature." But `generate(...)` fulfills the `SpeechGenerationModel` protocol requirement, whose signature has no `breathOffsets`. Adding the parameter in place would either break protocol conformance or force the same parameter onto every other conformer (LlamaTTS, SopranoTTS, PocketTTS, Marvis…).
**What was built to handle it:** Sortie 3 kept the protocol-conforming `generate(...)` intact (now a thin delegate calling the new overload with `breathOffsets: []`) and added a NEW overload `generate(text:voice:refAudio:refText:language:instruct:breathOffsets:generationParameters:)` on `Qwen3TTSModel` directly. The grep exit criterion (`breathOffsets: [Int] = []`) still matches, and existing callers compile unchanged.
**Should we have known this?** Yes — a quick check of `SpeechGenerationModel` before planning would have revealed it. The plan assumed a free-standing public method.
**Carry forward:** When threading a new parameter through a method that satisfies a shared protocol, plan for an overload (or a protocol-extension default) up front rather than an in-place signature edit.

### 2. The full CI-safe test suite cannot run green on this dev machine (pre-existing App Group gap)
**What happened:** Sortie 3's exit criterion required "the full CI-safe `xcodebuild test` block passes." Locally it returns `** TEST FAILED **` because storage-backed suites hit `Fatal error: SwiftAcervo: no App Group identifier configured` (plus a SNAC MLX empty-tensor crash). This is documented in AGENTS.md § App Group configuration but is easy to mistake for a regression.
**What was built to handle it:** The supervisor did not trust the agent's "pre-existing" claim — it `git stash`ed the change and re-ran the failing suites on the clean tree, reproducing the identical failures without the change. That proved zero regressions. The empty-`breathOffsets` path is a single `_generateSingle` call, byte-identical to the original `_generateImpl`.
**Should we have known this?** Partially — the App Group requirement is documented, but the plan's exit criterion ("full CI-safe block passes") is not locally satisfiable here. The criterion implicitly assumes a CI environment.
**Carry forward:** For build/test-gated sorties on this repo, the local verification of record is (a) build succeeds, (b) the change-relevant pure suite passes, and (c) clean-tree regression parity. Full-green is a CI/PR gate, not a local one. State this in future plans so agents don't spin against the App Group wall.

## Section 2: Process Discoveries

#### What the Agents Did Right
### 1. Faithful, minimal, behavior-preserving refactor
**What happened:** Sortie 3 renamed `_generateImpl` → `_generateSingle` (body untouched) and added a thin orchestrator; the empty-offsets branch is a single delegated call. Telemetry stayed one start/complete for the whole utterance.
**Right or wrong?** Right. The smallest possible diff (67 insertions, 1 deletion, one file) that satisfies FR1+FR2 and guarantees the no-op path is unchanged.
**Evidence:** `git diff --stat` = 1 file; clean-tree parity proved no behavioral change.
**Carry forward:** "Rename-then-wrap" is the correct shape for adding an optional orchestration layer over an existing impl.

#### What the Agents Did Wrong
### 2. Nothing material
**What happened:** No wasted files, no reverted commits, no over-engineering. The dormant crossfade scaffold (Sortie 4) is the only unused code, and it was explicitly required by FR4 (default-off, A/B-gated).
**Right or wrong?** Right. The scaffold is intentional dead-but-documented code, not waste.
**Evidence:** Every committed file survives into final state; 0 deletions in test-cleanup.
**Carry forward:** —

#### What the Planner Did Wrong
### 3. Two exit criteria were not locally satisfiable as written
**What happened:** (a) "Add `breathOffsets` to the public `generate` signature" collided with protocol conformance (Discovery 1); (b) "full CI-safe block passes" is not locally green here (Discovery 2). Both were navigable, but the agent had to adapt.
**Right or wrong?** Minor planner miss. The plan was otherwise unusually complete and correctly sequenced.
**Evidence:** Sortie 3 produced an overload instead of an in-place edit; the supervisor had to substitute clean-tree parity for the literal "full suite passes."
**Carry forward:** Pre-flight a one-line check of the protocol surface and the local test baseline during `breakdown`/`refine` so exit criteria are locally machine-verifiable.

## Section 3: Open Decisions

### 1. Confirm the full CI-safe suite is green on the PR
**Why it matters:** Local runs can't clear the App Group wall; the regression guarantee rests on clean-tree parity, not a green full run.
**Options:** (A) Open the `development → main`-bound PR and let CI run the CI-safe block; (B) configure the App Group locally and run it here.
**Recommendation:** A. CI is the repo's primary gate and configures the App Group. Confirm the `Qwen3TTSBreathSplitTests` suite shows up and the suite is green before merge.

### 2. Crossfade seam: enable or leave dormant?
**Why it matters:** FR4's equal-power crossfade is scaffolded but `breathSeamCrossfadeEnabled = false`. glosa-av semantics = ~0 silence (direct concat), so default-off is correct for now.
**Options:** (A) Leave dormant until an A/B listen justifies it; (B) wire a runtime/config toggle.
**Recommendation:** A. Do not enable without real-audio A/B verification, exactly as the plan and the in-code comment require.

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Split/concat helpers (FR3) | opus | 1/3 | ✓ | Foundation; survived unchanged into final state. Opus arguably oversized for ~1 min of well-specified work, but it's the dependency root — justified. |
| 3 | Public API + orchestrator (FR1+FR2) | sonnet | 1/3 | ✓ | The one behavior-changing sortie; adapted to a protocol-safe overload. Longest (~12 min) due to the full-suite gate + regression check. |
| 2 | CI-safe splitter tests (TR1) | sonnet | 1/3 | ✓ | 7 pure tests incl. emoji/ZWJ/combining; genuinely green locally. Sonnet (over haiku) paid off on unicode-scalar correctness. |
| 4 | Crossfade scaffold (FR4) | haiku | 1/3 | ✓ | Dormant, `concatenateChunks` untouched. Haiku correct for mechanical scaffold. |
| 5 | Local-only test + docs (TR2) | sonnet | 1/3 | ✓ | Mirrored DeterministicGenerationTests gating; compile-only CI contract satisfied. |

## Section 5: Harvest Summary

The mission landed clean: a source-compatible breath-seam API, a regression-proven no-op path, pure CI tests, a dormant FR4 scaffold, and docs — five first-attempt sorties, no retries, no rollback signals. The single most important thing learned for next time: **on this repo, "the full CI-safe suite passes" is a CI/PR gate, not a local one** (App Group fatal blocks storage-backed suites locally), so local verification of build/test-gated sorties should be specified as build + change-relevant pure suite + clean-tree regression parity. Test-cleanup pruned nothing — the two added suites were correctly CI-safe / intentionally local-only-with-graceful-skip, indicating the planner's test gating was sound.

## Section 6: Files

**Preserve (read-only reference for next iteration):**
| File | Branch | Why |
|------|--------|-----|
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSBreath.swift` | mission/seamstress-bellows/01 | The FR3 helpers + FR4 dormant scaffold; the seam machinery. |
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` | mission/seamstress-bellows/01 | The public `breathOffsets` overload + orchestrator. |
| `Tests/Qwen3TTSBreathSplitTests.swift` | mission/seamstress-bellows/01 | CI-safe splitter contract lock. |
| `Tests/Qwen3TTSBreathGenerateTests.swift` | mission/seamstress-bellows/01 | Local-only/nightly audio-path test. |

**Discard (will not exist after rollback):**
| File | Why it's safe to lose |
|------|----------------------|
| _(none — verdict is KEEP; nothing to discard)_ | — |

## Iteration Metadata

**Starting point commit:** `7f6493b` (Add gated [lang] visibility at the codec-prefill language boundary)
**Mission branch:** `mission/seamstress-bellows/01`
**Final commit on mission branch:** `6d5b1da`
**Rollback target:** `7f6493b` (same as starting point commit)
**Next iteration branch (if ever needed):** `mission/seamstress-bellows/02`

## Rollback Verdict

**Verdict:** `KEEP`

**Reasoning:** All 5 work-unit sorties COMPLETED on first attempt with zero BACKOFF/FATAL (Section 4). The only behavior-changing sortie (3) is a minimal, source-compatible overload whose no-op path was proven byte-identical via clean-tree regression parity (Section 1.2). Test-cleanup removed 0 of 2 added tests — both are correctly gated (Section 5). The two planner misses (Section 2.3) were navigable in-mission, not foundational errors. This matches the `KEEP` signal row exactly: all complete, low retry, ≤1 genuinely-new hard discovery, <10% tests pruned.

**Recommended action:**
- **KEEP** — Merge the mission branch via the repo's `development → main` PR flow. Follow-ups (not blockers):
  1. Open the PR and confirm the full CI-safe block (now including `Qwen3TTSBreathSplitTests`) is green in CI — the one gate not runnable locally (Open Decision 1).
  2. Leave the FR4 crossfade dormant until a real-audio A/B listen justifies enabling it (Open Decision 2).
