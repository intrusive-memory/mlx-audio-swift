---
source: REQUIREMENTS-telemetry.md
generated: 2026-05-07
generator: mission-supervisor breakdown
refined: 2026-05-07
refiner: mission-supervisor refine (Passes 1–4)
status: in-flight
feature_name: OPERATION SILENT STETHOSCOPE
iteration: 1
starting_point_commit: 802006722f1698f0c41997e1812b5eee2a2dbb12
mission_branch: mission/silent-stethoscope/01
---

# EXECUTION_PLAN.md — mlx-audio-swift Vendor-Neutral Telemetry

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure. Maps to agentic cycles, not to time.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

## Scope

Implement the vendor-neutral telemetry surface described in `REQUIREMENTS-telemetry.md` for `mlx-audio-swift`:

- Public `MLXAudioTelemetryEvent` enum + `MLXAudioTelemetryReporter` protocol in `MLXAudioCore`
- `setTelemetry(_:)` injection on stateful components (AudioModelManager, every TTS/STT/codec class)
- `telemetry:` defaulted parameter on free/static functions (`AudioUtils`)
- Emission of every event at the boundaries listed in §2 of the requirements doc
- Library-side `MockMLXAudioTelemetryReporter` and instrumentation tests
- `docs/TELEMETRY.md` documenting the event vocabulary

**Out of scope** (handled in a different repository):
- `MLXAudioTelemetryAdapter` and `GenerationOrchestrator` wiring in Produciesta (REQUIREMENTS §3)
- Updates to `Produciesta/MULTI_REPO_TELEMETRY.md`

**Coexists with** the existing internal counter telemetry already in `Sources/MLXAudioCore/Telemetry/` (`CounterStore.swift`, `Telemetry.swift`, `KVCacheLifecycleSentinel.swift`, etc.). The new public surface is additive — it does not replace or modify the internal telemetry.

**Invariants** (from REQUIREMENTS §6, must hold at every checkpoint):
1. Library never imports Produciesta or any host
2. No new dependencies (`swift-log`, etc.)
3. Default is silent — `nil` reporter has zero runtime cost
4. One enum, one protocol, one library
5. Reporter is `async` non-throwing
6. Every emission site uses `@autoclosure` so payload work runs only when a reporter is attached

---

## Resolved Design Decisions

These were open questions at breakdown time; resolved during refinement:

1. **No shared `emit()` helper** — `telemetry` storage is per-instance state, and `@autoclosure` must close over the instance. Each instrumented class copies the canonical 4-line snippet verbatim; the snippet is documented in the doc comment of `MLXAudioTelemetryReporter.swift` as the single source of truth. (REQUIREMENTS §2.1.)

   ```swift
   // Canonical per-instance helper (copy verbatim into every instrumented class):
   private func emit(_ event: @autoclosure () -> MLXAudioTelemetryEvent) async {
       guard let telemetry else { return }
       await telemetry.capture(event())
   }
   ```

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| foundation | `Sources/MLXAudioCore/Telemetry/` | 1 (Sortie 1) | 0 | none |
| core-instrumentation | `Sources/MLXAudioCore/` | 4 (Sorties 2, 5, 7, 17) | 1 (5 also Layer 1.5) | foundation; Sortie 5 also depends on Sortie 2 |
| tts-instrumentation | `Sources/MLXAudioTTS/Models/` | 5 (Sorties 3, 8, 9, 10, 11) | 1 | foundation |
| stt-instrumentation | `Sources/MLXAudioSTT/Models/` | 2 (Sorties 4, 12) | 1 | foundation |
| codec-instrumentation | `Sources/MLXAudioCodecs/` | 5 (Sorties 6, 13, 14, 15, 16) | 1 | foundation |
| verification | `Tests/MLXAudioTests/`, `docs/` | 2 (Sorties 18, 19) | 1 (docs) / 2 (integration) | foundation; Sortie 19 also depends on Sorties 2–17 |

---

## Parallelism Structure

**Critical Path** (length 4): `Sortie 1` → `Sortie 2` → `Sortie 5` → `Sortie 19`

**Dispatch Waves** (Layer-1 sorties parallelized at the 4-agent cap; supervising agent owns all build/test verification per the no-builds-in-sub-agents rule):

