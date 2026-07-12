#!/bin/bash

# Runs on the remote Linux compute node. It reuses binaries already installed
# by the VS Code or Cursor OpenAI extension; it never downloads a remote CLI.

set -u

LOCAL_BIN="${HOME}/.local/bin"
LOCAL_CODEX="${LOCAL_BIN}/codex"
LOCAL_REAL_CODEX="${LOCAL_BIN}/codex-jumpbridge-real"
LOCAL_CODE_HOST="${LOCAL_BIN}/codex-code-mode-host"
LEGACY_LAUNCHER_MARKER='codex-jumpbridge-real'

find_editor_codex() {
    find \
        "${HOME}/.vscode-server/extensions" \
        "${HOME}/.cursor-server/extensions" \
        -path '*/bin/linux-x86_64/codex' \
        -type f \
        -perm -u+x \
        2>/dev/null | sort -r
}

codex_version() {
    "$1" --version 2>/dev/null | head -n 1
}

mkdir -p "$LOCAL_BIN"
HOME_REAL="$(readlink -f "$HOME" 2>/dev/null || printf '%s' "$HOME")"

selected=''
target_version=''
if [ -x "$LOCAL_CODEX" ]; then
    target_version="$(codex_version "$LOCAL_CODEX")"
fi

while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidate_dir="$(dirname "$candidate")"
    candidate_host="${candidate_dir}/codex-code-mode-host"
    [ -x "$candidate_host" ] || continue
    candidate_version="$(codex_version "$candidate")"

    if [ -z "$target_version" ] || [ "$candidate_version" = "$target_version" ]; then
        selected="$candidate"
        target_version="$candidate_version"
        break
    fi
done < <(find_editor_codex)

if [ -z "$selected" ] && [ -x "$LOCAL_REAL_CODEX" ] &&
    [ -f "$LOCAL_CODEX" ] && grep -Fq "$LEGACY_LAUNCHER_MARKER" "$LOCAL_CODEX"; then
    selected="$(readlink -f "$LOCAL_REAL_CODEX" 2>/dev/null || true)"
fi

if [ -z "$selected" ]; then
    printf 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=MISSING\n'
    printf 'CODEX_JUMPBRIDGE_REMOTE_CODEX=MISSING\n'
    printf 'No matching VS Code/Cursor OpenAI extension bundle was found.\n' >&2
    exit 3
fi

if [ -e "$LOCAL_CODEX" ] || [ -L "$LOCAL_CODEX" ]; then
    if [ -L "$LOCAL_CODEX" ]; then
        existing_target="$(readlink -f "$LOCAL_CODEX" 2>/dev/null || true)"
        case "$existing_target" in
            "${HOME}/.vscode-server/extensions/"*|"${HOME}/.cursor-server/extensions/"*|\
            "${HOME_REAL}/.vscode-server/extensions/"*|"${HOME_REAL}/.cursor-server/extensions/"*) ;;
            *)
                printf 'CODEX_JUMPBRIDGE_REMOTE_CODEX=UNMANAGED\n'
                printf 'Refusing to replace an unmanaged ~/.local/bin/codex symlink.\n' >&2
                exit 6
                ;;
        esac
    elif grep -Fq "$LEGACY_LAUNCHER_MARKER" "$LOCAL_CODEX" 2>/dev/null; then
        :
    elif cmp -s "$LOCAL_CODEX" "$selected"; then
        :
    else
        printf 'CODEX_JUMPBRIDGE_REMOTE_CODEX=UNMANAGED\n'
        printf 'Refusing to replace an unmanaged ~/.local/bin/codex file.\n' >&2
        exit 6
    fi
fi

rm -f "$LOCAL_CODEX"
ln -s "$selected" "$LOCAL_CODEX"
rm -f "$LOCAL_REAL_CODEX"

if [ ! -x "$LOCAL_CODE_HOST" ]; then
    if [ -z "$selected" ]; then
        printf 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=NO_MATCHING_VERSION\n'
        printf 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=VERSION_MISMATCH\n'
        printf 'No editor codex-code-mode-host matches %s.\n' "$target_version" >&2
        exit 4
    fi
    ln -sfn "$(dirname "$selected")/codex-code-mode-host" "$LOCAL_CODE_HOST"
fi

if [ ! -x "$LOCAL_CODEX" ] || [ ! -x "$LOCAL_CODE_HOST" ]; then
    printf 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=FAILED\n'
    exit 5
fi

printf 'CODEX_JUMPBRIDGE_REMOTE_CODEX=%s\n' "$(codex_version "$LOCAL_CODEX")"
printf 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY\n'
