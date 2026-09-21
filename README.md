# Tare

Tare is a native macOS batch transcriber for video and audio
files. It extracts audio locally, uses MLX Whisper, MLX-Audio STT models, Parakeet v3, or MOSS-Diarize on the Mac, and writes
transcript artifacts to a folder on the Mac.

## Features

- Batch queue for common video and audio files.
- MKV organizer that can scan launch folders, clean show/movie names, move MKVs into a local media library, and start transcription from the organized files.
- TV episodes organize as `Show Name/Season 01/Show Name - S01E03 - Episode Title.mkv` and write a `Table of Contents.md` in the show folder.
- Local transcription with `ffmpeg` audio extraction, MLX Whisper, the custom Canary-Qwen MLX port, MLX-Audio STT models (Cohere Transcribe, realtime Voxtral, and Qwen3-ASR), the dedicated Voxtral Mini MLX backend, Parakeet v3, and MOSS-Diarize 0.9B.
- Optional cloud transcription through Google Gemini 3.5 Transcribe, with automatic language detection, Keychain-backed multi-key failover, provider-aware option validation, and automatic safe chunking for long recordings.
- Every supported input is automatically embedded with its transcription when possible: audio files receive custom lyrics, MKV files are updated with a subtitle track, and MP4/MOV/M4V files produce an IINA-friendly `.captioned.mkv`.
- Completed exports get a compact subject-based name and their own folder. Tare writes a `.tare-link.json` manifest inside that folder plus a hidden, compact source-side pointer. The pointer records the source fingerprint, every generated artifact, the semantic name, and the naming strategy/model, so re-importing the source can rediscover exactly which transcripts belong to it without overwriting earlier exports.
- Smart names are optional and on-demand: when the local FreeLLMAPI desktop app is already open, Tare sends a short transcript excerpt to its OpenAI-compatible endpoint and asks a quality-first, benchmark-informed free model for a title and folder name. Tare never starts a background server; if the app is closed, no key is configured, or a request times out, it uses deterministic filename cleanup and still completes the export.
- The only optional sidecar export in the app is a plain `.txt` text transcript.
- Model presets include Parakeet v3 for the fastest/lowest-memory path, Qwen3-ASR 1.7B 6-bit for a compact accuracy-focused path, Voxtral Mini 3B 8-bit with a dense encoder for the higher-quality 16-GB path, plus Canary-Qwen 2.5B, Voxtral Small 24B, Cohere Transcribe 2B, Qwen3-ASR 1.7B (BF16 and 8-bit), Voxtral Mini 4B realtime, Whisper Large v3, MOSS-Diarize 0.9B, and the existing smaller/English-only Whisper choices. The default local model remains the faster multilingual base preset.
- The Models tab discovers supported models already present in the local Hugging Face cache and keeps the normal model picker limited to those models. A collapsed download catalog is available when a new model is needed; the active model is protected from removal.
- Model readiness includes backend, cache, and device-capacity checks. Canary-Qwen is full precision and needs about 13.3 GiB in one Metal buffer; on a 16 GB M4 it is shown as cached but not runnable, with Parakeet v3 and Qwen3-ASR 1.7B 6-bit offered as safe local choices.
- The saved model selection is checked at launch; if it is cached but not runnable on this Mac, Tare selects the first usable local model and reports the recovery.
- Long videos are split into automatic 10-minute chunks and transcribed one chunk at a time so MLX does not run competing Metal jobs against the same memory pool.
- Text transcript, model, language, and batch folder choices are saved so repeated runs keep the last selected workflow.
- Native macOS file picker, drag and drop, settings, menus, and app bundle.
- Visible job progress with elapsed time and ETA in the app.
- The Transcript output panel appears directly below job status, with explicit ready, in-progress, and error states; long finished text scrolls inside the panel.
- MKV search roots, media-library folder, launch scanning, and automatic found-MKV processing are configurable in Settings.

## Backend

```bash
./script/setup_transcription_backend.sh
```

The app looks for the installed Tare backend in
`~/Library/Application Support/Tare/.venv` before falling back to a backend
bundled for a direct DMG launch. It uses `script/mlx_transcribe.py` from the
app bundle. `mlx-audio` is installed from
its pinned upstream commit for the MLX-native STT models; `mlx-lm` is used by
the custom Canary-Qwen adapter; MOSS remains compatible with the same
Transformers environment. The dedicated Voxtral Mini 3B 8-bit adapter uses
the pinned `mlx-voxtral==0.0.6` package, which is separate from the
`mlx_audio.stt.load` route because this published dense-encoder checkpoint has
a different weight layout.

Model files are never bundled in `Tare.app` or `Tare.dmg`. Tare discovers
supported repositories already in the user's Hugging Face cache and passes
those local-cache-backed model identifiers to the selected backend. The DMG
contains app resources and, when built from a provisioned checkout, the Python
runtime only. Cache entries are checked for the files required by their
selected backend; incomplete or incompatible snapshots stay out of the normal
picker and are labeled for repair.

