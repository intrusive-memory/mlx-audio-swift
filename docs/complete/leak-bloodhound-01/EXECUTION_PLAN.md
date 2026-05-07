---
feature_name: OPERATION LEAK BLOODHOUND
mission_branch: mission/leak-bloodhound/01
starting_point_commit: 1b18e29d88e49efc4abd5549fe9eb6e7065242a2
iteration: 1
---

# EXECUTION_PLAN.md — MLXAudio Telemetry

**Source**: `docs/TELEMETRY_REQUIREMENTS.md`
**Generated**: 2026-05-06
**Refined**: 2026-05-06 (4-pass refinement)
**Owner**: stovak@gmail.com
**Primary motivation**: Find memory leaks in long-running TTS/ASR generation loops.

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Overview

Add an in-process, library-appropriate telemetry surface to `mlx-audio-swift` consisting of:

1. A leveled severity model (`.off`, `.lifecycle`, `.operations`, `.memory`, `.verbose`) gated by a compile-time ceiling and a runtime floor.
2. Per-subsystem `os.Logger` and `OSSignposter` instances under `MLXAudio.Logging.*`.
3. An `actor`-backed counter store with a `Telemetry.snapshot()` / `Telemetry.resetCounters()` async API exposing live object counts and MLX memory state.
4. Paired init/deinit lifecycle instrumentation on every long-lived object (models, KV caches, tokenizers, engines) — the leak-detection minimum.
5. Operation-interval, memory-snapshot, and per-token signposts at progressively higher levels.
6. README + sample tests so host apps and contributors can use it.

The leak-finding minimum is Work Units 1–2 (Sorties 1–9); Work Units 3–5 layer on richer instrumentation; Work Unit 6 ships the docs.

---

## Authoritative References

- `docs/TELEMETRY_REQUIREMENTS.md` — full requirements, levels table, public API surface, defaults summary.
- `CLAUDE.md` — Claude-specific build instructions (`xcodebuild`, never `swift build` / `swift test`; `macos-26` runner).
- `AGENTS.md` — universal agent guidance, App Group setup.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| WU-1 Telemetry Foundation | `Sources/MLXAudioCore/Telemetry/` | 4 (S1–S4) | 0 | none |
| WU-2 Lifecycle Instrumentation | `Sources/MLXAudioCore/` (cross-cutting) | 5 (S5–S9) | 1 | WU-1 |
| WU-3 Operations Instrumentation | `Sources/MLXAudioCore/` (cross-cutting) | 2 (S10–S11) | 1 | WU-1 |
| WU-4 Memory Instrumentation | `Sources/MLXAudioCore/Telemetry/` + cross-cutting | 1 (S12) | 2 | WU-3 |
| WU-5 Verbose Instrumentation | `Sources/MLXAudioCore/` (cross-cutting) | 2 (S13–S14) | 1 | WU-1 |
| WU-6 Documentation & Examples | `Documentation.docc/`, `README.md`, `docs/` | 1 (S15) | 3 | WU-2, WU-3, WU-4, WU-5 |

**Layer semantics**: Layer N may begin only when every work unit in layers `< N` has all its sorties COMPLETED. Within a layer, work units may run in parallel subject to the build constraint (see Parallelism Structure below).

---

## WU-1 Telemetry Foundation

**Goal**: Land the public `Telemetry` API surface, build flag, env-var resolution, and per-subsystem logging/signpost scaffolding. No production callers are instrumented yet — this is pure scaffolding.

### Sortie 1: Core types & build flag

**Priority**: 45.25 — Foundation type that blocks all 14 downstream sorties; highest dependency depth in the plan.

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:
1. Create `Sources/MLXAudioCore/Telemetry/Telemetry.swift` declaring `public enum Telemetry` with nested `public enum Level: Int, Comparable, Sendable { case off, lifecycle, operations, memory, verbose }`.
2. Stub `public static var level: Level { get }` and `public static var ceiling: Level { get }` (real resolution lands in Sortie 2 — return `.lifecycle` placeholder for now).
3. Create `Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift` declaring `public struct TelemetrySnapshot: Sendable { let liveCounts: [String: Int]; let mlxActiveBytes: Int; let mlxPeakBytes: Int; let timestamp: Date }`.
4. In `Package.swift`, add `swiftSettings: [.define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug))]` to the `MLXAudioCore` target (and any test targets that need full ceiling).
5. Add the same define to test targets so suites compile against the full ceiling.

