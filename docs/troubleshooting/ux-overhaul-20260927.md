# UX overhaul — 2026-09-27

Canonical target: `/Users/tejas/Coding Projects/Swift Transcriber App`, branch
`codex/tare-product-rework`. Baseline `be41d3c`; work committed as `6151e98`
through `a3307d8`. The repository was made public first, on `main`, as
`9acd269`.

## Starting point

Five read-only audits ran in parallel over the Transcribe flow, Models, Cloud,
Settings plus accessibility, and visual design. They produced 121 findings,
deduped into `docs/ux/OVERHAUL-BACKLOG.md` (kept local; `docs/ux/` is
gitignored). High-confidence items were those three or more agents reported
independently: the 602pt recognition row in a 420pt window, and Start failures
whose only rendering lived on the Models tab.

## What changed

**Correctness.** Import no longer scans the filesystem on the main actor per
file; cancelling reports Cancelled instead of Failed with a raw ffmpeg exit
code; model selection and model dependency are separate, so an English language
setting can no longer make two models claim to be in use; the Models tab can
select a model at all; removal is confirmed; cache refresh merges instead of
replacing; a cloud cancel no longer re-uploads for every remaining key.

**Progress and state.** The local bridge already printed per-chunk progress that
Swift discarded, so `ProcessRunner` now streams stderr and the progress is real
rather than a frozen 20%. Batches end with a summary. The active job is tracked
separately from the user's selection.

**Design system.** Tokens for spacing, radii, metrics, colour, and type; a
`StatePresentation` type where the title is non-optional, so a state cannot be
rendered without its label; a queue `Table` with fixed-width cells and a
reserved chunk slot; a fixed-height status header and strip. The accent colour is
deliberately not overridden, because AppKit draws focus rings in the system
accent.

**Accessibility.** Zero `accessibility*` modifiers became a labelled table,
announced status changes, adaptive colours, one focusable menu replacing four
icon-only borderless buttons, and `⌘Delete` for Remove.

**Output and media.** Output-root failures report their cause; the caption
toggle is real; the MKV pipeline has controls behind a confirmation that lists
the affected files; seven unreachable transcript sidecars are now selectable, with
word-timestamp formats gated on model capability.

## Boundaries reached, and one refused

- **Keychain.** `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` was inert because
  `SecItem` targets the file-based login Keychain, which ignores the attribute.
  A `KeychainBackend` now probes with a throwaway write and migrates secrets when
  the data-protection Keychain is reachable. **A read cannot detect the missing
  entitlement** — a data-protection `SecItemCopyMatching` still returns "not
  found" — so detection must use an add.
- **Entitlements were deliberately not shipped.** `$(AppIdentifierPrefix)` is only
  substituted when a provisioning profile is embedded, so a template entitlements
  file signs as a literal non-matching group, and that makes every Keychain call
  fail with `errSecMissingEntitlement`. For a public repo each builder would have
  to generate their own team-scoped entitlement. The Swift fallback makes the
  situation safe either way, and the residual exposure is documented in the
  README and in `KeychainBackend`.
- **Export formats.** The store intersected formats down to two, so the other six
  sidecars were unreachable despite the exporter implementing all of them. The
  canonical set now lives on `ExportFormat`. A smoke test asserted the old
  two-format restriction and was updated to assert the real invariant.
- `TranscriptionConfiguration.requiresWordTimestamps` is still hardcoded `true`.
  Making it depend on the model would change embedded word-span output, which is
  a product decision; only the UI is gated.

## Verified

`swift build` clean with no warnings. `TranscriberCoreSmokeTests` and
`--exports-only` pass. All seven shell scripts pass `bash -n`. A secrets scan
over every commit shows nothing, and the scripts no longer contain an absolute
home path.

## Not verified

No UI was run. Layout claims — the `ViewThatFits` switchover points, the table
column widths, the capped content width — are unconfirmed visually. The cloud
path was exercised only through the mock `URLProtocol` tests; no real Google
request was made. The positive data-protection Keychain path could not be
exercised, because the throwaway test bundle was killed on launch.

## Residual

The local Hugging Face cache holds 8 repositories, none of them in Tare's
catalog, so this machine permanently reproduces the "no models" empty state. That
also means the Canary-Qwen 13.3 GiB capacity guard is never exercised, so it is
compile-verified only. A `--action selftest` in `script/manage_models.py` would
make it checkable without a 14 GB download.

`autoScanOnLaunch` and `autoProcessDiscoveredMKVs` still persist and are still
never read. Wiring them is a behaviour change — they default to four user
directories — so they were left alone rather than half-connected.
