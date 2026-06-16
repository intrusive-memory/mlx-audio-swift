---
feature_name: OPERATION SEAMSTRESS BELLOWS
starting_point_commit: 7f6493b371107ed78bba20c1756c7dd357c95b4d
mission_branch: mission/seamstress-bellows/01
iteration: 1
state: completed
---

# EXECUTION_PLAN.md — Qwen3-TTS "breath" phrasing seams

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Summary

Add **silent breath seams** to the Qwen3-TTS generation pipeline, faithfully
implementing the glosa-av `<breath/>` semantic: a silent phrasing hint that
splits a long line into re-seeded sub-utterances to stop ICL-cloned voices from
drifting in cadence/pitch. The caller passes **unicode-scalar offsets** (not
inline markers). No model, weight, config, tokenizer, or codec changes.

**Source**: `REQUIREMENTS.md`
**Branch policy**: branch from and commit to `development`; PR `development` → `main`.
**Build/test**: `xcodebuild -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`, preferring `make` targets. Never `swift build` / `swift test`.

### Verified anchor points (against current code)

- Public entry point `generate(...)` at `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:504`.
- Private `_generateImpl(...)` at `Qwen3TTS.swift:566` resolves one of four paths and returns a 1-D `MLXArray` (`audio.dim(0)` = sample count).
- Two call sites of `_generateImpl` inside `generate` (telemetry-wrapped path under `MLXAUDIO_TELEMETRY_FULL` + plain path).
- `concatenated(_:axis:)` is the in-repo MLX concatenation API (e.g. `Qwen3TTSSpeechDecoder.swift:706`).
- Test target `MLXAudioTests` has `path: "Tests"` (flat layout). New suites are top-level files under `Tests/`. Newer suites use swift-testing (`import Testing`) with `@testable import MLXAudioTTS`. Local-only suites carry a "LOCAL-ONLY" header banner and are excluded from the CI-safe `-only-testing` block (see `DeterministicGenerationTests.swift`).

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| Qwen3TTS Breath Seams | `.` (Sources/MLXAudioTTS + Tests) | 5 | 0 | none |

Single-project plan — one work unit spanning the Qwen3TTS source module and the test target.

---

### Sortie 1: Pure split/concat helpers (FR3)

**Priority**: 16.5 — foundational. Dependency depth 4 (blocks 2, 3, 4, 5); establishes the `splitTextAtBreaths`/`concatenateChunks` helpers reused by every downstream sortie. Must execute first. **Supervising agent only** (build gate).

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:
1. Create new file `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSBreath.swift`.
2. Implement `splitTextAtBreaths(_ text: String, offsets: [Int]) -> [String]`: splits `text` at **unicode-scalar** offsets; sorts and de-duplicates offsets; clamps/ignores out-of-range offsets (`< 0` or `> text.unicodeScalars.count`); drops empty segments so offset `0` and offset `== end` produce no spurious leading/trailing empty chunk; pure, deterministic, side-effect free.
3. Implement `concatenateChunks(_ chunks: [MLXArray]) -> MLXArray`: concatenates 1-D waveforms along axis 0 via `concatenated(_:axis:)`; single-chunk case returns that chunk; empty case returns a defined empty 1-D `MLXArray`.
4. Match the visibility/namespacing idiom of neighboring helper files in the directory so both functions are reachable from tests via `@testable import MLXAudioTTS`.

**Exit criteria**:
- [ ] `grep -n "func splitTextAtBreaths" Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSBreath.swift` matches the signature `splitTextAtBreaths(_ text: String, offsets: [Int]) -> [String]`.
- [ ] `grep -n "func concatenateChunks" Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSBreath.swift` matches `concatenateChunks(_ chunks: [MLXArray]) -> MLXArray`.
- [ ] Build succeeds: `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- [ ] `git diff --name-only` shows the only added/changed source file is `Qwen3TTSBreath.swift` (no model/weight/config/tokenizer/codec files touched).

---

### Sortie 2: CI-safe unit tests for the splitter (TR1)

**Priority**: 4.5 — dependency depth 1 (blocks 5); locks the splitter contract before the audio path leans on it. Parallel-layer member (depends only on Sortie 1). **Supervising agent only** (test gate). Dispatch after Sortie 3 within the layer if contending for the supervisor.

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (`Qwen3TTSBreath.swift` exists and builds).

**Tasks**:
1. Create `Tests/Qwen3TTSBreathSplitTests.swift` — suite `Qwen3TTSBreathSplitTests`, swift-testing (`import Testing`), `@testable import MLXAudioTTS`.
2. Cover every TR1 case: empty offsets → single segment equal to input; unsorted offsets → same result as sorted; duplicate offsets → de-duplicated, no empty segments leak; out-of-range offsets (negative, `> length`) → ignored/clamped; offset at `0` and at end → no spurious empty chunks; multibyte/emoji/combining-mark boundaries split on scalar counts (assert parity with `unicodeScalars.count`); round-trip — concatenating N split segments reconstructs the original `text`.
3. Register `Qwen3TTSBreathSplitTests` in the CI-safe `-only-testing` block in `CLAUDE.md`.

**Exit criteria**:
- [ ] `Tests/Qwen3TTSBreathSplitTests.swift` exists; `grep -c "@Test" Tests/Qwen3TTSBreathSplitTests.swift` ≥ 7 (one per TR1 case).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/Qwen3TTSBreathSplitTests CODE_SIGNING_ALLOWED=NO` passes.
- [ ] `grep -n "Qwen3TTSBreathSplitTests" CLAUDE.md` shows it inside the CI-safe `-only-testing` list.