| Wave | Sorties (concurrent) | Notes |
|------|----------------------|-------|
| 0 | 1 | Sequential. Supervising agent. Blocks everything. |
| 1 | 2, 3, 4, 6 | Highest-priority Layer-1 work — establishes the setter+emit pattern, plus first TTS / STT / codec to set per-family conventions. |
| 1.5 | 5 | Dispatched as soon as Sortie 2 exits, even if Wave 1 still has work outstanding. |
| 2 | 7, 8, 9, 10 | AudioUtils + remaining TTS family. |
| 3 | 11, 12, 13, 14 | Marvis TTS, Qwen3-ASR, Encodec, SNAC. |
| 4 | 15, 16, 17, 18 | Mimi, DACVAE, AudioPlayerManager cache, documentation. |
| 5 | 19 | Sequential. Supervising agent. End-to-end verification. |

**Maximum parallelism**: 4 sub-agents concurrent (cap). Without the cap, 16 sorties could in principle run concurrently after Sortie 1.

**Build constraints**: Every code-modifying sortie has `xcodebuild build` and `xcodebuild test` steps in its exit criteria. Per the parallelism rules, sub-agents do **not** run builds — they perform code edits only. The supervising agent runs the build/test verification at sortie exit. Sortie 18 (documentation) is the sole sub-agent task with no build step.

---

## Work Unit: foundation

### Sortie 1: Public Telemetry API

**Priority**: 56.25 — blocks all 18 downstream sorties; establishes the type vocabulary for the entire mission.

**Agent**: Supervising agent (foundation work; downstream sorties block on this).

**Entry criteria**:
- [ ] First sortie — no prerequisites

