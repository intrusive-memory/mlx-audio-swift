# Parity Fixtures

Numerical-parity test fixtures for the Swift ports of audio-codec and DSP layers.

Each subdirectory holds the canonical PyTorch-reference output for one layer
family. Swift parity tests load `input.safetensors` and `weights.safetensors`,
run the Swift port of the same layer, and assert
`MLX.allclose(swift_output, expected, atol: 1e-4, rtol: 1e-4)`.

## Why parity tests exist

Critical finding **C1** in `TESTING_REQUIREMENTS.md` (audit dated 2026-04-30)
identified that none of the codec/DSP Swift ports had numerical-correctness
tests against their original PyTorch reference implementations. A bug in any
ported layer (off-by-one in padding, transposed weights, wrong activation
constant, etc.) would compile and produce plausible-looking audio without
failing any test.

These fixtures close that gap. The PyTorch impl is the source of truth; the
Swift port must match it bit-for-bit modulo float32 rounding.

## Layout

```
Tests/media/parity/
├── _generate.py              # PyTorch reference generator (this directory)
├── README.md                 # this file
├── dsp/                      # short STFT primitive (Sortie 16 will extend this)
├── vocos_istft_head/         # Vocos ISTFTHead — gemelo-ai/vocos
├── encodec_quantizer/        # Encodec residual VQ — facebookresearch/encodec
├── dacvae_encoder_block/     # DAC encoder block — descriptinc/descript-audio-codec
├── snac_vq/                  # SNAC VQ — hubertsiuzdak/snac
└── mimi_rvq/                 # Mimi residual VQ — kyutai-labs/moshi
```

Every layer-family directory contains exactly three files:

| File                    | Contents                                       |
|-------------------------|------------------------------------------------|
| `input.safetensors`     | Inputs fed to the reference forward pass.      |
| `weights.safetensors`   | Layer parameters (random init, fixed seed).    |
| `expected.safetensors`  | Reference outputs to compare Swift against.    |

All tensors are saved as `float32`, contiguous, in CPU memory. Tensor key
naming inside each safetensors file is documented in the corresponding
generator function in `_generate.py` and follows the PyTorch
`state_dict()` naming convention where possible (e.g.,
`proj.weight`, `proj.bias`, `layers.0.codebook`).

## Regenerating

Requirements: Python 3.11+, `torch`, `numpy`, `safetensors`.

```bash
# Regenerate all six fixture sets (deterministic — fixed seed 1337):
python3 Tests/media/parity/_generate.py --all

# Regenerate just one family:
python3 Tests/media/parity/_generate.py --family dsp
python3 Tests/media/parity/_generate.py --family vocos_istft_head
python3 Tests/media/parity/_generate.py --family encodec_quantizer
python3 Tests/media/parity/_generate.py --family dacvae_encoder_block
python3 Tests/media/parity/_generate.py --family snac_vq
python3 Tests/media/parity/_generate.py --family mimi_rvq
```

The script seeds `torch.manual_seed(1337)` and `numpy.random.seed(1337)` at
the start of every family, so output is bit-identical across runs on the
same machine.

## Size budget

Combined fixtures must stay under 5 MiB so they can live in the repo
without bloating the SPM bundle. As of Sortie 1, total size is ≈ 45 KB.
If a future change pushes total size above 5 MiB, split heavy fixtures
out into a downloadable archive and update this README.

Verify with:

```bash
gdu -sb Tests/media/parity/    # GNU coreutils (brew install coreutils)
# or, on stock macOS without coreutils:
find Tests/media/parity -type f -exec stat -f "%z" {} \; | awk '{s+=$1} END {print s}'
```

## Adding a new fixture family

1. Add a `gen_<name>` function in `_generate.py` mirroring the upstream
   PyTorch reference. Keep input shapes small (≤ 32 channels, ≤ 64
   timesteps) so weights and outputs stay tiny.
2. Append `(name, gen_<name>)` to the `GENERATORS` dispatch dict.
3. Run `python3 Tests/media/parity/_generate.py --family <name>`.
4. Document the upstream source URL/path in the generator's docstring.
5. Author the corresponding Swift parity test in `Tests/`.

## Sortie scope notes

This directory was bootstrapped by **Sortie 1** of OPERATION ECHO DRAGNET
(see `EXECUTION_PLAN.md`). The Python pipeline is intentionally
self-contained:

- **Sortie 1** ships the pipeline and six initial fixture families.
- **Sortie 16** *extends* (does not replace) `_generate.py` with additional
  DSP fixtures: full mel spectrogram, FFT, STFT, iSTFT, hann window,
  resampling 48k→24k.
- **Sortie 20** ships a **separate** generator under
  `Tests/media/parity/tokenizer/_generate.py` for tokenizer round-trip
  fixtures. Tokenizer fixtures live in their own subdirectory because the
  upstream dependencies and audience differ from the codec/DSP layers.

If a fourth `_generate.py` is ever proposed, escalate the duplication
question to a maintainer before adding it (per the open-question
resolution in `EXECUTION_PLAN.md`).

## License notes

The PyTorch reference architectures mirrored in `_generate.py` are
re-implemented (not copied) from their upstream sources:

- Vocos — gemelo-ai/vocos (MIT)
- Encodec — facebookresearch/encodec (MIT)
- DAC — descriptinc/descript-audio-codec (MIT)
- SNAC — hubertsiuzdak/snac (MIT)
- Mimi — kyutai-labs/moshi (MIT/Apache-2.0)

Random fixture weights are not derived from any pretrained model.
