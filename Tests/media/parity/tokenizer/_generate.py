#!/usr/bin/env python3
"""
Unigram tokenizer reference-fixture generator — Sortie 20 of OPERATION ECHO DRAGNET.

Vocab source
------------
HuggingFace repo : mlx-community/pocket-tts
File             : tokenizer.json  (Unigram, 4000-entry vocab, Metaspace pre-tokenizer)

The Swift UnigramTokenizer (Sources/MLXAudioTTS/Models/PocketTTS/UnigramTokenizer.swift)
loads this file at runtime and implements byte-fallback unconditionally (see
encodeWithByteFallback at line 207 and decode at line 246).  The upstream
tokenizer.json ships with "byte_fallback": false; to match Swift behaviour this
script forces byte_fallback=True when constructing the Python Tokenizer so the
generated IDs are identical to what the Swift implementation produces.

Output
------
Tests/media/parity/tokenizer/unigram_reference.json

Format:  [ { "text": <str>, "ids": [ <int>, ... ] }, ... ]

The decode round-trip is verified here: every entry satisfies
    swift_decode(ids, vocab) == text
where swift_decode is a local reimplementation of the Swift decode() method.

Regenerating
------------
    python3 Tests/media/parity/tokenizer/_generate.py

Requires: Python 3.11+, tokenizers, huggingface_hub.
"""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
from pathlib import Path

try:
    from tokenizers import Tokenizer
except ImportError:
    sys.exit("ERROR: tokenizers is required.  Run: pip install tokenizers")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HF_REPO_ID    = "mlx-community/pocket-tts"
HF_FILENAME   = "tokenizer.json"
# Cache inside /tmp — only used when the committed vocab file is absent.
HF_CACHE_DIR  = os.path.join(tempfile.gettempdir(), "mlxaudio_parity_tokenizer_cache")

# Committed vocab file (byte_fallback already patched to true).
# Phase B committed this file alongside the reference JSON so regeneration
# is reproducible without a network call.
COMMITTED_VOCAB = Path(__file__).parent / "tokenizer.json"

OUTPUT_DIR    = Path(__file__).parent
OUTPUT_FILE   = OUTPUT_DIR / "unigram_reference.json"

# ---------------------------------------------------------------------------
# Test inputs
# Categories: ASCII, CJK, emoji, byte-fallback edge-cases, mixed.
# ---------------------------------------------------------------------------

