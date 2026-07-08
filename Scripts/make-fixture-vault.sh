#!/bin/bash
# Generates a fixture vault for manual testing / the Milestone 1 verification
# checklist. Usage: Scripts/make-fixture-vault.sh [entry-count] [output-dir]
# Defaults: 500 entries into ./TestVault-<count>. Output dirs matching
# TestVault* are gitignored.
set -euo pipefail

COUNT="${1:-500}"
OUT="${2:-TestVault-$COUNT}"

mkdir -p "$OUT/Journal/Ideas" "$OUT/Work"

for ((i = 0; i < COUNT; i++)); do
  # Spread creation dates over ~500 days, deterministic per index.
  ts=$(date -v -"$((i))"d -v -"$((i % 12))"H "+%Y-%m-%dT%H-%M-%S" 2>/dev/null)
  iso=$(date -v -"$((i))"d -v -"$((i % 12))"H "+%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/')

  case $((i % 3)) in
    0) parent="$OUT" ;;
    1) parent="$OUT/Journal" ;;
    2) parent="$OUT/Journal/Ideas" ;;
  esac

  dir="$parent/transcride-$ts-fixture-note-$i"
  mkdir -p "$dir"
  cat > "$dir/transcript.md" <<EOF
---
title: "Fixture Note $i"
created: $iso
duration: $((30 + i % 600)).0
favorite: $([ $((i % 17)) -eq 0 ] && echo true || echo false)
audio_deleted: false
source: fixture
engine: none
---

This is fixture entry number $i, generated for testing the vault UI.

It has a second paragraph so the snippet and detail view have something
to show. The quick brown fox jumps over the lazy dog, take $i.
EOF
done

echo "Created $COUNT entries in $OUT"
