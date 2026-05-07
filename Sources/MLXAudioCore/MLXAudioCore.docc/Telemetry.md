# Telemetry

In-process telemetry surface for finding memory leaks and profiling
generation hot paths in `MLXAudioCore`.

## Overview

`MLXAudioCore` ships a leveled telemetry system built on Apple's
`os.Logger` and `OSSignposter` frameworks. It is designed for:

- **Leak detection** — paired init/deinit counters on every long-lived
  object, queryable via ``Telemetry/snapshot()`` so tests can assert
  zero-delta after model allocation loops.
- **Performance tracing** — interval signposts on every `loadWeights`,
  `generate`, `encode`, and `decode` call site, grouped by subsystem
  in Instruments.
- **Memory pinpointing** — MLX active-memory deltas attached to every
  operation interval, accumulated in ``TelemetrySnapshot/perOpDeltas``.

The default active level is ``Telemetry/Level/lifecycle``, which adds
negligible overhead in production. Higher levels require a debug build
(the `MLXAUDIO_TELEMETRY_FULL` compile flag) and an environment variable
override.

See [docs/TELEMETRY_USAGE.md](https://github.com/intrusive-memory/mlx-audio-swift/blob/main/docs/TELEMETRY_USAGE.md)
for concrete walkthroughs and Instruments setup.
See [docs/TELEMETRY_REQUIREMENTS.md](https://github.com/intrusive-memory/mlx-audio-swift/blob/main/docs/TELEMETRY_REQUIREMENTS.md)
for the full requirements specification and defaults table.

---

## Levels

| Level | `Telemetry.Level` | Compile gate | What is added |
|------:|-------------------|--------------|----|
| 0 | ``Telemetry/Level/off`` | always | Nothing emitted |
| 1 | ``Telemetry/Level/lifecycle`` | always | Init/deinit counters on every long-lived object; ``Telemetry/snapshot()`` API |
| 2 | ``Telemetry/Level/operations`` | `MLXAUDIO_TELEMETRY_FULL` | Interval signposts on load/generate/encode/decode |
| 3 | ``Telemetry/Level/memory`` | `MLXAUDIO_TELEMETRY_FULL` | MLX memory deltas attached to each interval |
| 4 | ``Telemetry/Level/verbose`` | `MLXAUDIO_TELEMETRY_FULL` | Per-token/per-step point events |

---

## Public API

### `Telemetry` enum

``Telemetry`` is the entry point for all telemetry operations.

- ``Telemetry/level`` — the currently active level, resolved from the
  `MLXAUDIO_TELEMETRY` environment variable, clamped to ``Telemetry/ceiling``.
- ``Telemetry/ceiling`` — the compile-time ceiling. `.lifecycle` in release;
  `.verbose` when `MLXAUDIO_TELEMETRY_FULL` is defined.
- ``Telemetry/snapshot()`` — async snapshot of live object counts and MLX
  memory state.
- ``Telemetry/resetCounters()`` — zero live-object counts and per-op deltas.
  `mlxPeakBytes` is monotonic and survives reset.

### `TelemetrySnapshot` struct

``TelemetrySnapshot`` is the value returned by ``Telemetry/snapshot()``:

- ``TelemetrySnapshot/liveCounts`` — `[String: Int]` mapping counter key
  (e.g. `"Qwen3TTS.Model"`) to current live instance count.
- ``TelemetrySnapshot/mlxActiveBytes`` — current MLX GPU active memory in bytes.
- ``TelemetrySnapshot/mlxPeakBytes`` — process-lifetime high-water mark (not
  reset by ``Telemetry/resetCounters()``).
- ``TelemetrySnapshot/perOpDeltas`` — `[String: Int]` accumulated MLX memory
  deltas keyed by operation name (e.g. `"Qwen3TTS.generate"`). Requires Level 3.
- ``TelemetrySnapshot/timestamp`` — when the snapshot was taken.

### `MLXAudioLogging` enum

``MLXAudioLogging`` exposes one `public static let Logger` per subsystem so
host apps can filter on `log(1)` / Console.app:

| Property | Subsystem identifier |
|----------|----------------------|
| ``MLXAudioLogging/core`` | `MLXAudio.core` |
| ``MLXAudioLogging/modelResolver`` | `MLXAudio.modelResolver` |
| ``MLXAudioLogging/qwen3TTS`` | `MLXAudio.qwen3TTS` |
| ``MLXAudioLogging/llamaTTS`` | `MLXAudio.llamaTTS` |
| ``MLXAudioLogging/sopranoTTS`` | `MLXAudio.sopranoTTS` |
| ``MLXAudioLogging/pocketTTS`` | `MLXAudio.pocketTTS` |
| ``MLXAudioLogging/marvisTTS`` | `MLXAudio.marvisTTS` |
| ``MLXAudioLogging/qwen3ASR`` | `MLXAudio.qwen3ASR` |
| ``MLXAudioLogging/glmASR`` | `MLXAudio.glmASR` |
| ``MLXAudioLogging/codecs`` | `MLXAudio.codecs` |

The matching `OSSignposter` instances share the same subsystem identifier but
are `internal` to MLXAudioCore. Host apps that want their own signposts should
declare their own subsystems.

---

## Env-Var Reference

```
MLXAUDIO_TELEMETRY=off|lifecycle|operations|memory|verbose
```

Values are case-insensitive. Invalid values fall back to `.lifecycle`. If the
requested level exceeds the compile-time ceiling, the library clamps to the
ceiling and emits a one-shot warning on the `MLXAudio.Telemetry` logger.

---

## Topics

### Types
- ``Telemetry``
- ``TelemetrySnapshot``
- ``MLXAudioLogging``
