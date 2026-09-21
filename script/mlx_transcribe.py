#!/usr/bin/env python3

import argparse
import gc
import json
import math
import os
import subprocess
import shutil
import sys
import tempfile
from pathlib import Path

# These helpers are copied into the signed app bundle. Never mutate that bundle
# with import bytecode when a user runs the bridge directly.
sys.dont_write_bytecode = True


MOSS_MODEL_ID = "OpenMOSS-Team/MOSS-Transcribe-Diarize"
CANARY_MODEL_ID = "speechllms/canary-speechlm-mlx"
PARAKEET_MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"
VOXTRAL_MODEL_ID = "MarkusKaemmerer/Voxtral-Mini-3B-2507-8bit-dense-encoder"
MLX_AUDIO_MODEL_IDS = {
    "VincentGOURBIN/voxtral-small-4bit-mixed",
    "aufklarer/Cohere-Transcribe-2B-MLX-FP16",
    "mlx-community/Qwen3-ASR-1.7B-6bit",
    "mlx-community/Qwen3-ASR-1.7B-bf16",
    "mlx-community/Qwen3-ASR-1.7B-8bit",
    "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe audio locally with MLX Whisper, Parakeet v3, or MOSS-Diarize.")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default="mlx-community/whisper-base-mlx")
    parser.add_argument("--language")
    parser.add_argument("--chunk-seconds", type=int, default=default_chunk_seconds())
    parser.add_argument("--chunk-workers", type=int, default=int(os.environ.get("TARE_CHUNK_WORKERS", "1") or "1"))
    parser.add_argument("--word-timestamps", action="store_true")
    parser.add_argument("--max-new-tokens", type=int, default=env_int("TARE_MOSS_MAX_NEW_TOKENS", None, 16384))
    parser.add_argument("--max-length", type=int, default=env_int("TARE_MOSS_MAX_LENGTH", None, 131072))
    parser.add_argument("--device", default=os.environ.get("TARE_MOSS_DEVICE", "auto"))
    parser.add_argument("--dtype", default=os.environ.get("TARE_MOSS_DTYPE", "float32"))
    args = parser.parse_args()

    language = normalized_language(args.language)

    if is_canary_model(args.model):
        try:
            from canary_transcribe import transcribe_canary

            result = transcribe_canary(args, language)
        except Exception as exc:
            print(f"Canary-Qwen transcription failed: {exc}", file=sys.stderr)
            return 3

        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
        return 0

    if is_moss_model(args.model):
        try:
            result = transcribe_moss(args, language)
        except Exception as exc:
            print(f"MOSS transcription failed: {exc}", file=sys.stderr)
            return 3

        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
        return 0

    if is_parakeet_model(args.model):
        try:
            result = transcribe_parakeet(args, language)
        except Exception as exc:
            print(f"Parakeet transcription failed: {exc}", file=sys.stderr)
            return 3

        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
        return 0

    if is_voxtral_model(args.model):
        try:
            from voxtral_transcribe import transcribe_voxtral

            result = transcribe_voxtral(args, language)
        except Exception as exc:
            print(f"Voxtral transcription failed: {exc}", file=sys.stderr)
            return 3

        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
        return 0

    if is_mlx_audio_model(args.model):
        try:
            result = transcribe_mlx_audio(args, language)
        except Exception as exc:
            print(f"MLX-Audio transcription failed: {exc}", file=sys.stderr)
            return 3

        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
        return 0

    ensure_ffmpeg_on_path()

    try:
        import mlx_whisper
    except Exception as exc:
        print(f"mlx-whisper import failed: {exc}", file=sys.stderr)
        return 2
    configure_mlx_memory()

    try:
        result = transcribe_audio(mlx_whisper, args, language)
    except Exception as exc:
        print(f"transcription failed: {exc}", file=sys.stderr)
        return 3

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)

    return 0


def is_moss_model(model: str) -> bool:
    return model.strip().lower() == MOSS_MODEL_ID.lower()


def is_canary_model(model: str) -> bool:
    return model.strip().lower() == CANARY_MODEL_ID.lower()


def is_parakeet_model(model: str) -> bool:
    return model.strip().lower() == PARAKEET_MODEL_ID.lower()


