# Gemini cloud transcription and long-recording limits

## Symptom

A lecture longer than the dedicated Gemini transcription request limit fails
even though the account still has available daily usage. A second failure mode
is selecting a cloud model that the local model manager cannot inspect. A third
failure mode is discovering mid-upload that the API key/project cannot use
`gemini-3.5-transcribe`, or that free-tier project quotas are exhausted.

## Root cause and provider contract

`gemini-3.5-transcribe` is a cloud interaction model, not a local Hugging Face
checkpoint. Google documents a one-hour unary audio limit, reduced to
30 minutes when word timestamps or speaker diarization is enabled. Audio
tokenization for the dedicated Gemini 3.5 Transcribe product is duration-based.
Tare estimates input audio tokens using Google’s Gemini 3.5 Transcribe pricing
footnote of **25 audio tokens per second**
(<https://ai.google.dev/gemini-api/docs/pricing>). General multimodal audio docs
still mention 32 tok/s; Tare follows the dedicated transcription pricing value
for planning copy. Reducing file size alone does not make a 72-minute request
fit. Custom vocabulary is limited to 1,000 terms (Google recommends about 100)
and cannot be combined with timestamps or diarization. Verbatim mode is the
documented default; Smart mode cannot request those annotations. Automatic
language detection is represented by an omitted or empty `language_codes`
array, while known-language hints must be BCP-47 codes.

Authoritative provider references:

- <https://ai.google.dev/gemini-api/docs/transcribe>
- <https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe>
- <https://ai.google.dev/gemini-api/docs/pricing>
- <https://ai.google.dev/gemini-api/docs/files>
- <https://ai.google.dev/gemini-api/docs/rate-limits>

## Recovery implemented

- Added a distinct `.geminiTranscribe` backend and canonical model ID. Model
  alias normalization is case-insensitive for documented Gemini resource-style
  IDs, while the local catalog remains local-only.
- Added a **Transcribe via Cloud** tab with explicit cloud selection, option
  validation, and Keychain-backed API-key records. Only labels, last-four
  characters, order, enabled state, and usage metadata are stored in user
  defaults. Multiple enabled keys are ordered failover; they do not multiply
  Google project quotas.
- After a key is saved (and via **Verify model access**), Tare performs a
  lightweight authenticated `GET /v1beta/models/gemini-3.5-transcribe` check so
  missing model access is caught before a long lecture upload. The same check
  runs again during Start preflight for enabled keys.
- Tare measures the extracted audio with `ffprobe` before upload. It uses a
  55-minute safe chunk limit for unannotated requests and 28 minutes for
  annotated requests, below Google’s documented limits.
- Multi-hour recordings are split into the minimum safe number of core spans.
  Detected silence is preferred for interior boundaries; each boundary carries
  1.5 seconds of context, and the assembled transcript removes only matching
  boundary words. All final word timestamps are translated back to the source
  timeline. A 2h30m plain lecture plans as 3 safe chunks; annotated mode plans
  as 6 safe chunks. Progress shows chunk count and estimated audio tokens.
- Cloud audio is extracted to lossless FLAC while preserving sample rate and
  channel count. Files API uploads are streamed from disk, checked against the
  2 GB per-file limit, polled until active, and deleted after each interaction.
  The resumable upload follows Google’s two-phase headers and does not copy the
  API key to the returned signed upload URL. Interactions use the exact model
  ID, the documented audio `mime_type`, explicit `language_codes`, and
  `store=false` so Tare does not ask Google to retain the interaction.
- Requests are sequential per recording, retry transient 408/429/5xx and
  network failures with bounded exponential backoff (honoring a bounded
  `Retry-After` value), rotate to the next key after retryable/auth/model
  failures, and never export partial text after a failed chunk. If an annotated
  request returns no word annotations, Tare treats it as incomplete instead of
  silently exporting a lower-fidelity result. Rate-limit copy explicitly warns
  that free-tier RPD/TPM are per project.
- API-key metadata is persisted only after the Keychain secret succeeds, and
  destructive key updates roll back their metadata when Keychain deletion
  fails. Damaged metadata is surfaced as an error instead of being silently
  replaced by an empty list.
- Keychain reads and writes run away from the main actor, and the app does not
  read secrets from a SwiftUI body. Verify and Start each take one credential
  snapshot. The package scripts prefer the available Apple Development signing
  identity, preserving the app's Keychain access requirement between local
  rebuilds. Repeated approval prompts after every rebuild indicate ad-hoc
  signing; set `TARE_CODESIGN_IDENTITY` to a stable local identity or package
  on a Mac with an Apple Development identity. A secret saved by an older
  ad-hoc bundle may require one final approval or re-entry during the
  transition.
- When Google answers 2xx but the reply holds no usable transcript ("finished
  without returning transcript text" or "incomplete transcript"), Tare writes
  the raw reply to `~/Library/Logs/Tare/gemini-reply-<timestamp>.txt` (HTTP
  status, content type, body up to 256 KB). The API key is a request header
  and is never in that file. Observed 2026-10-04: a 67.6-minute m4a failed this
  way after 32 s while a 61-minute m4a succeeded; the cause was not yet known
  because the reply was not kept. Read the newest log file on the next
  occurrence.

## Validation

- Swift package build passes.
- Smoke coverage verifies model detection, cloud/local catalog separation,
  provider-option rejection, 71:52 two-chunk planning, two-hour annotated
  five-chunk planning, **exactly 2h30m (9000s) plain three-chunk and annotated
  six-chunk planning**, boundary overlap/silence preference, lossless
  source/chunk extraction, exact interaction payload construction, response
  timestamp assembly, authentication-key failover, and mock model-access
  verification through a URLProtocol mock.
- A real Google key and live provider request were not used; live cloud
  acceptance remains an operational follow-up requiring the user’s own key and
  authorization to send audio to Google.

## Residual risks

Provider-side project quotas, billing, model availability, and Google’s data
retention or policy behavior remain external to Tare. Free-tier RPD/TPM can
still reject a correctly chunked 2.5-hour lecture after planning and model
verification succeed — especially with annotations (more chunks) or when other
tools share the same Google project. Extra API keys help only when they belong
to different projects with separate quotas. If `ffprobe` cannot read a
duration, Tare stops before uploading rather than guessing a request size.
Very large individual chunks still respect the 2 GB Files API guard and report
an actionable failure instead of truncating audio.