**Exit criteria**:
- [ ] `test -f Sources/MLXAudioCore/Telemetry/Telemetry.swift` and `test -f Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift` both succeed.
- [ ] `grep -q 'MLXAUDIO_TELEMETRY_FULL' Package.swift` succeeds and the define is gated on `.debug` for both `MLXAudioCore` and the test target.
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Full CI-safe test block from `CLAUDE.md` (the long `xcodebuild test ... -only-testing:` invocation listing every CI-safe suite) exits 0.

---

### Sortie 2: Env-var resolution & level clamping

**Priority**: 43.5 — Blocks all 13 sorties downstream that gate work on `Telemetry.level`.

**Entry criteria**:
- [ ] Sortie 1 COMPLETED.

**Tasks**:
1. Implement `Telemetry.ceiling` so it resolves to `.verbose` when `MLXAUDIO_TELEMETRY_FULL` is defined and `.lifecycle` otherwise (use `#if MLXAUDIO_TELEMETRY_FULL`).
2. Implement `Telemetry.level` to read `MLXAUDIO_TELEMETRY` from `ProcessInfo.processInfo.environment`, parse to a `Level` (`off|lifecycle|operations|memory|verbose`, case-insensitive), default to `.lifecycle` when unset or unparseable.
3. Clamp the resolved level to `ceiling`. If the requested level exceeded the ceiling, emit a single warning to a dedicated `MLXAudio.Logging.telemetry` `Logger` (subsystem `"MLXAudio.Telemetry"`).
4. Resolution must be cached so the warning fires at most once per process.
5. Add unit-test target `MLXAudioTests/TelemetryConfigTests` covering: default = `.lifecycle`, valid env var values, invalid env var falls back to `.lifecycle`, clamp-to-ceiling emits a warning exactly once.

**Exit criteria**:
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryConfigTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 3: Per-subsystem Logger & OSSignposter scaffolding

**Priority**: 30.25 — Foundation reused by every signpost-emitting sortie (S5–S14).

**Entry criteria**:
- [ ] Sortie 1 COMPLETED.
- [ ] (Sortie 2 may run in parallel — only Sortie 1's types are required.)

**Tasks**:
1. Create `Sources/MLXAudioCore/Telemetry/Logging.swift` declaring `public enum MLXAudioLogging` with one static `Logger` and one matching `OSSignposter` per subsystem. (Resolved naming convention: top-level `MLXAudioLogging` enum, not nested under `Telemetry`. See Open Questions Q3.)
2. Subsystems (subsystem identifier shown — match Section 5 of requirements): `MLXAudio.core`, `MLXAudio.modelResolver`, `MLXAudio.qwen3TTS`, `MLXAudio.llamaTTS`, `MLXAudio.sopranoTTS`, `MLXAudio.pocketTTS`, `MLXAudio.marvisTTS`, `MLXAudio.qwen3ASR`, `MLXAudio.glmASR`, `MLXAudio.codecs`.
3. Each pair (`Logger` + `OSSignposter`) shares the same subsystem string so Instruments groups them together.
4. Mark `OSSignposter` instances `internal` (per Section 5: host apps must declare their own subsystems, not emit on ours). Loggers may be `public` so host apps can filter via `log` / Console.app.
5. Add `MLXAudioTests/TelemetryLoggingTests` asserting every subsystem instance is non-nil and every signposter's subsystem string matches its logger's.

**Exit criteria**:
- [ ] `grep -c 'public static let' Sources/MLXAudioCore/Telemetry/Logging.swift` returns ≥ 10 (one Logger per subsystem; `OSSignposter` declarations may use `internal static let` and are not counted here).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryLoggingTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] No `public` symbol matches `OSSignposter` in `Sources/MLXAudioCore/Telemetry/Logging.swift` (verify: `! grep -E 'public[[:space:]]+(static[[:space:]]+let|let).*OSSignposter' Sources/MLXAudioCore/Telemetry/Logging.swift`).
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 4: Counter store actor + snapshot/reset API

**Priority**: 25.75 — Blocks all lifecycle (S5–S9) and memory (S12) work; introduces actor concurrency surface.

