---
title: "mlx-audio-swift — Tokenizer Package Migration"
source: "REQUIREMENTS.md v4.0 (2026-04-21)"
generated: 2026-04-22
refined: 2026-04-22
status: "REFINED — ready to execute"
feature_name: OPERATION ROSETTA RELAY
iteration: 1
starting_point_commit: 5da3cd180f3abcc0c43c35301d806d73e6367a0b
mission_branch: mission/rosetta-relay/01
---

# EXECUTION_PLAN.md — mlx-audio-swift Tokenizer Migration (v4.0)

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure. Maps to agentic cycles, not time.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Summary

Replace `huggingface/swift-transformers` with `DePasqualeOrg/swift-tokenizers-mlx` (+ `swift-tokenizers`), both with `Swift` trait. Migrate 10 `AutoTokenizer.from(modelFolder:)` call sites to `from(directory:)` and 6 leftover `tokenizer.decode(tokens:)` call sites to `decode(tokenIds:)`. Single branch off `development`. Narrow, mechanical diff.

**Source**: `REQUIREMENTS.md` v4.0
**Target branch**: `development`
**Acceptance test (load-bearing)**: composed-consumer smoke — scratch SPM package depending on both SwiftBruja and mlx-audio-swift must resolve and build without duplicate-`Tokenizers` module diagnostics.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| tokenizer-migration | `.` (project root) | 7 | — | none |

Single-project mission — all sorties belong to one work unit.

---

## Priority Scores (Pass 2)

| Sortie | Name | Dep Depth | Foundation | Risk | Complexity | Priority | Exec Order |
|--------|------|-----------|------------|------|------------|----------|-----------|
| 1 | Package.swift dep swap | 6 | 1 | 3 | 2.0 | **24.0** | 1 |
| 3 | TTS call sites | 4 | 0 | 2 | 3.0 | **15.5** | 2 (parallel) |
| 2 | STT call sites | 4 | 0 | 2 | 2.0 | **15.0** | 2 (parallel) |
| 4 | Verification sweep | 3 | 0 | 1 | 1.0 | **10.5** | 3 |
| 5 | Unit test battery | 2 | 0 | 1 | 0.5 | **7.25** | 4 |
| 7 | Composed-consumer smoke | 0 | 0 | 3 | 1.5 | **3.75** | 5 (parallel, load-bearing) |
| 6 | Integration tests | 0 | 0 | 2 | 1.0 | **3.0** | 5 (parallel) |

**Priority order inside each layer is advisory only** — dependency order is load-bearing and unchanged from the original plan. Within Layer 1, Sortie 3 marginally outranks Sortie 2 (5 files vs 3 files); both must complete before Sortie 4 regardless.

---

## Sortie 1: Package.swift tokenizer dependency swap

**Priority**: 24.0 — foundation sortie, blocks all 6 others; only sortie establishing the new package graph.

**Layer**: 0 (foundation)

**Task type**: `code` (build/verification included)

**Dispatch**: supervising agent (contains `xcodebuild -resolvePackageDependencies`).

**Entry criteria**:
- [ ] First sortie — no prerequisites.
- [ ] Working tree clean on mission branch (`git status --porcelain` returns empty).

**Tasks**:
1. In `Package.swift` `dependencies:` block, remove the `.package(url: "https://github.com/huggingface/swift-transformers", ...)` entry.
2. Add `.package(url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx", .upToNextMajor(from: "0.2.0"), traits: ["Swift"])`.
3. Add `.package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git", .upToNextMajor(from: "0.3.2"), traits: ["Swift"])`.
4. In the `MLXAudioTTS` target `dependencies:` array, remove `.product(name: "Transformers", package: "swift-transformers")` and add `.product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx")` and `.product(name: "Tokenizers", package: "swift-tokenizers")`.
5. In the `MLXAudioSTT` target `dependencies:` array, perform the same swap as step 4.
6. Run `xcodebuild -resolvePackageDependencies -scheme MLXAudio-Package` to validate resolution.
7. Confirm no Rust backend leaked in: run `find ~/Library/Developer/Xcode/DerivedData -type d -name "*.xcframework" -path "*swift-tokenizers*" 2>/dev/null` and confirm 0 lines. Also check `.build/` if present: `find .build -type d -name "*.xcframework" 2>/dev/null | grep -i token` → 0 lines.

