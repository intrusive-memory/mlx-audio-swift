# MLXAudio Telemetry — Usage Walkthrough

This walkthrough is for host-app developers and contributors who want to use the
MLXAudio telemetry surface introduced in OPERATION LEAK BLOODHOUND (Sorties 1–14).
It covers three concrete use cases: leak detection at Level 1, per-op memory
pinpointing at Level 3, and Instruments trace capture at Level 2.

For the full specification — requirements, defaults table, and the authoritative
public API listing — see [`docs/TELEMETRY_REQUIREMENTS.md`](TELEMETRY_REQUIREMENTS.md).
For the test-side patterns already wired into the test suite, see
[`Tests/MLXAudioTests/README.md`](../Tests/MLXAudioTests/README.md).

---

## Glossary of Levels

Levels are monotonic — each includes everything below it.

| Level | Name | What it adds | Compile gate | Default? |
|------:|------|--------------|--------------|----------|
| 0 | `.off` | Nothing. | — | |
| 1 | `.lifecycle` | Paired init/deinit counters on every long-lived object. `Telemetry.snapshot()` / `resetCounters()` API. | Always compiled in | **Yes** |
| 2 | `.operations` | + Interval signposts on `loadWeights`, `encode`, `decode`, `generate`, model resolution, download. | `MLXAUDIO_TELEMETRY_FULL` only | |
| 3 | `.memory` | + MLX active-memory deltas before/after each operation. Per-op accumulation in `TelemetrySnapshot.perOpDeltas`. | `MLXAUDIO_TELEMETRY_FULL` only | |
| 4 | `.verbose` | + Per-token signposts in TTS/ASR generate loops. Per-decode-step in iterative codecs (Mimi). KV cache grow events in Mimi's transformer. | `MLXAUDIO_TELEMETRY_FULL` only | |

**Compile ceiling**: `MLXAUDIO_TELEMETRY_FULL` is defined in `.debug` builds
(including test builds) by `Package.swift`. Levels above `.lifecycle` strip at
compile time in release builds — they cannot accidentally ship in production.

**Runtime floor**: Set `MLXAUDIO_TELEMETRY=<level>` to override the default
within what is compiled. Valid values: `off|lifecycle|operations|memory|verbose`
(case-insensitive). If the requested level exceeds the compiled ceiling, the
library clamps to the ceiling and emits a one-shot warning on the
`MLXAudio.Telemetry` os.Logger subsystem.

---

## Example 1 — Leak Detection (Level 1)

Level 1 is the **default** at all build configurations. No env var or compile
flag is required. Use `Telemetry.snapshot()` / `Telemetry.resetCounters()` to
assert that live object counts return to zero after a generation loop.

### Step-by-step pattern

```swift
import MLXAudioCore
import Testing          // Swift Testing framework

@Test("Qwen3TTSModel does not leak")
func testQwen3TTSDoesNotLeak() async throws {
    // Step 1: Reset counters to a known state.
    await Telemetry.resetCounters()

    // Step 2: Capture baseline BEFORE the allocation loop.
    // Using delta (after - before) handles pre-existing live instances from
    // framework init without requiring absolute-zero counts.
    let before = await Telemetry.snapshot()

    // Step 3: Loop — create and drop inside autoreleasepool so ARC releases
    // deterministically at the end of each iteration.
    for _ in 0..<10 {
        autoreleasepool {
            let model = Qwen3TTSModel(config: someConfig)
            _ = model  // prevent compiler from eliding the allocation
            // ARC releases model here → deinit fires → Telemetry.trackLifecycleEnd
            // schedules a decrement on the CounterStore actor.
        }
    }

    // Step 4: Drain in-flight background Tasks before asserting.
    // trackLifecycleEnd uses fire-and-forget Task.detached; give the runtime
    // up to 200 ms to process them.
    var after = await Telemetry.snapshot()
    let key = "Qwen3TTS.Model"
    for _ in 0..<200 {
        if (after.liveCounts[key] ?? 0) == before.liveCounts[key, default: 0] { break }
        try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        after = await Telemetry.snapshot()
    }

    // Step 5: Assert the delta is zero.
    #expect(
        after.liveCounts[key, default: 0] == before.liveCounts[key, default: 0],
        "Qwen3TTS.Model leaked across 10 generate iterations"
    )
}
```

### Counter key reference

Every instrumented class registers under a `"<Family>.<Role>"` key:

| Counter key | Class | Role |
|-------------|-------|------|
| `Qwen3TTS.Model` | `Qwen3TTSModel` | Model weights |
| `LlamaTTS.Model` | `LlamaTTSModel` | Model weights |
| `SopranoTTS.Model` | `SopranoModel` | Model weights |
| `PocketTTS.Model` | `PocketTTSModel` | Model weights |
| `MarvisTTS.Model` | `MarvisTTSModel` | Model weights |
| `Qwen3ASR.Model` | `Qwen3ASRModel` | Model weights |
| `GLMASR.Model` | `GLMASRModel` | Model weights |
| `SNAC.Model` | `SNACDecoder` | Codec |
| `Mimi.Model` | `Mimi` | Codec |
| `Encodec.Model` | `Encodec` | Codec |
| `DAC.Model` | `DACVAE` | Codec |
| `Vocos.Model` | `Vocos` | Codec |
| `Qwen3TTS.Tokenizer` | `Qwen3TTSSpeechTokenizer` | Tokenizer |
| `PocketTTS.Tokenizer` | `SentencePieceTokenizer` | Tokenizer |
| `Core.Tokenizer` | `UnigramTokenizer` | Tokenizer |
| `Mimi.Tokenizer` | `MimiTokenizer` | Tokenizer |
| `Qwen3ASR.Aligner` | `Qwen3ForcedAlignerModel` | Aligner |
| `*.KVCache` | `KVCacheSimple` (via sentinel) | KV cache |

### Two instrumentation idioms

The library uses two distinct styles, both visible when reading `snapshot().liveCounts`:

**Idiom 1 — in-class init/deinit** (S6/S7/S8): Model and tokenizer classes call
`Telemetry.trackLifecycle(self, className:)` in `init` and
`Telemetry.trackLifecycleEnd(className:)` in `deinit`. Use this pattern when you
add lifecycle tracking to your own classes.

**Idiom 2 — sentinel / associated-object** (S5): Used for `KVCacheSimple` which
lives in an external package and cannot be subclassed. The free function
`attachKVCacheLifecycle(family:to:)` binds a `KVCacheLifecycleSentinel` via
`objc_setAssociatedObject`; when the cache is released, ARC releases the sentinel,
which fires the matching decrement in its own `deinit`.

### CI-safe leak test (no model downloads)

```sh
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
  CODE_SIGNING_ALLOWED=NO
```

Per-family leak tests (requires model downloads; runs in nightly workflow):

```sh
MLXAUDIO_NIGHTLY_RUN=1 xcodebuild test -scheme MLXAudio-Package \
  -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLeakDetectionQwen3TTSTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## Example 2 — Per-Op Memory Pinpointing (Level 3, `MLXAUDIO_TELEMETRY=memory`)

When a leak test fails, or when you want to understand which operation allocates
the most memory, run at Level 3. This requires a **debug build** (the
`MLXAUDIO_TELEMETRY_FULL` compile flag must be present).

### Enabling Level 3

Set the env var before invoking the test runner:

```sh
MLXAUDIO_TELEMETRY=memory xcodebuild test \
  -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLeakDetectionQwen3TTSTests \
  CODE_SIGNING_ALLOWED=NO
```

Or set it in the Xcode scheme's "Arguments → Environment Variables" panel.

### Reading `TelemetrySnapshot.perOpDeltas`

At Level 3, every `emitInterval` / `emitIntervalAsync` call in the library
captures `MLX.Memory.activeMemory` before and after its body and accumulates the
delta in `CounterStore.shared`. After the test run, call:

```swift
let snap = await Telemetry.snapshot()
// Print all operations sorted by total delta (positive = leak candidate)
let sorted = snap.perOpDeltas.sorted { $0.value > $1.value }
for (op, delta) in sorted {
    print(String(format: "  %-40s %+.1f MB", op, Double(delta) / 1_048_576))
}
```

A typical healthy output after 10 Qwen3TTS generation iterations looks like:

```
  Qwen3TTS.generate                         +0.0 MB   ← no leak
  Qwen3TTS.loadWeights.talker               +847.2 MB ← one-time load, OK
  ModelResolver.resolve                     +0.0 MB
```

A **leaking** session shows steadily positive `Qwen3TTS.generate`:

```
  Qwen3TTS.generate                         +420.0 MB ← 42 MB × 10 iterations