**Entry criteria**:
- [ ] Sortie 1 COMPLETED.
- [ ] Sortie 2 COMPLETED (uses resolved `level` to gate counter mutations cheaply).

**Tasks**:
1. Create `Sources/MLXAudioCore/Telemetry/CounterStore.swift` as an `actor` holding `liveCounts: [String: Int]`, `perOpDeltas: [String: Int]` (placeholder for WU-4), and a `mlxPeakBytes: Int` high-water mark.
2. Implement async `increment(className:)` and `decrement(className:)`. Updates must be no-ops when `Telemetry.level == .off`.
3. Implement `public static func snapshot() async -> TelemetrySnapshot` that snapshots `liveCounts`, reads `MLX.GPU.activeMemory()` for `mlxActiveBytes`, **always updates `mlxPeakBytes` to `max(mlxPeakBytes, mlxActiveBytes)`** (we maintain peak ourselves; do not depend on MLX exposing a peak API), sets `timestamp = Date()`.
4. Implement `public static func resetCounters() async` that zeros `liveCounts` and `perOpDeltas` but **preserves** `mlxPeakBytes` (per Section 9 — peak is monotonic across resets).
5. Provide an internal `Telemetry.trackLifecycle(_ instance: AnyObject, className: String)` helper that fires-and-forgets a `Task { await CounterStore.shared.increment(...) }` on init and a paired pattern for deinit (used by WU-2). Document the fire-and-forget contract in a single-line comment per the project's no-comment default carve-out for non-obvious invariants.
6. Add `MLXAudioTests/TelemetryCounterStoreTests` covering: increment/decrement balance, reset zeroes liveCounts, reset preserves `mlxPeakBytes`, snapshot is consistent under concurrent mutation (use `TaskGroup`).

**Exit criteria**:
- [ ] `Telemetry.snapshot()` and `Telemetry.resetCounters()` are `public static async` (verify via `grep -E 'public static func (snapshot|resetCounters).*async' Sources/MLXAudioCore/Telemetry/`).
- [ ] `mlxPeakBytes` survives `resetCounters()` (covered by `TelemetryCounterStoreTests.testResetPreservesPeak`).
- [ ] `Telemetry.trackLifecycle` exists as an `internal` helper (verify via `grep -E 'internal static func trackLifecycle' Sources/MLXAudioCore/Telemetry/`).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryCounterStoreTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

## WU-2 Lifecycle Instrumentation

**Goal**: Wire paired init/deinit lifecycle hooks into every long-lived object so `Telemetry.snapshot().liveCounts` reflects current memory residents. This is the leak-finding MVP — it ships before WU-3/4/5.

### Sortie 5: Lifecycle hook + KV cache instrumentation (highest leak-hunting priority)

**Priority**: 16.5 — KV caches are the #1 leak suspect in long-running generation loops; establishes the trackLifecycle pattern reused by S6–S8.

**Entry criteria**:
- [ ] WU-1 COMPLETED.

**Tasks**:
1. Audit `Sources/MLXAudioCore/` for all KV cache types — at minimum search for `KVCache`, `class.*Cache`, files referencing `keys`/`values` paired arrays. Produce a concrete list before editing (record the list in the sortie's COMPLETE doc).
2. For each KV cache class: in `init` (or designated factory) call `Telemetry.trackLifecycle(self, className: "<Family>.KVCache")` and emit `signposter.beginInterval("Lifetime", id, "...")`. In `deinit` call the matched decrement and `signposter.endInterval(...)`.
3. Use the object pointer (`ObjectIdentifier(self).hashValue` or the signposter's id-from-pointer helper) as the signpost ID so Instruments pairs begin/end intervals.
4. Lifecycle instrumentation is in the release ceiling, so it must NOT be wrapped in `#if MLXAUDIO_TELEMETRY_FULL` — only add `#if` gates when the call site is at level > `.lifecycle`.
5. Add `MLXAudioTests/TelemetryLifecycleHookTests` covering: trackLifecycle increments, deinit decrements, multiple instances counted independently.
6. Add a focused KV-cache leak test (synthetic KV cache instantiation, no model download) that creates and drops 10 KV caches and asserts `liveCount` returns to 0.

**Exit criteria**:
- [ ] All KV cache types identified in Task 1's audit have paired init/deinit lifecycle hooks (verify by listing the audit results in the sortie's COMPLETE doc and confirming each appears in the diff).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryLifecycleHookTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] KV-cache leak test (within `TelemetryLifecycleHookTests`) passes — no model downloads required.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 6: TTS + ASR model lifecycle instrumentation