The default output root is `~/Documents/Tare Transcripts`. Tare creates that
folder when the app launches, creates a named subfolder for each batch, shows
the current destination in the Export panel, and provides a direct Show in
Finder action.

### Smart transcript names and compact pointers

With **Use smart transcript names** enabled, each source is stored under a
readable subject folder. A typical result looks like:

```text
Tare Transcripts/
  Transcription Batch 2026-09-21 14-30-00 (2 Files)/
    BIO 111 - Cell Membranes/
      BIO-111-Cell-Membranes.plain-transcript.txt
      BIO-111-Cell-Membranes.tare-link.json
```

The visible manifest is pretty-printed for inspection. The hidden pointer next
to the original media is compact JSON and contains the source path, size,
modification time, transcript SHA-256, all output paths, the semantic display
name/folder, and the provider/model/strategy used for naming. Existing Tare
1.0 manifests remain readable.

FreeLLMAPI is an optional local desktop app. Paste its unified API key into
Settings; Tare stores it in the macOS Keychain under
`com.tejas.Tare.freellmapi` and never writes it to preferences, transcript
metadata, logs, or the DMG. Tare reads the local FreeLLMAPI port from its
configuration and makes one short request per completed transcript. It does
not launch FreeLLMAPI, install a LaunchAgent, or keep a replacement server
alive. Tare does not read the Keychain while launching or rendering Settings;
it reads the secret once, off the main actor, when a batch starts. If macOS
cannot authorize that read silently, Tare skips the provider and uses the
local filename fallback rather than presenting a modal prompt. The
environment variables `TARE_FREELLM_URL`, `TARE_FREELLM_MODEL`, and
`TARE_FREELLM_API_KEY` are available for development/automation overrides; do
not commit the key.

