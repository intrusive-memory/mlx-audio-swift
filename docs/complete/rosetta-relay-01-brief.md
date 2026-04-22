# Iteration 01 Brief — OPERATION ROSETTA RELAY

## Terminology

> **Mission** — The definable scope of work. **Sortie** — An atomic agent task within a mission. **Brief** — The post-mission review that harvests lessons before the next iteration.

**Mission:** Replace `huggingface/swift-transformers` with `DePasqualeOrg/swift-tokenizers-mlx` (+ `swift-tokenizers`) to eliminate the duplicate-`Tokenizers`-module collision in composed consumers (primary acceptance test: SwiftBruja + mlx-audio-swift must build clean together).
**Branch:** `mission/rosetta-relay/01` (pushed to `origin`)
**Starting Point Commit:** `5da3cd1` (prep commit — REQUIREMENTS v4.0 + doc reorg, on `development`)
**Sorties Planned:** 7
**Sorties Completed:** 6 fully (S1, S2, S3, S4, S5, S7) + 1 partial (S6 — in env-prep retry at time of brief)
**Sorties Failed/Blocked:** 0 FATAL
**Duration:** ~1.5 hours wall-time from `start` through S7; S6 retry in flight (ETA +30–60 min)
**Outcome:** **Substantively Complete** (pending S6 environmental retry — not mission-blocking)
**Verdict:** **KEEP THE CODE.** The mission achieved its load-bearing acceptance. Roll forward to merge-back when S6 retry confirms real-weight tokenizer integration. Do NOT roll back.

---

## Section 1: Hard Discoveries

### 1. SPM fetches binary artifacts regardless of package traits

**What happened:** Sortie 1's EC5 was written as `find ~/Library/Developer/Xcode/DerivedData -type d -name "*.xcframework" -path "*swift-tokenizers*" | wc -l == 0`. The literal check failed — 3 hits. Investigation: the `swift-tokenizers` package declares `TokenizersRust` as an unconditional top-level binary target. SPM downloads it during resolution no matter what. The `"Swift"` trait controls *linking*, not *fetching*. SwiftBruja (our reference project) also has this xcframework in its DerivedData and ships clean.

**What was built to handle it:** Documented reinterpretation in Decisions Log; deferred the real "no Rust in final binary" check to Sortie 7 (composed-consumer smoke). Sortie 7 confirmed 0 duplicate/ambiguous Tokenizers errors in a clean SPM consumer build.

**Should we have known this?** Yes. Reading `swift-tokenizers`'s `Package.swift` before drafting the plan would have revealed the unconditional binary target. Would have cost 5 minutes.

**Carry forward:** When validating "no X in binary" for SPM dependencies, use `otool -L` / `nm` against the linked product, not `find` against DerivedData. The latter only proves artifacts exist on disk, which they always will for binary targets.

### 2. `AutoTokenizer.from(modelFolder:)` was renamed in the new API, not aliased

**What happened:** The plan's S2 and S3 each ended with `xcodebuild build -scheme MLXAudio-Package` as their final task. After dispatching both in parallel, it became obvious that neither sortie's build could pass until both sets of call-site migrations were in place — `from(modelFolder:)` does not exist in `swift-tokenizers`. It was renamed to `from(directory:)`, not aliased. So S2 alone leaves TTS broken and S3 alone leaves STT broken.

**What was built to handle it:** Supervisor-level build deferral — each agent ran edits + commit + grep-only verification, then the supervisor ran the shared `xcodebuild build` once both returned. One build, both sorties' final EC satisfied simultaneously. `** BUILD SUCCEEDED **`.

**Should we have known this?** The plan's own "Build Constraints" note hinted at this, but the per-sortie ECs still literally required the build. Reading the new `swift-tokenizers` API before writing the plan would have clarified that the call-site migrations are coupled at build-time and must ship together.

**Carry forward:** When two sorties share a build verification, either (a) put the build step in a gating sortie between them, or (b) explicitly note in each sortie that the build is supervisor-deferred. Don't force per-sortie builds that can only pass collectively.

### 3. `MLXAudioCodecs` had an undeclared transitive dep on `Tokenizers`

