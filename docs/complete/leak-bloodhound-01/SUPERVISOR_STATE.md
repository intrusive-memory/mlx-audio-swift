# SUPERVISOR_STATE.md — OPERATION LEAK BLOODHOUND

> **Terminology**: A *mission* is the definable scope of work. A *sortie* is an atomic agent task within that mission.

## Mission Metadata

| Field | Value |
|-------|-------|
| Operation name | OPERATION LEAK BLOODHOUND |
| Mission branch | `mission/leak-bloodhound/01` |
| Starting point commit | `1b18e29d88e49efc4abd5549fe9eb6e7065242a2` |
| Iteration | 1 |
| Plan | `EXECUTION_PLAN.md` |
| Source requirements | `docs/TELEMETRY_REQUIREMENTS.md` |
| Dispatch mode | dynamic (no template in plan) |
| Started | 2026-05-06 |

## Plan Summary

- Work units: 6
- Total sorties: 15
- Dependency structure: layered (4 layers; serial in practice due to xcodebuild constraint)
- Critical path: S1 → S2 → S4 → S5 → S9 → S10 → S11 → S12 → S15 (length 9)
- Build constraint: only one `xcodebuild`-running sortie at a time on the supervising agent.

## Work Units

| Name | Directory | Sorties | Layer | Dependencies | State |
|------|-----------|---------|-------|--------------|-------|
| WU-1 Telemetry Foundation | `Sources/MLXAudioCore/Telemetry/` | S1–S4 | 0 | none | RUNNING |
| WU-2 Lifecycle Instrumentation | `Sources/MLXAudioCore/` | S5–S9 | 1 | WU-1 | NOT_STARTED |
| WU-3 Operations Instrumentation | `Sources/MLXAudioCore/` | S10–S11 | 1 | WU-1 | NOT_STARTED |
| WU-4 Memory Instrumentation | `Sources/MLXAudioCore/Telemetry/` + cross-cutting | S12 | 2 | WU-3 | NOT_STARTED |
| WU-5 Verbose Instrumentation | `Sources/MLXAudioCore/` | S13–S14 | 1 | WU-1 | NOT_STARTED |
| WU-6 Documentation & Examples | `docs/`, `README.md` | S15 | 3 | WU-2..WU-5 | NOT_STARTED |

## Per-Work-Unit State

### WU-1 Telemetry Foundation
- Work unit state: COMPLETED
- All 4 sorties COMPLETED (S1 `03e4181`, S2 `c02630a`, S3 `c990051`, S4 `ae07f53`).

### WU-2 Lifecycle Instrumentation
- Work unit state: COMPLETED
- All 5 sorties COMPLETED (S5 `3da7674`, S6 `5027e35`, S7 `38585e1`, S8 `790dcd5`, S9 `8c195ab`).

### WU-3 Operations Instrumentation
- Work unit state: COMPLETED
- Both sorties COMPLETED (S10 `3425dec`, S11 `767481a`).

### WU-4 Memory Instrumentation
- Work unit state: COMPLETED (single sortie S12 `e9c7bee`).

### WU-5 Verbose Instrumentation
- Work unit state: COMPLETED (S13 `886d9c8`, S14 `6e584b7`).

### WU-6 Documentation & Examples
- Work unit state: COMPLETED (S15 `c606c41`).

