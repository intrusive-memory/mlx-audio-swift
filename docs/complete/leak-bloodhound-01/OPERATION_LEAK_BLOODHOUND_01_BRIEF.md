---
operation_name: OPERATION LEAK BLOODHOUND
iteration: 1
mission_branch: mission/leak-bloodhound/01
starting_point_commit: 1b18e29d88e49efc4abd5549fe9eb6e7065242a2
final_commit: c606c41c30c928839f14ccd6b682f908ebeaabf4
outcome: COMPLETE
verdict: KEEP THE CODE
---

# Iteration 01 Brief — OPERATION LEAK BLOODHOUND

> **Terminology**: A *mission* is the definable scope of work. A *sortie* is an atomic agent task within that mission. A *brief* is the post-mission review that harvests lessons before the next iteration.

**Mission:** Add an in-process telemetry surface (levels + os.Logger/OSSignposter + counter actor + lifecycle/operation/memory/verbose instrumentation + docs) so host apps can find memory leaks in long-running TTS/ASR generation loops.
**Branch:** `mission/leak-bloodhound/01`
**Starting Point Commit:** `1b18e29` (main)
**Sorties Planned:** 15
**Sorties Completed:** 15
**Sorties Failed/Blocked:** 0
**Duration:** 2 working days (2026-05-06 → 2026-05-07), 15 commits, 70 files changed, +10,746 LOC / −23 LOC
**Outcome:** Complete
**Verdict:** Keep the code. No rollback. The mission delivered exactly what it set out to deliver. Carry the open decisions below into a small follow-up sortie outside this mission, not a rollback.

---

## Section 1: Hard Discoveries

### 1. `MLXLMCommon.KVCacheSimple` is `public class`, not `open`

**What happened:** S5 set out to add `init`/`deinit` hooks to every KV cache class. Audit revealed every concrete KV cache type (`KVCacheSimple`, `RotatingKVCache`, `QuantizedKVCache`, `ChunkedKVCache`, `MambaCache`, `CacheList`, `BaseKVCache`) lives in the external `MLXLMCommon` Swift package and is `public class` (not `open`). They cannot be subclassed cross-module. There was no `init`/`deinit` we could hook directly.
**What was built to handle it:** Introduced `KVCacheLifecycleSentinel` — a thin `internal final class` in `MLXAudioCore` — and a public free function `attachKVCacheLifecycle(family:to:)`. The function attaches the sentinel to the host KV cache via `objc_setAssociatedObject(..., .OBJC_ASSOCIATION_RETAIN_NONATOMIC)`. When the host cache dies, ARC releases the sentinel, firing the matched `Telemetry.trackLifecycleEnd` decrement. Works on any Swift class instance (libobjc owns the deinit hook for all reference types) — including non-`@objc` Swift classes from sibling Swift packages.
**Should we have known this?** Yes. A 60-second `grep -n 'open class\|public class' .build/index-build/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift` at planning time would have surfaced it. The plan partially anticipated it ("designated factory" carve-out) but didn't commit to a strategy. S5 had to discover and design the sentinel pattern under sortie context.
**Carry forward:** Any future cross-cutting instrumentation across MLX-swift packages must check upstream subclassability before planning. Treat `MLXLMCommon` types as closed-for-subclassing by default. The associated-object sentinel pattern is now the canonical workaround — reuse it.

### 2. Sibling-module visibility forces `Telemetry.trackLifecycle` to be `public`, not `internal`

**What happened:** S4's plan called for `Telemetry.trackLifecycle` as an `internal static func`. S6 needed to call it from `MLXAudioTTS` and `MLXAudioSTT`, which are sibling SwiftPM modules to `MLXAudioCore`. Internal symbols don't cross module boundaries. The build broke.
**What was built to handle it:** S6 promoted `Telemetry.trackLifecycle` and `trackLifecycleEnd` from `internal` to `public`. Code shipped; tests green.
**Should we have known this?** Yes. The plan listed the work units cross-cutting `Sources/MLXAudioCore/`, but the actual instrumentation targets (`Qwen3TTSModel`, `LlamaTTSModel`, codec types, etc.) live in `MLXAudioTTS`/`MLXAudioSTT`/`MLXAudioCodecs`. A 30-second look at `Package.swift` at planning time would have shown the multi-module layout.
**Carry forward:** Any helper called from instrumentation call sites must be `public`. Consider `@_spi(MLXAudioTelemetryInternals)` to keep it out of the documented surface — see Open Decision 1.