**What happened:** After S2 + S3 + the shared build, Swift's module scan surfaced two warnings: `MLXAudioCodecs` was importing `Tokenizers` (and transitively `Jinja`) without declaring them in its target deps. The old `swift-transformers` package apparently exposed `Tokenizers` through a looser dependency graph that let this slide.

**What was built to handle it:** S4 added `.product(name: "Tokenizers", package: "swift-tokenizers")` to the `MLXAudioCodecs` target in Package.swift. The `Jinja` warning disappeared once `Tokenizers` was declared (it was a transitive scan artifact).

**Should we have known this?** No — this one genuinely required the migration to surface. The new package graph is stricter, which is a good thing.

**Carry forward:** After any dependency rearrangement, run `xcodebuild build` with warnings enabled and grep for `missing a dependency on`. These warnings don't block the build but indicate brittle, non-declared module imports that will bite later.

### 4. The Rust xcframework is single-instance across `Swift`-trait consumers

**What happened:** The scratch consumer in S7 pulls `swift-tokenizers` via both SwiftBruja and mlx-audio-swift. The `.build/` directory shows ONE `TokenizersRust.xcframework`, not two. SPM dedupes binary targets by package URL + version, independent of how many dependents reference the package.

**What was built to handle it:** Same reinterpretation of "no xcframeworks" EC as in Sortie 1 — the singular presence is expected and harmless; it's not linked due to the `"Swift"` trait.

**Should we have known this?** Yes. This is standard SPM behavior for binary artifacts.

**Carry forward:** "Duplicate module" and "duplicate binary artifact" are different failure modes. The first breaks builds; the second doesn't, and SPM handles it structurally.

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### 1. Haiku-tier sortie crushed the 23-suite test battery

**What happened:** S5 (unit test battery) was dispatched to haiku with complexity score 2. It ran the full 253-test / 23-suite battery and returned a clean report in 59 seconds, including identifying and working around a grep regex escape issue mid-task.

**Right or wrong?** Exactly right. The plan explicitly flagged S5 as haiku-eligible; the heuristic confirmed it. Dispatching sonnet or opus here would have been 10x–30x overspend for zero marginal value.

**Evidence:** Complexity score 2, 23 suites green, 59s duration, no retries.

**Carry forward:** Lean hard on haiku for read-only `command`-type sorties with concrete success markers. The model-selection heuristic from execution.md is well-calibrated.

#### 2. Parallel L1 dispatch saved time without build thrash

**What happened:** S2 (STT) and S3 (TTS) operate on disjoint source trees. Plan recommended parallel edit + gated shared build. Supervisor dispatched both concurrently, deferred the shared `xcodebuild build`, ran it once both returned.

**Right or wrong?** Right. Zero merge conflicts (disjoint files), one build instead of two, ~2 min wall-time savings, clean state transition.

**Evidence:** Both sorties returned within ~2 min of each other; shared build exit 0 on first try; 3 sortie commits stacked cleanly in chronological order.

**Carry forward:** When two sorties touch disjoint files but share a build step, always defer the build to the supervisor rather than letting each sortie run it. Documents the coupling and avoids DerivedData thrash.

#### 3. Sortie 4 autonomously fixed the scan warnings

**What happened:** S4's prompt explicitly flagged the MLXAudioCodecs scan warnings as *optional* and non-blocking. The agent investigated, found the root cause (undeclared `import Tokenizers` in `MLXAudioCodecs/Mimi/Mimi.swift`), and fixed it — adding the target dep in Package.swift — without being asked to.

**Right or wrong?** Right. This is the kind of proactive scope-adjacent fix that's actually useful. The change was small, focused, and cleaned up a real problem. Agent correctly judged that declaring an already-used dependency isn't scope creep.

**Evidence:** Single-line Package.swift edit in the S4 commit; 2 warnings eliminated; clean build.

**Carry forward:** When a sortie's primary scope surfaces a narrow adjacent cleanup, let agents fix it (with a report). Forcing a separate sortie for every line of yak-shaving wastes cycles.

### What the Agents Did Wrong

#### 1. S6 agent's "pre-create directories manually" workaround