def is_voxtral_model(model: str) -> bool:
    return model.strip().lower() == VOXTRAL_MODEL_ID.lower()


def is_mlx_audio_model(model: str) -> bool:
    return model.strip().lower() in {identifier.lower() for identifier in MLX_AUDIO_MODEL_IDS}


def transcribe_mlx_audio(args, language):
    try:
        from mlx_audio.stt import load
    except Exception as exc:
        raise RuntimeError(
            "MLX-Audio dependencies are missing. Run script/setup_transcription_backend.sh."
        ) from exc

    print(f"MLX-Audio: loading {args.model}", file=sys.stderr, flush=True)
    model = load(args.model)
    options = {"verbose": False}
    if language:
        options["language"] = mlx_audio_language(args.model, language)
    result = model.generate(args.audio, **options)
    if not hasattr(result, "text"):
        raise RuntimeError("MLX-Audio returned no transcription result.")

    segments = []
    for raw_segment in getattr(result, "segments", []) or []:
        segment = raw_segment if isinstance(raw_segment, dict) else vars(raw_segment)
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        start = max(0.0, float(segment.get("start", 0.0) or 0.0))
        end = max(start + 0.2, float(segment.get("end", start + 0.2) or (start + 0.2)))
        segments.append({"start": start, "end": end, "text": text, "words": []})

    full_text = str(result.text).strip()
    if not full_text:
        raise RuntimeError("MLX-Audio returned empty transcription text.")
    if not segments:
        segments = [{"start": 0.0, "end": max(0.2, media_duration(args.audio)), "text": full_text, "words": []}]

    output_language = getattr(result, "language", None) or language or "auto"
    if isinstance(output_language, list):
        output_language = output_language[0] if output_language else "auto"
    payload = payload_from_segments(segments, str(output_language))
    payload["model"] = args.model
    payload["backend"] = "mlx-audio"
    payload["word_timestamps"] = False
    return payload


def mlx_audio_language(model: str, language: str) -> str:
    code = language.strip().lower()
    if "qwen3-asr" not in model.lower():
        return code
    return {
        "ar": "Arabic",
        "de": "German",
        "en": "English",
        "es": "Spanish",
        "fr": "French",
        "it": "Italian",
        "ja": "Japanese",
        "ko": "Korean",
        "pt": "Portuguese",
        "ru": "Russian",
        "zh": "Chinese",
    }.get(code, code)


def transcribe_parakeet(args, language):
    try:
        from parakeet_mlx import from_pretrained
    except Exception as exc:
        raise RuntimeError(
            "Parakeet dependencies are missing. Run script/setup_transcription_backend.sh."
        ) from exc

    chunk_duration = env_int("TARE_PARAKEET_CHUNK_SECONDS", None, 120)
    overlap_duration = env_int("TARE_PARAKEET_OVERLAP_SECONDS", None, 15)
    if chunk_duration < 0:
        chunk_duration = 0
    if overlap_duration < 0:
        overlap_duration = 0

    print(
        f"Parakeet v3: loading MLX model with {chunk_duration}s chunks",
        file=sys.stderr,
        flush=True,
    )
    model = from_pretrained(args.model)
    result = model.transcribe(
        args.audio,
        chunk_duration=float(chunk_duration),
        overlap_duration=float(overlap_duration),
    )

    segments = []
    for sentence in getattr(result, "sentences", []) or []:
        text = str(getattr(sentence, "text", "")).strip()
        if not text:
            continue
        start = max(0.0, float(getattr(sentence, "start", 0.0) or 0.0))
        end = max(start + 0.2, float(getattr(sentence, "end", start + 0.2) or (start + 0.2)))
        words = []
        for token in getattr(sentence, "tokens", []) or []:
            word_text = str(getattr(token, "text", "")).strip()
            if not word_text:
                continue
            word_start = max(start, float(getattr(token, "start", start) or start))
            word_end = max(word_start + 0.05, float(getattr(token, "end", word_start + 0.05) or (word_start + 0.05)))
            words.append({
                "word": word_text,
                "start": word_start,
                "end": word_end,
                "probability": None,
            })
        segments.append({
            "start": start,
            "end": end,
            "text": text,
            "words": words,
        })

    if not segments:
        full_text = str(getattr(result, "text", "")).strip()
        if full_text:
            segments.append({"start": 0.0, "end": 0.2, "text": full_text, "words": []})

    payload = payload_from_segments(segments, language or "auto")
    payload["model"] = args.model
    payload["backend"] = "parakeet-mlx"
    payload["word_timestamps"] = True
    return payload