**Exit criteria**:
- [ ] `grep -n "swift-transformers" Package.swift` returns 0 matches.
- [ ] `grep -n "swift-tokenizers-mlx" Package.swift` returns at least 1 match.
- [ ] `grep -nE "swift-tokenizers[\"\\.]" Package.swift` returns at least 1 match (the `swift-tokenizers` fork, anchored with `"` or `.` to avoid matching `swift-tokenizers-mlx`).
- [ ] `xcodebuild -resolvePackageDependencies -scheme MLXAudio-Package` exits with status 0.
- [ ] `find ~/Library/Developer/Xcode/DerivedData -type d -name "*.xcframework" -path "*swift-tokenizers*" 2>/dev/null | wc -l` is `0`.

---

## Sortie 2: Migrate STT call sites (modelFolder → directory, decode tokens → tokenIds)

**Priority**: 15.0 — unblocks 3 downstream sorties; disjoint source tree from Sortie 3.

**Layer**: 1 (parallel with Sortie 3)

**Task type**: `code` (build step included)

**Dispatch**: supervising agent or sub-agent. **Build contention note**: Sortie 2 and Sortie 3 share `~/Library/Developer/Xcode/DerivedData`. If both run xcodebuild concurrently, supervisor may need to serialize the build step (run S2 and S3 edit-and-commit in parallel, then run a single build). See Parallelism Structure § Build Constraints.

**Entry criteria**:
- [ ] Sortie 1 all exit criteria met.