```

That tells you the leak is inside `generate`, not during weight loading. Narrow
further by enabling Level 4 verbose signposts and reading the Instruments trace
(see Example 3).

### Canonical per-op keys

The keys in `perOpDeltas` match the interval names in Instruments exactly. See the
full key table in `COMPLETE_S12_MEMORY_SNAPSHOTS.md` or the summary below:

**Model resolution / weight loading** (examples):
- `"ModelResolver.resolve"`, `"Acervo.download"`, `"Qwen3TTS.loadWeights.talker"`,
  `"Qwen3TTS.loadWeights.speakerEncoder"`, `"LlamaTTS.loadWeights"`, etc.

**Generation / encode / decode**:
- `"Qwen3TTS.generate"`, `"LlamaTTS.generate"`, `"SopranoTTS.generate"`,
  `"PocketTTS.generate"`, `"MarvisTTS.generate"`, `"Qwen3ASR.generate"`,
  `"GLMASR.generate"`
- `"SNAC.encode"`, `"SNAC.decode"`, `"Mimi.encode"`, `"Mimi.decode"`,
  `"Encodec.encode"`, `"Encodec.decode"`, `"DAC.encode"`, `"DAC.decode"`,
  `"Vocos.decode"`

### Reset semantics

`Telemetry.resetCounters()` zeroes `liveCounts` **and** `perOpDeltas`. The
`mlxPeakBytes` field is intentionally **not** reset — it is a monotonic
process-lifetime high-water mark. Call `resetCounters()` between test iterations
to isolate per-iteration deltas.

---

## Example 3 — Instruments Trace Capture (Level 2 with os_signpost)

Level 2 attaches begin/end interval signposts to every `loadWeights`, `encode`,
`decode`, and `generate` call site, plus model resolution and file download.
These show up on the **os_signpost** instrument track in Xcode Instruments.

### Enabling Level 2

Level 2 requires a **debug build** with the `MLXAUDIO_TELEMETRY_FULL` compile
flag (set automatically by `Package.swift`). Override the runtime level:

```sh
MLXAUDIO_TELEMETRY=operations <your app binary>
```

Or in Xcode scheme → Run → Arguments → Environment Variables:
```
MLXAUDIO_TELEMETRY = operations
```

### Manual Instruments configuration (no .tracetemplate required)

1. Open **Xcode → Product → Profile** (`⌘ I`) with your app scheme selected.
   Instruments opens with the "Time Profiler" template.

2. Press **⌘ N** (New Instrument) and add **os_signpost**.

3. In the os_signpost instrument's "Subsystem" filter, type each subsystem
   identifier you want to trace. The 10 MLXAudio subsystems are:

   | Subsystem identifier | Models / codecs covered |
   |----------------------|------------------------|
   | `MLXAudio.core` | Core utilities |
   | `MLXAudio.modelResolver` | `ModelResolver.resolve`, `Acervo.download` |
   | `MLXAudio.qwen3TTS` | Qwen3-TTS family |
   | `MLXAudio.llamaTTS` | LlamaTTS / Orpheus |
   | `MLXAudio.sopranoTTS` | Soprano TTS |
   | `MLXAudio.pocketTTS` | PocketTTS |
   | `MLXAudio.marvisTTS` | Marvis TTS |
   | `MLXAudio.qwen3ASR` | Qwen3 ASR |
   | `MLXAudio.glmASR` | GLM-ASR |
   | `MLXAudio.codecs` | SNAC, Mimi, Encodec, DAC, Vocos |

4. Click **Record** and exercise your app (run a TTS generation, ASR transcription,
   etc.). Press **Stop**.

5. In the os_signpost lane, each interval appears as a colored bar. The bar label
   is the interval name (e.g., `"Qwen3TTS.generate"`). Hover over a bar to see
   duration. Use **Level 3** (`MLXAUDIO_TELEMETRY=memory`) to additionally see
   `before`/`after`/`delta` memory metadata on each interval event.

### Reading the timeline

**Healthy generation (no leak)**: Each `generate` interval ends, MLX memory
returns to near the `loadWeights` baseline. The "Lifetime" intervals for model
objects (Level 1) span the entire test; each KV cache lifetime bar is short,
starting inside `generate` and ending before the next iteration.

**Leak pattern**: A KV cache "Lifetime" bar that extends beyond the enclosing
`generate` interval (or never ends) indicates the cache is not being released
at the end of generation.

### Level 4 — per-token drilldown

If you need sub-operation resolution, set `MLXAUDIO_TELEMETRY=verbose`. This
emits one point event per token in every TTS/ASR generate loop and per decode
step in `MimiStreamingDecoder`. Use the os_signpost "Points of Interest" lane
to see token cadence.

The per-token event labels are:
- `"Qwen3TTS.token"`, `"LlamaTTS.token"`, `"SopranoTTS.token"`,
  `"PocketTTS.token"`, `"MarvisTTS.token"`, `"Qwen3ASR.token"`,
  `"GLMASR.token"`, `"Mimi.decodeStep"`

---

## Cross-references

- Full requirements and API specification: [`docs/TELEMETRY_REQUIREMENTS.md`](TELEMETRY_REQUIREMENTS.md)
- Test suite documentation and leak-detection patterns: [`Tests/MLXAudioTests/README.md`](../Tests/MLXAudioTests/README.md)
- Nightly leak-detection CI: [`.github/workflows/nightly-tests.yaml`](../.github/workflows/nightly-tests.yaml)
- Project README Telemetry section: [`README.md § Telemetry`](../README.md#telemetry)
