#!/usr/bin/env python3

"""Run Tare's published 8-bit Voxtral Mini MLX checkpoint.

The dense-encoder checkpoint is built for ``mlx-voxtral`` and is intentionally
not sent through ``mlx_audio.stt.load``.  Voxtral does not emit timestamps, so
Tare returns one approximate segment per safe audio pass and marks the result
as text-only.  Passes are kept short enough for a 16 GB Apple Silicon Mac.
"""

import gc
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


DEFAULT_CHUNK_SECONDS = 120
MIN_CHUNK_SECONDS = 60
MAX_CHUNK_SECONDS = 300
OVERLAP_SECONDS = 2
DEFAULT_MAX_NEW_TOKENS = 4096


def transcribe_voxtral(args, language):
    try:
        import mlx.core as mx
        from mlx_voxtral import VoxtralProcessor, load_voxtral_model
    except Exception as exc:
        raise RuntimeError(
            "Voxtral dependencies are missing. Run script/setup_transcription_backend.sh."
        ) from exc

    duration = media_duration(args.audio)
    chunk_seconds = configured_chunk_seconds()
    max_new_tokens = configured_max_new_tokens(args)

    print(
        f"Voxtral Mini: loading MLX model with {chunk_seconds}s memory-safe passes",
        file=sys.stderr,
        flush=True,
    )
    model, _ = load_voxtral_model(args.model, dtype=mx.bfloat16, lazy=True)
    processor = VoxtralProcessor.from_pretrained(args.model)

    segments = []
    previous_text = ""
    windows = pass_windows(duration, chunk_seconds)
    with tempfile.TemporaryDirectory(prefix="tare-voxtral-chunks-") as temporary_directory:
        for index, (core_start, core_end, input_start, input_end) in enumerate(
            windows,
            start=1,
        ):
            input_path = args.audio
            chunk_path = None
            if input_start > 0 or input_end < duration:
                chunk_path = Path(temporary_directory) / f"chunk-{index:05d}.wav"
                extract_chunk(args.audio, chunk_path, input_start, input_end - input_start)
                input_path = str(chunk_path)

            try:
                text = transcribe_pass(
                    model,
                    processor,
                    mx,
                    input_path,
                    language,
                    max_new_tokens,
                )
            finally:
                if chunk_path is not None:
                    try:
                        chunk_path.unlink()
                    except OSError:
                        pass
                release_mlx_cache(mx)

            text = remove_text_overlap(previous_text, text)
            if text:
                segments.append(
                    {
                        "start": max(0.0, core_start),
                        "end": max(core_start + 0.2, core_end),
                        "text": text,
                        "words": [],
                    }
                )
                previous_text = text

            percent = int((index / max(1, len(windows))) * 100)
            print(
                f"Finished Voxtral pass {index} ({percent}%)",
                file=sys.stderr,
                flush=True,
            )

    if not segments:
        raise RuntimeError("Voxtral returned empty transcription text.")

    return {
        "text": " ".join(segment["text"] for segment in segments).strip(),
        "segments": [
            {
                "index": index,
                "start": segment["start"],
                "end": segment["end"],
                "text": segment["text"],
                "words": [],
            }
            for index, segment in enumerate(segments, start=1)
        ],
        "language": language or "auto",
        "model": args.model,
        "backend": "mlx-voxtral",
        "word_timestamps": False,
    }


def transcribe_pass(model, processor, mx, audio_path, language, max_new_tokens):
    inputs = processor.apply_transcrition_request(
        audio=audio_path,
        language=language,
        sampling_rate=16000,
    )
    outputs = model.generate(
        input_ids=inputs.input_ids,
        input_features=inputs.input_features,
        max_new_tokens=max_new_tokens,
        temperature=0.0,
        repetition_penalty=1.0,
    )
    mx.eval(outputs)
    generated_tokens = outputs[0, inputs.input_ids.shape[1] :]
    return processor.decode(generated_tokens, skip_special_tokens=True).strip()


def pass_windows(duration, chunk_seconds):
    if duration <= 0 or duration <= chunk_seconds:
        return [(0.0, max(0.2, duration), 0.0, max(0.2, duration))]

    windows = []
    core_start = 0.0
    while core_start < duration:
        core_end = min(duration, core_start + chunk_seconds)
        input_start = max(0.0, core_start - OVERLAP_SECONDS) if core_start > 0 else 0.0
        windows.append((core_start, core_end, input_start, core_end))
        core_start = core_end
    return windows


def configured_chunk_seconds():
    raw_value = os.environ.get("TARE_VOXTRAL_CHUNK_SECONDS", str(DEFAULT_CHUNK_SECONDS))
    try:
        value = int(raw_value)
    except (TypeError, ValueError):
        value = DEFAULT_CHUNK_SECONDS
    return min(max(value, MIN_CHUNK_SECONDS), MAX_CHUNK_SECONDS)


def configured_max_new_tokens(args):
    raw_value = os.environ.get("TARE_VOXTRAL_MAX_NEW_TOKENS")
    if raw_value is None:
        raw_value = getattr(args, "max_new_tokens", DEFAULT_MAX_NEW_TOKENS)
    try:
        value = int(raw_value)
    except (TypeError, ValueError):
        value = DEFAULT_MAX_NEW_TOKENS
    return min(max(value, 128), DEFAULT_MAX_NEW_TOKENS)


def remove_text_overlap(previous_text, current_text):
    current_text = " ".join(current_text.split())
    if not previous_text or not current_text:
        return current_text

    previous_tokens = previous_text.split()
    current_tokens = current_text.split()
    max_overlap = min(24, len(previous_tokens), len(current_tokens))
    for overlap in range(max_overlap, 1, -1):
        previous_tail = [normalize_token(token) for token in previous_tokens[-overlap:]]
        current_head = [normalize_token(token) for token in current_tokens[:overlap]]
        if previous_tail == current_head:
            return " ".join(current_tokens[overlap:]).strip()
    return current_text


def normalize_token(token):
    return re.sub(r"[^\w]+", "", token.casefold())


def media_duration(path):
    ffprobe = resolve_executable("ffprobe")
    if ffprobe is None:
        return 0.0
    try:
        output = subprocess.check_output(
            [
                ffprobe,
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                path,
            ],
            text=True,
        )
        return max(0.0, float(output.strip() or "0"))
    except (OSError, subprocess.CalledProcessError, ValueError):
        return 0.0


def extract_chunk(source, destination, start, duration):
    ffmpeg = resolve_executable("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is required to split long audio for Voxtral.")
    subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-ss", f"{start:.3f}",
            "-i", source,
            "-t", f"{max(0.2, duration):.3f}",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            str(destination),
        ],
        check=True,
    )


def resolve_executable(name):
    found = shutil.which(name)
    if found:
        return found
    for candidate in (f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}", f"/usr/bin/{name}"):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def release_mlx_cache(mx):
    gc.collect()
    try:
        if hasattr(mx, "synchronize"):
            mx.synchronize()
        if hasattr(mx, "clear_cache"):
            mx.clear_cache()
        elif hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
            mx.metal.clear_cache()
    except Exception:
        pass