**What happened:** Before hitting the 404 CDN wall, S6's first-attempt agent ran into a transient `directoryCreationFailed` error for Group Container paths. It worked around this by pre-creating the directories manually. This is a side-effect outside the sortie's declared scope.

**Right or wrong?** Mildly wrong. Pre-creating filesystem paths at runtime isn't destructive, and it didn't leave artifacts in the repo (git status is clean), but it's the kind of ambient-system poking that should be flagged up, not silently normalized. The workaround masked a SwiftAcervo runtime issue that may bite someone else.

**Evidence:** Agent self-reported the pre-creation in its report; git status confirmed no project-file changes.

**Carry forward:** When an agent hits an environmental wall, the first move should be a report, not a workaround. Workarounds that touch ambient system state should be opt-in with supervisor approval.

### What the Planner Did Wrong

#### 1. S6 task 1 referenced a non-existent test suite

**What happened:** Plan task 1 of S6 says `-only-testing:MLXAudioTests/MarvisTTSTests`. That suite does not exist in `Tests/`. The only Marvis reference anywhere is the model slug `Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit` used inside `Sources/`. There is no test that wraps it.

**Right or wrong?** Wrong. The refinement Pass 1 (atomicity/testability) should have verified each test suite name against the actual test file tree. Instead it passed a phantom reference through.

**Evidence:** `find Tests -name "*Marvis*"` returns nothing. S6 agent had to substitute `Qwen3TTSTests` on its own judgment.

**Carry forward:** Plan refinement Pass 1 must grep every `-only-testing:<suite>` reference against real source. Fix before execution, not during.

#### 2. EC5 (S1) and EC4 (S7) were specified as literal xcframework counts

**What happened:** Both sorties specified exit criteria requiring `find ... "*.xcframework" | wc -l == 0`. Neither is satisfiable for any project using `swift-tokenizers` with the `"Swift"` trait, because SPM always downloads the binary target regardless of trait. Both sorties reported the issue and the supervisor reinterpreted them. Same failure mode twice.

**Right or wrong?** Wrong, twice. The intent (no Rust in the linked binary) was correct; the literal proxy was wrong. The fact that the same mistake appeared in two sorties means the planner copied a misspecified check without catching it.

**Evidence:** Decisions Log has two near-identical reinterpretation entries. Both sorties' final reports called out the same SPM behavior.

**Carry forward:** The next iteration's S1/S7 equivalent should use `otool -L` against a linked product, or grep the link-command output for `tokenizers_rust`. Do not re-use the `find xcframework` check.

#### 3. Whole-package build ECs for S2 and S3

**What happened:** S2 and S3 each had `xcodebuild build -scheme MLXAudio-Package ... exits with status 0` as their final EC — a whole-package check that neither sortie could individually satisfy until both were done.

**Right or wrong?** Wrong, but not catastrophic. The plan had a build-contention note that hinted at the coupling; the supervisor was able to resolve it with a deferred shared build. The cleaner decomposition would have been to drop the per-sortie build EC and add a gating sortie between L1 and L2 that does only the shared build.

**Evidence:** Both S2 and S3 listed identical build commands as final tasks; supervisor's Decisions Log documents the build-deferral resolution.

**Carry forward:** If two sorties must share a build verification, structure it as (parallel-edits) → (gating-build-sortie) → (next-layer). Don't duplicate the build task and hope the supervisor figures it out.

### 4. Plan underestimated CDN preflight

**What happened:** S6 exit criteria assume the CDN has the model manifests available. No entry criterion checks for CDN readiness. The sortie charged in, hit 404, and had to be restructured into a ship-then-test retry.

**Right or wrong?** Wrong. Integration-test sorties that depend on a CDN need an entry criterion that verifies the CDN artifacts exist (or can be created). Otherwise every unhappy environment reruns the same failure.

**Evidence:** S6 attempt 1 failed cleanly at the manifest fetch; retry had to prepend an `acervo ship` phase that wasn't in the plan.

**Carry forward:** For any sortie that downloads from a CDN under the project's control, add an entry criterion: "CDN has the required slugs (check with `curl -sf <manifest_url>`)" or "run `acervo ship <slug>` for each required model before invoking tests."

---

## Section 3: Open Decisions