**Priority**: 4.5 — Single-purpose follow-on to S5; pattern is established.

**Entry criteria**:
- [ ] Sortie 5 COMPLETED (helper + pattern proven).

**Tasks**:
1. Add lifecycle hooks to `Qwen3TTSModel`, `LlamaTTSModel`, `SopranoTTSModel`, `PocketTTSModel`, `MarvisTTSModel` (TTS) and `Qwen3ASRModel`, `GLMASRModel` (ASR).
2. Counter key format: `"<Family>.Model"` — e.g. `"Qwen3TTS.Model"`, `"LlamaTTS.Model"`, `"GLMASR.Model"`.
3. Use the family's matching `OSSignposter` from WU-1 Sortie 3.
4. Add `MLXAudioTests/TelemetryModelLifecycleSmokeTests` containing one test per family that constructs the model via its existing `*ModuleSetup` test fixture path (synthetic config, no model download), drops it, calls `await Telemetry.snapshot()`, and asserts `snapshot.liveCounts["<Family>.Model"] == 0`. Tests that cannot avoid a real download should be marked `@available(*, deprecated, message: "Local-only")` or skipped via `XCTSkipUnless(ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1")` so they don't break CI.

**Exit criteria**:
- [ ] All 7 model classes have lifecycle hooks using their family signposter (verify via `grep -l 'trackLifecycle' Sources/MLXAudioCore/**/*.swift` includes one entry per family).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryModelLifecycleSmokeTests CODE_SIGNING_ALLOWED=NO` exits 0 (skips families that require downloads when `MLXAUDIO_NIGHTLY_RUN` is unset).
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 7: Codec model lifecycle instrumentation

**Priority**: 4.25 — Same pattern as S6, codec families.

**Entry criteria**:
- [ ] Sortie 5 COMPLETED.

**Tasks**:
1. Identify all codec model classes — at minimum SNAC, Mimi, Encodec, DAC, Vocos. Produce the concrete list from `Sources/MLXAudioCore/` (record in COMPLETE doc).
2. Add lifecycle hooks to each, using counter keys `"SNAC.Model"`, `"Mimi.Model"`, `"Encodec.Model"`, `"DAC.Model"`, `"Vocos.Model"`.
3. All five share the `MLXAudio.codecs` signposter.

**Exit criteria**:
- [ ] All codec model classes identified in Task 1 have lifecycle hooks (verify per audit list in COMPLETE doc).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/VocosTests -only-testing:MLXAudioTests/EncodecTests -only-testing:MLXAudioTests/DACVAETests -only-testing:MLXAudioTests/SNACVQTests -only-testing:MLXAudioTests/MimiLayerTests -only-testing:MLXAudioTests/DACVAEWatermarkerTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 8: Tokenizer + engine lifecycle instrumentation

**Priority**: 4.25 — Same pattern as S6/S7, tokenizer/engine families.

**Entry criteria**:
- [ ] Sortie 5 COMPLETED.

**Tasks**:
1. Identify tokenizer classes (`Qwen3TTSSpeechTokenizer`, `UnigramTokenizer` wrappers, etc.) and engine/runner top-level objects exposed in the public API. Produce the concrete list (record in COMPLETE doc).
2. Add lifecycle hooks with counter keys formatted as `"<Family>.Tokenizer"` or `"<Family>.Engine"` as appropriate.
3. Use the relevant family signposter; tokenizers shared across families use `MLXAudio.core`.

**Exit criteria**:
- [ ] All identified tokenizer + engine classes have lifecycle hooks (per audit list in COMPLETE doc).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerTests -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerEncodeTests -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerWeightTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 9: Leak detection test pattern + nightly integration

**Priority**: 7.75 — Establishes the leak-test pattern reused by host apps; ships the WU-2 leak-finding MVP.

**Entry criteria**:
- [ ] Sorties 5–8 COMPLETED.

**Tasks**:
1. Add `MLXAudioTests/TelemetryLeakDetectionPatternTests` containing the canonical pattern from requirements Section 7 (reset → baseline snapshot → loop → assert). Use synthetic configs (no model downloads) so the pattern test is CI-safe.
2. Add a real `testQwen3TTSDoesNotLeak` (and one analogous test per major family) that exercises the documented pattern. Place these in suites that require model downloads — they go in the **local-only** list, not the CI-safe block.
3. Update `.github/workflows/nightly-tests.yaml` to include the new local-only leak suites.
4. Update `CLAUDE.md` "Local-Only Test Suites" table with the new leak suites.
5. Document the leak-detection workflow in `Tests/MLXAudioTests/README.md` (create if absent) referencing the requirements doc.

**Exit criteria**:
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] `grep -q 'TelemetryLeakDetection' .github/workflows/nightly-tests.yaml` succeeds (the new model-backed leak suites appear in the nightly workflow).
- [ ] `grep -q 'TelemetryLeakDetection\|leak detection' CLAUDE.md` succeeds (the local-only table is updated).
- [ ] `test -f Tests/MLXAudioTests/README.md` succeeds and the file contains the string `TELEMETRY_REQUIREMENTS.md`.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

## WU-3 Operations Instrumentation

### Sortie 10: Operation intervals — resolution, download, and weight loading

**Priority**: 9.5 — Foundation for memory snapshots (S12); blocks WU-4.

**Entry criteria**:
- [ ] WU-1 COMPLETED.

**Tasks**:
1. Wrap `ModelResolver.resolve` in an interval signpost on `MLXAudio.modelResolver`. Gate with `if Telemetry.level >= .operations` and `#if MLXAUDIO_TELEMETRY_FULL` so it strips at lower compile ceilings.
2. Wrap `Acervo.download` per file on `MLXAudio.modelResolver` with the same gating.
3. Wrap `Module.loadWeights` per model family (Qwen3TTS, LlamaTTS, SopranoTTS, PocketTTS, MarvisTTS, Qwen3ASR, GLMASR; codecs SNAC, Mimi, Encodec, DAC, Vocos) on each family's signposter with the same gating.
4. Add `MLXAudioTests/TelemetryOperationsTests` (CI-safe) with two tests:
   - `testLevelResolvesFromEnv`: sets `MLXAUDIO_TELEMETRY=operations` in a child task's environment override and verifies `Telemetry.level == .operations`.
   - `testInstrumentedCallEmitsInterval`: uses a `TestSignposterRecorder` (see Open Questions Q4 — chosen approach) wired into one weight-loading call path; asserts the recorder observed exactly one begin/end pair on the expected subsystem.