def transcribe_moss(args, language):
    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoProcessor
        from moss_transcribe_diarize import parse_transcript
        from moss_transcribe_diarize.inference_utils import (
            DEFAULT_PROMPT,
            build_transcription_messages,
            generate_transcription,
        )
    except Exception as exc:
        raise RuntimeError(
            "MOSS dependencies are missing. Run script/setup_transcription_backend.sh."
        ) from exc

    duration = media_duration(args.audio)
    if duration > 90 * 60:
        raise RuntimeError(
            "MOSS supports recordings up to 90 minutes in one pass. "
            "Choose a Whisper model for automatic chunking or split this file first."
        )

    requested_device = str(args.device or "auto").strip().lower()
    device = resolve_moss_device(torch, requested_device)
    dtype = resolve_moss_dtype(torch, args.dtype, device)
    if device.type == "mps":
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    if hasattr(torch, "set_float32_matmul_precision"):
        torch.set_float32_matmul_precision("high")

    print(
        f"MOSS-Diarize 0.9B: loading on {device} ({dtype_name(dtype)})",
        file=sys.stderr,
        flush=True,
    )
    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        trust_remote_code=True,
        dtype="auto",
    )
    processor = AutoProcessor.from_pretrained(
        args.model,
        trust_remote_code=True,
        fix_mistral_regex=True,
    )
    model = model.to(dtype=dtype).to(device).eval()

    prompt = DEFAULT_PROMPT
    if language:
        prompt += f" 目标语种代码：{language}。"

    result = generate_transcription(
        model,
        processor,
        build_transcription_messages(args.audio, prompt),
        max_length=max(1024, int(args.max_length)),
        max_new_tokens=max(128, int(args.max_new_tokens)),
        do_sample=False,
        device=device,
        dtype=dtype,
    )
    raw_text = str(result.get("text", "")).strip()
    segments = parse_transcript(raw_text)
    if not segments:
        raise RuntimeError("MOSS returned no structured [timestamp][speaker] transcript segments.")

    payload_segments = []
    full_text_lines = []
    for index, segment in enumerate(segments, start=1):
        text = str(segment.text).strip()
        start = max(0.0, float(segment.start))
        end = max(start + 0.2, float(segment.end))
        speaker = str(segment.speaker).strip()
        if not text:
            continue
        payload_segments.append(
            {
                "index": index,
                "start": start,
                "end": end,
                "text": text,
                "speaker": speaker,
                "words": [],
            }
        )
        full_text_lines.append(f"{speaker}: {text}" if speaker else text)

    if not payload_segments:
        raise RuntimeError("MOSS returned only empty structured transcript segments.")

    return {
        "text": "\n".join(full_text_lines).strip(),
        "segments": payload_segments,
        "language": language or "auto",
        "model": args.model,
        "backend": "moss-transformers",
        "speaker_diarization": True,
    }


def resolve_moss_device(torch, requested: str):
    if requested in {"", "auto"}:
        if torch.cuda.is_available():
            return torch.device("cuda:0")
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")

    if requested == "cuda" and torch.cuda.is_available():
        return torch.device("cuda:0")
    if requested == "mps" and hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return torch.device("mps")
    if requested == "cpu":
        return torch.device("cpu")
    raise RuntimeError(f"Requested MOSS device is unavailable: {requested}")


def resolve_moss_dtype(torch, requested: str, device):
    normalized = str(requested or "float32").strip().lower()
    if normalized in {"float32", "fp32", "32"}:
        return torch.float32
    if normalized in {"float16", "fp16", "16"}:
        return torch.float16
    if normalized in {"bfloat16", "bf16"}:
        return torch.bfloat16
    raise RuntimeError(f"Unsupported MOSS dtype: {requested}")


def dtype_name(dtype) -> str:
    return str(dtype).replace("torch.", "")