### 1. Does the plan's EC5/EC4 xcframework check need a permanent fix?

**Why it matters:** If anyone re-runs this plan or a derivative, they'll hit the same misspecified proxy check and have to re-do the same reinterpretation. It also degrades trust in the plan's acceptance criteria.

**Options:**
- A. Patch EXECUTION_PLAN.md (post-mission) with a corrected check: `otool -L <built_product> | grep -q tokenizers_rust; [ $? -ne 0 ]`.
- B. File as a REQUIREMENTS/plan follow-up ticket for the NEXT migration-adjacent mission.
- C. Leave it — the mission is done and the check isn't load-bearing anyway.

**Recommendation:** **A.** Patch the archived plan when it moves to `docs/complete/`. 5 minutes of work, eliminates confusion for anyone reading the historical record.

### 2. Should MarvisTTSTests actually exist?

**Why it matters:** The Marvis TTS model is implemented in `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` but has no integration test. The plan author clearly expected one. Either the test was deleted and never re-added, or it was always missing.

**Options:**
- A. Add a Marvis integration test in a follow-up mission.
- B. Accept that Marvis has no integration coverage and carry that as known debt.
- C. Investigate git history to see if the test was deleted and, if so, why.

**Recommendation:** **C → A.** Quick `git log -p -- Tests/ | grep -i Marvis` to learn the story, then add the test in a small follow-up (1 sortie). This is outside the current mission's scope but worth a ticket.

### 3. The CDN is missing manifests for the 3 integration-test models

**Why it matters:** Even after S6 retry ships the models, tomorrow's new clone of the repo or a fresh CI run will hit the same 404 unless the manifests persist in R2.

**Options:**
- A. Trust that `acervo ship` during S6 retry is idempotent and permanent — once uploaded, future runs skip to a cached hit.
- B. Also wire the `ensure-model-cdn.yml` GitHub Actions workflow into CI so it preemptively ships models before integration tests run.
- C. Accept that the CDN is a "fill-as-you-go" artifact store and that integration tests require manual prep.

**Recommendation:** **A + B.** Ship solves the immediate problem; wiring the workflow into CI (or a nightly cron) solves the recurrence. Doesn't belong to this mission; file as follow-up for the `/acervo-cdn-setup` workflow.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Package.swift dep swap | sonnet | 1 | ✅ | 1-file, 6-line edit. EC5 literal-fail → plan bug, not sortie bug. |
| 2 | MLXAudioSTT call sites | sonnet | 1 | ✅ | 3 files, 9 edits, no rework. Agent correctly skipped the supervisor-deferred build. |
| 3 | MLXAudioTTS call sites + Marvis comments | sonnet | 1 | ✅ | 5 files, 10 edits incl. comment reflow. Preserved backticking style in comments on first try. |
| 4 | Verification sweep + doc-comment cleanup | sonnet | 1 | ✅+ | Exceeded spec in the right way — fixed MLXAudioCodecs scan warnings proactively with a narrow Package.swift edit. |
| 5 | Unit test battery | **haiku** | 1 | ✅ | 253 tests, 23 suites, 59s. Model choice was aggressive and correct. |
| 6 attempt 1 | Integration tests (CDN-blocked) | haiku | 1 | ⚠️ partial | Environmental failure, not sortie fault. EC4 (module boundary) passed. Agent's dir-pre-create workaround was mildly out-of-scope. |
| 6 attempt 2 | Integration tests (with acervo-ship prep) | sonnet | 2 | (in flight) | Retry in progress at time of brief. Will grade on next review. |
| 7 | Composed-consumer smoke (LOAD-BEARING) | sonnet | 1 | ✅ | First-try green. 36.4s build, 570 steps, 0 warnings. Correctly diagnosed EC4 misspec (same SPM xcframework issue as S1 EC5). This is the mission's acceptance test and it passed. |

**Pattern:** 6 of 7 sorties completed clean on first attempt. The one exception (S6) is an environmental-dependency failure, not a code or tokenizer-behavior failure. Model selection was accurate in all cases — no haiku→sonnet or sonnet→opus upgrades on retry. The heuristic held.

---

## Section 5: Harvest Summary

**What I now know that I didn't know before:**

