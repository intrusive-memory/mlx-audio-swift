#!/usr/bin/env python3
"""
_generate.py — PyTorch reference fixture generator for Swift parity tests.

Emits, per layer family, three safetensors files:
  - input.safetensors      — input tensor(s) fed to the reference impl
  - weights.safetensors    — model parameters (small random init, fixed seed)
  - expected.safetensors   — output tensor(s) from running the PyTorch reference

The Swift side loads input + weights, runs the Swift port of the same layer,
and asserts MLX.allclose(swift_output, expected, atol=1e-4, rtol=1e-4).

Layer families (Sortie 1):
  dsp/                  Short FFT/iSTFT round-trip primitive
  vocos_istft_head/     Vocos ISTFTHead (linear -> mag/phase -> iSTFT)
  encodec_quantizer/    Encodec residual VQ (single layer, small codebook)
  dacvae_encoder_block/ DAC encoder block (Snake1d + WNConv1d residuals + downsample)
  snac_vq/              SNAC vector quantizer (single layer, small codebook)
  mimi_rvq/             Mimi residual VQ (2 layers, small codebook)

Sortie 16 will EXTEND this script with additional DSP fixtures
(mel spectrogram, hann window, resampling). It will NOT replace it.

Usage:
  python3 Tests/media/parity/_generate.py --all
  python3 Tests/media/parity/_generate.py --family dsp
  python3 Tests/media/parity/_generate.py --family vocos_istft_head

Requirements: Python 3.11+, torch, numpy, safetensors.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from pathlib import Path
from typing import Callable, Dict

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from safetensors.torch import save_file

SEED = 1337
PARITY_ROOT = Path(__file__).resolve().parent


def _seed_everything(seed: int = SEED) -> None:
    torch.manual_seed(seed)
    np.random.seed(seed)


def _save(path: Path, tensors: Dict[str, torch.Tensor]) -> None:
    """Save a dict of tensors to a safetensors file. All tensors -> float32 contiguous."""
    out = {}
    for k, v in tensors.items():
        if not isinstance(v, torch.Tensor):
            v = torch.as_tensor(v)
        out[k] = v.detach().to(torch.float32).contiguous().cpu()
    path.parent.mkdir(parents=True, exist_ok=True)
    save_file(out, str(path))


# ---------------------------------------------------------------------------
# Family 1: DSP — short STFT round-trip primitive
# ---------------------------------------------------------------------------
def gen_dsp(out_dir: Path) -> None:
    """A small STFT primitive: real input -> stft (one frame) -> magnitude.

    Sortie 1 ships a minimal smoke-style DSP fixture so the loader has
    something to chew on. Sortie 16 will replace this with the full DSP
    suite (mel spec, hann window, resampling, etc.).
    """
    _seed_everything()
    n_fft = 64
    hop_length = 16
    win_length = 64
    # 256-sample input — small, deterministic.
    t = torch.linspace(0.0, 1.0, steps=256, dtype=torch.float32)
    # Mixed sine + small noise so we exercise both real and imag bins.
    audio = torch.sin(2.0 * math.pi * 5.0 * t) + 0.1 * torch.randn(256)
    audio = audio.to(torch.float32)

    window = torch.hann_window(win_length, periodic=True, dtype=torch.float32)

    # STFT (complex), magnitude as expected output.
    stft = torch.stft(
        audio,
        n_fft=n_fft,
        hop_length=hop_length,
        win_length=win_length,
        window=window,
        center=True,
        pad_mode="reflect",
        return_complex=True,
    )
    magnitude = torch.abs(stft).to(torch.float32)  # [n_fft//2+1, frames]

    _save(out_dir / "input.safetensors", {"audio": audio})
    _save(
        out_dir / "weights.safetensors",
        {"window": window},
    )
    _save(
        out_dir / "expected.safetensors",
        {"magnitude": magnitude},
    )


# ---------------------------------------------------------------------------
# Family 2: Vocos ISTFTHead
# ---------------------------------------------------------------------------
class VocosISTFTHead(nn.Module):
    """Faithful (small) port of Vocos ISTFTHead.

    Reference: https://github.com/gemelo-ai/vocos
    src/vocos/heads.py — ISTFTHead

    Operation:
      Linear(dim -> n_fft+2)
      split -> mag = exp(clamp(x[..., :n_fft//2+1])); phase = x[..., n_fft//2+1:]
      complex spec = mag * exp(j * phase)
      iSTFT(spec)
    """

    def __init__(self, dim: int, n_fft: int, hop_length: int):
        super().__init__()
        self.n_fft = n_fft
        self.hop_length = hop_length
        out_dim = n_fft + 2
        self.proj = nn.Linear(dim, out_dim)
        # Hann window as buffer (fixed, not a parameter, but we save it as a
        # weight so the Swift side gets the same window).
        self.register_buffer(
            "window", torch.hann_window(n_fft, periodic=True, dtype=torch.float32)
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [batch, time, dim]   (Vocos uses [B, dim, T] internally; we use the
        # NLP-style [B, T, dim] layout to match the Swift API more closely.)
        x = self.proj(x)  # [B, T, n_fft+2]
        half = self.n_fft // 2 + 1
        log_mag = x[..., :half]
        phase = x[..., half:]
        log_mag = torch.clamp(log_mag, max=10.0)
        mag = torch.exp(log_mag)
        # Build complex spec: [B, freq, T]
        spec = torch.complex(mag * torch.cos(phase), mag * torch.sin(phase))
        spec = spec.transpose(1, 2).contiguous()  # [B, freq, T]
        # iSTFT per batch element.
        outs = []
        for b in range(spec.shape[0]):
            y = torch.istft(
                spec[b],
                n_fft=self.n_fft,
                hop_length=self.hop_length,
                win_length=self.n_fft,
                window=self.window,
                center=True,
                length=None,
            )
            outs.append(y)
        return torch.stack(outs, dim=0)


def gen_vocos_istft_head(out_dir: Path) -> None:
    _seed_everything()
    dim = 16
    n_fft = 32
    hop_length = 8
    batch = 1
    time = 8

    head = VocosISTFTHead(dim=dim, n_fft=n_fft, hop_length=hop_length).eval()
    x = torch.randn(batch, time, dim, dtype=torch.float32)

    with torch.no_grad():
        y = head(x)

    _save(out_dir / "input.safetensors", {"x": x})
    weights = {
        "proj.weight": head.proj.weight.detach(),
        "proj.bias": head.proj.bias.detach(),
        "window": head.window.detach(),
    }
    _save(out_dir / "weights.safetensors", weights)
    _save(out_dir / "expected.safetensors", {"audio": y})


# ---------------------------------------------------------------------------
# Family 3: Encodec residual VQ
# ---------------------------------------------------------------------------
class EncodecVectorQuantizer(nn.Module):
    """Single-layer Encodec VQ (no EMA training, just nearest-neighbor lookup).

    Reference: facebookresearch/encodec
    encodec/quantization/core_vq.py — VectorQuantization

    Forward:
      input x: [B, dim, T]
      For each timestep, find nearest codebook vector by L2 distance.
      Output = lookup(indices), shape [B, dim, T]
    """

    def __init__(self, codebook_size: int, dim: int):
        super().__init__()
        self.codebook = nn.Parameter(torch.randn(codebook_size, dim))

    def forward(self, x: torch.Tensor):
        # x: [B, dim, T]
        b, d, t = x.shape
        flat = x.permute(0, 2, 1).reshape(-1, d)  # [B*T, dim]
        # L2 distance to each codebook vector.
        # ||a - b||^2 = ||a||^2 - 2 a·b + ||b||^2
        dists = (
            flat.pow(2).sum(dim=-1, keepdim=True)
            - 2.0 * flat @ self.codebook.t()
            + self.codebook.pow(2).sum(dim=-1)
        )
        indices = dists.argmin(dim=-1)  # [B*T]
        quantized = F.embedding(indices, self.codebook)  # [B*T, dim]
        quantized = quantized.reshape(b, t, d).permute(0, 2, 1).contiguous()
        return quantized, indices.reshape(b, t)


class EncodecResidualVQ(nn.Module):
    """2-layer residual VQ stack."""

    def __init__(self, num_layers: int, codebook_size: int, dim: int):
        super().__init__()
        self.layers = nn.ModuleList(
            [EncodecVectorQuantizer(codebook_size, dim) for _ in range(num_layers)]
        )

    def forward(self, x: torch.Tensor):
        residual = x
        quantized = torch.zeros_like(x)
        all_indices = []
        for layer in self.layers:
            q, idx = layer(residual)
            quantized = quantized + q
            residual = residual - q
            all_indices.append(idx)
        indices = torch.stack(all_indices, dim=1)  # [B, num_layers, T]
        return quantized, indices


def gen_encodec_quantizer(out_dir: Path) -> None:
    _seed_everything()
    dim = 8
    codebook_size = 16
    num_layers = 2
    batch = 1
    time = 12

    rvq = EncodecResidualVQ(
        num_layers=num_layers, codebook_size=codebook_size, dim=dim
    ).eval()
    x = torch.randn(batch, dim, time, dtype=torch.float32)

    with torch.no_grad():
        quantized, indices = rvq(x)

    _save(out_dir / "input.safetensors", {"x": x})
    weights = {
        f"layers.{i}.codebook": layer.codebook.detach()
        for i, layer in enumerate(rvq.layers)
    }
    _save(out_dir / "weights.safetensors", weights)
    _save(
        out_dir / "expected.safetensors",
        {"quantized": quantized, "indices": indices.to(torch.float32)},
    )


# ---------------------------------------------------------------------------
# Family 4: DACVAE encoder block
# ---------------------------------------------------------------------------
class Snake1d(nn.Module):
    """Snake activation: x + (1/alpha) * sin(alpha*x)^2.

    Reference: descriptinc/descript-audio-codec
    dac/nn/layers.py — Snake1d
    """

    def __init__(self, channels: int):
        super().__init__()
        self.alpha = nn.Parameter(torch.ones(1, channels, 1))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [B, C, T]
        return x + (1.0 / (self.alpha + 1e-9)) * torch.sin(self.alpha * x).pow(2)


class DACResidualUnit(nn.Module):
    """Snake1d -> Conv1d(k=7,d=d) -> Snake1d -> Conv1d(k=1)."""

    def __init__(self, dim: int, dilation: int):
        super().__init__()
        self.s1 = Snake1d(dim)
        # Plain Conv1d (no weight-norm here — Swift parity tests should target the
        # composed weights; ConvWeighted parity is its own sortie).
        self.c1 = nn.Conv1d(dim, dim, kernel_size=7, dilation=dilation, padding=0)
        self.s2 = Snake1d(dim)
        self.c2 = nn.Conv1d(dim, dim, kernel_size=1, dilation=1, padding=0)
        self.dilation = dilation

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = self.s1(x)
        # Symmetric padding for dilated conv with kernel=7.
        pad = (7 - 1) * self.dilation
        y = F.pad(y, (pad // 2, pad - pad // 2))
        y = self.c1(y)
        y = self.s2(y)
        y = self.c2(y)
        return x + y


class DACEncoderBlock(nn.Module):
    """3 residual units (dilations 1,3,9) -> Snake1d -> Conv1d downsample."""

    def __init__(self, dim: int, stride: int):
        super().__init__()
        self.r1 = DACResidualUnit(dim, dilation=1)
        self.r2 = DACResidualUnit(dim, dilation=3)
        self.r3 = DACResidualUnit(dim, dilation=9)
        self.snake = Snake1d(dim)
        self.down = nn.Conv1d(dim, dim * 2, kernel_size=2 * stride, stride=stride)
        self.stride = stride

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.r1(x)
        x = self.r2(x)
        x = self.r3(x)
        x = self.snake(x)
        # Pad for the strided downsample.
        pad = self.stride
        x = F.pad(x, (pad // 2, pad - pad // 2))
        x = self.down(x)
        return x


def gen_dacvae_encoder_block(out_dir: Path) -> None:
    _seed_everything()
    dim = 8
    stride = 2
    batch = 1
    time = 32

    block = DACEncoderBlock(dim=dim, stride=stride).eval()
    x = torch.randn(batch, dim, time, dtype=torch.float32)

    with torch.no_grad():
        y = block(x)

    _save(out_dir / "input.safetensors", {"x": x})
    sd = block.state_dict()
    _save(out_dir / "weights.safetensors", {k: v.detach() for k, v in sd.items()})
    _save(out_dir / "expected.safetensors", {"y": y})


# ---------------------------------------------------------------------------
# Family 5: SNAC VQ
# ---------------------------------------------------------------------------
class SNACVectorQuantizer(nn.Module):
    """SNAC-style vector quantizer with optional projection.

    Reference: hubertsiuzdak/snac
    snac/vq.py — VectorQuantize

    Forward:
      x: [B, D_in, T]
      proj_in:  Conv1d(D_in -> codebook_dim, k=1)
      lookup nearest codebook vector per timestep
      proj_out: Conv1d(codebook_dim -> D_in, k=1)
      output:   [B, D_in, T]
    """

    def __init__(self, input_dim: int, codebook_dim: int, codebook_size: int):
        super().__init__()
        self.input_dim = input_dim
        self.codebook_dim = codebook_dim
        self.codebook_size = codebook_size
        self.in_proj = nn.Conv1d(input_dim, codebook_dim, kernel_size=1)
        self.out_proj = nn.Conv1d(codebook_dim, input_dim, kernel_size=1)
        self.codebook = nn.Embedding(codebook_size, codebook_dim)

    def forward(self, x: torch.Tensor):
        # x: [B, D_in, T]
        z = self.in_proj(x)  # [B, codebook_dim, T]
        b, d, t = z.shape
        flat = z.permute(0, 2, 1).reshape(-1, d)
        codebook = self.codebook.weight  # [codebook_size, codebook_dim]
        dists = (
            flat.pow(2).sum(dim=-1, keepdim=True)
            - 2.0 * flat @ codebook.t()
            + codebook.pow(2).sum(dim=-1)
        )
        indices = dists.argmin(dim=-1)  # [B*T]
        quantized = F.embedding(indices, codebook)  # [B*T, codebook_dim]
        quantized = quantized.reshape(b, t, d).permute(0, 2, 1).contiguous()
        out = self.out_proj(quantized)  # [B, D_in, T]
        return out, indices.reshape(b, t)


def gen_snac_vq(out_dir: Path) -> None:
    _seed_everything()
    input_dim = 8
    codebook_dim = 4
    codebook_size = 16
    batch = 1
    time = 12

    vq = SNACVectorQuantizer(
        input_dim=input_dim, codebook_dim=codebook_dim, codebook_size=codebook_size
    ).eval()
    x = torch.randn(batch, input_dim, time, dtype=torch.float32)

    with torch.no_grad():
        y, indices = vq(x)

    _save(out_dir / "input.safetensors", {"x": x})
    sd = vq.state_dict()
    _save(out_dir / "weights.safetensors", {k: v.detach() for k, v in sd.items()})
    _save(
        out_dir / "expected.safetensors",
        {"y": y, "indices": indices.to(torch.float32)},
    )


# ---------------------------------------------------------------------------
# Family 6: Mimi residual VQ
# ---------------------------------------------------------------------------
class MimiVectorQuantizer(nn.Module):
    """Single-codebook Mimi VQ layer.

    Reference: kyutai-labs/moshi (mimi)
    moshi/quantization/core_vq.py — VectorQuantization

    Mimi uses split residual VQ (semantic + acoustic). For Sortie 1 we ship
    a minimal 2-layer residual stack so the Swift port has a numerical
    reference to compare against. Sortie 17 (Mimi layer tests) will exercise
    the full split-residual structure on top of this primitive.
    """

    def __init__(self, codebook_size: int, dim: int):
        super().__init__()
        self.codebook = nn.Parameter(torch.randn(codebook_size, dim))

    def forward(self, x: torch.Tensor):
        b, d, t = x.shape
        flat = x.permute(0, 2, 1).reshape(-1, d)
        dists = (
            flat.pow(2).sum(dim=-1, keepdim=True)
            - 2.0 * flat @ self.codebook.t()
            + self.codebook.pow(2).sum(dim=-1)
        )
        indices = dists.argmin(dim=-1)
        quantized = F.embedding(indices, self.codebook)
        quantized = quantized.reshape(b, t, d).permute(0, 2, 1).contiguous()
        return quantized, indices.reshape(b, t)


class MimiResidualVQ(nn.Module):
    def __init__(self, num_layers: int, codebook_size: int, dim: int):
        super().__init__()
        self.layers = nn.ModuleList(
            [MimiVectorQuantizer(codebook_size, dim) for _ in range(num_layers)]
        )

    def forward(self, x: torch.Tensor):
        residual = x
        quantized = torch.zeros_like(x)
        all_indices = []
        for layer in self.layers:
            q, idx = layer(residual)
            quantized = quantized + q
            residual = residual - q
            all_indices.append(idx)
        indices = torch.stack(all_indices, dim=1)
        return quantized, indices


def gen_mimi_rvq(out_dir: Path) -> None:
    _seed_everything()
    dim = 8
    codebook_size = 16
    num_layers = 2
    batch = 1
    time = 12

    rvq = MimiResidualVQ(
        num_layers=num_layers, codebook_size=codebook_size, dim=dim
    ).eval()
    x = torch.randn(batch, dim, time, dtype=torch.float32)

    with torch.no_grad():
        quantized, indices = rvq(x)

    _save(out_dir / "input.safetensors", {"x": x})
    weights = {
        f"layers.{i}.codebook": layer.codebook.detach()
        for i, layer in enumerate(rvq.layers)
    }
    _save(out_dir / "weights.safetensors", weights)
    _save(
        out_dir / "expected.safetensors",
        {"quantized": quantized, "indices": indices.to(torch.float32)},
    )


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
GENERATORS: Dict[str, Callable[[Path], None]] = {
    "dsp": gen_dsp,
    "vocos_istft_head": gen_vocos_istft_head,
    "encodec_quantizer": gen_encodec_quantizer,
    "dacvae_encoder_block": gen_dacvae_encoder_block,
    "snac_vq": gen_snac_vq,
    "mimi_rvq": gen_mimi_rvq,
}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Generate parity fixtures for Swift parity tests."
    )
    ap.add_argument(
        "--all", action="store_true", help="Regenerate all six fixture sets."
    )
    ap.add_argument(
        "--family",
        choices=sorted(GENERATORS.keys()),
        help="Regenerate a single fixture family.",
    )
    args = ap.parse_args()

    if not args.all and not args.family:
        ap.error("must pass --all or --family <name>")
    if args.all and args.family:
        ap.error("cannot combine --all with --family")

    families = list(GENERATORS.keys()) if args.all else [args.family]
    for name in families:
        out_dir = PARITY_ROOT / name
        print(f"[parity] generating {name} -> {out_dir}")
        GENERATORS[name](out_dir)
        # Verify the three required files exist.
        for f in ("input.safetensors", "weights.safetensors", "expected.safetensors"):
            p = out_dir / f
            if not p.is_file():
                print(f"[parity] ERROR: missing {p}", file=sys.stderr)
                return 1
            if p.stat().st_size == 0:
                print(f"[parity] ERROR: empty {p}", file=sys.stderr)
                return 1

    print(f"[parity] done — wrote {len(families)} fixture set(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
