#!/bin/bash
# Public Mac entrypoint. Installs a private, pinned runtime only when PowerShell is absent.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'This entrypoint requires macOS.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
entry=start.ps1
if [[ ${1:-} == --download ]]; then entry=get.ps1; shift; fi
if command -v pwsh >/dev/null 2>&1 && [[ $(pwsh -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion -ge [version]"7.5"') == True ]]; then
    exec pwsh -NoProfile -File "$source_dir/$entry" "$@"
fi
version=7.6.6
case $(uname -m) in
    arm64) arch=arm64; digest=6df833d094ebac1c1a74340d7b3437f4aaf5e03ce640484a1c4359f3ce8b3db1 ;;
    x86_64) arch=x64; digest=e325ed9f666894eb39a5ea52800b602da2fb4242bbe9747ceddb39cdc66de805 ;;
    *) echo 'Unsupported Mac architecture.' >&2; exit 1 ;;
esac
# Separate from application installs: existing launchers may still reference this runtime.
runtime_root="$HOME/Library/Application Support/HotPl8-Runtimes"
runtime="$runtime_root/powershell-$version-$arch"
if [[ -L "$runtime_root" || -L "$runtime" ]]; then echo 'Runtime destination must not be a link.' >&2; exit 1; fi
umask 077
mkdir -p "$runtime_root"
if [[ ! -f "$runtime/.hotpl8-runtime" ]]; then
    [[ ! -e "$runtime" ]] || { echo 'Runtime destination is not owned by HotPl8.' >&2; exit 1; }
    stage=$(mktemp -d "$runtime_root/download.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    echo 'Preparing the HotPl8 runtime for your user account.' >&2
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 180 \
        "https://github.com/PowerShell/PowerShell/releases/download/v$version/powershell-$version-osx-$arch.tar.gz" -o "$stage/runtime.tar.gz"
    actual=$(shasum -a 256 "$stage/runtime.tar.gz"); actual=${actual%% *}
    [[ "$actual" == "$digest" ]] || { echo 'Runtime checksum mismatch.' >&2; exit 1; }
    mkdir "$stage/runtime"
    tar -xzf "$stage/runtime.tar.gz" -C "$stage/runtime"
    chmod u+x "$stage/runtime/pwsh"
    printf '%s\n' "$digest" > "$stage/runtime/.hotpl8-runtime"
    # No overwrite: simultaneous installers either reuse the completed runtime or fail safely.
    [[ ! -e "$runtime" ]] || { echo 'Another installation is preparing this runtime; retry setup.' >&2; exit 1; }
    mv "$stage/runtime" "$runtime"
fi
[[ $(cat "$runtime/.hotpl8-runtime") == "$digest" && -x "$runtime/pwsh" ]] || { echo 'Runtime receipt is invalid.' >&2; exit 1; }
if [[ -n ${stage:-} ]]; then rm -rf -- "$stage"; trap - EXIT; fi
exec "$runtime/pwsh" -NoProfile -File "$source_dir/$entry" "$@"
