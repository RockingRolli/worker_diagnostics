#!/usr/bin/env bash
# Copies the files that ship into the game's staging area, for the in-game uploader (Mod Hub > My Mods).
# Usage: ./stage.sh <TF3 local folder>
#   e.g. ./stage.sh ~/.local/share/Steam/userdata/<steam id>/3493540/local
# After the first upload the game writes _metadata/mod.io_fileid.txt into the staging copy; it is copied back here,
# so later uploads update the same mod.io entry. Commit it.
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
	echo "usage: $0 <TF3 local folder, the one containing staging_area>" >&2
	exit 1
fi

repo="$(cd "$(dirname "$0")" && pwd)"
modid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["modId"])' "$repo/mod.json")"
stage="$1/staging_area/$modid"

fileid="_metadata/mod.io_fileid.txt"
if [[ -f "$stage/$fileid" && ! -f "$repo/$fileid" ]]; then
	cp "$stage/$fileid" "$repo/$fileid"
	echo "copied $fileid back into the repository, commit it"
fi

lua "$repo/tests/test_core.lua" > /dev/null || { echo "tests failed, nothing staged" >&2; exit 1; }

mkdir -p "$stage"
rsync -a --delete "$repo/mod.json" "$repo/strings.json" "$repo/_metadata" "$repo/content" "$stage/"
echo "staged $modid revision $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$repo/mod.json") to $stage"