The model preference is quality-first rather than popularity-first: Tare uses
the local FreeLLMAPI catalog's intelligence ordering, then tries fast free
fallbacks when a route is unavailable. Public benchmark suites such as
[OpenRouter Benchmarks](https://openrouter.ai/benchmarks) and
[LiveBench](https://livebench.ai/) are useful quality signals, while OpenRouter
explicitly notes that free-model usage rankings are adoption metrics rather
than accuracy benchmarks. The live `/v1/models` response remains authoritative
for availability, and `TARE_FREELLM_MODEL` can pin a known-good route.

### Google Gemini cloud transcription

The **Transcribe via Cloud** tab is a separate provider path for the exact
`gemini-3.5-transcribe` model. It does not enter the local Hugging Face model
catalog, does not require the local MLX bridge, and does not put model files in
the app. The user must explicitly select the cloud model and add at least one
Google Gemini API key.

API keys are stored as secrets in the macOS Keychain. Tare stores only a label,
the last four characters, enabled state, order, and usage metadata in its local
preferences. Keys are tried in the configured order and the next key is used
after authentication, rate-limit, transient service, or network failure.
Google applies quotas per Cloud project, not per API key, so multiple keys are
failover and resilience—not a way to multiply quota. Tare never puts a key in
a URL or transcript output. Cloud mode, annotation choices, vocabulary, output
folder, and batch-folder behavior are saved automatically, so a restart keeps
the configured workflow.

Keychain secret reads and writes run off the main UI actor, and a batch takes
one credential snapshot instead of rereading the Keychain during every SwiftUI
refresh or transcription job. Release and development packaging automatically
uses the first available Apple Development signing identity (or the explicit
`TARE_CODESIGN_IDENTITY` value); this keeps the app's Keychain access
requirement stable across rebuilds. If a Mac has no Apple signing identity,
packaging falls back to ad-hoc signing and macOS may ask for Keychain approval
again after a rebuild. A key created by an older ad-hoc Tare build may require
one final approval or re-entry when first opened by the stable-signed build.

Verbatim mode is the Google-documented default and preserves the spoken
content. Smart mode is optional and is intended for more readable lecture
transcripts. Verbatim mode can request word timestamps and/or speaker labels.
Tare rejects the combinations Google rejects: smart mode with annotations, or
custom vocabulary with word timestamps or speaker diarization. Vocabulary is
trimmed, de-duplicated, and limited to 1,000 terms before a request is sent;
Google recommends keeping it near 100 terms for best results. When a language
is selected, Tare sends a supported BCP-47 hint; Auto Detect sends the
documented empty `language_codes` array.

Long recordings are planned from measured duration before upload. Tare uses
55-minute safe chunks for unannotated requests and 28-minute safe chunks when
word timestamps or speaker labels are enabled, leaving margin below Google’s
documented 60-minute and 30-minute unary limits. Interior boundaries prefer
detected silence and include 1.5 seconds of context so words are not cut at a
hard boundary; the final assembly removes only duplicate boundary words and
restores source-relative timestamps. Cloud intermediates and chunks use
lossless FLAC while preserving the source sample rate and channels. Multi-hour
lectures are processed sequentially, every chunk must succeed, and Tare does
not export partial text after a failed chunk. Each uploaded Files API object is
deleted after its interaction completes. Interactions are sent with
`store=false`, and the API key is sent only to Google API requests—not to the
signed upload URL or any saved transcript.

The cloud path requires `ffmpeg` and `ffprobe` so Tare can measure duration and
prepare lossless chunks safely. It refuses files over Google’s 2 GB per-file
limit and stops if duration cannot be measured. See Google’s
[audio transcription guide](https://ai.google.dev/gemini-api/docs/transcribe),
[Files API](https://ai.google.dev/gemini-api/docs/files), and
[rate-limit guidance](https://ai.google.dev/gemini-api/docs/rate-limits) for
provider-side limits and data handling.

Canary-Qwen uses the cached `speechllms/canary-speechlm-mlx` encoder and LLM
overlay with a local `Qwen/Qwen3-1.7B` base model. Tare never bundles that
base model or the Canary weights. The full-precision combined load is not
usable below its Metal buffer requirement; the Models screen reports that
constraint before transcription starts. MOSS uses the official
`OpenMOSS-Team/MOSS-Transcribe-Diarize` Transformers
runtime with anonymous speaker labels and a 90-minute single-pass limit.
Parakeet uses the Apple-Silicon `parakeet-mlx` runtime with the
`mlx-community/parakeet-tdt-0.6b-v3` checkpoint and internal long-audio
chunking. Qwen3-ASR 1.7B 6-bit uses the MLX-Audio loader and is approximately
2.03 GB. Voxtral Mini 3B 8-bit uses
`MarkusKaemmerer/Voxtral-Mini-3B-2507-8bit-dense-encoder`, is approximately
6.02 GB, and is split into memory-safe passes for 16-GB Apple Silicon Macs;
it does not provide word timestamps. The Models tab can download a selected
repository into that same cache, but it does not present the full catalog
until the user asks for it.

## Finder Quick Actions

```bash
./script/install_quick_actions.sh
```

This installs three macOS Services/Quick Actions in `~/Library/Services`:

- `Clean Name`
- `Transcribe with Tare`
- `Clean Names then Transcribe`

The installer stages the available `clean-name-cli.py` from the local Name Clean app.
The transcription actions save outputs next to the selected source media by default.
They embed subtitles directly into MKV files and embed custom lyrics into supported
audio files such as `.m4a` and `.mp3`. Audio originals are kept in `Original Audio Backups`.
For MP4, M4V, and MOV inputs they write an IINA-friendly
`.captioned.mkv` beside the source instead of creating a `mov_text` track that
IINA may not expose consistently. Replaced MKV originals are moved to an
`Original Video Backups` folder beside the source.
Finder Quick Actions read the saved app preferences for model, language, output
text transcript, and batch-folder behavior. Environment
variables such as `TARE_MODEL`, `TARE_LANGUAGE`,
`TARE_CHUNK_SECONDS`, and `TARE_FORMATS` still
override the saved choices. `TARE_CHUNK_WORKERS` is accepted for
compatibility, but MLX chunk transcription stays serialized by default to avoid
Metal backend crashes under load.
The dedicated Voxtral adapter also accepts `TARE_VOXTRAL_CHUNK_SECONDS`
(default 120 seconds, clamped to 60–300) and
`TARE_VOXTRAL_MAX_NEW_TOKENS` (default 4096).
Set `TARE_OUTPUT_DIR` to force a central output folder.
The installer also stages a release `TranscriberBatch` binary and helper script
under `~/Library/Application Support/Tare` so Finder can run the
actions without needing to execute project scripts from `Documents`.

Progress logs are written here:

- `~/Library/Logs/NameClean/quick-action-clean.log`
- `~/Library/Logs/Tare/quick-action-transcribe.log`
- `~/Library/Logs/Tare/quick-action-clean-then-transcribe.log`

## Build

```bash
swift run TranscriberCoreSmokeTests
swift run TranscriberBatch -- --attach-to-source --output "$HOME/Documents/Tare" path/to/video.mp4
./script/build_and_run.sh --verify
./script/build_and_run.sh --dmg
./script/build_and_run.sh --install
```

The normal run path stages its temporary development app outside the project
`dist/` directory. Release packaging stages the app in a temporary directory,
then writes only `dist/Tare-<version>-macOS-<arch>.dmg` and its `.sha256`
checksum. The DMG contains one `Tare.app` and an `Applications` shortcut.
Installation replaces only the canonical `/Applications/Tare.app`; any prior
bundle is moved to the user's Trash for recovery, and no second app bundle is
left in `dist/`.
