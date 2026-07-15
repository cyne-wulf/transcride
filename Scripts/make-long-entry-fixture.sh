#!/bin/bash
# Builds one long-form Transcride entry by looping a real source entry. The
# output is intended for playback, transcript, search, editing, and memory
# profiling; it does not exercise transcription because timed artifacts are
# generated up front.
#
# Usage:
#   Scripts/make-long-entry-fixture.sh --source <entry-dir> [options]
#
# Options:
#   --hours <number>       Target length in hours (default: 12)
#   --output <vault-dir>   Fixture vault (default: TestVault-<hours>h)
#   --title <text>         Entry title (default: <hours> Hour Performance Fixture)
#   --bitrate <rate>       AAC bitrate passed to ffmpeg (default: 32k)
#   --force                Replace this script's existing fixture entry
#   --help                 Show this help
#
# Requires python3, ffmpeg, and ffprobe. TestVault* output is gitignored.
set -euo pipefail

usage() {
  cat <<'EOF'
Builds one long-form Transcride entry by looping a real source entry.

Usage:
  Scripts/make-long-entry-fixture.sh --source <entry-dir> [options]

Options:
  --hours <number>       Target length in hours (default: 12)
  --output <vault-dir>   Fixture vault (default: TestVault-<hours>h)
  --title <text>         Entry title (default: <hours> Hour Performance Fixture)
  --bitrate <rate>       AAC bitrate passed to ffmpeg (default: 32k)
  --force                Replace this script's existing fixture entry
  --help                 Show this help
EOF
}

SOURCE=""
HOURS="12"
OUTPUT=""
TITLE=""
BITRATE="32k"
FORCE=false