**Tasks**:
1. Create `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift` defining the `public enum MLXAudioTelemetryEvent: Sendable` with every case listed in REQUIREMENTS §1.1 (model lifecycle, TTS, STT, codecs, audio I/O, memory, errors — ~30 cases). All payloads are primitive `Sendable` types; error payloads are `String`.
2. Create `Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift` defining `public protocol MLXAudioTelemetryReporter: Sendable` with one `async` non-throwing method `capture(_:)`, plus `public struct NoopMLXAudioTelemetryReporter: MLXAudioTelemetryReporter`. In the protocol's doc comment, paste the canonical per-instance `emit(_:)` snippet from "Resolved Design Decisions" above as the documented copy-target for downstream sorties.
3. Add `Tests/MLXAudioTests/Telemetry/MLXAudioTelemetryEventTests.swift` with: (a) construction smoke test for every enum case, (b) `Sendable` conformance check, (c) `NoopMLXAudioTelemetryReporter` round-trip test.
4. Add `Tests/MLXAudioTests/Telemetry/MockMLXAudioTelemetryReporter.swift` shared test double (an `actor` storing `[MLXAudioTelemetryEvent]`) for use by all instrumentation sorties.

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/MLXAudioTelemetryEventTests CODE_SIGNING_ALLOWED=NO` passes (this also proves `MockMLXAudioTelemetryReporter` is visible from the test target — the test imports and uses it)
- [ ] `grep -RIn "import .*Produciesta" Sources/MLXAudioCore/Telemetry/` returns empty (invariant 1)
- [ ] `grep -c "@autoclosure" Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift` returns ≥ 1 (canonical snippet documented per Resolved Design Decisions)

---

## Work Unit: core-instrumentation (part 1)

### Sortie 2: AudioModelManager Instrumentation

**Priority**: 11.25 — establishes the `setTelemetry` + per-instance `emit` pattern reused by every other stateful class; gates the Metal sampler in Sortie 5.

**Agent**: Supervising agent (Wave 1).

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `private var telemetry: (any MLXAudioTelemetryReporter)?` and `public func setTelemetry(_:)` to the `AudioModelManager` actor in `Sources/MLXAudioCore/AudioModelManager.swift`.
2. Add the canonical private `emit(_:) async` helper from `MLXAudioTelemetryReporter.swift`'s doc comment (REQUIREMENTS §2.1 / Resolved Design Decisions).
3. Wire `modelDownloadStart` / `modelDownloadComplete` / `modelDownloadError` around every call site that invokes `Acervo.download(component:)` or HuggingFace hub fetch within this file.
4. Wire `modelLoadStart` / `modelLoadComplete` / `modelLoadError` around the weight-loading path. `modelLoadComplete` must include `sizeMB` and `metalAllocatedMB` sampled from `MTLDevice.currentAllocatedSize`.
5. Wire `modelUnloadStart` / `modelUnloadComplete` around the unload path; `modelUnloadComplete` must include `freedMB`.
6. Add `Tests/MLXAudioTests/Telemetry/AudioModelManagerTelemetryTests.swift` using `MockMLXAudioTelemetryReporter` to assert: (a) load sequence emits start+complete in order, (b) failure paths emit `*Error`, (c) with `nil` reporter no events are recorded and Metal sampling is skipped (verified by asserting the mock reporter receives zero events when `setTelemetry` is never called).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/AudioModelManagerTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `git diff Sources/MLXAudioCore/AudioModelManager.swift | grep -E '^\+\s*public ' | grep -v -E 'setTelemetry|public func emit' | wc -l` returns 0 (no new public API beyond `setTelemetry`)
- [ ] `grep -E "MTLDevice|currentAllocatedSize" Sources/MLXAudioCore/AudioModelManager.swift` shows every Metal sampling site is reachable only inside an `await emit(...)` body (manual check; the no-`@autoclosure`-leak check is automated via grep that no `MTLDevice` reference appears outside an `emit(` line)

---

## Work Unit: tts-instrumentation (Qwen3TTS first to set the pattern)

### Sortie 3: Qwen3TTS Instrumentation

**Priority**: 8.0 — first TTS sortie; establishes the streaming-progress emission pattern for Sorties 8–11.

**Agent**: Sub-agent (Wave 1). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical per-instance `emit(_:) async` helper to the public Qwen3-TTS entry-point class in `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift`.
2. Wire `ttsGenerationStart` at the top of every public `generate*` API (`generate`, `generateStream`, `generateBase`, `generateCustomVoice`, `generateICL` — whichever exist).
3. Wire `ttsGenerationComplete` after the final audio array materializes (capture `durationSeconds`, `audioSamples`, `sampleRate`).
4. Wire `ttsGenerationProgress` from the streaming path at a configurable interval (default every 10% or every N tokens — primitives only, no Metal sampling, no emission inside the per-step decode `for`/`while` loop body — emit at fraction-complete checkpoints only).
5. Wire `ttsGenerationError` on every throw site reachable from the public APIs.
6. Add `Tests/MLXAudioTests/Telemetry/Qwen3TTSTelemetryTests.swift` (module-setup level — no model download) asserting: setter is no-op on a non-loaded model, emission helper compiles, and `nil`-default zero-overhead. Real generation tests stay in the local-only suite.

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/Qwen3TTSTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/Qwen3TTSConfigTests -only-testing:MLXAudioTests/Qwen3TTSRoutingTests -only-testing:MLXAudioTests/Qwen3TTSPrepareBaseInputsTests -only-testing:MLXAudioTests/Qwen3TTSPrepareICLInputsTests -only-testing:MLXAudioTests/Qwen3TTSGenerateCustomVoiceTests -only-testing:MLXAudioTests/Qwen3TTSGenerateICLTests CODE_SIGNING_ALLOWED=NO` passes (existing CI-safe Qwen3TTS tests unbroken)

---

## Work Unit: stt-instrumentation (GLM-ASR first to set the pattern)

### Sortie 4: GLM-ASR Instrumentation

**Priority**: 8.0 — first STT sortie; establishes the `phase:` error-string pattern for Sortie 12.

**Agent**: Sub-agent (Wave 1). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public GLM-ASR class under `Sources/MLXAudioSTT/Models/GLMASR/`.
2. Wire `sttTranscriptionStart` at the top of every public transcribe/decode entry point (capture `audioSamples`, `sampleRate`).
3. Wire `sttTranscriptionComplete` after the final transcript is returned (capture `durationSeconds`, `textLength`).
4. Wire `sttTranscriptionError` on every throw site reachable from public APIs; include a `phase: String` describing where the error occurred (e.g., `"feature_extraction"`, `"decode"`, `"forced_align"`).
5. Add `Tests/MLXAudioTests/Telemetry/GLMASRTelemetryTests.swift` (setup-only, no model download).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/GLMASRTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/GLMASRModuleSetupTests -only-testing:MLXAudioTests/GLMASRModelTests CODE_SIGNING_ALLOWED=NO` passes (existing GLM-ASR tests unbroken)

---

## Work Unit: core-instrumentation (part 2)

### Sortie 5: Metal Memory Sampler & WiredMemoryManager

**Priority**: 7.5 — highest-risk work in the mission (Metal sampling thresholds); blocked by Sortie 2 because the sampler attaches at AudioModelManager load/unload boundaries.

**Agent**: Supervising agent (Wave 1.5 — dispatched immediately after Sortie 2 exits).

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied
- [ ] Sortie 2 exit criteria all satisfied

**Tasks**:
1. Add `telemetry` storage + `setTelemetry(_:)` to `WiredMemoryManager` in `Sources/MLXAudioCore/WiredMemoryManager.swift`. Use the canonical `emit(_:)` helper.
2. Emit `wiredMemoryState` snapshots at the existing coarse-grained boundaries already used by the manager (do not introduce new sampling timers).
3. Create `Sources/MLXAudioCore/Telemetry/MetalMemorySampler.swift` (new file) — a sampler that emits `metalBufferAllocated` / `metalBufferDeallocated` only when the delta vs. the previous sample exceeds 10 MB (REQUIREMENTS §2.6).
4. Wire the sampler at model load/unload boundaries inside `AudioModelManager` (build on Sortie 2's plumbing; do not modify TTS/STT hot loops).
5. Add `Tests/MLXAudioTests/Telemetry/MemoryTelemetryTests.swift` asserting: (a) sampler suppresses sub-10MB deltas, (b) sampler emits when delta crosses threshold, (c) `nil` reporter on `WiredMemoryManager` produces zero events when its lifecycle methods run.

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/MemoryTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `test -f Sources/MLXAudioCore/Telemetry/MetalMemorySampler.swift` returns true

---

## Work Unit: codec-instrumentation (Vocos first to set the pattern)

### Sortie 6: Vocos Codec Instrumentation

**Priority**: 7.0 — first codec sortie; establishes the encode/decode emission pattern for Sorties 13–16.

**Agent**: Sub-agent (Wave 1). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public Vocos class(es) under `Sources/MLXAudioCodecs/Vocos/`.
2. Wire `codecEncodeStart` / `codecEncodeComplete` / `codecError` around every public encode method (capture `inputSamples`, `compressionRatio = inputBytes / outputBytes`).
3. Wire `codecDecodeStart` / `codecDecodeComplete` / `codecError` around every public decode method (capture `codedFrames`, `outputSamples`).
4. Verify no emission inside per-frame loops; sample only at boundaries.
5. Add `Tests/MLXAudioTests/Telemetry/VocosTelemetryTests.swift` extending the existing `VocosTests` patterns (no model download).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/VocosTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/VocosTests CODE_SIGNING_ALLOWED=NO` passes (existing tests unbroken)

---

## Work Unit: core-instrumentation (part 3)

### Sortie 7: AudioUtils Instrumentation

**Priority**: 6.75 — establishes the defaulted-parameter (`telemetry: ... = nil`) injection pattern for all free/static functions; isolated to one file.

**Agent**: Sub-agent (Wave 2). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add a defaulted `telemetry: (any MLXAudioTelemetryReporter)? = nil` parameter to `AudioUtils.loadAudioArray(_:)` in `Sources/MLXAudioCore/AudioUtils.swift`.
2. Add the same defaulted parameter to `AudioUtils.saveAudioArray(_:audio:sampleRate:)`.
3. Wire `audioLoadStart` / `audioLoadComplete` / `audioIOError` around the read path (capture `fileSizeMB`, `samples`, `sampleRate`, `durationSeconds`).
4. Wire `audioSaveStart` / `audioSaveComplete` / `audioIOError` around the write path (capture `samples`, `sampleRate`, `fileSizeMB`).
5. Add `Tests/MLXAudioTests/Telemetry/AudioUtilsTelemetryTests.swift` covering load+save success, load+save error, and `nil`-default zero-overhead.

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds (proves all existing call sites compile unchanged because the parameter is defaulted)
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/AudioUtilsTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/AudioIORoundTripTests -only-testing:MLXAudioTests/AudioUtilsTests CODE_SIGNING_ALLOWED=NO` passes (existing tests unbroken — confirms no signature break)

---

## Work Unit: tts-instrumentation (remaining)

### Sortie 8: Soprano TTS Instrumentation

**Priority**: 6.0 — follows the pattern set in Sortie 3.

**Agent**: Sub-agent (Wave 2). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public Soprano TTS class in `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift`.
2. Wire `ttsGenerationStart` / `ttsGenerationComplete` / `ttsGenerationError` around every public `generate*` entry point.
3. Wire `ttsGenerationProgress` from the streaming path if Soprano exposes one; otherwise document inline that progress is omitted because generation is non-streaming.
4. Verify no telemetry emission occurs inside per-step decode loops.
5. Add `Tests/MLXAudioTests/Telemetry/SopranoTTSTelemetryTests.swift` (setup-only).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/SopranoTTSTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/SopranoModuleSetupTests CODE_SIGNING_ALLOWED=NO` passes (existing test unbroken)

### Sortie 9: Llama TTS (Orpheus) Instrumentation

**Priority**: 6.0 — follows the pattern set in Sortie 3.

**Agent**: Sub-agent (Wave 2). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift`.
2. Wire `ttsGenerationStart` / `ttsGenerationComplete` / `ttsGenerationError` around every public `generate*` entry point.
3. Wire `ttsGenerationProgress` from the streaming path (LlamaTTS streams via Orpheus token sequences); emit only at fraction-complete checkpoints, never inside the inner loop body.
4. Verify `KVCache` and other internal allocations are not emitted as events (those belong to the existing internal counter telemetry).
5. Add `Tests/MLXAudioTests/Telemetry/LlamaTTSTelemetryTests.swift` (setup-only).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/LlamaTTSTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/LlamaTTSModuleSetupTests CODE_SIGNING_ALLOWED=NO` passes (existing test unbroken)

### Sortie 10: PocketTTS Instrumentation

**Priority**: 6.0 — follows the pattern set in Sortie 3.

**Agent**: Sub-agent (Wave 2). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public PocketTTS class in `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift`.
2. Wire `ttsGenerationStart` / `ttsGenerationComplete` / `ttsGenerationError` around every public `generate*` entry point.
3. PocketTTS uses flow matching (no discrete-token streaming) — document inline why `ttsGenerationProgress` is emitted only at coarse fraction-complete checkpoints (or omitted entirely if there is no natural progress signal).
4. Verify no emission occurs inside the flow-matching ODE solver loop.
5. Add `Tests/MLXAudioTests/Telemetry/PocketTTSTelemetryTests.swift` (setup-only).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/PocketTTSTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/PocketTTSModuleSetupTests CODE_SIGNING_ALLOWED=NO` passes (existing test unbroken)

### Sortie 11: Marvis TTS (CSM/Sesame) Instrumentation

**Priority**: 6.0 — follows the pattern set in Sortie 3.

**Agent**: Sub-agent (Wave 3). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` (and `CSMModel.swift`/`CSMLlamaModel.swift` if they expose public `generate*`).
2. Wire `ttsGenerationStart` / `ttsGenerationComplete` / `ttsGenerationError` around every public `generate*` entry point.
3. Wire `ttsGenerationProgress` from the streaming path; emit only at fraction-complete checkpoints.
4. Marvis pipes through Mimi for codec; the Mimi `codecDecode*` events are emitted by Sortie 15, so Marvis must not double-emit codec events.
5. Add `Tests/MLXAudioTests/Telemetry/MarvisTTSTelemetryTests.swift` (setup-only).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/MarvisTTSTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/MarvisTTSModuleSetupTests CODE_SIGNING_ALLOWED=NO` passes (existing test unbroken)

---

## Work Unit: stt-instrumentation (remaining)

### Sortie 12: Qwen3-ASR Instrumentation

**Priority**: 6.0 — follows the pattern set in Sortie 4.

**Agent**: Sub-agent (Wave 3). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public Qwen3-ASR class under `Sources/MLXAudioSTT/Models/Qwen3ASR/`.
2. Wire `sttTranscriptionStart` / `sttTranscriptionComplete` / `sttTranscriptionError` around every public transcribe entry point.
3. The audio chunker (`SplitAudioIntoChunks`) and `ForceAlignProcessor` are not public surfaces — do not instrument them at this layer; `phase:` strings on errors describe their role instead.
4. Add `Tests/MLXAudioTests/Telemetry/Qwen3ASRTelemetryTests.swift` (setup-only).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/Qwen3ASRTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/Qwen3ASRModuleSetupTests -only-testing:MLXAudioTests/ForceAlignProcessorTests -only-testing:MLXAudioTests/Qwen3ASRHelperTests CODE_SIGNING_ALLOWED=NO` passes (existing tests unbroken)

---

## Work Unit: codec-instrumentation (remaining)

### Sortie 13: Encodec Codec Instrumentation

**Priority**: 5.0 — follows the pattern set in Sortie 6.

**Agent**: Sub-agent (Wave 3). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public Encodec class(es) under `Sources/MLXAudioCodecs/Encodec/`.
2. Wire `codecEncodeStart` / `codecEncodeComplete` / `codecError` around every public encode method.
3. Wire `codecDecodeStart` / `codecDecodeComplete` / `codecError` around every public decode method.
4. Verify no emission inside per-frame loops.
5. Add `Tests/MLXAudioTests/Telemetry/EncodecTelemetryTests.swift` (no model download).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/EncodecTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/EncodecTests CODE_SIGNING_ALLOWED=NO` passes (existing test unbroken)

### Sortie 14: SNAC Codec Instrumentation

**Priority**: 5.0 — follows the pattern set in Sortie 6.

**Agent**: Sub-agent (Wave 3). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public SNAC class(es) under `Sources/MLXAudioCodecs/SNAC/`.
2. Wire `codecEncodeStart` / `codecEncodeComplete` / `codecError` around every public encode method.
3. Wire `codecDecodeStart` / `codecDecodeComplete` / `codecError` around every public decode method.
4. Verify no emission inside per-frame loops or VQ codebook lookups.
5. Add `Tests/MLXAudioTests/Telemetry/SNACTelemetryTests.swift` (no model download).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/SNACTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/SNACVQTests CODE_SIGNING_ALLOWED=NO` passes (existing test unbroken)

### Sortie 15: Mimi Codec Instrumentation

**Priority**: 5.0 — follows the pattern set in Sortie 6.

**Agent**: Sub-agent (Wave 4). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public Mimi class(es) under `Sources/MLXAudioCodecs/Mimi/`.
2. Wire `codecEncodeStart` / `codecEncodeComplete` / `codecError` around every public encode method.
3. Wire `codecDecodeStart` / `codecDecodeComplete` / `codecError` around every public decode method.
4. Verify no emission inside per-frame transformer loops.
5. Add `Tests/MLXAudioTests/Telemetry/MimiTelemetryTests.swift` (no model download).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/MimiTelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/MimiLayerTests CODE_SIGNING_ALLOWED=NO` passes (existing test unbroken)

### Sortie 16: DACVAE Codec Instrumentation

**Priority**: 5.0 — follows the pattern set in Sortie 6.

**Agent**: Sub-agent (Wave 4). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `setTelemetry(_:)` and the canonical `emit(_:) async` helper to the public DACVAE class(es) under `Sources/MLXAudioCodecs/DACVAE/`.
2. Wire `codecEncodeStart` / `codecEncodeComplete` / `codecError` around every public encode method.
3. Wire `codecDecodeStart` / `codecDecodeComplete` / `codecError` around every public decode method.
4. Verify no emission inside the watermarker or per-frame decode loops.
5. Add `Tests/MLXAudioTests/Telemetry/DACVAETelemetryTests.swift` (no model download).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/DACVAETelemetryTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/DACVAETests -only-testing:MLXAudioTests/DACVAEWatermarkerTests CODE_SIGNING_ALLOWED=NO` passes (existing tests unbroken)

---

## Work Unit: core-instrumentation (part 4)

### Sortie 17: AudioPlayerManager Buffer Cache

**Priority**: 4.75 — narrowly scoped: emits `audioBufferCacheGrowth` when the player's internal cache grows. Independent of the Metal sampler in Sortie 5.

**Agent**: Sub-agent (Wave 4). Supervising agent runs build/test at exit.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied

**Tasks**:
1. Add `telemetry` storage + `setTelemetry(_:)` to `AudioPlayerManager` in `Sources/MLXAudioCore/AudioPlayerManager.swift`. Use the canonical `emit(_:)` helper.
2. Emit `audioBufferCacheGrowth` whenever its internal cache grows (insertion paths only — never inside per-frame playback loops).
3. Add `Tests/MLXAudioTests/Telemetry/AudioBufferCacheTelemetryTests.swift` asserting: (a) `audioBufferCacheGrowth` fires on cache insertion, (b) `nil` reporter produces zero events, (c) no emission on cache hit (read without insert).

**Exit criteria**:
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/AudioBufferCacheTelemetryTests CODE_SIGNING_ALLOWED=NO` passes

---

## Work Unit: verification

### Sortie 18: Documentation

**Priority**: 1.5 — only depends on Sortie 1 (public API stable); can run in parallel with all instrumentation work.

**Agent**: Sub-agent (Wave 4). No build step — pure documentation. Supervising agent verifies exit criteria.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all satisfied (public API stable)

**Tasks**:
1. Create `docs/TELEMETRY.md` documenting: the event vocabulary (one section per category from REQUIREMENTS §1.1), the reporter protocol contract, the injection patterns (setter for stateful, defaulted parameter for static), the invariants from REQUIREMENTS §6, and the anti-patterns from REQUIREMENTS §7.
2. Add a "Host adapter" section pointing to the Produciesta repo for the reference adapter implementation; do **not** include adapter source in this repo.
3. Cross-link `docs/TELEMETRY.md` from `CLAUDE.md` (next to the existing `docs/TELEMETRY_USAGE.md` reference) and from the repo `README.md` if it has a docs index.
4. Add example snippets showing: (a) how a host attaches a reporter, (b) how to write a `MockMLXAudioTelemetryReporter` for tests, (c) how to add a new event case (and what version-bump rule applies).

**Exit criteria**:
- [ ] `test -f docs/TELEMETRY.md` returns true
- [ ] `grep -q 'docs/TELEMETRY.md' CLAUDE.md` returns true
- [ ] For every relative `[label](path)` link in `docs/TELEMETRY.md`, `test -e <path>` returns true (a one-line shell loop is acceptable; example: `awk -F'[][]' '/\]\(/ {print $4}' docs/TELEMETRY.md | grep -v '^http' | while read p; do test -e "docs/$p" -o -e "$p" || { echo "BROKEN: $p"; exit 1; }; done`)
- [ ] `git diff --name-only` lists only files under `docs/`, plus optionally `CLAUDE.md` and `README.md` (no source/test files modified)

### Sortie 19: Integration & Zero-Overhead Verification

**Priority**: 3.5 — final mission verification; depends on every prior sortie.

**Agent**: Supervising agent (Wave 5).

**Entry criteria**:
- [ ] Sorties 2–17 exit criteria all satisfied
- [ ] `MockMLXAudioTelemetryReporter` available from Sortie 1

**Tasks**:
1. Add `Tests/MLXAudioTests/Telemetry/EndToEndTelemetryTests.swift` exercising one full path per category (model lifecycle, codec encode/decode, audio I/O) using `MockMLXAudioTelemetryReporter`. Use only CI-safe surfaces (no model downloads).
2. Add a baseline zero-overhead test that runs `AudioUtils.loadAudioArray` and a codec round-trip with `nil` reporter and asserts no observable side effects (no `print`, no `os_log`, no Metal sampling). Compare wall-clock vs. baseline within tolerance to verify invariant 3.
3. Add a hot-loop guard test (`Tests/MLXAudioTests/Telemetry/HotLoopGuardTests.swift` — or fold into EndToEnd) that performs the cross-cutting check: `grep -RIn "await emit(" Sources/MLXAudioTTS/ Sources/MLXAudioSTT/` returns zero matches inside any line that is also indented inside a `for ` or `while ` block (acceptable approximation: assert the file-level grep `grep -A2 -E '(for |while )' Sources/MLXAudioTTS/**/*.swift Sources/MLXAudioSTT/**/*.swift | grep 'await emit('` returns empty).
4. Document the canonical invariant grep commands in `docs/TELEMETRY.md` (the same ones run in this sortie's exit criteria).
5. Update `CLAUDE.md`'s `make test` target list to include every new `*TelemetryTests` suite added in Sorties 1–17 (`MLXAudioTelemetryEventTests`, `AudioModelManagerTelemetryTests`, `Qwen3TTSTelemetryTests`, `GLMASRTelemetryTests`, `MemoryTelemetryTests`, `VocosTelemetryTests`, `AudioUtilsTelemetryTests`, `SopranoTTSTelemetryTests`, `LlamaTTSTelemetryTests`, `PocketTTSTelemetryTests`, `MarvisTTSTelemetryTests`, `Qwen3ASRTelemetryTests`, `EncodecTelemetryTests`, `SNACTelemetryTests`, `MimiTelemetryTests`, `DACVAETelemetryTests`, `AudioBufferCacheTelemetryTests`, `EndToEndTelemetryTests`, `HotLoopGuardTests`).

**Exit criteria**:
- [ ] `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` runs the full CI-safe suite and passes
- [ ] `xcodebuild test ... -only-testing:MLXAudioTests/EndToEndTelemetryTests -only-testing:MLXAudioTests/HotLoopGuardTests CODE_SIGNING_ALLOWED=NO` passes
- [ ] Zero-overhead wall-clock delta: with `nil` reporter the codec round-trip + WAV load is **within 5% of baseline** (the asserted tolerance lives in the test; documented here for traceability)
- [ ] `grep -RIn "import .*Produciesta" Sources/` returns empty (invariant 1 — vendor neutrality)
- [ ] `grep -RIn "import swift_log\|import Logging\|import OSLog" Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift` returns empty (invariant 2 — no new deps)
- [ ] For every test name in task 5, `grep -F "<name>" CLAUDE.md` returns ≥ 1 match

---

## Open Questions & Missing Documentation

| Sortie | Issue Type | Description | Resolution |
|--------|-----------|-------------|------------|
| 1 | Open question (resolved) | "Shared internal `emit()` helper *or* document the inline `@autoclosure` pattern" | **Document the canonical snippet** in `MLXAudioTelemetryReporter.swift` doc comments; do not extract a shared helper because `telemetry` is per-instance state. Each instrumented class copies the 4-line snippet verbatim. See "Resolved Design Decisions" section. |
| 2 | Vague criterion (auto-fixed) | "No new public API on `AudioModelManager` other than `setTelemetry(_:)`" | Replaced with `git diff` + `grep` exit criterion that returns 0. |
| 3, 8–11 | Vague criterion (auto-fixed) | "Existing `<family>*` setup tests still pass" | Replaced with explicit `-only-testing:` lists per sortie. |
| 5 (was 4) | Non-atomic (auto-fixed) | Original Sortie 4 mixed Metal sampler creation + WiredMemoryManager + AudioPlayerManager cache | Split into Sortie 5 (Metal + WiredMemoryManager) and Sortie 17 (AudioPlayerManager cache). |
| 19 (was 17) | Vague criterion (auto-fixed) | "passes within tolerance"; "Invariant grep checks return empty"; cross-cutting hot-loop check inside Sortie 4 | Tolerance pinned at 5%; grep commands enumerated explicitly; hot-loop check moved out of memory-instrumentation sortie into the integration sortie where it belongs. |
| 18 | Vague criterion (auto-fixed) | "renders without broken internal links" | Replaced with explicit shell loop verifying `test -e` for every relative link target. |

**Manual review required**: 0 items. Plan is unblocked.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 6 |
| Total sorties | 19 (was 18; Sortie 4 split into 5 and 17) |
| Dependency structure | 3 layers — foundation (1) → instrumentation fan-out (2–18) → verification (19) |
| Critical path | 4 hops: Sortie 1 → Sortie 2 → Sortie 5 → Sortie 19 |
| Maximum parallelism | 4 sub-agents concurrent (cap); 16 sorties parallelizable in principle after Sortie 1 |
| Dispatch waves | 5 waves (0–5; Wave 1.5 is Sortie 5 dispatched mid-Wave-1 once Sortie 2 exits) |
| Sub-agent sorties | 14 (all instrumentation + docs); supervising agent runs builds at verification |
| Supervising-agent-only sorties | 5 (Sortie 1, 2, 5, 19, plus build/test verification on every sub-agent sortie) |

---

## Refinement Audit Trail

| Pass | Issues Found | Auto-Fixed | Manual Review |
|------|-------------|------------|--------------|
| 1. Atomicity & Testability | 11 (1 non-atomic + 10 vague criteria) | 11 | 0 |
| 2. Prioritization | n/a (scoring + reorder) | priority annotations + renumber | 0 |
| 3. Parallelism | n/a (analysis) | parallelism structure + agent allocation | 0 |
| 4. Open Questions & Vague Criteria | 1 open question | 1 | 0 |

**Verdict**: Plan is ready to execute. Next step: `/mission-supervisor start`.
