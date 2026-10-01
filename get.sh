#!/bin/bash
# Public Mac download entry. macOS supplies curl, plutil, tar, and shasum.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'This entrypoint requires macOS.' >&2; exit 1; }
umask 077
stage=$(mktemp -d "${TMPDIR:-/tmp}/hotpl8-bootstrap.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
fetch() { curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 "$1" -o "$2"; }
fetch 'https://api.github.com/repos/Mmore35/hotpl8/commits/main' "$stage/revision.json"
revision=$(/usr/bin/plutil -extract sha raw "$stage/revision.json")
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid source revision.' >&2; exit 1; }
for file in start.sh get.ps1; do
    fetch "https://raw.githubusercontent.com/Mmore35/hotpl8/$revision/$file" "$stage/$file"
done
bash "$stage/start.sh" --download "$@"
