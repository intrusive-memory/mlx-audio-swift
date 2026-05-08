# Iteration 01 Brief — OPERATION SILENT STETHOSCOPE

**Mission:** Implement the vendor-neutral `MLXAudioTelemetryEvent` + `MLXAudioTelemetryReporter` surface across `mlx-audio-swift` (codecs, TTS, STT, audio I/O, memory) without adding dependencies and without breaking the silent default.
**Branch:** `mission/silent-stethoscope/01`
**Starting Point Commit:** `802006722f1698f0c41997e1812b5eee2a2dbb12`
**Sorties Planned:** 19
**Sorties Completed:** 19
**Sorties Failed/Blocked:** 0
**Duration:** Single agentic cycle (one wave-graph traversal). 19 commits, all on `mission/silent-stethoscope/01`. ~10,369 insertions / 259 deletions across 41 files.
**Outcome:** Complete
**Verdict:** Keep the code. Carry the open decisions (emission-pattern unification, unload telemetry, STT phase vocabulary) forward into a follow-up mission, not a rollback.

---

## 1. Hard Discoveries

### 1. AudioModelManager / WiredMemoryManager are `public enum`, not `actor`

**What happened:** EXECUTION_PLAN.md Sortie 2 (and by inheritance Sortie 5) prescribed `Add private var telemetry … to the AudioModelManager actor`. Both `AudioModelManager` and `WiredMemoryManager` are `public enum` namespaces with static-only members. Stored properties cannot live on enums. There is also no instance to attach `setTelemetry` to.
**What was built to handle it:** Each got a file-private actor wrapper — `_AudioModelManagerTelemetryStorage` (Sortie 2, commit `57e008f`) and `_WiredMemoryManagerTelemetryStorage` (Sortie 5, commit `e7025f2`). The public surface is a static `setTelemetry(_:)` plus a static `await emit(_:)` that proxies into the actor. Sortie 17 (`AudioPlayerManager`) is `@MainActor public class` and used the canonical instance pattern directly.
**Should we have known this?** Yes. A 30-second `grep -n "public enum\|public class\|public actor" Sources/MLXAudioCore/AudioModelManager.swift Sources/MLXAudioCore/WiredMemoryManager.swift Sources/MLXAudioCore/AudioPlayerManager.swift` during breakdown would have surfaced the three different shapes and forced the plan to be precise.
**Carry forward:** **Inspect the actual declaration kind of every target class before writing instrumentation tasks.** The canonical `setTelemetry` snippet has three variants, not one: instance (actor/class), static-namespace (enum), and `@MainActor` class. The reporter doc-comment in `MLXAudioTelemetryReporter.swift` should document all three.

### 2. Vocos has no encode path