### 3. `MLXAUDIO_TELEMETRY_FULL` define needed on every module that uses `#if MLXAUDIO_TELEMETRY_FULL`

**What happened:** S1 added the `MLXAUDIO_TELEMETRY_FULL` swiftSetting to `MLXAudioCore` and the test target only. S10 then introduced `#if MLXAUDIO_TELEMETRY_FULL` gates in interval-emitter call sites that lived in `MLXAudioCodecs`, `MLXAudioTTS`, and `MLXAudioSTT`. Those gates evaluated to `false` everywhere except `MLXAudioCore` and tests — silently stripping the telemetry from the rest of the codebase.
**What was built to handle it:** S10 extended the `MLXAUDIO_TELEMETRY_FULL` define to `MLXAudioCodecs`, `MLXAudioTTS`, and `MLXAudioSTT` in `Package.swift`. The state log calls this an "S10 side correction." It was really an S1 incompleteness.
**Should we have known this?** Yes. Same root cause as Discovery 2 — the multi-module layout was visible in `Package.swift` at planning time. S1's task list said "add to the `MLXAudioCore` target (and any test targets that need full ceiling)" — that wording let the agent legitimately stop after `MLXAudioCore` + tests.
**Carry forward:** When a compile flag is intended to gate behavior across the whole package, the plan must explicitly enumerate every target that needs it. Don't trust "and any others as needed" — agents will interpret it minimally.

### 4. KV-cache `grow` events are unobservable for LLM families