**Tasks**:
1. In `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` line 634, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
2. In `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` lines 275 and 280, change `.decode(tokens:` to `.decode(tokenIds:`.
3. In `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` line 577, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
4. In `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` line 1594, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
5. In `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` lines 1014, 1073, 1290, 1362, change `.decode(tokens:` to `.decode(tokenIds:`.
6. Run `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` to confirm STT (and TTS, since it's package-scoped) compiles.

**Exit criteria**:
- [ ] `grep -rn "AutoTokenizer\.from(modelFolder:" Sources/MLXAudioSTT` returns 0 matches.
- [ ] `grep -rn "\.decode(tokens:" Sources/MLXAudioSTT` returns 0 matches.
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` exits with status 0.

---

## Sortie 3: Migrate TTS call sites (modelFolder → directory) + Marvis comment

**Priority**: 15.5 — unblocks 3 downstream sorties; includes largest fan-out (5 TTS models).

**Layer**: 1 (parallel with Sortie 2)

**Task type**: `code` (build step included)

**Dispatch**: supervising agent or sub-agent. See build contention note on Sortie 2.

**Entry criteria**:
- [ ] Sortie 1 all exit criteria met.

**Tasks**:
1. In `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` line 586, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
2. In `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` line 521, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
3. In `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` line 903, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
4. In `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` line 63, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
5. In `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` line 190, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
6. In `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift`, update BOTH comment references to `swift-transformers 1.3.0 API`:
   - Line 57: `// swift-transformers 1.3.0 API.` → `// swift-tokenizers 0.3.2 API.`
   - Line 189: `// swift-transformers 1.3.0 API (\`AutoTokenizer.from(modelFolder:)\`).` → `// swift-tokenizers 0.3.2 API (\`AutoTokenizer.from(directory:)\`).`
7. In `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` line 1703, change `AutoTokenizer.from(modelFolder:` to `AutoTokenizer.from(directory:`.
8. Run `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` to confirm TTS compiles.

**Exit criteria**:
- [ ] `grep -rn "AutoTokenizer\.from(modelFolder:" Sources/MLXAudioTTS` returns 0 matches.
- [ ] `grep -n "swift-transformers 1.3.0" Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` returns 0 matches.
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` exits with status 0.

---

## Sortie 4: Global verification sweep + Sources/ doc-comment cleanup

**Priority**: 10.5 — gate for all downstream testing; catches any `swift-transformers` residue missed in S2/S3.

**Layer**: 2

**Task type**: `code` (build step included)

**Dispatch**: supervising agent.

**Entry criteria**:
- [ ] Sortie 2 all exit criteria met.
- [ ] Sortie 3 all exit criteria met.

**Tasks**:
1. Run `grep -rn "AutoTokenizer\.from(modelFolder:" Sources Tests` and confirm 0 matches.
2. Run `grep -rn "\.decode(tokens:" Sources Tests` and confirm 0 matches.
3. Run `grep -rn "swift-transformers" Sources` and review each hit. Known residues (at plan-refinement time) include at least:
   - `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:1747` — doc comment about tokenizer.json.
   - `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift:458` — reference to a BPETokenizer bug.
   - Any remaining Marvis comments not cleaned in Sortie 3.
   For each hit: update the comment to reference `swift-tokenizers` / `swift-tokenizers-mlx` where it describes the current dependency; keep the comment if it describes a historical bug (but reword to not imply we still depend on swift-transformers).
4. Do NOT modify `docs/complete/` references to `swift-transformers` (historical context).
5. Re-run `grep -rn "swift-transformers" Sources` to confirm 0 matches after edits.
6. Run `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` to confirm the full package still builds.

**Exit criteria**:
- [ ] `grep -rn "AutoTokenizer\.from(modelFolder:" Sources Tests` returns 0 matches.
- [ ] `grep -rn "\.decode(tokens:" Sources Tests` returns 0 matches.
- [ ] `grep -rn "swift-transformers" Sources` returns 0 matches.
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` exits with status 0.

---

## Sortie 5: Run unit test battery (no-download tests)

**Priority**: 7.25 — gate for integration testing; runs the full CLAUDE.md-sanctioned battery.

**Layer**: 3

**Task type**: `command` (single scripted invocation).

**Dispatch**: supervising agent. Haiku-eligible (well-defined command execution).

**Entry criteria**:
- [ ] Sortie 4 all exit criteria met.

**Tasks**:
1. Run the full no-download unit test battery from `CLAUDE.md`:
   ```
   xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
     -only-testing:MLXAudioTests/VocosTests \
     -only-testing:MLXAudioTests/EncodecTests \
     -only-testing:MLXAudioTests/DACVAETests \
     -only-testing:MLXAudioTests/GLMASRModuleSetupTests \
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
     CODE_SIGNING_ALLOWED=NO
   ```
2. Capture the exit code and summary (`** TEST SUCCEEDED **` vs `** TEST FAILED **`).

**Exit criteria**:
- [ ] `xcodebuild test` exits with status 0.
- [ ] Output contains `** TEST SUCCEEDED **`.
- [ ] No `Test Suite '<suite>' failed` lines in output.

---

## Sortie 6: Integration tests — 1 TTS + 1 STT + 1 codec with real downloads

**Priority**: 3.0 — final-mile validation with real weights; catches runtime tokenizer behavior regressions.

**Layer**: 4 (parallel with Sortie 7)

**Task type**: `command` (three scripted test invocations).

**Dispatch**: supervising agent.

**Entry criteria**:
- [ ] Sortie 5 all exit criteria met.
- [ ] Network available for model downloads.

**Tasks**:
1. Run one TTS integration test that loads its tokenizer via `AutoTokenizer.from(directory:)`:
   ```
   xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
     -only-testing:MLXAudioTests/MarvisTTSTests CODE_SIGNING_ALLOWED=NO
   ```
2. Run one STT integration test:
   ```
   xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
     -only-testing:MLXAudioTests/Qwen3ASRTests CODE_SIGNING_ALLOWED=NO
   ```
3. Run one codec integration test that exercises download paths:
   ```
   xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
     -only-testing:MLXAudioTests/MimiTests CODE_SIGNING_ALLOWED=NO
   ```
4. Verify module boundary: grep the compiled TTS and STT test targets for any `import Transformers` — there should be none. Instead the code imports the `Tokenizers` module from `swift-tokenizers`. Run `grep -rn "^import Transformers" Sources Tests` → 0 matches.

**Exit criteria**:
- [ ] `MarvisTTSTests` exits with status 0 and output contains `** TEST SUCCEEDED **`.
- [ ] `Qwen3ASRTests` exits with status 0 and output contains `** TEST SUCCEEDED **`.
- [ ] `MimiTests` exits with status 0 and output contains `** TEST SUCCEEDED **`.
- [ ] `grep -rn "^import Transformers" Sources Tests` returns 0 matches.

---

## Sortie 7: Composed-consumer smoke test (scratch SPM package) — LOAD-BEARING

**Priority**: 3.75 — LOAD-BEARING acceptance test. This IS the motivation for the migration (composed-consumer build was broken by `swift-transformers` duplicate-`Tokenizers` module under SwiftBruja).

**Layer**: 4 (parallel with Sortie 6)

**Task type**: `code` + `command` (creates a scratch package, runs build).

**Dispatch**: supervising agent.

**Policy exception**: This sortie uses `swift build` (not `xcodebuild`) inside the scratch directory. This is an **intentional exception** to the project CLAUDE.md rule "never use `swift build`". Reason: the smoke test simulates a real consumer's SPM-only build flow, which is exactly the scenario that broke before the migration. Using xcodebuild here would measure a different scenario and not validate the fix. Do NOT propagate `swift build` into the main project — this exception is local to the `/tmp/tokenizer-smoke` scratch directory only.

**Entry criteria**:
- [ ] Sortie 5 all exit criteria met.
- [ ] Mission branch pushed to `origin` so scratch package can reference it by SHA. Supervisor (or sortie agent) runs `git push -u origin $(git rev-parse --abbrev-ref HEAD)` as the first step if not already pushed. Confirm with `git rev-parse --abbrev-ref --symbolic-full-name @{u}` returning the mission branch name.

**Tasks**:
1. Resolve the current mission-branch SHA: `MISSION_SHA=$(git rev-parse HEAD)`.
2. Resolve the SwiftBruja reference to test against: default is the latest release SHA on `main` (`git ls-remote https://github.com/intrusive-memory/SwiftBruja.git main` — first column).
3. Create a scratch directory outside the project tree at `/tmp/tokenizer-smoke-${MISSION_SHA:0:8}/`.
4. Inside it, write a `Package.swift` declaring a library target that depends on:
   - `intrusive-memory/SwiftBruja` pinned to the resolved SHA.
   - `intrusive-memory/mlx-audio-swift` pinned to `MISSION_SHA`.
   Include a single `.swift` source that imports both libraries' public entry points (e.g. `import MLXAudioCore` and whichever top-level module SwiftBruja exposes).
5. Run `swift package resolve` in the scratch directory. Capture full output.
6. Run `swift build` in the scratch directory. Capture full output.
7. Grep the captured output for any of: `duplicate`, `ambiguous`, `Tokenizers` in an error context. Any such hit is a failure.
8. `find /tmp/tokenizer-smoke-${MISSION_SHA:0:8}/.build -type d -name "*.xcframework" 2>/dev/null | wc -l` — confirm 0.
9. Tear down the scratch directory: `rm -rf /tmp/tokenizer-smoke-${MISSION_SHA:0:8}/`.

**Exit criteria**:
- [ ] `swift package resolve` exits with status 0.
- [ ] `swift build` exits with status 0.
- [ ] Captured build output contains 0 lines matching `error:.*Tokenizers` or `duplicate.*Tokenizers` or `ambiguous.*Tokenizers`.
- [ ] `find /tmp/tokenizer-smoke-*/.build -type d -name "*.xcframework" | wc -l` returns `0`.
- [ ] Scratch directory removed (`test ! -e /tmp/tokenizer-smoke-${MISSION_SHA:0:8}`).

---

## Parallelism Structure (Pass 3)

**Critical Path**: Sortie 1 → (Sortie 2 **or** 3) → Sortie 4 → Sortie 5 → (Sortie 6 **or** 7) — **5 sorties**.

**Parallel Execution Groups**:

| Group | Sorties | Concurrency | Notes |
|-------|---------|-------------|-------|
| G0 | S1 | 1 | Foundation — no parallelism. |
| G1 | S2, S3 | up to 2 | Disjoint source trees (STT vs TTS). Both need `xcodebuild build` — see Build Constraints. |
| G2 | S4 | 1 | Verification gate. |
| G3 | S5 | 1 | Test battery. |
| G4 | S6, S7 | up to 2 | Disjoint validation paths (integration tests vs consumer smoke). |

**Agent allocation**: 1 supervising agent + up to 1 concurrent sub-agent (G1 and G4 each contribute at most one parallel sub-agent).

**Maximum parallelism**: 2 agents simultaneously (during G1 and G4). Plan is structurally shallow — not a candidate for 4-agent fan-out.

**Build Constraints** (policy: sub-agents should not run concurrent xcodebuild invocations against the same DerivedData):

- **G1 (S2 + S3)**: Both sorties contain a final `xcodebuild build` step. If run truly concurrently against the same DerivedData cache, SPM/xcodebuild may serialize internally but can also thrash module caches. **Recommended pattern**: supervisor dispatches S2 and S3 in parallel for the code-edit phase, but gates the build step so only one xcodebuild runs at a time. Simplest safe realization: run S2 and S3 sequentially (edit + build per sortie) at the cost of ~2 min of extra wall time. Plan defaults to sequential unless supervisor proves DerivedData isolation (e.g. `-derivedDataPath` per sortie).
- **G4 (S6 + S7)**: S6 runs xcodebuild test against project DerivedData. S7 runs `swift build` in a scratch directory with its own `.build/`. No DerivedData collision — safe to parallelize.

**Missed opportunities**: None — the plan is a short linear critical path. The only theoretical win is running S6 and S7 concurrently (already planned in G4).

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 7 |
| Dependency structure | layered (L0 → L1 parallel(2,3) → L2(4) → L3(5) → L4 parallel(6,7)) |
| Critical path length | 5 sorties (1 → 2 or 3 → 4 → 5 → 6 or 7) |
| Max concurrent agents | 2 (1 supervising + 1 sub-agent during G1 and G4) |
| Load-bearing acceptance | Sortie 7 (composed-consumer smoke) |

---

## Breakdown Notes

- **Requirements detected**: 10 acceptance-checklist items + 3 goal outcomes + 4 test categories = 17 requirement signals, consolidated into 7 sorties.
- **Atomic tasks**: ~36 individual file/line edits grouped by subsystem (STT vs TTS) and concern (deps vs call sites vs verification vs tests). Added 1 task during refinement: Sortie 3 task 6 now covers BOTH Marvis comment sites (lines 57 and 189), not just line 189, because the refinement source scan found two.
- **Parallelism**: Sorties 2 & 3 operate on disjoint source trees (`MLXAudioSTT` vs `MLXAudioTTS`) and can run concurrently after S1; build step serialization recommended (see Parallelism Structure). Sorties 6 & 7 are independent validation paths after unit tests pass with no DerivedData collision.
- **Single work unit**: The requirements explicitly describe "Single branch off development. Narrow, mechanical diff" — splitting into multiple work units would add ceremony without benefit.
- **Sortie 7 is load-bearing**: per Risk Ledger, the composed-consumer smoke test IS the acceptance test for the motivation. Do not waive under time pressure.

---

## Open Questions & Missing Documentation (Pass 4)

### Auto-fixed during refinement

| Sortie | Original Issue | Fix Applied |
|--------|---------------|-------------|
| 1 | Exit criterion "No *.xcframework directory exists under any tokenizer-related package checkout" — no concrete find command. | Replaced with explicit `find ~/Library/Developer/Xcode/DerivedData -type d -name "*.xcframework" -path "*swift-tokenizers*"` command returning 0 lines. |
| 1 | `grep -n "swift-tokenizers\"" Package.swift` — quote-only anchor fragile to formatting. | Replaced with `grep -nE "swift-tokenizers[\"\\.]"` to anchor on either quote or period (`.git`). |
| 3 | Task list only updated Marvis comment at line 189; line 57 also has the same comment text. | Split task 6 into two sub-items covering both lines. |
| 4 | Task 3 ("review each hit") was unscripted; some `swift-transformers` comments are legitimate historical context (e.g. bug reference in Soprano.swift:458). | Enumerated known residues and clarified treatment rule (update forward-looking refs; reword historical-bug refs to not imply active dependency). |
| 5 | Exit: "All listed test suites report PASS" — no concrete assertion. | Replaced with `** TEST SUCCEEDED **` marker + absence of `Test Suite '<suite>' failed`. |
| 6 | Exit: "Tokenizer encode/decode round-trip assertion passes (existing tests already cover this or no new assertion is added if existing coverage is sufficient)" — two alternative outcomes, no selection rule. | Removed the vague clause entirely. Added a cleaner check: `grep -rn "^import Transformers" Sources Tests` returns 0 matches. The existing Marvis/Qwen3ASR/Mimi tests already exercise encode/decode via model inference; no new assertions needed. |
| 7 | Entry: "Migration branch is pushed to origin" — not specified whose responsibility. | Added explicit `git push -u origin` step to Task 1 with confirmation command. |
| 7 | Uses `swift build` which conflicts with project CLAUDE.md ("never use swift build"). | Added "Policy exception" callout explaining the intentional deviation (scratch directory only, consumer-experience validation). |

### Remaining items flagged for user review (non-blocking)

| Sortie | Issue | Recommendation |
|--------|-------|---------------|
| 7 | SwiftBruja reference SHA is resolved dynamically at sortie execution (`git ls-remote main`). If SwiftBruja's `main` happens to be broken independently of this migration, Sortie 7 will fail with a misleading signal. | **Mitigation**: agent should distinguish a SwiftBruja-internal compile error from a `Tokenizers`-module error in the failure report. Not a blocker for starting execution. |
| 6 | Integration tests download real model weights from HuggingFace; network flakiness can fail the sortie spuriously. | **Mitigation**: standard retry machinery (BACKOFF → upgrade model on retry) is sufficient. Not a blocker. |

**VERDICT**: No blocking open questions. Plan is ready to execute.

---

## Refinement Complete — Plan is Ready to Execute

### Pass Results

| Pass | Status | Changes |
|------|--------|---------|
| 1. Atomicity & Testability | ✓ PASS | 0 splits, 0 merges. All 7 sorties right-sized (estimated 8-24 turns each, budget 50). 3 vague exit criteria tightened. |
| 2. Prioritization | ✓ PASS | 0 reordered (dependency order correct). Priority scores added to each sortie. |
| 3. Parallelism | ✓ PASS | 2 parallel groups identified (G1: S2/S3, G4: S6/S7). Build-constraint note added for G1. Max 2 concurrent agents. |
| 4. Open Questions & Vague Criteria | ✓ PASS | 8 issues auto-fixed. 2 non-blocking items flagged for user awareness. 0 require manual resolution before execution. |

### Execution Summary

- Total sorties: 7
- Estimated sortie sizes: S1=13, S2=18, S3=24, S4=15, S5=8, S6=12, S7=20 turns (all within 50-turn budget)
- Critical path length: 5 sorties
- Max parallelism: 2 concurrent agents (during G1 and G4)
- Rough wall-time estimate: 25-45 min assuming parallel G1/G4 and no retries; 40-70 min with sequential G1 (build-contention-safe path).

**VERDICT**: ✓ Plan is ready to execute.

**Next step**: `/mission-supervisor start`