**Exit criteria**:
- [ ] `ModelResolver.resolve`, `Acervo.download`, and at least 12 `loadWeights` call sites (1 per model/codec family) have interval signposts behind the `.operations` gate (verify: `grep -c 'beginInterval\|withIntervalSignpost' Sources/MLXAudioCore/**/*.swift` returns ≥ 14 new occurrences).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryOperationsTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 11: Operation intervals — generate / encode / decode entry points

**Priority**: 6.5 — Completes WU-3; blocks memory deltas (S12).

**Entry criteria**:
- [ ] Sortie 10 COMPLETED.

**Tasks**:
1. Wrap public `encode` / `decode` / `generate` entry points for each TTS family (Qwen3TTS, LlamaTTS, SopranoTTS, PocketTTS, MarvisTTS) on the family signposter, behind `if Telemetry.level >= .operations` AND `#if MLXAUDIO_TELEMETRY_FULL`.
2. Wrap public `generate` / `transcribe` entry points for each ASR family (Qwen3ASR, GLMASR) on the family signposter with the same gating.
3. Wrap public codec `encode` / `decode` entry points (SNAC, Mimi, Encodec, DAC, Vocos) on `MLXAudio.codecs` with the same gating.
4. Extend `TelemetryOperationsTests` with one test per family asserting that with telemetry at `.operations`, a synthetic `generate` (or smallest available API surface) call emits exactly one begin/end pair on the expected family signposter.

