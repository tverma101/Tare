#!/usr/bin/env python3

"""Tare adapter for the custom speechllms/canary-speechlm-mlx port.

This repository is not an mlx-audio checkpoint. It contains a FastConformer
encoder and a partial Qwen overlay, so it must be combined with the local
Qwen3-1.7B base model before generation.
"""

import sys
from pathlib import Path

import librosa
import mlx.core as mx
import numpy as np


CANARY_MODEL_ID = "speechllms/canary-speechlm-mlx"
QWEN_BASE_MODEL_ID = "Qwen/Qwen3-1.7B"
CANARY_MINIMUM_METAL_BUFFER_BYTES = 14_246_936_576
QWEN_REQUIRED_FILES = ("config.json", "tokenizer.json", "tokenizer_config.json")
SAMPLE_RATE = 16_000
N_MELS = 128


def transcribe_canary(args, language):
    if runtime_issue := canary_runtime_issue():
        raise RuntimeError(runtime_issue)

    from huggingface_hub import snapshot_download

    canary_dir = Path(snapshot_download(CANARY_MODEL_ID, local_files_only=True))
    qwen_dir = Path(snapshot_download(QWEN_BASE_MODEL_ID, local_files_only=True))
    _require_files(
        canary_dir,
        (
            "attention.py",
            "modules.py",
            "subsampling.py",
            "model.py",
            "mlx_canary_encoder.safetensors",
            "mlx_canary_llm.safetensors",
        ),
    )
    _require_qwen_files(qwen_dir)

    audio_features = extract_mel(args.audio)
    canary_model = load_encoder(canary_dir)
    audio_embeds, _ = canary_model.encode_audio(audio_features)

    llm, tokenizer = load_llm(canary_dir, qwen_dir)
    embed_tokens = get_embed_tokens(llm)
    t1 = [151644, 872, 198, 3167, 3114, 279, 2701, 25, 220]
    t2 = [151645, 198, 151644, 77091, 198]
    emb1 = embed_tokens(mx.array([t1]))
    emb2 = embed_tokens(mx.array([t2]))
    scaled_audio_embeds = audio_embeds.astype(embed_tokens.weight.dtype)
    full_embeds = mx.concatenate([emb1, scaled_audio_embeds, emb2], axis=1)
    mx.eval(full_embeds)

    from mlx_lm.models.cache import make_prompt_cache

    cache = make_prompt_cache(llm)
    dummy = mx.zeros((1, full_embeds.shape[1]), dtype=mx.int32)
    logits = llm(dummy, cache=cache, input_embeddings=full_embeds)
    token = mx.argmax(logits[:, -1, :], axis=-1)
    mx.eval(token)

    generated = []
    end_id = tokenizer.convert_tokens_to_ids("<|im_end|>")
    max_tokens = max(1, min(int(args.max_new_tokens), 1024))
    for _ in range(max_tokens):
        token_id = token.item()
        if token_id in (tokenizer.eos_token_id, end_id):
            break
        generated.append(token_id)
        logits = llm(mx.array([[token_id]]), cache=cache)
        token = mx.argmax(logits[:, -1, :], axis=-1)
        mx.eval(token)

    text = tokenizer.decode(generated).strip()
    if not text:
        raise RuntimeError("Canary returned empty transcription text.")

    return {
        "text": text,
        "segments": [{
            "start": 0.0,
            "end": max(0.2, media_duration(args.audio)),
            "text": text,
            "words": [],
        }],
        "language": language or "en",
        "model": CANARY_MODEL_ID,
        "backend": "canary-mlx",
        "word_timestamps": False,
    }


def extract_mel(audio_path: str):
    y, _ = librosa.load(audio_path, sr=SAMPLE_RATE, mono=True)
    if y.size == 0:
        raise RuntimeError("Canary cannot transcribe an empty audio file.")
    y = np.append(y[0], y[1:] - 0.97 * y[:-1])
    stft = librosa.stft(
        y,
        n_fft=512,
        hop_length=160,
        win_length=400,
        window="hann",
        center=True,
    )
    power = np.abs(stft) ** 2
    mel_filter = librosa.filters.mel(
        sr=SAMPLE_RATE,
        n_fft=512,
        n_mels=N_MELS,
        fmin=0.0,
        fmax=8000.0,
        norm="slaney",
        htk=False,
    )
    with np.errstate(all="ignore"):
        mel = mel_filter @ power
    log_mel = np.log(np.maximum(mel, 1e-5))
    mean = log_mel.mean(axis=1, keepdims=True)
    std = log_mel.std(axis=1, keepdims=True) + 1e-5
    return mx.array(((log_mel - mean) / std).T[None])


def load_encoder(canary_dir: Path):
    _prepend_import_path(canary_dir)
    from model import CanaryModel, FastConformerEncoder

    encoder = FastConformerEncoder(
        feat_in=128,
        n_layers=32,
        d_model=1024,
        ff_expansion_factor=4,
        n_heads=8,
        conv_kernel_size=9,
        dropout=0.0,
    )
    model = CanaryModel(encoder=encoder, llm_dim=2048)
    model.load_weights(list(mx.load(str(canary_dir / "mlx_canary_encoder.safetensors")).items()), strict=False)
    model.eval()
    return model


def load_llm(canary_dir: Path, qwen_dir: Path):
    from mlx_lm.utils import load_model
    from transformers import AutoTokenizer

    model, _ = load_model(qwen_dir)
    overlay = mx.load(str(canary_dir / "mlx_canary_llm.safetensors"))
    model.load_weights(list(overlay.items()), strict=False)
    model.eval()
    tokenizer = AutoTokenizer.from_pretrained(qwen_dir, local_files_only=True)
    return model, tokenizer


def get_embed_tokens(model):
    if hasattr(model, "model") and hasattr(model.model, "embed_tokens"):
        return model.model.embed_tokens
    raise RuntimeError("Canary could not find Qwen's embedding layer.")


def media_duration(path: str) -> float:
    import subprocess

    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return float(result.stdout.strip())
    except (TypeError, ValueError):
        return 0.2


def _require_files(root: Path, filenames):
    missing = [filename for filename in filenames if not (root / filename).is_file()]
    if missing:
        raise RuntimeError(f"Canary cache is incomplete; missing {', '.join(missing)}.")


def _require_qwen_files(root: Path):
    _require_files(root, QWEN_REQUIRED_FILES)
    if not any(root.glob("*.safetensors")):
        raise RuntimeError("Canary cache is incomplete; Qwen3-1.7B weights are missing.")


def canary_runtime_issue() -> str | None:
    try:
        info = mx.device_info()
    except Exception:
        try:
            info = mx.metal.device_info()
        except Exception:
            return None

    try:
        max_buffer_length = int(info.get("max_buffer_length", 0))
    except (AttributeError, TypeError, ValueError):
        return None

    if max_buffer_length <= 0 or max_buffer_length >= CANARY_MINIMUM_METAL_BUFFER_BYTES:
        return None

    return (
        "Canary-Qwen full-precision inference needs about "
        f"{format_gib(CANARY_MINIMUM_METAL_BUFFER_BYTES)} in one Metal buffer, "
        f"but this Mac supports {format_gib(max_buffer_length)}. "
        "Choose Parakeet v3 or Qwen3-ASR 1.7B 6-bit."
    )


def format_gib(byte_count: int) -> str:
    return f"{byte_count / (1024 ** 3):.1f} GiB"


def _prepend_import_path(path: Path):
    path_string = str(path)
    if path_string not in sys.path:
        sys.path.insert(0, path_string)