TEST_CASES: list[tuple[str, str]] = [
    # Pure ASCII ---------------------------------------------------------------
    # description, text
    ("ascii_simple",        "Hello world"),
    ("ascii_sentence",      "The quick brown fox jumps over the lazy dog"),
    ("ascii_lower",         "hello"),
    ("ascii_punct",         "Hello, world!"),
    ("ascii_numbers",       "Test 123"),

    # CJK (characters outside Unigram vocab — forces byte-fallback in Swift) ---
    ("cjk_chinese",         "你好"),          # 你好
    ("cjk_japanese",        "日本"),           # 日本
    ("cjk_mixed_ascii",     "Hello 中文"),     # Hello 中文

    # Emoji (outside Unigram vocab — forces byte-fallback) ----------------------
    ("emoji_face",          "\U0001f60a"),             # 😊
    ("emoji_music",         "\U0001f3b5"),             # 🎵

    # Latin-accented characters INSIDE the Unigram vocab (no byte-fallback) -----
    ("latin_accented",      "Héllo"),             # Héllo
    ("latin_cafe",          "café"),              # café

    # Byte-fallback edge-cases --------------------------------------------------
    # Tab (U+0009) is not a standalone Unigram token — encoded as <0x09>.
    ("byte_fallback_tab",   "test\ttab"),
    # Purely CJK string: all characters force byte-fallback via <0xXX> tokens.
    ("byte_fallback_pure_cjk", "测试"),       # 测试
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_byte_fallback_tokenizer(repo_id: str, filename: str, cache_dir: str) -> tuple[Tokenizer, list[str]]:
    """Return a Tokenizer with byte_fallback=True, plus the raw vocab list.

    Source priority:
      1. COMMITTED_VOCAB (Tests/media/parity/tokenizer/tokenizer.json) — already
         patched and committed by Phase B.  No network call needed.
      2. HuggingFace Hub download — fallback when the committed file is absent
         (e.g. fresh checkout before the vocab file existed).  Patches
         byte_fallback=True before loading.
    """
    if COMMITTED_VOCAB.exists():
        print(f"Using committed vocab file: {COMMITTED_VOCAB}")
        with open(COMMITTED_VOCAB, encoding="utf-8") as fh:
            tok_dict = json.load(fh)
        # Already patched — byte_fallback should be True.
        assert tok_dict["model"].get("byte_fallback") is True, (
            "Committed tokenizer.json has byte_fallback != True — was it overwritten?"
        )
        vocab: list[str] = [entry[0] for entry in tok_dict["model"]["vocab"]]
        tokenizer = Tokenizer.from_file(str(COMMITTED_VOCAB))
        return tokenizer, vocab

    # Fallback: download from HuggingFace Hub.
    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        sys.exit(
            "ERROR: huggingface_hub is required for the network fallback path.\n"
            "Run: pip install huggingface_hub\n"
            "Or commit the vocab file at: Tests/media/parity/tokenizer/tokenizer.json"
        )

    print(f"Committed vocab not found — downloading from {repo_id} …")
    tok_path = hf_hub_download(repo_id=repo_id, filename=filename, cache_dir=cache_dir)
    with open(tok_path, encoding="utf-8") as fh:
        tok_dict = json.load(fh)

    # Extract vocab list for Swift-decode simulation
    vocab = [entry[0] for entry in tok_dict["model"]["vocab"]]

    # Patch byte_fallback to match Swift behaviour
    patched = copy.deepcopy(tok_dict)
    patched["model"]["byte_fallback"] = True

    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8")
    try:
        json.dump(patched, tmp)
        tmp.flush()
        tokenizer = Tokenizer.from_file(tmp.name)
    finally:
        tmp.close()
        os.unlink(tmp.name)

    return tokenizer, vocab


def swift_decode(ids: list[int], vocab: list[str]) -> str:
    """Reimplementation of UnigramTokenizer.decode (UnigramTokenizer.swift:246).

    Collects <0xXX> byte tokens into a buffer and decodes the buffer as UTF-8,
    then replaces the Metaspace character ▁ with a space and strips leading/
    trailing whitespace — exactly matching the Swift implementation.
    """
    pieces: list[str] = []
    byte_buf: list[int] = []

    for id_ in ids:
        if id_ < 0 or id_ >= len(vocab):
            continue
        tok = vocab[id_]
        # Byte token pattern: <0xXX>  (length == 6, starts with <0x, ends with >)
        if len(tok) == 6 and tok.startswith("<0x") and tok.endswith(">"):
            byte_buf.append(int(tok[3:-1], 16))
        else:
            if byte_buf:
                pieces.append(bytes(byte_buf).decode("utf-8", errors="replace"))
                byte_buf.clear()
            pieces.append(tok)

    if byte_buf:
        pieces.append(bytes(byte_buf).decode("utf-8", errors="replace"))

    joined = "".join(pieces)
    return joined.replace("▁", " ").strip()  # ▁ → space, then strip


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    print(f"Loading tokenizer (committed file or {HF_REPO_ID} fallback) …")
    tokenizer, vocab = load_byte_fallback_tokenizer(HF_REPO_ID, HF_FILENAME, HF_CACHE_DIR)
    print(f"Vocab size: {len(vocab)}")

    records: list[dict] = []
    failures: list[str] = []

    for description, text in TEST_CASES:
        enc = tokenizer.encode(text)
        ids: list[int] = enc.ids
        decoded = swift_decode(ids, vocab)
        if decoded != text:
            failures.append(
                f"  [{description}] {repr(text)} -> ids={ids} -> decoded={repr(decoded)}"
            )
        records.append({"text": text, "ids": ids})
        print(f"  {description:30s}  ids={ids}")

    if failures:
        print("\nROUND-TRIP FAILURES:")
        for f in failures:
            print(f)
        sys.exit(1)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as fh:
        json.dump(records, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    byte_size = OUTPUT_FILE.stat().st_size
    print(f"\nWrote {len(records)} entries to {OUTPUT_FILE}")
    print(f"File size: {byte_size} bytes (limit: 51200)")
    assert byte_size <= 51_200, f"Output exceeds 50 KB: {byte_size} bytes"
    assert len(records) >= 10, f"Fewer than 10 entries: {len(records)}"
    print("All assertions passed.")


if __name__ == "__main__":
    main()