**Exit criteria**:
- [ ] At least 14 generate/encode/decode entry points are wrapped (5 TTS × ≥1 + 2 ASR × ≥1 + 5 codec × ≥1 = 12 minimum; 14 with secondary entry points). Verify by counting new `beginInterval` sites added relative to S10's diff.
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryOperationsTests CODE_SIGNING_ALLOWED=NO` exits 0 with the new per-family tests passing.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

## WU-4 Memory Instrumentation

### Sortie 12: MLX memory snapshots & per-op deltas

**Priority**: 5.5 — Completes the per-call leak-pinpointing capability.

**Entry criteria**:
- [ ] WU-3 COMPLETED (S10 and S11).

**Tasks**:
1. For every Level-2 interval added in S10/S11, capture `MLX.GPU.activeMemory()` before and after the interval, attach `before` / `after` / `delta` as signpost metadata.
2. Accumulate per-op deltas in `CounterStore.perOpDeltas` keyed by operation name (e.g. `"qwen3TTS.generate"`).
3. Surface `perOpDeltas` in `TelemetrySnapshot` (extend the struct — additive, non-breaking).
4. `resetCounters()` zeros `perOpDeltas`. `mlxPeakBytes` continues to be preserved.
5. Extend `MLXAudioTests/TelemetryCounterStoreTests` (or add `TelemetryMemoryTests`) covering: per-op delta accumulation, reset behavior, monotonic peak.

**Exit criteria**:
- [ ] `grep -q 'perOpDeltas' Sources/MLXAudioCore/Telemetry/TelemetrySnapshot.swift` succeeds.
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryCounterStoreTests -only-testing:MLXAudioTests/TelemetryMemoryTests CODE_SIGNING_ALLOWED=NO` exits 0 (the second `-only-testing` is included if `TelemetryMemoryTests` is the chosen file).
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

## WU-5 Verbose Instrumentation

### Sortie 13: Verbose — TTS / ASR per-token signposts

**Priority**: 4.5 — Independent of WU-2/3/4; gated, strips in release.

**Entry criteria**:
- [ ] WU-1 COMPLETED.
- [ ] (Independent of WU-2/3/4 — adds new gated signposts only.)

