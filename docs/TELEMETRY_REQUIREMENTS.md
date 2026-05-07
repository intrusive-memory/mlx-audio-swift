# MLXAudio Telemetry Requirements

**Status**: Draft (in progress)
**Owner**: stovak@gmail.com
**Started**: 2026-05-06
**Primary motivation**: Find memory leaks in long-running TTS/ASR generation loops.

---

## 1. Scope

This document specifies the in-process telemetry surface for `mlx-audio-swift`.
Out of scope:

- Off-device / network telemetry (explicitly rejected — no per-device reporting).
- Backend integrations (Datadog, OTLP, etc.). Host apps may consume the
  `os.Logger` / `OSSignposter` streams however they wish.
- Crash reporting (handled by host apps).

In scope:

- Structured logging via Apple `os.Logger`, segregated by subsystem.
- Performance signposts via `OSSignposter` for Instruments traces.
- An in-process counters API (`Telemetry.snapshot()`) suitable for
  leak-detection assertions in tests.
- A leveled severity model with a sensible default and a compile-time
  ceiling on which levels are even built.

---

## 2. Goals & non-goals

### Goals

- **G1 — Leak detection.** Tests must be able to load N model instances,
  drop them, and assert live counts return to zero.
- **G2 — Zero overhead at default level in release builds.** The library
  should add no measurable cost to production workloads when telemetry
  is at the default `.lifecycle` level.
- **G3 — Instruments-native.** Signposts must show up grouped sensibly in
  Xcode Instruments without custom tooling.
- **G4 — Library-appropriate.** No global side effects, no opaque
  background threads, no implicit network. Host apps stay in control.

### Non-goals

- Per-device telemetry, analytics, or usage reporting.
- Replacing existing `print` / debug output (separate cleanup pass).
- Performance regression testing — that's the nightly perf suite's job.

---

## 3. Levels

Levels are monotonic — each level includes everything below it.

| Level | Name | What it adds | Overhead | Primary use |
|------:|------|--------------|----------|-------------|
| 0 | `.off` | Nothing emitted. | Zero | Embedded / sensitive contexts |
| 1 | `.lifecycle` | Init/deinit signposts on long-lived objects (`Module` subclasses holding weights, `KVCache`, tokenizers, engines). `Telemetry.liveCounts()` snapshot API. | Negligible | **Default. Leak detection.** |
| 2 | `.operations` | + Interval signposts around `loadWeights`, `encode`, `decode`, `generate`, model resolution / download. | ~µs/call | Instruments traces, hot-path inspection |
| 3 | `.memory` | + MLX memory snapshot (`GPU.activeMemory()`, peak) emitted before/after each operation. Per-op delta surfaced in `TelemetrySnapshot`. | Small but non-zero | Per-call leak pinpointing |
| 4 | `.verbose` | + Per-token / per-decode-step signposts inside generate loops. | Non-trivial | Active debugging only |

**Default active level: `.lifecycle`.**

---

## 4. Build configuration

