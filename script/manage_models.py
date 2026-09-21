#!/usr/bin/env python3

"""Manage the Hugging Face cache used by Tare's local speech models."""

import argparse
import json
import importlib.util
import sys


MLX_AUDIO_MODEL_IDS = {
    "speechllms/canary-speechlm-mlx",
    "VincentGOURBIN/voxtral-small-4bit-mixed",
    "aufklarer/Cohere-Transcribe-2B-MLX-FP16",
    "mlx-community/Qwen3-ASR-1.7B-6bit",
    "mlx-community/Qwen3-ASR-1.7B-bf16",
    "mlx-community/Qwen3-ASR-1.7B-8bit",
    "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
}
QWEN3_ASR_MODEL_IDS = {
    "mlx-community/Qwen3-ASR-1.7B-6bit",
    "mlx-community/Qwen3-ASR-1.7B-bf16",
    "mlx-community/Qwen3-ASR-1.7B-8bit",
}
VOXTRAL_MODEL_IDS = {
    "MarkusKaemmerer/Voxtral-Mini-3B-2507-8bit-dense-encoder",
}
QWEN3_ASR_REQUIRED_FILES = (
    "config.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
)
VOXTRAL_REQUIRED_FILES = (
    "config.json",
    "model-00001-of-00002.safetensors",
    "model-00002-of-00002.safetensors",
    "model.safetensors.index.json",
    "params.json",
    "preprocessor_config.json",
    "tekken.json",
)
CANARY_MODEL_ID = "speechllms/canary-speechlm-mlx"
CANARY_BASE_MODEL_ID = "Qwen/Qwen3-1.7B"
CANARY_MINIMUM_METAL_BUFFER_BYTES = 14_246_936_576
CANARY_REQUIRED_FILES = (
    "attention.py",
    "modules.py",
    "subsampling.py",
    "model.py",
    "mlx_canary_encoder.safetensors",
    "mlx_canary_llm.safetensors",
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Download, inspect, and remove Tare speech models.")
    parser.add_argument("--action", choices=("status", "inventory", "download", "install", "delete", "remove"), required=True)
    parser.add_argument("--model")
    args = parser.parse_args()

    try:
        if args.action == "inventory":
            result = inventory()
        elif not args.model:
            parser.error(f"--model is required for {args.action}")
        elif args.action == "status":
            result = status_for(args.model)
        elif args.action in {"download", "install"}:
            from huggingface_hub import snapshot_download

            snapshot_download(repo_id=args.model)
            if args.model == CANARY_MODEL_ID:
                snapshot_download(repo_id=CANARY_BASE_MODEL_ID)
            result = status_for(args.model)
        else:
            result = remove_model(args.model)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(f"model management failed: {exc}", file=sys.stderr)
        return 3


def cache_repositories(model: str):
    from huggingface_hub import scan_cache_dir

    return [
        repo
        for repo in scan_cache_dir().repos
        if repo.repo_type == "model" and repo.repo_id == model
    ]


def status_for(model: str) -> dict:
    repositories = cache_repositories(model)
    revisions = [revision for repo in repositories for revision in repo.revisions]
    size_bytes = sum(repo.size_on_disk for repo in repositories)
    if model == CANARY_MODEL_ID:
        size_bytes += sum(
            repo.size_on_disk
            for repo in cache_repositories(CANARY_BASE_MODEL_ID)
        )
    snapshot_path = str(revisions[0].snapshot_path) if revisions else None
    is_usable, issue_message = usability_for(model, revisions[0].snapshot_path if revisions else None)
    return {
        "modelIdentifier": model,
        "isAvailable": bool(revisions),
        "isUsable": is_usable,
        "issueMessage": issue_message,
        "sizeBytes": int(size_bytes),
        "cachePath": snapshot_path,
    }


def usability_for(model: str, snapshot_path) -> tuple[bool, str | None]:
    if not snapshot_path:
        return False, None
    if model == CANARY_MODEL_ID:
        missing = [filename for filename in CANARY_REQUIRED_FILES if not (snapshot_path / filename).is_file()]
        if missing:
            return False, f"Canary cache is incomplete; missing {', '.join(missing)}."
        if not importlib.util.find_spec("mlx_lm"):
            return False, "Canary requires the mlx-lm backend in Tare's local Python environment."
        if not any(qwen_base_is_complete(revision.snapshot_path) for repo in cache_repositories(CANARY_BASE_MODEL_ID) for revision in repo.revisions):
            return False, "Canary requires Qwen3-1.7B in the local Hugging Face cache."
        if runtime_issue := canary_runtime_issue():
            return False, runtime_issue
        return True, None
    if model in QWEN3_ASR_MODEL_IDS:
        missing = [filename for filename in QWEN3_ASR_REQUIRED_FILES if not (snapshot_path / filename).is_file()]
        if missing:
            return False, f"Qwen3-ASR cache is incomplete; missing {', '.join(missing)}."
        if not safetensors_are_complete(snapshot_path):
            return False, "Qwen3-ASR cache is incomplete; its safetensors weights are missing or unfinished."
        return True, None
    if model in VOXTRAL_MODEL_IDS:
        missing = [filename for filename in VOXTRAL_REQUIRED_FILES if not (snapshot_path / filename).is_file()]
        if missing:
            return False, f"Voxtral cache is incomplete; missing {', '.join(missing)}."
        if not importlib.util.find_spec("mlx_voxtral"):
            return False, "Voxtral requires the mlx-voxtral backend in Tare's local Python environment."
        return True, None
    if model in MLX_AUDIO_MODEL_IDS and not (snapshot_path / "config.json").is_file():
        return False, "Cached files are incomplete for Tare's MLX-Audio loader."
    return True, None


def qwen_base_is_complete(snapshot_path) -> bool:
    required_files = ("config.json", "tokenizer.json", "tokenizer_config.json")
    return all((snapshot_path / filename).is_file() for filename in required_files) and safetensors_are_complete(snapshot_path)


def canary_runtime_issue() -> str | None:
    """Return a deterministic capacity warning before Canary allocates its weights."""
    try:
        import mlx.core as mx
    except Exception:
        return "Canary requires the MLX runtime in Tare's local Python environment."

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


def safetensors_are_complete(snapshot_path) -> bool:
    """Require every weight named by a repository's safetensors index."""
    index_path = snapshot_path / "model.safetensors.index.json"
    if index_path.is_file():
        try:
            index = json.loads(index_path.read_text(encoding="utf-8"))
            expected = {
                str(filename).rsplit("/", 1)[-1]
                for filename in index.get("weight_map", {}).values()
            }
            if expected:
                return all((snapshot_path / filename).is_file() for filename in expected)
        except (OSError, ValueError, TypeError):
            return False

    return any(
        path.is_file() and path.suffix == ".safetensors"
        for path in snapshot_path.glob("*.safetensors")
    )


def inventory() -> list[dict]:
    """Return only complete model snapshots already present in the local cache."""
    from huggingface_hub import scan_cache_dir

    statuses = []
    for repo in scan_cache_dir().repos:
        if repo.repo_type != "model" or not repo.revisions:
            continue
        statuses.append(status_for(repo.repo_id))
    return sorted(statuses, key=lambda status: status["modelIdentifier"].lower())


def remove_model(model: str) -> dict:
    from huggingface_hub import scan_cache_dir

    cache_info = scan_cache_dir()
    revisions = [
        revision.commit_hash
        for repo in cache_info.repos
        if repo.repo_type == "model" and repo.repo_id == model
        for revision in repo.revisions
    ]
    if revisions:
        cache_info.delete_revisions(*revisions).execute()
    return status_for(model)


if __name__ == "__main__":
    raise SystemExit(main())