while (($#)); do
  case "$1" in
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --hours)
      HOURS="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --bitrate)
      BITRATE="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command in python3 ffmpeg ffprobe; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ -z "$SOURCE" || ! -d "$SOURCE" ]]; then
  echo "--source must name an existing Transcride entry directory" >&2
  exit 2
fi

if ! [[ "$HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! python3 - "$HOURS" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
then
  echo "--hours must be a number greater than zero" >&2
  exit 2
fi

HOURS_TAG="${HOURS//./-}h"
OUTPUT="${OUTPUT:-TestVault-$HOURS_TAG}"
TITLE="${TITLE:-$HOURS Hour Performance Fixture}"
# EntryFolderName requires a canonical 19-character timestamp after the
# `transcride-` prefix. A fixed fixture identity keeps --force deterministic;
# frontmatter carries the actual generation date shown in the library.
ENTRY_NAME="transcride-2000-01-01T00-00-00-fixture-$HOURS_TAG-long-input"
ENTRY="$OUTPUT/$ENTRY_NAME"
TEMP_ENTRY="$OUTPUT/.${ENTRY_NAME}.tmp.$$"
OLD_ENTRY="$OUTPUT/.${ENTRY_NAME}.old.$$"

SOURCE_TRANSCRIPT="$SOURCE/transcript.original.json"
SOURCE_WAVEFORM="$SOURCE/waveform.json"
if [[ ! -f "$SOURCE_TRANSCRIPT" || ! -f "$SOURCE_WAVEFORM" ]]; then
  echo "Source entry must contain transcript.original.json and waveform.json" >&2
  exit 1
fi

SOURCE_AUDIO=""
for candidate in "$SOURCE"/*.m4a "$SOURCE"/*.wav "$SOURCE"/*.caf "$SOURCE"/*.mp3 "$SOURCE"/*.flac; do
  if [[ -f "$candidate" ]]; then
    SOURCE_AUDIO="$candidate"
    break
  fi
done
if [[ -z "$SOURCE_AUDIO" ]]; then
  echo "Source entry does not contain supported audio" >&2
  exit 1
fi

SOURCE_MARKDOWN=""
for candidate in "$SOURCE"/*.md; do
  if [[ -f "$candidate" && "$(basename "$candidate")" != .* ]]; then
    SOURCE_MARKDOWN="$candidate"
    break
  fi
done

if [[ -e "$ENTRY" ]]; then
  if [[ "$FORCE" != true ]]; then
    echo "Fixture already exists: $ENTRY (pass --force to replace it)" >&2
    exit 1
  fi
fi

mkdir -p "$OUTPUT"
rm -rf "$TEMP_ENTRY"
mkdir -p "$TEMP_ENTRY"
cleanup() {
  rm -rf "$TEMP_ENTRY"
  if [[ -e "$OLD_ENTRY" && ! -e "$ENTRY" ]]; then
    mv "$OLD_ENTRY" "$ENTRY"
  else
    rm -rf "$OLD_ENTRY"
  fi
}
trap cleanup EXIT

TARGET_SECONDS=$(python3 - "$HOURS" <<'PY'
import sys
print(f"{float(sys.argv[1]) * 3600:.6f}")
PY
)
SOURCE_DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$SOURCE_AUDIO")

echo "Generating $HOURS-hour audio from $(basename "$SOURCE_AUDIO")..."
ffmpeg -hide_banner -loglevel error -stats -stream_loop -1 \
  -i "$SOURCE_AUDIO" -t "$TARGET_SECONDS" -map 0:a:0 -vn \
  -ac 1 -ar 16000 -c:a aac -b:a "$BITRATE" -movflags +faststart \
  "$TEMP_ENTRY/audio.m4a"

python3 - \
  "$SOURCE_TRANSCRIPT" "$SOURCE_WAVEFORM" "$SOURCE_MARKDOWN" \
  "$TEMP_ENTRY" "$TARGET_SECONDS" "$SOURCE_DURATION" "$TITLE" <<'PY'
import copy
import datetime
import json
import math
import pathlib
import re
import sys

(
    transcript_path,
    waveform_path,
    markdown_path,
    output_path,
    target_seconds_text,
    source_duration_text,
    title,
) = sys.argv[1:]

target_seconds = float(target_seconds_text)
source_duration = float(source_duration_text)
output = pathlib.Path(output_path)

with open(transcript_path, encoding="utf-8") as handle:
    source_transcript = json.load(handle)
with open(waveform_path, encoding="utf-8") as handle:
    source_waveform = json.load(handle)

source_segments = source_transcript.get("segments", [])
source_peaks = source_waveform.get("peaks", [])
peaks_per_second = int(source_waveform.get("peaksPerSecond", 0))
if not source_segments:
    raise SystemExit("Source transcript contains no segments")
if not source_peaks or peaks_per_second <= 0:
    raise SystemExit("Source waveform contains no valid peaks")
if not math.isfinite(source_duration) or source_duration <= 0:
    raise SystemExit("Source audio has an invalid duration")

segments = []
cycle = 0
while cycle * source_duration < target_seconds:
    offset = cycle * source_duration
    for source_segment in source_segments:
        segment_start = float(source_segment["start"]) + offset
        if segment_start >= target_seconds:
            break
        words = []
        for source_word in source_segment.get("words", []):
            word_start = float(source_word["start"]) + offset
            if word_start >= target_seconds:
                break
            word = copy.deepcopy(source_word)
            word["start"] = word_start
            word["end"] = min(target_seconds, float(source_word["end"]) + offset)
            words.append(word)
        if not words:
            continue
        segment = copy.deepcopy(source_segment)
        segment["start"] = segment_start
        segment["end"] = min(target_seconds, float(source_segment["end"]) + offset)
        segment["words"] = words
        segments.append(segment)
    cycle += 1

transcript = copy.deepcopy(source_transcript)
transcript["segments"] = segments
engine = transcript.setdefault("engine", {})
options = engine.setdefault("options", {})
options["fixture"] = f"looped to {target_seconds:.0f} seconds"
engine["created"] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")

target_peak_count = math.ceil(target_seconds * peaks_per_second)
peaks = [source_peaks[index % len(source_peaks)] for index in range(target_peak_count)]
waveform = {
    "version": 1,
    "peaksPerSecond": peaks_per_second,
    "duration": target_seconds,
    "peaks": peaks,
}

speaker_names = {}
if markdown_path:
    markdown = pathlib.Path(markdown_path).read_text(encoding="utf-8")
    if markdown.startswith("---\n"):
        header_end = markdown.find("\n---\n", 4)
        if header_end >= 0:
            for line in markdown[4:header_end].splitlines():
                match = re.fullmatch(r"speaker_([A-Za-z0-9_-]+):\s*(.*)", line)
                if match:
                    value = match.group(2).strip().strip('"').strip("'")
                    if value:
                        speaker_names[match.group(1).upper()] = value

def speaker_display_name(speaker_id):
    if speaker_id.upper() in speaker_names:
        return speaker_names[speaker_id.upper()]
    match = re.fullmatch(r"[Ss]([0-9]+)", speaker_id)
    return f"Speaker {match.group(1)}" if match else speaker_id

parts = []
previous_end = None
current_speaker = None
started = False
for segment in segments:
    speaker = segment.get("speaker")
    for word in segment.get("words", []):
        text = str(word.get("text", "")).strip()
        if not text:
            continue
        speaker_changed = started and speaker != current_speaker
        if started:
            pause_break = previous_end is not None and float(word["start"]) - previous_end >= 2.0
            parts.append("\n\n" if speaker_changed or pause_break else " ")
        if speaker is not None and (not started or speaker_changed):
            parts.append(f"**{speaker_display_name(str(speaker))}:** ")
        parts.append(text)
        previous_end = float(word["end"])
        current_speaker = speaker
        started = True

def yaml_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'

created = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
markdown = (
    "---\n"
    f"title: {yaml_quote(title)}\n"
    f"created: {created}\n"
    f"duration: {target_seconds:.2f}\n"
    "source: fixture\n"
    "engine: repeated-source\n"
    "---\n\n"
    + "".join(parts)
    + "\n"
)

with open(output / "transcript.original.json", "w", encoding="utf-8") as handle:
    json.dump(transcript, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
with open(output / "waveform.json", "w", encoding="utf-8") as handle:
    json.dump(waveform, handle, separators=(",", ":"))
markdown_name = title.replace("/", "-").replace(":", "-")
markdown_name = markdown_name.lstrip(".")[:100].strip()
markdown_name = f"{markdown_name}.md" if markdown_name else "transcript.md"
with open(output / markdown_name, "w", encoding="utf-8") as handle:
    handle.write(markdown)

word_count = sum(len(segment.get("words", [])) for segment in segments)
print(f"Generated {len(segments):,} segments, {word_count:,} words, and {len(peaks):,} peaks")
PY

if [[ -e "$ENTRY" ]]; then
  mv "$ENTRY" "$OLD_ENTRY"
fi
if ! mv "$TEMP_ENTRY" "$ENTRY"; then
  if [[ -e "$OLD_ENTRY" ]]; then
    mv "$OLD_ENTRY" "$ENTRY"
  fi
  exit 1
fi
rm -rf "$OLD_ENTRY"
trap - EXIT

ACTUAL_DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$ENTRY/audio.m4a")
echo "Created fixture: $ENTRY"
echo "Target duration: $TARGET_SECONDS seconds; audio duration: $ACTUAL_DURATION seconds"
du -sh "$ENTRY"