**Tasks**:
1. Add per-token signpost in TTS generate loops (Qwen3TTS, LlamaTTS, SopranoTTS, PocketTTS, MarvisTTS).
2. Add per-token signpost in ASR generate loops (Qwen3ASR, GLMASR).
3. All signposts wrapped behind `if Telemetry.level >= .verbose` AND `#if MLXAUDIO_TELEMETRY_FULL` so they strip in release builds.
4. Add `MLXAudioTests/TelemetryVerboseTests` (CI-safe) with: `testVerboseLevelResolvesUnderFullCeiling` (sets `MLXAUDIO_TELEMETRY=verbose`, asserts `Telemetry.level == .verbose`); `testTTSPerTokenEmitsExpectedCount` (uses a synthetic per-step recorder hooked into one TTS family's generate loop, asserts N events for N requested tokens).

**Exit criteria**:
- [ ] All 7 TTS+ASR generate loops emit a per-token signpost gated by `.verbose` AND `MLXAUDIO_TELEMETRY_FULL` (verify: `grep -c 'level >= .verbose' Sources/MLXAudioCore/**/*.swift` returns ≥ 7 new occurrences).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryVerboseTests CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

### Sortie 14: Verbose — Codec per-step + KV cache grow events

**Priority**: 4.5 — Completes WU-5.

**Entry criteria**:
- [ ] Sortie 13 COMPLETED (TelemetryVerboseTests target exists; pattern is established).

**Tasks**:
1. Audit codec implementations for iterative decode loops — explicitly check Mimi, SNAC, Encodec. Produce the concrete list of iterative codecs in the COMPLETE doc (resolves Open Question Q5).
2. Add per-decode-step signpost in each iterative codec identified in Task 1, on the `MLXAudio.codecs` signposter, gated by `.verbose` AND `MLXAUDIO_TELEMETRY_FULL`.
3. Add a "grow" event signpost in every KV cache type (from S5's audit) emitted when capacity grows, gated by `.verbose` AND `MLXAUDIO_TELEMETRY_FULL`.
4. Extend `MLXAudioTests/TelemetryVerboseTests` with: `testCodecPerStepEmitsExpectedCount` (one test per iterative codec); `testKVCacheGrowEmitsEventOnResize` (synthetic KV cache, force a grow, assert one event observed).

**Exit criteria**:
- [ ] Iterative codecs identified in Task 1 each emit per-step signposts (per audit list in COMPLETE doc).
- [ ] All KV cache types from S5's audit emit a grow event (verify against S5's audit list in S5's COMPLETE doc).
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/TelemetryVerboseTests CODE_SIGNING_ALLOWED=NO` exits 0 with the new tests passing.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0.

---

## WU-6 Documentation & Examples

### Sortie 15: README, sample tests, Instruments template

**Priority**: 1.25 — Final ship step; depends on every prior work unit.

**Entry criteria**:
- [ ] WU-2, WU-3, WU-4, WU-5 all COMPLETED.

**Tasks**:
1. Add a "Telemetry" section to the project `README.md` covering: levels, compile flag, env var, defaults, and a leak-detection example copied from requirements Section 7.
2. Add or update a DocC article under `Documentation.docc/` (or `Sources/MLXAudioCore/MLXAudioCore.docc/` if that's the convention) presenting the `Telemetry` API, `TelemetrySnapshot`, and the per-subsystem `Logger`/`OSSignposter` map.
3. Add a `docs/TELEMETRY_USAGE.md` walkthrough with at least three concrete examples: leak detection (Level 1), per-op memory pinpointing (Level 3 with `MLXAUDIO_TELEMETRY=memory`), Instruments trace capture (Level 2 with the os_signpost track).
4. (Optional) Add an Instruments `.tracetemplate` to `docs/` if it adds value; otherwise document how to configure the os_signpost track manually inside `docs/TELEMETRY_USAGE.md`.
5. Cross-link from `AGENTS.md` and `CLAUDE.md` to `docs/TELEMETRY_USAGE.md` so future agents discover it.

**Exit criteria**:
- [ ] `grep -q '## Telemetry' README.md` succeeds and the section references the env var, the compile flag, and the leak-detection pattern.
- [ ] `test -f docs/TELEMETRY_USAGE.md` and `grep -q 'TELEMETRY_REQUIREMENTS.md' docs/TELEMETRY_USAGE.md` both succeed.
- [ ] `grep -q 'TELEMETRY_USAGE.md' AGENTS.md` and `grep -q 'TELEMETRY_USAGE.md' CLAUDE.md` both succeed.
- [ ] Full CI-safe test block from `CLAUDE.md` exits 0 (sanity — docs-only changes shouldn't break tests).

---

## Parallelism Structure

**Critical path** (longest dependency chain): Sortie 1 → 2 → 4 → 5 → 9 → 10 → 11 → 12 → 15 (length: 9 sorties).

**Layer structure** (corrected from initial plan — WU-3 and WU-5 only depend on WU-1, so they belong in Layer 1):

| Layer | Work Units | Sorties | Notes |
|-------|------------|---------|-------|
| 0 | WU-1 | S1 → {S2, S3} → S4 (S4 needs S2) | S2 and S3 may parallelise after S1 lands |
| 1 | WU-2, WU-3, WU-5 | WU-2: S5 → {S6, S7, S8} → S9; WU-3: S10 → S11; WU-5: S13 → S14 | All three work units only depend on WU-1; conceptually parallel |
| 2 | WU-4 | S12 | Depends on WU-3 |
| 3 | WU-6 | S15 | Depends on every other work unit |

**Parallel Execution Groups** (subject to build constraint):

- **Group 1 (after S1 completes)**: S2 (supervising agent — has tests) + S3 (supervising agent — has tests). Practical: serial.
- **Group 2 (after WU-1 completes)**: WU-2/WU-3/WU-5 conceptually parallel. Practical: serial across work units; intra-WU-2 only S6/S7/S8 are theoretically parallel after S5.
- **Group 3 (after WU-3 completes)**: S12 (single sortie).
- **Group 4 (after all)**: S15.

**Build constraint — IMPORTANT**:
- Every sortie in this mission has an `xcodebuild test` or `xcodebuild build` command in its exit criteria. Concurrent `xcodebuild` invocations against the same `Package.swift` and `DerivedData` are unsafe and corrupt build state.
- **Therefore: only one sortie may execute at a time on the supervising agent.** Sub-agent dispatch is reserved for no-build work (audits/research outputs that the supervising agent then consumes, and the optional research portion of S15 docs).
- **Agent allocation**:
  - 1 supervising agent — handles every sortie sequentially in priority order.
  - Up to 4 sub-agents — usable only for: (a) audit subtasks within S5/S7/S8/S14 that produce a list-of-classes deliverable consumed by the supervising agent; (b) the docs research portion of S15.
- This is honest: this mission gains little from parallelism. Critical-path serial execution is the realistic plan.

---

## Open Questions & Missing Documentation

### Auto-fixed during refinement

| Original | Resolution |
|----------|-----------|
| **Q1 (S4)**: "updates `mlxPeakBytes` to `max(current, active)` if MLX exposes a peak" — ambiguous dependency on MLX API. | **Resolved**: S4 task 3 now reads "always updates `mlxPeakBytes` to `max(mlxPeakBytes, mlxActiveBytes)` (we maintain peak ourselves; do not depend on MLX exposing a peak API)". |
| **Q2 (S6)**: "Manual smoke test" exit criterion — not machine-verifiable. | **Resolved**: S6 task 4 now defines `TelemetryModelLifecycleSmokeTests` with explicit per-family assertions and `XCTSkipUnless` gating for download-required families. |
| **Q3 (S3)**: "or namespace via `Telemetry.Logging` — match codebase convention" — alternative without decision. | **Resolved**: S3 task 1 picks `MLXAudioLogging` top-level enum. Rationale: namespacing under `Telemetry` would conflict with the existing `Telemetry` enum's static API; a top-level peer is cleaner and matches Apple's `os.Logging` conventions. |
| **Q4 (S10)**: "or by using a recorder hook" — alternative without decision. | **Resolved**: S10 task 4 picks `TestSignposterRecorder` (a small test-only fake conforming to a thin protocol that the production code calls through). Rationale: this is the same pattern used by `TestSignposter` in the Apple sample code; avoids relying on `MLXAUDIO_TELEMETRY` env-var resolution timing during tests. |
| **Q5 (old S12, now S14)**: "iterative codecs (Mimi, SNAC, Encodec where iterative)" — vague which codecs are iterative. | **Resolved**: S14 task 1 makes "audit which codecs are iterative" an explicit deliverable with the result recorded in COMPLETE doc. |

### Remaining open questions (non-blocking; can be resolved during execution)

| Sortie | Question | Why non-blocking |
|--------|----------|------------------|
| S5 | What signpost-id-from-pointer helper does `OSSignposter` provide on macOS 26? | Apple API; the executing agent can look up `OSSignposter.makeSignpostID()` or use `ObjectIdentifier(self).hashValue` and proceed. |
| S6 | Do all 7 model classes have a synthetic-config init usable without a model download? | If a family lacks one, the test for that family is gated by `XCTSkipUnless(MLXAUDIO_NIGHTLY_RUN==1)` and runs only in nightly. Pattern is already documented in `CLAUDE.md` for similar suites. |
| S15 | Is there an existing DocC catalog at `Documentation.docc/` or `Sources/MLXAudioCore/MLXAudioCore.docc/`? | Either path is acceptable; the executing agent picks based on what exists when S15 runs. |

No blocking issues remain.

---

## Summary

| Metric | Value |
|--------|-------|
| Requirements detected | 31 (10 levels-table rows + 12 API symbols + 9 instrumentation targets, plus build/env/test rules) |
| Atomic tasks | ~70 (across 15 sorties) |
| Work units | 6 |
| Sorties | 15 (was 13; S10 split → S10+S11; old S12 split → S13+S14) |
| Dependency structure | 4 layers (was 5; corrected WU-3/WU-5 layer placement) |
| Critical path length | 9 sorties (S1→S2→S4→S5→S9→S10→S11→S12→S15) |

**Refinement summary**:

| Pass | Result |
|------|--------|
| 1. Atomicity & Testability | 2 sorties split (S10, old S12), 1 vague exit criterion fixed (S6), all sorties now estimate ≤ 32 turns. |
| 2. Prioritization | Priority scores added to all 15 sorties; existing dependency order confirmed correct. No reordering needed. |
| 3. Parallelism | Layer table corrected (WU-3/WU-5 are Layer 1, not Layer 2). Build constraint honestly documented: serial execution is the realistic plan. |
| 4. Open Questions | 5 issues auto-fixed in-line; 3 remaining questions classified non-blocking with documented fallbacks. |

**Leak-finding minimum**: WU-1 + WU-2 (Sorties 1–9). May ship as v1 before WU-3/4/5.

**Verdict**: ✓ Plan is ready to execute. Next step: `/mission-supervisor start`