def env_int(primary_key: str, legacy_key: str | None, default: int) -> int:
    fallback = os.environ.get(legacy_key, str(default)) if legacy_key else str(default)
    raw_value = os.environ.get(primary_key, fallback)
    try:
        return int(raw_value)
    except (TypeError, ValueError):
        return default


def transcribe_audio(mlx_whisper, args, language):
    chunk_seconds = max(0, int(args.chunk_seconds or 0))
    duration = media_duration(args.audio)

    if chunk_seconds > 0 and duration > chunk_seconds + 30:
        return transcribe_chunked(mlx_whisper, args, language, duration, chunk_seconds)

    result = mlx_whisper.transcribe(
        args.audio,
        **transcribe_options(args.model, language, args.word_timestamps),
    )
    return payload_from_result(result, language)


def transcribe_chunked(mlx_whisper, args, language, duration, chunk_seconds):
    workers = effective_worker_count(args.chunk_workers)
    chunk_count = int(math.ceil(duration / chunk_seconds))
    print(
        f"Chunked transcription: {chunk_count} chunks, {workers} worker(s), {chunk_seconds}s chunks",
        file=sys.stderr,
        flush=True,
    )

    with tempfile.TemporaryDirectory(prefix="tare-whisper-chunks-") as temporary_directory:
        results = []
        for index in range(chunk_count):
            start = index * chunk_seconds
            length = min(chunk_seconds, max(0.2, duration - start))
            chunk_url = Path(temporary_directory) / f"chunk-{index:05d}.wav"
            extract_chunk(args.audio, chunk_url, start, length)
            try:
                results.append(transcribe_chunk(mlx_whisper, args.model, language, args.word_timestamps, (index, start, str(chunk_url))))
            finally:
                try:
                    chunk_url.unlink()
                except OSError:
                    pass
                release_mlx_cache()
            percent = int(((index + 1) / chunk_count) * 100)
            print(
                f"Finished chunk {index + 1}/{chunk_count} ({percent}%)",
                file=sys.stderr,
                flush=True,
            )

    segments = []
    detected_language = language or "auto"
    for index, start, payload in sorted(results, key=lambda item: item[0]):
        detected_language = payload.get("language") or detected_language
        for segment in payload.get("segments", []):
            text = str(segment.get("text", "")).strip()
            if not text:
                continue
            raw_start = float(segment.get("start", 0.0) or 0.0)
            raw_end = float(segment.get("end", raw_start + 0.2) or (raw_start + 0.2))
            segment_start = raw_start + start
            segment_end = raw_end + start
            words = []
            for word in segment.get("words", []) or []:
                word_text = str(word.get("word", "") or word.get("text", "")).strip()
                if not word_text:
                    continue
                word_start = float(word.get("start", raw_start) or raw_start) + start
                word_end = float(word.get("end", raw_start + 0.05) or (raw_start + 0.05)) + start
                words.append(
                    {
                        "word": word_text,
                        "start": word_start,
                        "end": max(word_end, word_start + 0.05),
                        "probability": word.get("probability"),
                    }
                )
            segments.append(
                {
                    "start": segment_start,
                    "end": max(segment_end, segment_start + 0.2),
                    "text": text,
                    "words": words,
                }
            )
    return payload_from_segments(segments, detected_language)


def transcribe_chunk(mlx_whisper, model, language, word_timestamps, job):
    index, start, chunk_path = job
    result = mlx_whisper.transcribe(
        chunk_path,
        **transcribe_options(model, language, word_timestamps),
    )
    return index, start, payload_from_result(result, language)


def transcribe_options(model, language, word_timestamps):
    options = {
        "path_or_hf_repo": model,
        "verbose": False,
        "condition_on_previous_text": False,
        "word_timestamps": bool(word_timestamps),
    }
    if word_timestamps:
        options["hallucination_silence_threshold"] = 1.0
    if language:
        options["language"] = language
    return options


def payload_from_result(result, language):
    segments = []
    for segment in result.get("segments", []):
        start = float(segment.get("start", 0.0) or 0.0)
        end = float(segment.get("end", start + 0.2) or (start + 0.2))
        text = str(segment.get("text", "")).strip()
        if text:
            words = []
            for word in segment.get("words", []) or []:
                word_text = str(word.get("word", "") or word.get("text", "")).strip()
                if not word_text:
                    continue
                word_start = float(word.get("start", start) or start)
                word_end = float(word.get("end", word_start + 0.05) or (word_start + 0.05))
                words.append(
                    {
                        "word": word_text,
                        "start": word_start,
                        "end": max(word_end, word_start + 0.05),
                        "probability": word.get("probability"),
                    }
                )
            segments.append({"start": start, "end": max(end, start + 0.2), "text": text, "words": words})
    return payload_from_segments(segments, result.get("language") or language or "auto")