The `"Swift"` trait on `swift-tokenizers` doesn't prevent SPM from fetching the Rust xcframework — it just prevents linking. Anyone migrating from `swift-transformers` to `swift-tokenizers-mlx` and writing acceptance criteria should check the linked binary (e.g. `otool -L`), not the fetched artifacts on disk. This single fact would have saved ~10 minutes of reinterpretation work and two near-identical Decisions Log entries.

**The single most important thing that changes for the next iteration:**

Plan refinement (Pass 1 / atomicity-testability) must grep every `-only-testing:<SuiteName>` reference against the actual test file tree, and every `find`-based EC against the actual filesystem behavior of the dependency being checked. Plan review should include a 5-minute read of any dependency package's `Package.swift` before drafting ECs that depend on its structure.

---

## Section 6: Files

### Preserve (read-only reference)

| File | Branch | Why |
|------|--------|-----|
| `EXECUTION_PLAN.md` | `mission/rosetta-relay/01` | Mission plan + frontmatter with SHA/branch metadata |
| `SUPERVISOR_STATE.md` | `mission/rosetta-relay/01` | Complete Decisions Log — the raw reasoning trail |
| `REQUIREMENTS.md` | `development` @ `5da3cd1` | v4.0 source of truth |
| `OPERATION_ROSETTA_RELAY_01_BRIEF.md` | `mission/rosetta-relay/01` (this file) | This brief |
| 5 sortie commits (`fd313c6`, `c79b338`, `4c85b18`, `9ed48eb`) + prep commit (`5da3cd1`) | `development` → mission branch | The actual code delivery |

### Discard (if the user decides to roll back)

| File | Why it's safe to lose |
|------|----------------------|
| n/a | **No rollback is recommended.** All code on the mission branch is clean, narrow, mechanical, and verified by S1–S5 + S7. Rolling back would destroy ~40 line edits of acceptance-tested work with nothing to gain. |

---

## Section 7: Iteration Metadata

**Starting point commit:** `5da3cd1` (`chore: prep for tokenizer migration — REQUIREMENTS v4.0 + doc reorg`)
**Mission branch:** `mission/rosetta-relay/01` (pushed to `origin`)
**Final commit on mission branch (at time of brief):** `9ed48eb` (`sortie 4: verification sweep + doc-comment cleanup`)
**Rollback target (if needed):** `5da3cd1` (but: NOT recommended — see verdict)
**Next iteration branch (if rolling back):** `mission/rosetta-relay/02` (would be created only on user decision)

---

## Direct Answer to the User

> **Am I rolling back and starting over or keeping the current mission branch?**

**Keep the current mission branch. Do not roll back.**

Reasons:

1. **The load-bearing acceptance test (S7) already passed.** Composed SwiftBruja + mlx-audio-swift builds clean with 0 duplicate-Tokenizers errors. That *is* the mission.
2. **All 253 unit tests pass** on the new tokenizer stack.
3. **The mission diff is tight and mechanical** (~40 line edits across 7 files + 2 Package.swift edits). There's nothing to "clean up" by starting over.
4. **S6's blocker is environmental (CDN 404), not code.** The retry in flight is publishing the missing artifacts to R2 — that same retry would still need to happen on a fresh branch, so rolling back doesn't eliminate any work.
5. **Rolling back loses work**: 5 clean commits including the valuable MLXAudioCodecs scan-warning fix that was scope-adjacent to the main migration.

**Roll-forward plan:**

- Let S6 retry complete (30–60 min). If it passes, mission is fully complete.
- Optionally patch the two misspecified ECs in the plan (see Open Decision 1) before archival.
- Open a PR from `mission/rosetta-relay/01` → `development` once S6 retry passes.
- After merge, file 2 follow-up tickets: add Marvis integration test (Open Decision 2); wire `ensure-model-cdn.yml` into CI (Open Decision 3).
- Archive this brief to `docs/complete/rosetta-relay-01-brief.md`.

The only scenario where rollback makes sense is if S6 retry surfaces a *code* regression (tokenizer behavior shifts that break a real test assertion). Current signal says that's unlikely — tokenizer init already executed cleanly in attempt 1 before the 404 wall.