Two-layer model: a compile-time **ceiling** (which levels are even built
into the binary) and a runtime **floor** (which level is active within
what's compiled in).

### Compile-time ceiling

Controlled by Swift compile flags declared in `Package.swift` under
`swiftSettings`. Default builds compile only level 0 + 1; higher levels
are removed via `#if` so they cannot accidentally ship in release.

| Flag | Effect |
|------|--------|
| *(none)* | Levels 0–1 compiled in. Levels 2–4 stripped at build time. |
| `MLXAUDIO_TELEMETRY_FULL` | All levels compiled in. |

`Package.swift` should automatically define `MLXAUDIO_TELEMETRY_FULL`
under `.debug` configuration:

```swift
swiftSettings: [
    .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
]
```

So:

- Debug builds (Xcode-driven dev, `make test`) → all levels available.
- Release builds → only `.off` and `.lifecycle` available, regardless
  of runtime env vars.

### Runtime floor

Within whatever levels are compiled in, the active level defaults to
`.lifecycle` and may be overridden at process start via environment
variable, with no rebuild required:

```
MLXAUDIO_TELEMETRY=off|lifecycle|operations|memory|verbose
```

If the requested level is higher than the compiled ceiling, the library
clamps to the ceiling and emits a single warning to `os.Logger` under
the `MLXAudio.Telemetry` subsystem.

### Test override

Test targets get `MLXAUDIO_TELEMETRY_FULL` defined (debug config), and
default to `.lifecycle` so leak assertions work without further setup.
Suites that need higher levels set `MLXAUDIO_TELEMETRY` in their
process info on a per-test basis.

---

## 5. Public API surface

All under `MLXAudioCore.Telemetry`.

```swift
public enum Telemetry {
    public enum Level: Int, Comparable, Sendable {
        case off, lifecycle, operations, memory, verbose
    }

    /// Currently active level. Resolved at first access from
    /// `MLXAUDIO_TELEMETRY` env var, clamped to compile-time ceiling.
    /// Single global switch — there is intentionally no per-subsystem override.
    public static var level: Level { get }

    /// Compile-time ceiling. `.lifecycle` in release builds,
    /// `.verbose` when `MLXAUDIO_TELEMETRY_FULL` is defined.
    public static var ceiling: Level { get }

    /// Snapshot of live object counts and MLX memory state.
    public static func snapshot() async -> TelemetrySnapshot

    /// Zero live-object counts and per-op deltas.
    /// `mlxPeakBytes` is monotonic and is **not** affected by reset
    /// (it's a process-lifetime high-water mark).
    /// Intended for tests between iterations.
    public static func resetCounters() async
}

public struct TelemetrySnapshot: Sendable {
    public let liveCounts: [String: Int]      // e.g. ["Qwen3TTS.Model": 1]
    public let mlxActiveBytes: Int
    public let mlxPeakBytes: Int               // monotonic; survives resetCounters()
    public let timestamp: Date
}
```

The counter store is implemented as an `actor` — `Telemetry.snapshot()` /
`resetCounters()` are therefore `async`. Init/deinit hooks in level-1
instrumentation use a fire-and-forget `Task { … }` to avoid forcing
every model's `init` / `deinit` to be async.

The per-subsystem `OSSignposter` instances are **internal** to
MLXAudio. Host apps that want their own signposts should declare their
own subsystems rather than emitting on ours, to keep Instruments
traces cleanly separated.

`os.Logger` instances are per-subsystem and exposed under
`MLXAudio.Logging.<subsystem>` so host apps can filter via `log` /
Console.app:

- `MLXAudio.Logging.core`
- `MLXAudio.Logging.modelResolver`
- `MLXAudio.Logging.qwen3TTS`
- `MLXAudio.Logging.llamaTTS`
- `MLXAudio.Logging.sopranoTTS`
- `MLXAudio.Logging.pocketTTS`
- `MLXAudio.Logging.marvisTTS`
- `MLXAudio.Logging.qwen3ASR`
- `MLXAudio.Logging.glmASR`
- `MLXAudio.Logging.codecs` (SNAC, Mimi, Encodec, DAC, Vocos)

Each subsystem owns an `OSSignposter` with the same identifier so
Instruments groups them cleanly.

---

## 6. Instrumentation map

### Level 1 (`.lifecycle`) — paired init/deinit signposts

Every long-lived object gets a `signpost.beginInterval("Lifetime", id, …)`
in init and `endInterval(…)` in deinit. Object class + instance pointer
are included so Instruments can pair them. The same events also bump
the per-class counter exposed via `liveCounts`.

Targets (initial set):

- All `MLX.Module` subclasses that hold model weights
  (`Qwen3TTSModel`, `LlamaTTSModel`, `SopranoTTSModel`, `PocketTTSModel`,
  `MarvisTTSModel`, `Qwen3ASRModel`, `GLMASRModel`, codec models).
- KV cache types — **highest priority** for leak hunting in generate
  loops.
- Tokenizer instances.
- Engine / runner top-level objects exposed in the public API.

### Level 2 (`.operations`) — interval signposts

- `ModelResolver.resolve` (whole call, including HF download).
- `Module.loadWeights` per model.
- `encode`, `decode`, `generate` public entry points.
- `Acervo.download` per file.

### Level 3 (`.memory`) — pre/post memory snapshots

For every Level-2 interval, attach a `before`/`after`/`delta` of MLX
memory (active + peak) as signpost metadata, and accumulate per-op
deltas in `TelemetrySnapshot`.

### Level 4 (`.verbose`) — per-iteration

- Per-token signpost in TTS/ASR generate loops.
- Per-decode-step in iterative codecs.
- KV cache grow events.

---

## 7. Memory leak detection workflow

The intended `XCTest` pattern (Level 1 only — the default):

```swift
func testQwen3TTSDoesNotLeak() throws {
    Telemetry.resetCounters()
    let baseline = Telemetry.snapshot()

    for _ in 0..<10 {
        autoreleasepool {
            let model = try Qwen3TTSModel(...)
            _ = try model.generate(...)
        }
    }

    let after = Telemetry.snapshot()
    XCTAssertEqual(
        after.liveCounts["Qwen3TTS.Model", default: 0],
        baseline.liveCounts["Qwen3TTS.Model", default: 0],
        "Qwen3TTSModel instances leaked across 10 generate iterations"
    )
}
```

For per-op leak pinpointing, run the same test under `MLXAUDIO_TELEMETRY=memory`
to get MLX memory deltas per operation; for visual inspection, run under
Instruments with the os_signpost track.

---

## 8. Defaults summary

| Context | Compile ceiling | Active level |
|---------|-----------------|--------------|
| Release build, no env var | `.lifecycle` | `.lifecycle` |
| Release build, env var set higher | `.lifecycle` (clamped) | `.lifecycle` + warning |
| Debug build, no env var | `.verbose` | `.lifecycle` |
| Debug build, `MLXAUDIO_TELEMETRY=memory` | `.verbose` | `.memory` |
| Test target, no env var | `.verbose` | `.lifecycle` |

---

## 9. Resolved decisions

All v1 design questions have been resolved (2026-05-06):

- **Global level only.** No per-subsystem overrides. A single
  `MLXAUDIO_TELEMETRY` env var controls the whole library. May revisit
  if a single noisy module ever forces global verbose.
- **`mlxPeakBytes` is monotonic.** `resetCounters()` zeroes live-object
  counts and per-op deltas only; peak survives so the
  process-lifetime high-water mark is preserved across test iterations.
- **Counter store is an `actor`.** Matches the pattern used elsewhere
  in this codebase. Public `snapshot()` / `resetCounters()` are
  therefore `async`. Init/deinit hooks use fire-and-forget `Task { … }`.
- **`OSSignposter` instances are internal.** Host apps declare their
  own subsystems rather than emitting on ours.

---

## 10. Implementation phases (proposed)

1. **Scaffolding** — `Telemetry` enum, `TelemetrySnapshot`, env-var
   resolution, `Logger`/`OSSignposter` per subsystem, build flag.
2. **Level 1 instrumentation** — paired init/deinit on all model and
   KV cache types. Land first leak-detection test.
3. **Level 2 instrumentation** — operation intervals.
4. **Level 3 instrumentation** — MLX memory snapshots.
5. **Level 4 instrumentation** — per-token / per-step.
6. **Docs & examples** — README section, sample `XCTest` patterns,
   Instruments template if useful.

Phases 1–2 are the leak-finding minimum and can ship before 3–5.