def payload_from_segments(segments, language):
    filtered_segments = [
        segment for segment in sorted(segments, key=lambda item: item["start"])
        if not is_repetitive_hallucination(segment["text"])
    ]

    return {
        "text": " ".join(segment["text"] for segment in filtered_segments).strip(),
        "segments": [
            {
                "index": index,
                "start": segment["start"],
                "end": max(segment["end"], segment["start"] + 0.2),
                "text": segment["text"],
                "words": segment.get("words", []),
            }
            for index, segment in enumerate(filtered_segments, start=1)
        ],
        "language": language,
    }


def media_duration(path):
    ffprobe = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
    if not os.path.exists(ffprobe):
        return 0.0

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


def extract_chunk(source, destination, start, duration):
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", f"{start:.3f}",
            "-i", source,
            "-t", f"{duration:.3f}",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            str(destination),
        ],
        check=True,
    )


def normalized_language(language):
    if language is None:
        return None
    language = language.strip().lower()
    if not language or language in {"auto", "detect", "auto-detect", "automatic"}:
        return None
    if "_" in language:
        language = language.split("_", 1)[0]
    if "-" in language:
        language = language.split("-", 1)[0]
    return language


def ensure_ffmpeg_on_path() -> None:
    if shutil.which("ffmpeg"):
        return

    candidate_paths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]
    for candidate in candidate_paths:
        if os.path.exists(candidate) and os.access(candidate, os.X_OK):
            directory = os.path.dirname(candidate)
            existing_path = os.environ.get("PATH", "")
            os.environ["PATH"] = directory if not existing_path else f"{directory}:{existing_path}"
            return

    print("ffmpeg was not found. Install it with Homebrew or add it to PATH.", file=sys.stderr)


def default_chunk_seconds() -> int:
    raw_value = os.environ.get("TARE_CHUNK_SECONDS", "600")
    try:
        value = int(raw_value)
    except ValueError:
        return 600
    if value <= 0:
        return 0
    return min(max(value, 60), 900)


def effective_worker_count(raw_worker_count) -> int:
    try:
        requested = int(raw_worker_count or 1)
    except ValueError:
        requested = 1
    requested = max(1, requested)
    if requested > 1:
        print(
            "Parallel MLX chunk workers are disabled for stability; using 1 worker.",
            file=sys.stderr,
            flush=True,
        )
    return 1


def configure_mlx_memory() -> None:
    try:
        import mlx.core as mx
    except Exception:
        return

    raw_cache_limit_mb = os.environ.get("TARE_MLX_CACHE_MB", "512")
    try:
        cache_limit = max(0, int(raw_cache_limit_mb)) * 1024 * 1024
    except ValueError:
        cache_limit = 512 * 1024 * 1024

    try:
        if hasattr(mx, "set_cache_limit"):
            mx.set_cache_limit(cache_limit)
        elif hasattr(mx, "metal") and hasattr(mx.metal, "set_cache_limit"):
            mx.metal.set_cache_limit(cache_limit)
    except Exception:
        pass


def release_mlx_cache() -> None:
    gc.collect()
    try:
        import mlx.core as mx
        if hasattr(mx, "synchronize"):
            mx.synchronize()
        if hasattr(mx, "clear_cache"):
            mx.clear_cache()
        elif hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
            mx.metal.clear_cache()
    except Exception:
        pass


def is_repetitive_hallucination(text: str) -> bool:
    tokens = [token.strip(".,!?;:()[]{}\"'").lower() for token in text.split()]
    tokens = [token for token in tokens if token]
    if len(tokens) < 4:
        return False

    unique_tokens = set(tokens)
    if len(unique_tokens) == 1:
        return True

    if len(unique_tokens) == 2 and len(tokens) >= 8:
        return True

    return False


if __name__ == "__main__":
    raise SystemExit(main())