### Known Issue
- **Test interference (pre-existing, non-blocking)**: `TelemetryLifecycleHookTests` + `TelemetryCounterStoreTests` interact when run together in the same `xcodebuild test` invocation (verified by S10's agent against a `git stash` baseline). Both pass individually. Neither is in the CLAUDE.md CI-safe block. Worth tracking for a future cleanup sortie outside this mission, or flag for the brief.




## Active Agents

| Work Unit | Sortie | Sortie State | Attempt | Model | Complexity Score | Task ID | Output File | Dispatched At |
|-----------|--------|-------------|---------|-------|-----------------|---------|-------------|---------------|
| (none — mission complete) | | | | | | | | |

### Completed Sorties

| Work Unit | Sortie | Commit | Outcome |
|-----------|--------|--------|---------|
| WU-1 | 1 | `03e4181` | COMPLETED — Telemetry/TelemetrySnapshot types + MLXAUDIO_TELEMETRY_FULL define landed; CI-safe test block green (326 tests / 38 suites). |
| WU-1 | 2 | `c02630a` | COMPLETED — env-var resolution + clamp-to-ceiling + one-shot warning, TelemetryConfigTests passing. |
| WU-1 | 3 | `c990051` | COMPLETED — MLXAudioLogging map (10 public Loggers + 10 internal OSSignposters), 14/14 TelemetryLoggingTests pass; CI-safe block 326/326. |
| WU-1 | 4 | `ae07f53` | COMPLETED — CounterStore actor + Telemetry.snapshot/reset/trackLifecycle/trackLifecycleEnd; 10/10 + 326/326. WU-1 fully complete. |
| WU-2 | 5 | `3da7674` | COMPLETED — KV cache lifecycle via `KVCacheLifecycleSentinel` + `attachKVCacheLifecycle`; 14 call sites across 9 families; 6/6 lifecycle-hook tests + 326/326 CI-safe block. Audit: every KV cache here is `MLXLMCommon.KVCacheSimple` (external, non-open) → associated-object sentinel pattern. |
| WU-2 | 6 | `5027e35` | COMPLETED — 7 TTS/ASR top-level models hooked (Qwen3TTS, Llama, Soprano, Pocket, Marvis, Qwen3ASR, GLMASR); 7/7 model-lifecycle smoke tests + 326/326. **Deviation noted**: `Telemetry.trackLifecycle`/`trackLifecycleEnd` promoted from `internal` → `public` (sibling-module visibility constraint: MLXAudioTTS / MLXAudioSTT cannot access internals of MLXAudioCore). Marvis test gated by `MLXAUDIO_NIGHTLY_RUN==1` (no synthetic-config init). |
| WU-2 | 7 | `38585e1` | COMPLETED — 5/5 codec families hooked (SNAC, Mimi, Encodec, DACVAE, Vocos), all sharing `MLXAudioLogging.codecsSignposter`; 5/5 codec lifecycle smoke tests + 40/40 codec suite + 326/326. Vocos.swift needed `import MLXAudioCore` added; explicit `super.init()` required by Swift two-phase init. |
| WU-2 | 8 | `790dcd5` | COMPLETED — 4 tokenizer classes + 1 engine/aligner instrumented (Qwen3TTSSpeechTokenizer, UnigramTokenizer→Core.Tokenizer shared, SentencePieceTokenizer→PocketTTS.Tokenizer, MimiTokenizer, Qwen3ForcedAlignerModel→Qwen3ASR.Aligner); 5/5 new TelemetryTokenizerEngineLifecycleSmokeTests + 326/326 CI-safe block. |
| WU-2 | 9 | `8c195ab` | COMPLETED — TelemetryLeakDetectionPatternTests (CI-safe, 2 tests covering both idioms), 7 nightly per-family suites (Qwen3TTS/Llama/Soprano/Pocket/Marvis/Qwen3ASR/GLMASR), nightly-tests.yaml + CLAUDE.md table + Tests/MLXAudioTests/README.md. CI-safe block: 328/328 across 39 suites. **WU-2 fully complete; leak-finding MVP shippable.** |
| WU-3 | 10 | `3425dec` | COMPLETED — `Telemetry.emitInterval`/`emitIntervalAsync` helpers + `Telemetry.Family` enum in new `IntervalEmitter.swift`; 18 wraps (resolve + 2 download + 15 loadWeights). Test seams `_intervalRecorder` + `_levelOverride` resolve Q4. **Side correction**: Package.swift now defines `MLXAUDIO_TELEMETRY_FULL` for MLXAudioCore, MLXAudioCodecs, MLXAudioTTS, MLXAudioSTT, and tests (was only MLXAudioCore + tests after S1). 4/4 TelemetryOperationsTests + 326/326 CI-safe block. **Pre-existing flake noted**: TelemetryLifecycleHookTests + TelemetryCounterStoreTests interfere when in same xcodebuild invocation; not in CI-safe block; predates S10. |
| WU-3 | 11 | `767481a` | COMPLETED — 16 wraps across 5 TTS (`generate`), 2 ASR (`generate` w/ private impl extraction), 9 codec entry points (SNAC/Mimi/Encodec/DAC encode+decode + Vocos.decode). TelemetryOperationsTests grew 4→16 (12 new per-family tests; 9 CI-safe + 3 NIGHTLY-only for families needing real tokenizer). 16/16 + 328/328. WU-3 fully complete. |
| WU-4 | 12 | `e9c7bee` | COMPLETED — `perOpDeltas: [String: Int]` field added to TelemetrySnapshot (default `[:]` for source compat), `CounterStore.recordPerOpDelta` actor method, `IntervalEmitter` captures `MLX.Memory.activeMemory` before/after at `.memory` level. 5 new TelemetryMemoryTests; CI-safe block green. Also stabilised TelemetryCounterStoreTests `drain()` from 2→5 yields per iteration. WU-4 complete. |
| WU-5 | 13 | `886d9c8` | COMPLETED — `Telemetry.emitEvent(family:name:tokenIndex:)` point-event helper + `TelemetryEventRecorder` protocol + `_eventRecorder` test seam. 9 per-token signpost sites across 7 files (5 TTS + 2 ASR generate loops); 3/3 TelemetryVerboseTests + 329/329 CI-safe block (now 39 suites). |
| WU-5 | 14 | `6e584b7` | COMPLETED — Q5 resolved: only Mimi is iterative (per-step events in `MimiStreamingDecoder.decodeFrames`); SNAC/Encodec/DACVAE/Vocos are single-shot. Mimi `KVCache.grow` event in `MimiTransformer.Attention.callAsFunction`. **Documented API gap**: LLM-family KV cache grow events not observable — `MLXLMCommon.KVCacheSimple.update()` is external + non-subclassable. 5/5 TelemetryVerboseTests + 326/326 CI-safe block. WU-5 fully complete. |
| WU-6 | 15 | `c606c41` | COMPLETED — README `## Telemetry` section, `docs/TELEMETRY_USAGE.md` (3 worked examples: leak detection, per-op memory pinpointing, Instruments trace capture), DocC article at `Sources/MLXAudioCore/MLXAudioCore.docc/Telemetry.md` (new catalog), AGENTS.md + CLAUDE.md cross-links. 328/328 CI-safe tests + all 4 doc exit criteria. **Mission capstone — OPERATION LEAK BLOODHOUND complete.** |

## Decisions Log

| Timestamp | Work Unit | Sortie | Decision | Rationale |
|-----------|-----------|--------|----------|-----------|
| 2026-05-06 | — | — | Operation named OPERATION LEAK BLOODHOUND | THE RITUAL — telemetry-for-leak-hunting metaphor (bloodhound tracking leaks). |
| 2026-05-06 | — | — | Mission branch `mission/leak-bloodhound/01` created from `main@1b18e29` | Iteration 1 (no prior `*_BRIEF.md` files); branched off main per existing mission-branch convention. |
| 2026-05-06 | WU-1 | S1 | Model: opus | Override: foundation_score=1 AND dependency_depth ≥ 5. Complexity 11; 14 downstream sorties depend on this scaffolding. |
| 2026-05-06 | WU-1 | S1 | COMPLETED (commit `03e4181`) | All exit criteria pass; CI-safe test block green (326 tests / 38 suites). |
| 2026-05-06 | WU-1 | S2 | Model: opus | Override: foundation_score=1 AND dependency_depth ≥ 5; 13 downstream sorties gate on resolved `Telemetry.level`. |
| 2026-05-06 | WU-1 | S2 | COMPLETED (commit `c02630a`) | All exit criteria pass; TelemetryConfigTests green and CI-safe block green. |
| 2026-05-06 | WU-1 | S3 | Model: sonnet | Cost optimization: S3 work is mechanical OSLog scaffolding with explicit, machine-verifiable exit criteria. Sergeant principle (right tool for the job) — 10x savings vs opus is justified for low-ambiguity scaffolding. |
| 2026-05-06 | WU-1 | S3 | COMPLETED (commit `c990051`) | All 4 exit criteria pass; 14/14 TelemetryLoggingTests + 326/326 CI-safe block. |
| 2026-05-06 | WU-1 | S4 | Model: opus | Override re-affirmed: foundation_score=1 AND dep_depth≥5. Complexity 15 — actor concurrency design + MLX.GPU.activeMemory integration + Sendable surface — too risky to downgrade. |
| 2026-05-06 | WU-1 | S4 | COMPLETED (commit `ae07f53`) | All 5 exit criteria pass. WU-1 fully COMPLETED. SourceKit diagnostic on Telemetry.swift was stale index lag — actual build/test green. Layer 1 unlocks (WU-2/WU-3/WU-5 eligible). |
| 2026-05-06 | — | — | Layer 1 dispatch order: S5 first | S5 has highest priority (16.5) and establishes the trackLifecycle pattern reused by S6/S7/S8. Build constraint forces serial; running highest-priority Layer-1 work first matches the leak-hunting-MVP goal in the plan. |
| 2026-05-06 | WU-2 | S5 | Model: opus | Complexity 16; cross-cutting audit + hook insertion across multiple KV cache files; deinit-concurrency requires careful Sendable handling; foundation for S6/S7/S8. |
| 2026-05-06 | WU-2 | S5 | COMPLETED (commit `3da7674`) | Audit revealed all KV caches are external `MLXLMCommon.KVCacheSimple`. Solved with associated-object `KVCacheLifecycleSentinel` + `attachKVCacheLifecycle(family:to:)` helper at 14 call sites across 9 families. 6/6 + 326/326. SourceKit diagnostic about `Tokenizers` import on existing files = stale index lag (pre-existing transitive dep, not modified by S5). |
| 2026-05-06 | WU-2 | S6 | Model: sonnet | Pattern is established by S5; S6 is mechanical application across 7 model classes with explicit family→signposter mapping. 10x cost saving justified. |
| 2026-05-06 | WU-2 | S6 | COMPLETED with API deviation (commit `5027e35`) | `Telemetry.trackLifecycle`/`trackLifecycleEnd` promoted internal → public. Reason: MLXAudioTTS / MLXAudioSTT are sibling SwiftPM modules to MLXAudioCore; internal symbols cannot cross module boundaries. Accepted: API still gated by visibility intent (host apps unlikely to use it directly). Tracking note: consider `@_spi(MLXAudioTelemetryInternals)` follow-up for stricter discipline if it becomes an issue downstream. Tests: 7/7 + 326/326 green. |
| 2026-05-06 | WU-2 | S7 | Model: sonnet | Pattern fully established. Mechanical application across 5 codec families, all sharing the `MLXAudioLogging.codecs` signposter. |
| 2026-05-06 | WU-2 | S7 | COMPLETED (commit `38585e1`) | 5/5 codec families hooked; 40/40 codec suite + 326/326 CI-safe block. SourceKit `Tokenizers` diagnostic on Mimi.swift = stale index lag (transitive dep, not modified by S7). |
| 2026-05-06 | WU-2 | S8 | Model: sonnet | Pattern fully established. Mechanical extension to tokenizer + engine classes. |
| 2026-05-06 | WU-2 | S8 | COMPLETED (commit `790dcd5`) | 4 tokenizers + 1 aligner; 5/5 + 326/326. Audit found no separate engine top-level types beyond models already instrumented in S6. |
| 2026-05-06 | WU-2 | S9 | Model: sonnet | Capstone: CI-safe pattern test + 7 nightly per-family suites + nightly-tests.yaml YAML edit + CLAUDE.md table + new Tests README. Sonnet handles workflow YAML edits well; complexity 12 stays below opus threshold. |
| 2026-05-06 | WU-2 | S9 | COMPLETED (commit `8c195ab`) | All 5 exit criteria pass; CI-safe block 328/328 across 39 suites; both idioms (in-class + sentinel) covered by pattern tests; 7 nightly suites wired with `MLXAUDIO_NIGHTLY_RUN=1` gate. WU-2 fully complete. |
| 2026-05-06 | — | — | Layer 1 next-up: S10 first | After WU-2: WU-3 (S10/S11) and WU-5 (S13/S14) remain in Layer 1, plus WU-4 (S12) in Layer 2 blocked by WU-3. S10 has highest priority among unblocked sorties (9.5) and unlocks WU-4 via S11. Build constraint forces serial. |
| 2026-05-06 | WU-3 | S10 | Model: opus | Complexity 19; cross-cutting wrap of resolve/download/loadWeights across 12+ call sites, plus introduction of `TestSignposterRecorder` DI seam (Q4 resolution). Foundation for S11+S12. |
| 2026-05-06 | WU-3 | S10 | COMPLETED with side correction (commit `3425dec`) | 18 wraps + DI seam landed. **Side correction**: Package.swift `MLXAUDIO_TELEMETRY_FULL` define extended from MLXAudioCore + tests (S1's incomplete coverage) to MLXAudioCodecs/MLXAudioTTS/MLXAudioSTT — required for `#if MLXAUDIO_TELEMETRY_FULL` to compile-strip in sibling modules. Pre-existing test flake on Lifecycle+CounterStore tests when run together. Test count 326/326 (sortie may have run pre-linter CLAUDE.md). |
| 2026-05-06 | WU-3 | S11 | Model: sonnet | Pattern + helpers fully landed by S10. S11 is call-site addition across ~14 public entry points + per-family tests. Sonnet handles this well; complexity 12 below opus threshold. |
| 2026-05-06 | WU-3 | S11 | COMPLETED (commit `767481a`) | 16 wraps + 12 new per-family tests; 16/16 + 328/328. WU-3 fully complete. ASR generate paths required body extraction to `_generateImpl` private helpers to avoid duplicating logic inside the interval-emitting closure. |
| 2026-05-06 | WU-4 | S12 | Model: sonnet | Single seam in IntervalEmitter (no per-call-site changes), additive TelemetrySnapshot field, tests. Complexity 10. |
| 2026-05-07 | WU-4 | S12 | COMPLETED (commit `e9c7bee`) | `perOpDeltas` field added; `recordPerOpDelta` on actor; before/after MLX memory captured at `.memory` level. 5 new TelemetryMemoryTests. WU-4 fully complete. |
| 2026-05-07 | WU-5 | S13 | Model: sonnet | Per-token point-event helper `Telemetry.emitEvent` + recorder seam parallel to S10, plus 7 generate-loop edits + 2 tests. Complexity 11. |
| 2026-05-07 | WU-5 | S13 | COMPLETED (commit `886d9c8`) | 9 per-token sites + emitEvent helper + recorder; 3/3 verbose tests + 329/329. WU-5 in progress. |
| 2026-05-07 | WU-5 | S14 | Model: sonnet | Audit + per-step codec events (Q5 resolution) + KV-cache grow events. May fall back to documented-API-gap stub for grow events on KVCacheSimple if direct observation infeasible. |
| 2026-05-07 | WU-5 | S14 | COMPLETED with documented API gap (commit `6e584b7`) | Q5 resolved: only Mimi is iterative. KV-grow event landed for Mimi; LLM families documented as API gap (KVCacheSimple is external, non-subclassable). 5/5 + 326/326. WU-5 fully complete. |
| 2026-05-07 | WU-6 | S15 | Model: sonnet | Final sortie (mission capstone). Docs only — README + DocC + TELEMETRY_USAGE.md + cross-links. Sonnet sufficient; complexity 10. |
| 2026-05-07 | WU-6 | S15 | COMPLETED (commit `c606c41`) | All exit criteria pass; 328/328 CI-safe tests; new DocC catalog created at `Sources/MLXAudioCore/MLXAudioCore.docc/`. **MISSION COMPLETE.** |
| 2026-05-07 | — | — | OPERATION LEAK BLOODHOUND COMPLETE | All 6 work units (15 sorties) COMPLETED in priority order. 15 commits on `mission/leak-bloodhound/01` from `1b18e29` (start) to `c606c41` (end). Next: `/mission-supervisor brief` for post-mission review (auto-triggers `clean`). |

## Build Constraint Reminder

Per the plan's Parallelism Structure section, every sortie has an `xcodebuild` invocation in its exit criteria. Concurrent `xcodebuild` against the same `Package.swift` / `DerivedData` corrupts state. **Sorties run sequentially on the supervising agent.** Sub-agents are reserved for no-build audits (S5/S7/S8/S14 audit subtasks, S15 docs research).

## Status

🎖️ **OPERATION LEAK BLOODHOUND — MISSION COMPLETE** 🎖️

All 6 work units (15 sorties) COMPLETED on `mission/leak-bloodhound/01`. Mission ranged from `1b18e29` (starting point on main) to `c606c41` (S15 docs capstone) — 15 commits, all green.

**Next user action**: `/mission-supervisor brief` — runs the post-mission review and auto-triggers `clean` to archive every root-level mission artifact into `docs/complete/leak-bloodhound-01/`.
