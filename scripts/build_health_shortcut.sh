#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version="3.1"
source_file="$repo_dir/shortcuts/Z1 Import Health.xml"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/z1-health-shortcut.XXXXXX")
unsigned_file="$build_dir/Z1 Import Health.wflow"
signed_file="$repo_dir/shortcuts/Z1 Import Health v$version.shortcut"

trap 'rm -r "$build_dir"' EXIT HUP INT TERM
plutil -lint "$source_file"
plutil -convert binary1 -o "$unsigned_file" "$source_file"
shortcuts sign --mode anyone --input "$unsigned_file" --output "$signed_file"
echo "$signed_file"