**What happened:** Sortie 6 prescribed `codecEncodeStart/Complete` + `codecDecodeStart/Complete` with a `compressionRatio = inputBytes / outputBytes`. Vocos is a synthesis-only vocoder (mel → audio). There is no encode method to wrap; `compressionRatio` is undefined for a one-way decoder.
**What was built to handle it:** Decode-only emission (commit `a82b41f`). The async-overload pattern (see process discovery #1) was set here.
**Should we have known this?** Yes. One sentence of upstream README would have answered this. The plan generalized "codec = encode+decode" without checking each codec.
**Carry forward:** Per-codec entry in EXECUTION_PLAN.md must list which directions exist (encode-only, decode-only, both). Vocos = decode-only, others = both.

### 3. Hot-loop guard naive grep matches English in comments

**What happened:** The Sortie 19 cross-cutting check (`grep '(for |while )' … | grep 'await emit('`) returned false positives — line comments containing the English words "for" and "while" matched. Example: `// emit once for the entire batch` followed two lines later by `await emit(...)`.
**What was built to handle it:** `HotLoopGuardTests` strips line comments (`sed 's://.*$::'`) before the grep pipeline. The original supervisor-supplied grep is preserved verbatim in the EXECUTION_PLAN.md exit criterion (for traceability), but the test uses the refined pipeline. Documented in `docs/TELEMETRY.md` (Sortie 19, commit `520ce0c`).
**Should we have known this?** Partially. Anyone who has written a grep-based lint check has hit this before. Worth flagging in the breakdown's "naive lints lie" checklist.
**Carry forward:** Any grep-based exit criterion that touches Swift source needs to strip line comments first. Add this as a refine-questions checklist item.

### 4. Marvis pipes through Mimi — codec events have one owner

**What happened:** Marvis TTS (`MarvisTTSModel`) does not run its own codec; it calls `_audio_tokenizer.codec.encodeStep` and `_streamingDecoder.decodeFrames`, which are Mimi entry points. If Marvis instrumented codec events, every Marvis generation would double-emit (once at the Marvis layer, once at the Mimi layer).
**What was built to handle it:** Sortie 11 (Marvis, commit `5ca156e`) emits zero `codec*` events. Sortie 15 (Mimi, commit `7d99163`) wires the async-overload codec events at the Mimi method boundary, which is the natural ownership layer.
**Should we have known this?** Yes — call-graph inspection. The plan treated Marvis and Mimi as independent sorties; in reality there is a containment relationship.
**Carry forward:** Document codec ownership explicitly in the plan: "If TTS model X embeds codec Y, codec events are emitted by Y, not X." Generalizes to: every shared subcomponent has exactly one emission owner.

### 5. PocketTTS flow-matching has no fraction signal

**What happened:** Sortie 10 prescribed `ttsGenerationProgress` "at fraction-complete checkpoints." PocketTTS's generation is a flow-matching ODE solver; there is no monotonic step-count or token-count to derive a fraction from.
**What was built to handle it:** `ttsGenerationProgress` was omitted entirely. The omission is documented inline in the source and in the brief paragraph attached to commit `fb1ba13`. Soprano (Sortie 8), Qwen3TTS (Sortie 3), Llama (Sortie 9), Marvis (Sortie 11) all emit `ttsGenerationProgress` once with `fractionComplete: 1.0` after the inner loop drains. PocketTTS emits nothing.
**Should we have known this?** Yes. Sortie 10's task description even acknowledges flow-matching has no discrete tokens, but still asked for a fraction. The plan should have just said "no progress event."
**Carry forward:** When a sortie's task description hedges ("…or omit if no natural signal"), pre-decide which side of the fork applies. Hedges in plans become inconsistencies in code.

### 6. STT throw-site phase strings are per-model, not standardized

**What happened:** Sortie 4 (GLM-ASR, commit `3f9a1fb`) used three phase strings on `sttTranscriptionError`: `"tokenizer"`, `"feature_extraction"`, `"decode"`. Sortie 12 (Qwen3-ASR, commit `57b57d9`) added a fourth, `"audio_chunking"`, because Qwen3-ASR runs `SplitAudioIntoChunks` before the encoder.
**What was built to handle it:** Each model declares its own phase strings; the API contract is "phase is a free-form string describing where the throw originated." This works for two STT models. It will not scale to N models without a shared vocabulary.
**Should we have known this?** No — the asymmetric Qwen3-ASR audio-chunking step was not visible until the code was open. This is a genuine emergent constraint.
**Carry forward:** If a third STT model is added, lift `phase` to a `enum SttPhase` (still free-string-compatible via a `.custom(String)` case). For now, document the existing four phases in `docs/TELEMETRY.md` § STT.

---

## 2. Process Discoveries

### What the Agents Did Right

#### 1. Codec async-overload pattern (Sorties 6, 13, 14, 15, 16)

**What happened:** Vocos (Sortie 6) introduced a clean pattern: keep the existing synchronous `decode(_:)` method untouched; add a new `decode(_:telemetry:)` async overload that emits at the boundaries. The four follow-on codec sorties (Encodec, SNAC, Mimi, DACVAE) all converged on this without prompting.
**Right or wrong?** Right. Zero churn for sync callers; opt-in async path for instrumented callers; emission at the public boundary. The pattern propagated cleanly because Sortie 6 set the precedent and the dispatch order put it before its peers.
**Evidence:** Five codecs, five matching commits (`a82b41f`, `b5b20ef`, `24563fe`, `7d99163`, `2e7fe6d`), all using the same overload shape. No reverts or rework.
**Carry forward:** Pattern-setter + follow-on dispatch order is worth preserving for any cross-cutting concern. When N sorties share a problem shape, run the most representative one first and let it normalize the pattern.

#### 2. 4-agent parallelism cap

**What happened:** Wave 1 dispatched Sorties 2/3/4/6 concurrently; Wave 2 added 5/7/8/9; etc. Cap held. No agent stepped on another's file (each sortie owned a distinct directory or file).
**Right or wrong?** Right. The plan's work-unit decomposition was orthogonal enough that 4-way concurrency had zero merge conflicts.
**Evidence:** Linear commit history (no merge commits inside the mission); 19 commits in dependency-respecting order; full CI-safe suite green at the final gate.
**Carry forward:** Keep the 4-agent cap and keep the work-unit-per-directory invariant. The two together prevent the merge hell that breaks parallel sortie missions.

#### 3. MockMLXAudioTelemetryReporter as test-target shared infra

**What happened:** Sortie 1 added a single `MockMLXAudioTelemetryReporter` actor in `Tests/MLXAudioTests/Telemetry/`. Every subsequent telemetry test imported and used it. No duplicated mock, no per-suite reinvention.
**Right or wrong?** Right. Saved an estimated 18× of mock-writing busywork.
**Evidence:** `grep -l MockMLXAudioTelemetryReporter Tests/MLXAudioTests/Telemetry/*.swift` matches every telemetry test file.
**Carry forward:** Whenever foundation establishes a test contract, make the shared test double a Sortie 1 deliverable, not a per-sortie chore.

### What the Agents Did Wrong

#### 4. Two divergent sync-path emission patterns

**What happened:** Sorties 4 (GLM-ASR), 7 (AudioUtils), 12 (Qwen3-ASR) emit from synchronous methods using `Task { [weak self] in await self?.emit(...) }` (fire-and-forget). Sorties 6, 13, 14, 15, 16 (codecs) introduce a new `async` overload of the public method and emit inline. The codec pattern is cleaner; the STT/AudioUtils pattern is racy (emission may complete after the next caller starts).
**Right or wrong?** Wrong, in the sense that two patterns now exist for the same problem. Each sortie chose locally rationally — STT/AudioUtils have many existing sync call sites, async-overload would fork the API. But the divergence shipped without a planning decision.
**Evidence:** Carry-over #3 in `SUPERVISOR_STATE.md`. `grep -A2 "Task {" Sources/MLXAudioCore/AudioUtils.swift Sources/MLXAudioSTT/Models/*/*.swift` shows fire-and-forget; `grep -A2 "func .*async.*telemetry:" Sources/MLXAudioCodecs/*/*.swift` shows async overloads.
**Carry forward:** Refine pass should add a "cross-sortie pattern reconciliation" check. Whenever ≥2 sorties solve the same shape, pre-decide the pattern in the plan so divergence is impossible.

#### 5. Sortie 2 silently skipped the unload path

**What happened:** Sortie 2's task list said "Wire `modelUnloadStart` / `modelUnloadComplete` around the unload path." `AudioModelManager` has no public unload entry point. Sortie 2 elided those events and noted "follow-up needed." The note lives in `SUPERVISOR_STATE.md` carry-over #2, not in the code.
**Right or wrong?** Wrong to skip silently. The right call would have been to escalate: either (a) add a public unload entry point to AudioModelManager (out of scope), or (b) explicitly mark `modelUnload*` as deferred in the plan and remove them from Sortie 2's exit criteria.
**Evidence:** No `modelUnload` emissions in `Sources/MLXAudioCore/AudioModelManager.swift`. No corresponding test. No row in `EXECUTION_PLAN.md` saying "unload deferred."
**Carry forward:** Sub-agents must not silently descope. If a task line cannot be executed as written, the sortie reports BLOCKED and the supervising agent decides — descope, defer, or re-scope. Add this to the agent dispatch prompt template.

### What the Planner Did Wrong

#### 6. Generalized "actor" assumption across three different class shapes

**What happened:** The plan assumed `AudioModelManager`, `WiredMemoryManager`, and `AudioPlayerManager` were all actors. None of them are; the three have three different shapes (enum, enum, MainActor class). Hard discovery #1 covers the workaround.
**Right or wrong?** Wrong. A 30-second declaration check during breakdown would have produced three correctly-typed sortie templates.
**Evidence:** Carry-over #1 in `SUPERVISOR_STATE.md`. Two file-private storage actors had to be invented mid-flight to bridge the gap.
**Carry forward:** Add to `commands/breakdown.md` an explicit step: "For each target type referenced in the plan, run `grep -n 'public (enum|class|actor|struct)' <file>` and record the actual kind in the work-unit table." This is cheap and prevents Hard Discovery #1 from recurring.

#### 7. Hedging language inside task descriptions

**What happened:** Sortie 10's task 3 read: "PocketTTS uses flow matching… document inline why `ttsGenerationProgress` is emitted only at coarse fraction-complete checkpoints (or omitted entirely if there is no natural progress signal)." That is an open question disguised as a task. The agent had to make the call.
**Right or wrong?** Wrong for a refined plan. The refine-questions pass exists exactly to eliminate hedges. This one slipped through.
**Evidence:** Hedge present at line 337-338 of EXECUTION_PLAN.md.
**Carry forward:** `commands/refine.md` Pass 4 should grep for `\b(or|either|optionally)\b` inside task lists and flag every hit. Hedges in plans = inconsistencies in code.

---

## 3. Open Decisions

### 1. Standardize sync-path emission: fire-and-forget vs async overload

**Why it matters:** Today, GLM-ASR, AudioUtils, Qwen3-ASR fire-and-forget; the five codecs use async overloads. A host adapter that consumes events sees two ordering models. Race conditions in fire-and-forget can cause `*Start` to arrive after `*Complete` from a parallel call.
**Options:**
- **A. Migrate STT/AudioUtils to async overloads** (matches the codec pattern). Cost: every existing sync caller in Produciesta and elsewhere must adopt the async path or accept the sync path emits nothing. High blast radius.
- **B. Migrate codecs to fire-and-forget** (matches the STT pattern). Cost: introduces races in codec emissions; no win on call-site ergonomics; loses the "emission completes before return" guarantee.
- **C. Document both as supported, codify when each applies**: async overload when the public API is already async or has few sync callers; fire-and-forget when the public API is sync and has many callers. Add this to `docs/TELEMETRY.md`.
**Recommendation:** **C**, today. **A** if/when a host actually hits a race. The async-overload pattern is technically better but the migration cost is real and we have no evidence of races in production.

### 2. Add unload telemetry path

**Why it matters:** `modelUnload{Start,Complete}` are defined in the enum, documented in `docs/TELEMETRY.md`, and never emitted. Hosts wanting to track Metal pressure on model release have no signal. Hard discovery: `AudioModelManager` has no public unload.
**Options:**
- **A. Add a public `unload(modelId:)` to AudioModelManager** and emit there.
- **B. Emit from per-model `deinit`** (if the model holds the manager reference).
- **C. Drop `modelUnload*` from the enum** until there's a real owner.
**Recommendation:** **A**. The enum case already exists and is documented; backing it out is more churn than wiring an unload entry point. Track as a single sortie in the next mission.

### 3. STT phase string vocabulary

**Why it matters:** Two models, four phase strings today (`tokenizer`, `feature_extraction`, `decode`, `audio_chunking`). A third STT model will add more. Hosts that filter on phase will break each time.
**Options:**
- **A. Promote `phase` to `enum SttPhase` with a `.custom(String)` escape hatch.**
- **B. Document the four current phases as canonical, treat unknowns as opaque.**
- **C. Defer until a third STT model is added.**
**Recommendation:** **C**. Two data points is not a vocabulary. Wait for forcing function.

---

## 4. Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Public Telemetry API (foundation) | opus | 1 | Yes | 29 enum cases survived unchanged through all 18 downstream sorties. Foundation stuck. |
| 2 | AudioModelManager Instrumentation | opus | 1 | Partial | Built file-private actor (not in plan) and silently dropped unload events. Output survived but is incomplete relative to plan. |
| 3 | Qwen3TTS Instrumentation | sonnet | 1 | Yes | Pattern-setter; `ttsGenerationProgress: fractionComplete=1.0` convention used by 4 follow-ons. |
| 4 | GLM-ASR Instrumentation | sonnet | 1 | Yes (with caveat) | Set the fire-and-forget pattern that diverged from the codec async-overload pattern. Locally correct, globally inconsistent. |
| 5 | Metal Sampler + WiredMemoryManager | opus | 1 | Yes | New `MetalMemorySampler.swift` (235 LOC) with 10MB threshold gating. Survived integration. |
| 6 | Vocos Codec | sonnet | 1 | Yes | Pattern-setter for codecs. Decode-only documented. async-overload propagated cleanly. |
| 7 | AudioUtils | sonnet | 1 | Yes | Defaulted-parameter pattern (not setter) — the only sortie using it. Existing call sites compiled unchanged. |
| 8 | Soprano TTS | sonnet | 1 | Yes | Followed Sortie 3. |
| 9 | Llama TTS | sonnet | 1 | Yes | Followed Sortie 3. |
| 10 | PocketTTS | sonnet | 1 | Yes | Made the right call to omit `ttsGenerationProgress`. Hedge in plan handled correctly. |
| 11 | Marvis TTS | sonnet | 1 | Yes | Correctly emitted zero codec events (delegated to Sortie 15). |
| 12 | Qwen3-ASR | sonnet | 1 | Yes | Added new `audio_chunking` phase string. |
| 13 | Encodec | sonnet | 1 | Yes | Followed Sortie 6. |
| 14 | SNAC | sonnet | 1 | Yes | Followed Sortie 6. |
| 15 | Mimi | sonnet | 1 | Yes | Owns Marvis's codec events too. |
| 16 | DACVAE | sonnet | 1 | Yes | Followed Sortie 6. Watermarker untouched. |
| 17 | AudioPlayerManager Buffer Cache | sonnet | 1 | Yes | `@MainActor public class` — used canonical instance pattern directly. |
| 18 | Documentation | sonnet | 1 | Yes | 471-line `docs/TELEMETRY.md`. All relative links resolve. |
| 19 | Integration + zero-overhead + hot-loop guard | opus | 1 | Yes | Full CI-safe suite green. Refined hot-loop grep to strip comments. |

**Accuracy summary:** 18 of 19 sorties fully accurate, 1 partial (Sortie 2 — silent unload-path descope). Zero retries. Zero reverts. Zero files created and later deleted.

---

## 5. Harvest Summary

The mission shipped a clean, additive, vendor-neutral telemetry surface across 41 files in 19 sequential commits with no rework. The single most important thing learned: **the planner generalized too aggressively about Swift type shapes**. `actor`, `class`, `enum`, and `@MainActor class` need different injection patterns, and the plan assumed they were the same. A 30-second `grep` during breakdown would have surfaced this; instead the agents invented two file-private storage actors mid-flight to bridge the gap. The next iteration's breakdown step must include a "verify declaration kind of every target type" gate.

Secondary lesson: **divergent solution patterns inside one mission are a planning failure, not an agent failure.** The fire-and-forget vs async-overload split was rational locally but inconsistent globally. Refine should reconcile cross-sortie patterns before dispatch.

---

## 6. Files

### Preserve (read-only reference for next iteration)

| File | Branch | Why |
|------|--------|-----|
| `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift` | `mission/silent-stethoscope/01` | The 29-case event vocabulary. Stable contract; downstream missions extend, never replace. |
| `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift` | `mission/silent-stethoscope/01` | Protocol + canonical `emit(_:)` snippet. Update doc comment with the three injection-shape variants. |
| `Sources/MLXAudioCore/Telemetry/MetalMemorySampler.swift` | `mission/silent-stethoscope/01` | 10MB-threshold sampler. New mission may extend the threshold or add per-model attribution. |
| `Tests/MLXAudioTests/Telemetry/MockMLXAudioTelemetryReporter.swift` | `mission/silent-stethoscope/01` | Shared test double; reused by every telemetry test. |
| `Tests/MLXAudioTests/Telemetry/HotLoopGuardTests.swift` | `mission/silent-stethoscope/01` | Refined comment-stripping grep. Reuse if a follow-up mission adds new hot loops. |
| `docs/TELEMETRY.md` | `mission/silent-stethoscope/01` | Public documentation. Update as new events / patterns are added. |

### Discard (will not exist after rollback)

No files to discard. Mission is COMPLETE; nothing to roll back. All 41 changed files are intentional production deliverables.

---

## 7. Iteration Metadata

**Starting point commit:** `802006722f1698f0c41997e1812b5eee2a2dbb12` (`pre-telemetry baseline`)
**Mission branch:** `mission/silent-stethoscope/01`
**Final commit on mission branch:** `520ce0cf8bf5d78c44b97b576fd44dd9769bb70f` (`Sortie 19: Integration + zero-overhead + hot-loop guard`)
**Rollback target:** N/A — verdict is **keep the code**, no rollback.
**Next iteration branch:** N/A. The open decisions (§3) are scoped for a separate follow-up mission, not a re-run of this one. If the user later wants to attack the open decisions, that becomes `mission/silent-stethoscope/02` from the **head** of `01`, not from the starting point.

---

## Iteration Metadata

**Starting point commit:** `802006722f1698f0c41997e1812b5eee2a2dbb12` (`pre-telemetry baseline`)
**Mission branch:** `mission/silent-stethoscope/01`
**Final commit on mission branch:** `520ce0cf8bf5d78c44b97b576fd44dd9769bb70f`
**Rollback target:** N/A (verdict: keep)
**Next iteration branch:** `mission/silent-stethoscope/02` only if open decisions §3 are attacked; branch from `mission/silent-stethoscope/01` HEAD, not from the starting-point commit.
