#!/bin/sh
set -eu

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/transcride-editor.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

cp "$package_dir/package.json" "$temporary_dir/package.json"
cp "$package_dir/package-lock.json" "$temporary_dir/package-lock.json"
cp "$package_dir/tsconfig.json" "$temporary_dir/tsconfig.json"
cp -R "$package_dir/src" "$temporary_dir/src"
cp -R "$package_dir/scripts" "$temporary_dir/scripts"

(cd "$temporary_dir" && npm ci --ignore-scripts --no-audit --no-fund)
(cd "$temporary_dir" && TRANSCRIDE_EDITOR_DIST="$temporary_dir/rebuilt" node scripts/build.mjs)
diff -ru "$package_dir/dist" "$temporary_dir/rebuilt"
