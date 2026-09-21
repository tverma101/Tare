#!/usr/bin/env python3
"""Convert MKV/media files into QuickTime-friendly MP4 files.

The converter keeps compatible H.264/HEVC video streams when possible, converts
audio to AAC, and converts text subtitle streams to mov_text so QuickTime can
show them from inside the MP4 container.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO


COMPATIBLE_VIDEO_CODECS = {"h264", "hevc", "mpeg4"}
TEXT_SUBTITLE_CODECS = {"ass", "ssa", "subrip", "srt", "text", "webvtt", "mov_text"}
IMAGE_SUBTITLE_CODECS = {"dvd_subtitle", "hdmv_pgs_subtitle", "pgssub", "xsub"}
SIDECAR_EXTENSIONS = [".srt", ".vtt", ".ass", ".ssa"]


@dataclass
class ConversionResult:
    source: str
    output: str
    changed: bool
    reason: str
    video_mode: str
    text_subtitles: int
    skipped_subtitles: int
    elapsed_seconds: float

    def to_dict(self) -> dict[str, object]:
        return {
            "source": self.source,
            "output": self.output,
            "changed": self.changed,
            "reason": self.reason,
            "video_mode": self.video_mode,
            "text_subtitles": self.text_subtitles,
            "skipped_subtitles": self.skipped_subtitles,
            "elapsed_seconds": round(self.elapsed_seconds, 3),
        }


def resolve_executable(name: str) -> str:
    for candidate in [
        f"/opt/homebrew/bin/{name}",
        f"/usr/local/bin/{name}",
        f"/usr/bin/{name}",
        f"/bin/{name}",
    ]:
        if os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate

    found = shutil.which(name)
    if found:
        return found

    raise RuntimeError(f"{name} was not found")


def run_json(command: list[str]) -> dict[str, object]:
    process = subprocess.run(command, text=True, capture_output=True)
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or f"{command[0]} failed")
    return json.loads(process.stdout)


def unique_output_path(source: Path, output_dir: Path | None) -> Path:
    directory = output_dir or source.parent
    directory.mkdir(parents=True, exist_ok=True)
    stem = source.stem
    candidate = directory / f"{stem}.mp4"
    index = 2

    while candidate.exists() and candidate.resolve() != source.resolve():
        candidate = directory / f"{stem} ({index}).mp4"
        index += 1

    return candidate


def sibling_sidecars(source: Path) -> list[Path]:
    sidecars: list[Path] = []
    for extension in SIDECAR_EXTENSIONS:
        candidate = source.with_suffix(extension)
        if candidate.exists():
            sidecars.append(candidate)
    return sidecars


def sanitize_title(path: Path) -> str:
    value = path.stem.replace(".", " ").replace("_", " ")
    value = re.sub(r"\s+", " ", value).strip()
    return value or path.stem


def probe_streams(ffprobe: str, source: Path) -> list[dict[str, object]]:
    payload = run_json([
        ffprobe,
        "-v",
        "error",
        "-show_streams",
        "-of",
        "json",
        str(source),
    ])
    streams = payload.get("streams", [])
    if not isinstance(streams, list):
        return []
    return [stream for stream in streams if isinstance(stream, dict)]


def convert_one(
    source: Path,
    *,
    ffmpeg: str,
    ffprobe: str,
    output_dir: Path | None,
    force_transcode_video: bool,
    dry_run: bool,
) -> ConversionResult:
    started = time.monotonic()
    if not source.exists():
        return ConversionResult(str(source), str(source), False, "missing", "none", 0, 0, 0)
    if source.is_dir():
        return ConversionResult(str(source), str(source), False, "directory skipped", "none", 0, 0, 0)

    streams = probe_streams(ffprobe, source)
    video_streams = [stream for stream in streams if stream.get("codec_type") == "video"]
    if not video_streams:
        return ConversionResult(str(source), str(source), False, "no video stream", "none", 0, 0, time.monotonic() - started)

    video_codec = str(video_streams[0].get("codec_name", "")).lower()
    copy_video = video_codec in COMPATIBLE_VIDEO_CODECS and not force_transcode_video
    video_mode = "copy" if copy_video else "h264"

    text_subtitles = [
        stream for stream in streams
        if stream.get("codec_type") == "subtitle"
        and str(stream.get("codec_name", "")).lower() in TEXT_SUBTITLE_CODECS
    ]
    skipped_subtitles = [
        stream for stream in streams
        if stream.get("codec_type") == "subtitle"
        and str(stream.get("codec_name", "")).lower() not in TEXT_SUBTITLE_CODECS
    ]
    sidecars = sibling_sidecars(source)
    output = unique_output_path(source, output_dir)

    command = [ffmpeg, "-hide_banner", "-stats", "-y", "-i", str(source)]
    for sidecar in sidecars:
        command += ["-i", str(sidecar)]

    command += ["-map", "0:v:0", "-map", "0:a?"]
    for stream in text_subtitles:
        command += ["-map", f"0:{stream['index']}"]
    for offset, _ in enumerate(sidecars, start=1):
        command += ["-map", f"{offset}:0"]

    if copy_video:
        command += ["-c:v", "copy"]
    else:
        command += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]

    command += [
        "-c:a",
        "aac",
        "-b:a",
        "192k",
    ]

    subtitle_count = len(text_subtitles) + len(sidecars)
    if subtitle_count:
        command += ["-c:s", "mov_text"]

    command += [
        "-map_metadata",
        "0",
        "-metadata",
        f"title={sanitize_title(source)}",
        "-movflags",
        "+faststart",
        str(output),
    ]

    if dry_run:
        reason = "dry run"
    else:
        process = subprocess.run(command, text=True, capture_output=True)
        if process.returncode != 0:
            stderr = process.stderr.strip()
            raise RuntimeError(stderr or f"ffmpeg failed for {source.name}")
        reason = "converted"

    if skipped_subtitles:
        reason += f"; skipped {len(skipped_subtitles)} non-text subtitle stream(s)"
        skipped_names = ", ".join(str(stream.get("codec_name", "unknown")) for stream in skipped_subtitles)
        reason += f" ({skipped_names})"

    return ConversionResult(
        str(source),
        str(output),
        True,
        reason,
        video_mode,
        subtitle_count,
        len(skipped_subtitles),
        time.monotonic() - started,
    )


def format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, remainder = divmod(int(seconds), 60)
    if minutes < 60:
        return f"{minutes}m {remainder}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m"


def progress_line(index: int, total: int, result: ConversionResult, started: float) -> str:
    elapsed = time.monotonic() - started
    average = elapsed / max(index, 1)
    eta = average * max(total - index, 0)
    return (
        f"[{index}/{total}] {Path(result.source).name} -> {Path(result.output).name} "
        f"({result.reason}; video={result.video_mode}; subtitles={result.text_subtitles}) "
        f"| elapsed {format_duration(elapsed)} | eta {format_duration(eta)}"
    )


def write_progress(line: str, *, enabled: bool, log_handle: TextIO | None) -> None:
    if enabled:
        print(line, file=sys.stderr, flush=True)
    if log_handle:
        print(line, file=log_handle, flush=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert videos to QuickTime-compatible MP4.")
    parser.add_argument("paths", nargs="+", help="Video files to convert.")
    parser.add_argument("--output-dir", help="Write converted MP4 files to this directory instead of beside each input.")
    parser.add_argument("--force-transcode-video", action="store_true", help="Transcode video to H.264 even if it could be copied.")
    parser.add_argument("--dry-run", action="store_true", help="Preview commands without converting.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON results.")
    parser.add_argument("--progress", action="store_true", help="Print per-file progress with elapsed time and ETA to stderr.")
    parser.add_argument("--log", help="Append progress to this log file.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    ffmpeg = resolve_executable("ffmpeg")
    ffprobe = resolve_executable("ffprobe")
    output_dir = Path(args.output_dir).expanduser() if args.output_dir else None
    log_handle: TextIO | None = None
    results: list[ConversionResult] = []
    started = time.monotonic()

    try:
        if args.log:
            log_path = Path(args.log).expanduser()
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_handle = log_path.open("a", encoding="utf-8")
            print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] QuickTime conversion run", file=log_handle)

        total = len(args.paths)
        for index, raw in enumerate(args.paths, start=1):
            result = convert_one(
                Path(raw).expanduser(),
                ffmpeg=ffmpeg,
                ffprobe=ffprobe,
                output_dir=output_dir,
                force_transcode_video=args.force_transcode_video,
                dry_run=args.dry_run,
            )
            results.append(result)
            write_progress(progress_line(index, total, result, started), enabled=args.progress, log_handle=log_handle)
    finally:
        if log_handle:
            log_handle.close()

    if args.json:
        print(json.dumps([result.to_dict() for result in results], indent=2))
    else:
        for result in results:
            if result.changed:
                print(f"Converted: {result.source} -> {result.output} ({result.reason})")
            else:
                print(f"Skipped: {result.source} ({result.reason})")

    return 1 if any(result.reason == "missing" for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
