#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy==2.5.4"]
# ///
"""Writes Smart Turn's filterbank, and the reference the app's `Mel` is checked against.

The filterbank is `Apps/Topo/Resources/smartturn-mel.bin`: Whisper's 80 Slaney mel filters over
the 201 bins of a 400-point FFT at 16 kHz, `[80][201]` little-endian float32, mel-major, exactly
`_MEL_FILTERS.T` of pipecat's `_whisper_features.py` (BSD-2-Clause, © Daily), which is vendored
unchanged beside this script as `scripts/vendor/whisper_features.py`, so the only download is
numpy. `scripts/tests/smartturn-mel-test.sh` regenerates it and compares the bytes. numpy is
pinned because the fixture below is compared bit for bit, and its FFT is numpy's.

`--fixture PATH` writes instead what pipecat's numpy reference computes for the test signal
(`chirp`, written by the same formula in `Tests/Client/SmartTurnTests.swift`): every tenth of the 800
frames of the `[80][800]` features, `[80][80]` little-endian float32, mel-major.

    scripts/smartturn-mel.py                     # the bundled filterbank
    scripts/smartturn-mel.py --out PATH          # the filterbank, somewhere else
    scripts/smartturn-mel.py --fixture PATH      # the reference features of the test signal
"""

import argparse
import importlib.util
import pathlib
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent


def reference():
    spec = importlib.util.spec_from_file_location("whisper_features", HERE / "vendor" / "whisper_features.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def chirp() -> np.ndarray:
    """Eight seconds at 16 kHz: a second of nothing, then a sweep from 100 Hz to 4 kHz whose
    level swells and falls, so the features have silence, tone and dynamics in them."""
    n = np.arange(16000 * 8, dtype=np.float64)
    t = n / 16000.0
    sweep = np.sin(2 * np.pi * (100.0 * t + (4000.0 - 100.0) / (2 * 8.0) * t * t))
    level = 0.05 + 0.45 * np.abs(np.sin(np.pi * t / 3.0))
    signal = np.where(t < 1.0, 0.0, level * sweep)
    return signal.astype(np.float32)


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--out", type=pathlib.Path, default=ROOT / "Apps/Topo/Resources/smartturn-mel.bin")
    group.add_argument("--fixture", type=pathlib.Path)
    args = parser.parse_args()
    whisper = reference()
    if args.fixture:
        features = whisper.compute_whisper_log_mel_features(chirp())
        assert features.shape == (80, 800), features.shape
        args.fixture.write_bytes(np.ascontiguousarray(features[:, ::10]).astype("<f4").tobytes())
        print(f"wrote {args.fixture}", file=sys.stderr)
        return 0
    filters = whisper._MEL_FILTERS
    assert filters.shape == (201, 80), filters.shape
    args.out.write_bytes(np.ascontiguousarray(filters.T).astype("<f4").tobytes())
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