---

### Sortie 3: Public API + orchestration refactor (FR1 + FR2)

**Priority**: 8 — highest of the parallel layer. Dependency depth 1 (blocks 5); foundation (defines the public `generate(..., breathOffsets:)` API surface) and carries the only behavior-changing refactor (rename + orchestrator) with full-regression risk. Dispatch first within the {2, 3, 4} layer. **Supervising agent only** (build + full CI-safe test gate).

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (`splitTextAtBreaths` / `concatenateChunks` available).

**Tasks**:
1. In `Qwen3TTS.swift`, rename the existing private `_generateImpl` (≈ line 566) to `_generateSingle` with its **body unchanged** (still resolves the path and returns one waveform).
2. Add a new `_generateImpl` orchestrator: when `breathOffsets` is empty → call `_generateSingle` exactly once with the same args (today's behavior, no added work); otherwise → sort, de-duplicate, and clamp offsets, call `splitTextAtBreaths`, call `_generateSingle` once per **non-empty** segment passing **identical** `voice / refAudio / refText / language / instruct / generationParameters`, then `concatenateChunks` the per-segment waveforms.
3. Add `breathOffsets: [Int] = []` to the public `generate` signature (positioned between `instruct` and `generationParameters` per FR1), thread it into **both** `_generateImpl` call sites inside `generate` (telemetry-wrapped and plain), and add a doc-comment describing it as unicode-scalar indices into `text`.
4. Keep `generate`-level telemetry as one start/complete for the whole utterance (no per-chunk telemetry required).

**Exit criteria**:
- [ ] `grep -n "func _generateSingle" Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` matches; `grep -n "func _generateImpl" Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` matches the new orchestrator.
- [ ] `grep -n "breathOffsets: \[Int\] = \[\]" Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` matches in the public `generate` signature.
- [ ] Build succeeds: `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` (proves existing call sites compile unchanged — source-compatible).
- [ ] The full CI-safe `xcodebuild test` block in `CLAUDE.md` passes (no regression to the empty-`breathOffsets` path).

---

### Sortie 4: Optional default-off crossfade seam scaffold (FR4)

**Priority**: 1.5 — lowest. Dependency depth 0 (blocks nothing); default-off scaffold with no behavioral change. Can slot anywhere after Sortie 1; deprioritized within the parallel layer. **Supervising agent only** (build gate).

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (`Qwen3TTSBreath.swift` exists).

**Tasks**:
1. In `Qwen3TTSBreath.swift`, add a named, **default-off** constant (e.g. `let breathSeamCrossfadeEnabled = false`) and an equal-power crossfade-of-a-few-ms helper that is invoked **only** when the constant is true.
2. Keep the default seam path as **direct concatenation** (glosa-av = ~0 silence) — `concatenateChunks` behavior is unchanged when the flag is off.
3. Add a code comment stating the crossfade must be verified against real audio (A/B listen) before being enabled by default, and must not be enabled by default in this mission.

**Exit criteria**:
- [ ] `grep -n "breathSeamCrossfadeEnabled" Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSBreath.swift` shows the constant initialized to `false`, and grep shows an equal-power crossfade function in the same file.
- [ ] Build succeeds: `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- [ ] The full CI-safe `xcodebuild test` block in `CLAUDE.md` passes (flag off ⇒ no behavioral change).

---

### Sortie 5: Local-only audio test + docs (TR2)

**Priority**: 2.5 — terminal sortie. Dependency depth 0; joins the critical path as the integration check (model-download risk 2). Must run last — depends on both Sortie 2 and Sortie 3. **Supervising agent only** (build-for-testing gate).

**Entry criteria**:
- [ ] Sortie 2 exit criteria met (splitter tested).
- [ ] Sortie 3 exit criteria met (`breathOffsets` wired through `generate`).

**Tasks**:
1. Create `Tests/Qwen3TTSBreathGenerateTests.swift` — suite `Qwen3TTSBreathGenerateTests`, gated identically to the other model-download suites (LOCAL-ONLY header banner + the same nightly/skip gate used by `DeterministicGenerationTests`), `@testable import MLXAudioTTS`.
2. Test A: `generate(..., breathOffsets:)` returns a waveform whose total sample count is approximately the sum of the per-chunk sample counts (assert within a documented tolerance).
3. Test B: the empty-`breathOffsets` path is byte-identical to calling `generate` without the parameter — use deterministic generation settings (greedy / temperature 0 or a fixed MLX random seed, matching how `DeterministicGenerationTests` achieves reproducibility).
4. Register `Qwen3TTSBreathGenerateTests` in the **local-only** table in `CLAUDE.md` (NOT the CI-safe `-only-testing` list) and add a short description of the `breathOffsets` parameter to `CLAUDE.md`/docs.

**Exit criteria**:
- [ ] `Tests/Qwen3TTSBreathGenerateTests.swift` exists with two `@Test` functions (sample-count-sum and byte-identical empty path).
- [ ] `Qwen3TTSBreathGenerateTests` does **not** appear in the CI-safe `-only-testing` block: `grep -c "Qwen3TTSBreathGenerateTests" CLAUDE.md` shows it only in the local-only table.
- [ ] `xcodebuild build-for-testing -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` exits 0 (suite compiles in CI without running).
- [ ] `grep -n "breathOffsets" CLAUDE.md` shows the parameter is documented.

---

## Parallelism Structure

**Critical Path**: Sortie 1 → Sortie 3 → Sortie 5 (length: 3 sorties). A second chain Sortie 1 → Sortie 2 → Sortie 5 is equal length; both feed Sortie 5.

**Parallel Execution Groups**:
- **Group 1** (foundation — must complete first):
  - Sortie 1 (Qwen3TTSBreath.swift) — **SUPERVISING AGENT ONLY** (build gate)
- **Group 2** (depends on Group 1; the {2, 3, 4} cluster — independent of each other):
  - Sortie 3: API + orchestration refactor — **SUPERVISING AGENT ONLY** (build + full test gate) — dispatch first (priority 8)
  - Sortie 2: CI-safe splitter tests — **SUPERVISING AGENT ONLY** (test gate)
  - Sortie 4: crossfade scaffold — **SUPERVISING AGENT ONLY** (build gate)
- **Group 3** (depends on Sortie 2 AND Sortie 3):
  - Sortie 5: local-only audio test + docs — **SUPERVISING AGENT ONLY** (build-for-testing gate)

**Agent Constraints**:
- **Supervising agent**: Handles **all five sorties** — every sortie's exit criteria are build/compile/test gated, and only the supervising agent may build. This plan is effectively build-serialized.
- **Sub-agents (up to 4)**: The {2, 3, 4} cluster could have its *file authoring* fanned out to sub-agents (write the test suite, write the scaffold, edit `Qwen3TTS.swift`) with **no build operations**, but each sortie's verification (build/test) must funnel back through the supervising agent. Given the small per-sortie size (~11–14 turns), the coordination overhead likely outweighs the gain; recommend the supervisor execute Group 2 sequentially in priority order (3 → 2 → 4) unless contention warrants fan-out.

**Parallelism summary**: Maximum *authoring* parallelism in Group 2 is 3 sub-agents; effective *verified* parallelism is 1 (build gate). Critical path 3 sorties; wall-clock ≈ 5 sequential supervisor sorties.

---

## Open Questions

<!-- Consumed by Pass 1 of refine (`refine-blockers`). Each entry MUST be resolved before refinement can proceed past Pass 1. -->

_No blocking open questions identified during breakdown._

The requirements document is unusually complete: its "Decisions already made (do not re-litigate)" section resolves every choice that would normally block a sortie — the seam semantic (silent chunk-seam, ~0 audible silence), the API surface (caller passes offsets, no in-text parser), the offset units (unicode-scalar indices matching glosa-av's `unicodeScalars.count`), and the absence of a `strength` parameter. FR4's crossfade is explicitly deferred and default-off, so it does not block. The one non-blocking detail (deterministic settings needed for TR2's byte-identical assertion) is captured as a task constraint in Sortie 5 and is satisfiable with the repo's existing seeded-determinism approach (`DeterministicGenerationTests`); it is a test-implementation detail, not a foundational decision.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 5 |
| Open questions | 0 |
| Dependency structure | layered (Sortie 1 → {2, 3, 4} → 5) |
| Critical path | 3 sorties (1 → 3 → 5) |
| Dispatch order | 1, then 3 → 2 → 4 (by priority), then 5 |
| Max sub-agent parallelism | 3 (authoring only — all builds funnel to the supervising agent) |
| Context budget | 50 turns/sortie (all sorties right-sized, ~11–15 est.) |
