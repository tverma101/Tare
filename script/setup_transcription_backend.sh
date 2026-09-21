#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install --upgrade \
  "mlx==0.32.1" \
  "mlx-lm==0.31.3" \
  "mlx-voxtral==0.0.6" \
  mlx-whisper \
  parakeet-mlx
.venv/bin/python -m pip install "git+https://github.com/OpenMOSS/MOSS-Transcribe-Diarize.git@0e3d1403fd8f1f1c674e883ecee96b9f630794ebe"
.venv/bin/python -m pip install \
  "mlx-audio[stt] @ git+https://github.com/Blaizzy/mlx-audio.git@4da826f2d7771fe35df0ececc5694272d7dceaa1"