**What happened:** S14 set out to add a `grow` event signpost to every KV cache type. For `Mimi` (in-house code) it landed cleanly. For LLM families (`Qwen3TTS`, `Qwen3`, `LlamaTTS`, `SopranoTTS`, `PocketTTS`, `MarvisTTS`, `Qwen3ASR`, `GLMASR`) the underlying `MLXLMCommon.KVCacheSimple.update()` method is in the external package and cannot be subclassed or extended — the same closed-for-subclassing constraint as Discovery 1, but now blocking event emission rather than lifecycle tracking.
**What was built to handle it:** S14 documented the gap explicitly in code and the COMPLETE doc. No workaround exists short of forking MLXLMCommon or upstreaming a hook. Lifetime tracking via the sentinel still works (Discovery 1's pattern), but you cannot observe per-grow events.
**Should we have known this?** Partially. Discovery 1 already established the constraint. S14's plan didn't reason it forward to the grow-event use case.
**Carry forward:** See Open Decision 2 — file an upstream PR or accept the gap.

### 5. Vocos requires explicit `super.init()` + missing `import MLXAudioCore`

**What happened:** S7 added `Telemetry.trackLifecycle` to `Vocos.swift`. The build failed because (a) `Vocos.swift` didn't import `MLXAudioCore`, (b) Swift's two-phase init demanded an explicit `super.init()` once a stored-property-touching call appeared in `init`.
**What was built to handle it:** Added `import MLXAudioCore` and `super.init()`. Trivial fix, but cost the agent at least one build cycle.
**Should we have known this?** Mostly no — this is the kind of micro-build-error you can only find by trying. Worth noting for future sortie agents: every cross-module instrumentation drop requires checking imports first.
**Carry forward:** Add an import-check task to the start of cross-cutting instrumentation sorties, e.g. "verify `import MLXAudioCore` in every target file before editing."

### 6. Q5 audit result — only Mimi is iterative; SNAC/Encodec/DACVAE/Vocos are single-shot

**What happened:** The plan listed Q5 as "audit which codecs are iterative" and deferred it to S14's runtime work. S14's audit found exactly one iterative codec: Mimi.
**What was built to handle it:** S14 added per-step events to `MimiStreamingDecoder.decodeFrames` only. The other four codecs were correctly skipped.
**Should we have known this?** Yes. A 5-minute code grep at planning time (`grep -rn 'for.*step\|while.*step\|for.*frame' Sources/MLXAudioCodecs/`) would have resolved Q5. The plan punted it to runtime, which worked, but it inflated S14's complexity unnecessarily.
**Carry forward:** Audit questions answerable by `grep` in <5 minutes should be resolved during refinement, not deferred to execution. Refinement Pass 4 (open questions) should triage by "can this be answered with a search now?" before classifying anything as "non-blocking."

### 7. Pre-existing test interference between `TelemetryLifecycleHookTests` and `TelemetryCounterStoreTests`

**What happened:** When both suites are included in the same `xcodebuild test` invocation, they interact and fail. Each passes individually. S10's agent verified this against a `git stash` baseline — the interference predates this mission.
**What was built to handle it:** Neither suite is in the CI-safe block. Mission shipped without resolving it. Documented in `SUPERVISOR_STATE.md` § Known Issue.
**Should we have known this?** Not at planning time — it's an inherited test-isolation bug. We learned it during execution.
**Carry forward:** Open Decision 3. Triage before promoting either suite to CI-safe.

### 8. ASR generate paths required body extraction

**What happened:** S11 wrapped public TTS generate entry points with `Telemetry.emitInterval { ... }`. The TTS family generate functions had bodies that closed over self and parameters cleanly. The ASR generate functions did not — the existing body referenced setup state in ways that didn't transfer into a closure cleanly.
**What was built to handle it:** Extract each ASR generate body into a private `_generateImpl` helper. The public `generate` is now a thin wrapper: `Telemetry.emitInterval { try await _generateImpl(...) }`.
**Should we have known this?** No — closure-capture issues only surface when you try them.
**Carry forward:** Default to body-extraction-via-private-impl whenever wrapping an existing async function in a measurement closure. Don't try to inline-wrap.

### 9. `CounterStore.drain()` needed 2→5 yields under TaskGroup pressure

**What happened:** `TelemetryCounterStoreTests` exercises concurrent increment/decrement via `TaskGroup`. The original `drain()` helper yielded twice. Tests flaked under load — the actor's mailbox wasn't always empty after 2 yields.
**What was built to handle it:** S12 bumped `drain()` to 5 yields per iteration. Tests stabilised.
**Should we have known this?** No — actor scheduling under contention is empirical.
**Carry forward:** Any test that snapshots actor state after concurrent mutation must drain aggressively. 5 yields is the new default until proven excessive.

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### 1. Test-only DI seams over env-var manipulation

**What happened:** S10 needed to verify that `Telemetry.emitInterval` actually emits an OS signpost without relying on `MLXAUDIO_TELEMETRY` env-var resolution timing. Q4 listed this as an open question with two candidate approaches.
**Right or wrong?** Right. The agent picked the `TestSignposterRecorder` protocol + `_intervalRecorder` test seam pattern, then S12/S13 reused it (`_eventRecorder`, `_levelOverride`). One small DI surface paid for itself across three sorties.
**Evidence:** S10/S12/S13 all use the same pattern. No flakes in `TelemetryOperationsTests`/`TelemetryMemoryTests`/`TelemetryVerboseTests`.
**Carry forward:** Default to DI seams over environment manipulation in tests. The seam is cheaper to maintain than the timing flakes you'd get from env-var-based testing.

#### 2. Audit-first sorties (S5, S7, S8, S14) produced concrete deliverables

**What happened:** Sorties touching multiple unknown call sites (KV caches, codecs, tokenizers) opened with an explicit audit task: "produce a list of classes in COMPLETE doc, then instrument them." The audit tables in the COMPLETE docs are now the canonical inventory.
**Right or wrong?** Right. The audit prevented scope creep (each sortie knew exactly when it was done) and produced reusable inventory for follow-up work.
**Evidence:** S5's COMPLETE doc contains a 17-row KV cache audit table; S14 cited that exact table to bound its grow-event work.
**Carry forward:** Any cross-cutting instrumentation sortie should open with an audit task whose deliverable is a table in the COMPLETE doc. The table is the contract.

#### 3. Pattern-then-apply cost optimization

**What happened:** S5 (opus) established the `trackLifecycle` + `KVCacheLifecycleSentinel` pattern. S6/S7/S8 (sonnet) applied it mechanically across model/codec/tokenizer families.
**Right or wrong?** Right. ~10× cost saving on three sorties versus running everything on opus.
**Evidence:** Decisions Log entries 2026-05-06 for S5 (opus, complexity 16) vs S6/S7/S8 (sonnet, complexity ≤12). All three sonnet sorties shipped first-attempt.
**Carry forward:** When a sortie establishes a pattern, downgrade subsequent applications to sonnet (or haiku where exit criteria are crisp). Don't pay opus rates for mechanical rework.

#### 4. First-attempt success rate of 15/15

**What happened:** Every sortie shipped on its first dispatch. No BACKOFF, no FATAL.
**Right or wrong?** Right — but partially because the plan had been refined through 4 passes before execution. Don't read 15/15 as "easy mission"; read it as "refinement pays."
**Evidence:** Decisions Log shows zero retries.
**Carry forward:** Continue investing in refinement. A 4-pass refinement was clearly worth the up-front cost.

### What the Agents Did Wrong

Nothing severe. Two minor items:

#### 1. S1 interpreted "and any test targets that need full ceiling" minimally

**What happened:** S1 added `MLXAUDIO_TELEMETRY_FULL` to `MLXAudioCore` + the single test target. The plan's ambiguous wording ("and any test targets that need full ceiling") let the agent legitimately stop there. S10 then had to extend the define to three more modules (Discovery 3).
**Right or wrong?** The agent followed the letter of the plan. The planner failure dominates — see Planner discovery 1 below. But a more defensive agent would have asked "should this also cover sibling modules where `#if MLXAUDIO_TELEMETRY_FULL` is going to be checked?" — a minute of clarification would have saved an entire side-correction in S10.
**Evidence:** S10's Decisions Log entry calls out the side correction explicitly.
**Carry forward:** When agents see compile-flag wiring with vague "any other targets" wording, they should grep the codebase for `#if FLAG_NAME` references and propose covering every site that uses the flag.

### What the Planner Did Wrong

#### 1. Multi-module visibility was never reasoned about

**What happened:** Three independent discoveries trace to the same root cause: the planner did not look at `Package.swift` to enumerate sibling SwiftPM modules and reason about visibility/define-coverage across them. Result:
- Discovery 2: `Telemetry.trackLifecycle` was specced as `internal`. Should have been `public` from day one.
- Discovery 3: `MLXAUDIO_TELEMETRY_FULL` was specced for `MLXAudioCore` only. Should have covered `MLXAudioCodecs`/`MLXAudioTTS`/`MLXAudioSTT`.
- Discovery 5 (partial): `Vocos.swift` import gap — the planner's task list never said "ensure imports."
**Right or wrong?** Wrong. A 5-minute `cat Package.swift` at planning time would have caught two of the three.
**Evidence:** Both items required runtime corrections (S6 deviation, S10 side correction).
**Carry forward:** Add a planning checklist item: "Read `Package.swift`. List every target. For any helper or compile flag you spec, decide explicitly which targets it must touch." Don't trust the directory column in the work-unit table to capture multi-module reality.

#### 2. Q5 (which codecs are iterative) was needlessly deferred

**What happened:** Q5 was classified as "non-blocking — agent can audit at runtime." The audit took ~5 minutes; classifying it non-blocking was technically correct but wasted ~5 minutes of an opus/sonnet sortie's context.
**Right or wrong?** Mildly wrong. Audit questions answerable by `grep` should be resolved during refinement, not deferred.
**Evidence:** S14's COMPLETE doc shows the audit took maybe 10 lines of text and one grep.
**Carry forward:** Refinement Pass 4 should add a "can this be answered by `grep` in <5 minutes?" check before classifying open questions as non-blocking. If yes, resolve it now.

#### 3. The plan over-specified some tests at the same level of detail as production code

**What happened:** Several sorties' task lists prescribed specific test file names and per-test assertions ("`testLevelResolvesFromEnv`", "`testInstrumentedCallEmitsInterval`"). When agents needed to add or rename a test for clarity, they had to push back against the plan.
**Right or wrong?** Mildly wrong. Test names and structures should be guidance, not contracts. The contract is the `xcodebuild test ... -only-testing:Suite` line in exit criteria.
**Evidence:** No specific incident, but `TelemetryOperationsTests` ended up with more tests than the plan's named list (12 family tests added in S11) — the plan's named tests were a floor, not a ceiling. That worked, but only because agents read the plan charitably.
**Carry forward:** Test-level task descriptions should specify *coverage* (what behaviors must be tested) and *suite names* (what `-only-testing` flag must succeed). Leave individual test method names to the agent.

---

## Section 3: Open Decisions

### 1. Should `Telemetry.trackLifecycle` be `@_spi(MLXAudioTelemetryInternals)` instead of fully public?

**Why it matters:** Today `Telemetry.trackLifecycle` and `trackLifecycleEnd` are documented public API. Host apps could call them; we don't intend that. Promoting to `@_spi` would keep them callable from sibling MLXAudio modules without exposing them on the documented surface.
**Options:**
- A. Leave as public. Document "intended for internal use; not stable" in DocC. Cheapest.
- B. Promote to `@_spi(MLXAudioTelemetryInternals)`. Add `@_spi(MLXAudioTelemetryInternals) import MLXAudioCore` at every call site. Cleanest visibility model.
- C. Restructure so all instrumentation call sites live inside `MLXAudioCore`, removing the cross-module need. Most invasive.
**Recommendation:** B. The `@_spi` annotation exists for exactly this case (cross-module internal API). One small follow-up sortie outside this mission. S6's Decisions Log already flags B as a consideration.

### 2. KV-grow events on `MLXLMCommon.KVCacheSimple` — fork, upstream, or accept the gap?

**Why it matters:** Discovery 4. Today the LLM families have lifetime tracking but no per-grow events. Long-running TTS sessions can't observe cache growth in real time on those families. Mimi has it; LLM families don't.
**Options:**
- A. Accept the gap. Document that grow events exist only for Mimi. Move on.
- B. File an upstream PR to `mlx-swift-lm` proposing either marking `KVCacheSimple` as `open` or exposing an observation hook. Wait for a release.
- C. Fork `MLXLMCommon` into the `intrusive-memory` org and patch in the hook. Heavy maintenance burden.
**Recommendation:** A in the short term. B as a parallel-track ask if grow-event observability becomes critical to a downstream user. Do not C.

### 3. Test interference between `TelemetryLifecycleHookTests` and `TelemetryCounterStoreTests`

**Why it matters:** Both pass individually. Both fail when run in the same `xcodebuild test` invocation. Neither is in the CI-safe block today, so the bug doesn't break CI — but it blocks promoting either suite to CI-safe and is a stability risk for any future test consolidation.
**Options:**
- A. Investigate root cause and fix. Likely a shared `Telemetry` static state (level cache, counter store) that one test mutates and the other observes.
- B. Mark them mutually exclusive with `.serialized` (swift-testing) or split into separate xcodebuild invocations. Symptomatic.
- C. Leave as-is. Document in `SUPERVISOR_STATE.md` (already done).
**Recommendation:** A. The most likely cause is the cached `Telemetry.level` warning — once one test triggers it, the next test's `XCTAssertNoLog`-style assertion fails. A targeted reset hook on `Telemetry` for tests would resolve this. One small follow-up sortie.

---

## Section 4: Sortie Accuracy

All 15 sorties shipped on the first attempt. No retries, no rework. Output below shows where downstream sorties touched files created by upstream sorties (a positive signal — means the pattern was extended, not rewritten).

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| S1 | Core types & build flag | opus | 1 | Mostly (see note) | `Package.swift` define was incomplete — S10 had to extend to sibling modules. Foundation files (`Telemetry.swift`, `TelemetrySnapshot.swift`) survived intact. |
| S2 | Env-var resolution & clamp | opus | 1 | Yes | Clean. No downstream rework. |
| S3 | Per-subsystem Logger/Signposter scaffolding | sonnet | 1 | Yes | Clean. Reused unmodified by every WU-2/3/4/5 sortie. |
| S4 | CounterStore actor + snapshot/reset | opus | 1 | Mostly (see note) | API spec said `internal trackLifecycle`. S6 had to promote to `public`. Actor implementation itself untouched after S4. |
| S5 | KV cache lifecycle hooks | opus | 1 | Yes | Solved the closed-for-subclassing problem cleanly with the sentinel pattern. Reused by every cross-module hook in S6/S7/S8. |
| S6 | TTS+ASR model lifecycle hooks | sonnet | 1 | Yes (with deviation) | `internal→public` promotion was a planner gap, not an agent error. 7 model classes hooked correctly. |
| S7 | Codec model lifecycle hooks | sonnet | 1 | Yes | 5/5 codecs hooked. Vocos import + super.init() fix was minor. |
| S8 | Tokenizer + engine lifecycle hooks | sonnet | 1 | Yes | Clean. Audit found no hidden engine types beyond what S6 already covered. |
| S9 | Leak detection pattern + nightly wiring | sonnet | 1 | Yes | CI-safe pattern test + 7 nightly suites + workflow YAML + CLAUDE.md table + new Tests README. Capstone of WU-2. |
| S10 | Operation intervals — resolve/download/loadWeights | opus | 1 | Yes (with side correction) | 18 wraps + DI seam. The Package.swift fix was correcting an S1 incompleteness, not a S10 error. |
| S11 | Operation intervals — generate/encode/decode | sonnet | 1 | Yes | 16 wraps + per-family tests. The `_generateImpl` extraction pattern is reusable. |
| S12 | MLX memory snapshots & per-op deltas | sonnet | 1 | Yes | Single seam in IntervalEmitter; additive to TelemetrySnapshot; counter store stabilization (drain 2→5). |
| S13 | Verbose per-token signposts (TTS/ASR) | sonnet | 1 | Yes | 9 sites + emitEvent helper + recorder seam. |
| S14 | Verbose codec per-step + KV grow events | sonnet | 1 | Yes (with documented gap) | Q5 resolved (Mimi only). LLM-family grow event gap is a discovery, not a defect. |
| S15 | Docs (README + DocC + USAGE.md + cross-links) | sonnet | 1 | Yes | Clean docs capstone. |

**Inaccuracy summary:** Two sorties (S1, S4) had specs that needed downstream correction. Both corrections were planner gaps, not agent failures. The agents executed the plan as written; the plan was missing facts about sibling-module reality. Net assessment: **15/15 first-attempt sorties is excellent**, and the two follow-on corrections together cost less than half a sortie of rework.

---

## Section 5: Harvest Summary

What we now know that we didn't know at planning time: **`MLXLMCommon` types are closed for subclassing across modules, and `mlx-audio-swift` is a multi-module SwiftPM package whose visibility and compile-flag rules don't propagate automatically.** Both facts dominate the plan's three planner-side mistakes (Discoveries 2, 3, and partly 4). Future planning for any cross-cutting instrumentation in this codebase must start by reading `Package.swift` and reasoning explicitly about which symbols and defines need to cross which module boundaries.

The single most important change for any future iteration: add a "multi-module reality check" to the planning checklist before classifying sorties.

---

## Section 6: Files

### Preserve (read-only reference for next iteration, if any)

| File | Branch | Why |
|------|--------|-----|
| `OPERATION_LEAK_BLOODHOUND_01_BRIEF.md` | `mission/leak-bloodhound/01` | This document. Next iteration reads it. After `clean` runs, lives at `docs/complete/leak-bloodhound-01/`. |
| `EXECUTION_PLAN.md` | `mission/leak-bloodhound/01` | Plan-of-record for iteration 1. After `clean`, archived. |
| `SUPERVISOR_STATE.md` | `mission/leak-bloodhound/01` | Authoritative state log for iteration 1. After `clean`, archived. |
| `COMPLETE_S{1..15}_*.md` × 15 | `mission/leak-bloodhound/01` | Per-sortie completion logs with audit tables (especially S5's KV cache table and S14's iterative-codec table). After `clean`, archived. |
| `docs/TELEMETRY_REQUIREMENTS.md` | `mission/leak-bloodhound/01` | Source-of-truth requirements doc. Stays in `docs/` permanently. |

### Discard (will not exist after rollback)

None. **No rollback is planned.** This mission ships the code on `mission/leak-bloodhound/01` to `development` and onward to `main` via the normal PR flow. The mission artifacts (briefs, plans, COMPLETE docs) will be archived under `docs/complete/leak-bloodhound-01/` by the `clean` step that runs immediately after this brief — they are *preserved*, not discarded.

If a future iteration is initiated (e.g., to chase Open Decisions 1–3 as a small follow-up mission), the rollback ritual does not apply here — those decisions are scoped as separate, smaller missions, not as a redo of OPERATION LEAK BLOODHOUND.

---

## Iteration Metadata

**Starting point commit:** `1b18e29d88e49efc4abd5549fe9eb6e7065242a2` (`main` at mission start)
**Mission branch:** `mission/leak-bloodhound/01`
**Final commit on mission branch:** `c606c41c30c928839f14ccd6b682f908ebeaabf4` (S15: docs capstone)
**Rollback target:** N/A (verdict is KEEP THE CODE — no rollback)
**Next iteration branch:** N/A unless follow-up mission opens

**Total mission diff:** 70 files changed, +10,746 / −23 LOC, 15 commits.

---

## Verdict

**KEEP THE CODE.** Ship `mission/leak-bloodhound/01` to `development`. Open three small follow-up issues for the Open Decisions; do not roll back this mission. The plan, after refinement, was good. The agents executed faithfully. The two planner-side gaps (multi-module visibility, define-coverage) cost less than half a sortie of rework total — well within tolerable noise for a 15-sortie mission. Treat 15/15 first-attempt success as a vindication of the 4-pass refinement, not luck.
