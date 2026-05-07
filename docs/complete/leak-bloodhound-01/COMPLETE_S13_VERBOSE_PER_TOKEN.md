# SORTIE 13 COMPLETE — Verbose Per-Token Signposts

**Branch**: `mission/leak-bloodhound/01`
**Commit**: `886d9c8`
**Date**: 2026-05-07

---

## What Was Done

### 1. `Telemetry.emitEvent` Helper (IntervalEmitter.swift)

Added `Telemetry.emitEvent(family:name:tokenIndex:)` — a synchronous point-event helper (parallel to the existing `emitInterval` pattern from S10/S11):

```swift
public static func emitEvent(
    family: Family,
    name: StaticString,
    tokenIndex: Int
) {
    let sp = family.signposter
    let id = sp.makeSignpostID()
    sp.emitEvent(name, id: id, "token:\(tokenIndex)")
    #if MLXAUDIO_TELEMETRY_FULL
    _eventRecorder?.recordEvent(family: family.rawValue, name: "\(name)", tokenIndex: tokenIndex)
    #endif
}
```

### 2. `TelemetryEventRecorder` Protocol + `_eventRecorder` Seam

Added behind `#if MLXAUDIO_TELEMETRY_FULL`:

- `TelemetryEventRecorder` protocol (mirrors `TelemetryIntervalRecorder`)
- `nonisolated(unsafe) internal static var _eventRecorder: TelemetryEventRecorder?`
- `_installEventRecorder(_:) -> TelemetryEventRecorder?` swap-and-return seam

### 3. Per-Token Signposts in All 7 Generate Loops

Each insertion uses the two-layer gate:
```swift
#if MLXAUDIO_TELEMETRY_FULL
if Telemetry.level >= .verbose {
    Telemetry.emitEvent(family: .<family>, name: "<Family>.token", tokenIndex: step)
}
#endif
```

| File | Family | Loop variable |
|------|--------|---------------|
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:905` | `.qwen3TTS` | `step` |
| `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift:761` | `.llamaTTS` | `i` |
| `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift:881` | `.sopranoTTS` | `sopranoTokenStep` (manual counter, loop uses `_`) |
| `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift:287` | `.pocketTTS` | `step` |
| `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift:497` | `.marvisTTS` | `marvisTokenStep` (manual counter, loop uses `_`) |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift:1024` | `.qwen3ASR` | `qwen3TokenStep` |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift:1092` | `.qwen3ASR` | `qwen3ChunkTokenStep` |
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift:439` | `.glmASR` | `glmTokenStep` (generate) |
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift:514` | `.glmASR` | `glmStreamTokenStep` (generateStream) |

### 4. TelemetryVerboseTests.swift (CI-safe, no model downloads)

Three tests, race-condition-free design:

- **`testVerboseLevelResolvesUnderFullCeiling`**: Verifies Level enum ordering and `_installLevelOverride`/`_levelOverride` round-trip. Reads `_levelOverride` directly (not `Telemetry.level`) to avoid cross-suite race windows.
- **`testTTSPerTokenEmitsExpectedCount`**: Installs `TestEventRecorder`, calls `emitEvent` 5 times directly (no generate loop, no level manipulation), asserts exactly 5 events with correct family/name/index.
- **`testVerboseGateShortCircuits`**: Uses local `let belowVerbose = Telemetry.Level.operations` and `let atVerbose = Telemetry.Level.verbose` constants — no global `_levelOverride` writes, immune to concurrent suite execution.

---

## Verification

### Exit Criterion: ≥ 7 occurrences of `level >= .verbose` in Sources/

```
$ grep -rn 'level >= .verbose' Sources/MLXAudioTTS Sources/MLXAudioSTT
```

Result: **9 occurrences** (5 TTS + 4 ASR — 2 loops each in GLMASR and Qwen3ASR).

### Test Results

```
TelemetryVerboseTests (isolation):  3/3 passed
Full CI-safe block (329 tests, 39 suites):  ALL PASSED
```

---

## Files Changed

- `Sources/MLXAudioCore/Telemetry/IntervalEmitter.swift` — `emitEvent`, `TelemetryEventRecorder`, `_eventRecorder`, `_installEventRecorder`
- `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` — per-token signpost
- `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` — per-token signpost
- `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` — per-token signpost (manual counter)
- `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` — per-token signpost
- `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` — per-token signpost (manual counter)
- `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` — per-token signposts (2 loops)
- `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` — per-token signposts (generate + generateStream)
- `Tests/TelemetryVerboseTests.swift` — new CI-safe test suite (3 tests)
