# Canary-Qwen memory readiness

## Symptom

Tare showed Canary-Qwen as “Installed and ready”, but transcription failed after roughly 19 seconds with a Metal allocation error. The model cache was present, so the old readiness check gave the user the wrong next action.

## Root cause

On the verified Apple M4 with 16 GiB unified memory, MLX reported a maximum buffer length of 9,534,832,640 bytes. The full-precision Canary-Qwen path requested 14,246,936,576 bytes in one Metal buffer. The cached Canary encoder plus its cached `Qwen/Qwen3-1.7B` base was therefore complete but not runnable on this device; this was a device-capacity mismatch, not a missing-model failure.

## Failed attempt

The old bridge reached the MLX loader and emitted:

`[metal::malloc] Attempting to allocate 14246936576 bytes which is greater than the maximum allowed buffer size 9534832640 bytes.`

Checking only Hugging Face snapshot completeness could not detect this condition.

## Recovery

`manage_models.py` now combines the Canary and Qwen footprint and compares the known full-precision requirement with `mlx.core`’s Metal device limit. The app model manager reports the cached model as unusable with an actionable message and offers Parakeet v3 or Qwen3-ASR 1.7B 6-bit. The bridge repeats the same guard before loading audio, encoder weights, or the Qwen model. Swift maps allocator-limit errors to the same user-facing recovery.

When a saved managed model is not usable at launch, `TranscriptionStore` selects the first usable cached model and reports the recovery. The user can still explicitly select Canary later; Start will stop at the same preflight message.

## Validation

- Source and installed model-manager status: `isAvailable: true`, `isUsable: false`, with the 13.3 GiB versus 8.9 GiB explanation.
- Source and installed Canary bridge probes: exit code 3 with the actionable message and no result file.
- Installed Models UI: Canary appears in the expanded catalog with the capacity message; Parakeet is marked “In use”.
- Installed app Start: preflight passed for Parakeet and the job reached “Transcribing”.
- Packaged Parakeet bridge: completed `New Recording.m4a` with 47,451 text characters and 889 segments.

## Residual gap

Canary-Qwen is intentionally retained in the catalog for hardware with a sufficient Metal buffer. It is not quantized or removed automatically, and the app/DMG still contain no model weights.

## Records

- Project turn log: `docs/codex/turn-log.md`
- Prior release/model checkpoints: Codex memory rollout summaries for the Tare release and Canary cache guard.
