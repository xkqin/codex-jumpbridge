#!/bin/bash

# Runs on the remote Linux compute node. It reuses binaries already installed
# by the VS Code or Cursor OpenAI extension; it never downloads a remote CLI.

set -u

LOCAL_BIN="${HOME}/.local/bin"
LOCAL_CODEX="${LOCAL_BIN}/codex"
LOCAL_REAL_CODEX="${LOCAL_BIN}/codex-jumpbridge-real"
LOCAL_CODE_HOST="${LOCAL_BIN}/codex-code-mode-host"
LAUNCHER_MARKER='CODEX_JUMPBRIDGE_HOME_LAUNCHER'

find_editor_codex() {
    find \
        "${HOME}/.vscode-server/extensions" \
        "${HOME}/.cursor-server/extensions" \
        -path '*/bin/linux-x86_64/codex' \
        -type f \
        -perm -u+x \
        2>/dev/null | sort -r
}

migrate_native_history() {
    legacy_master="${HOME}/.codex-jumpbridge/history/master"
    native_home="${HOME}/.codex"
    marker="${native_home}/.jumpbridge-native-history-v1.4.2"

    [ -d "$legacy_master" ] || return 0
    [ -f "$marker" ] && return 0
    umask 077
    mkdir -p "$native_home"

    for tree in sessions archived_sessions; do
        source_tree="${legacy_master}/${tree}"
        target_tree="${native_home}/${tree}"
        [ -d "$source_tree" ] || continue
        mkdir -p "$target_tree"
        while IFS= read -r relative; do
            source_file="${source_tree}/${relative#./}"
            target_file="${target_tree}/${relative#./}"
            [ -e "$target_file" ] && continue
            mkdir -p "$(dirname "$target_file")" || return 1
            cp -p "$source_file" "$target_file" || return 1
        done < <(cd "$source_tree" && find . -type f -print) || return 1
    done

    master_index="${legacy_master}/session_index.jsonl"
    native_index="${native_home}/session_index.jsonl"
    if [ -f "$master_index" ]; then
        touch "$native_index"
        while IFS= read -r record || [ -n "$record" ]; do
            [ -n "$record" ] || continue
            thread_id="$(printf '%s\n' "$record" | sed -n \
                's/.*"\(id\|thread_id\)"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f-]*\)".*/\2/p')"
            if [ -n "$thread_id" ] && grep -Eq \
                '"(id|thread_id)"[[:space:]]*:[[:space:]]*"'"$thread_id"'"' \
                "$native_index"; then
                continue
            fi
            printf '%s\n' "$record" >> "$native_index"
        done < "$master_index"
    fi

    : > "$marker"
    printf 'CODEX_JUMPBRIDGE_NATIVE_HISTORY=MIGRATED\n'
}

codex_version() {
    "$1" --version 2>/dev/null | head -n 1
}

mkdir -p "$LOCAL_BIN"
migrate_native_history || {
    printf 'CODEX_JUMPBRIDGE_NATIVE_HISTORY=FAILED\n' >&2
    exit 7
}
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
    [ -f "$LOCAL_CODEX" ] && grep -Fq "$LAUNCHER_MARKER" "$LOCAL_CODEX"; then
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
    elif grep -Fq "$LAUNCHER_MARKER" "$LOCAL_CODEX" 2>/dev/null; then
        :
    elif cmp -s "$LOCAL_CODEX" "$selected"; then
        :
    else
        printf 'CODEX_JUMPBRIDGE_REMOTE_CODEX=UNMANAGED\n'
        printf 'Refusing to replace an unmanaged ~/.local/bin/codex file.\n' >&2
        exit 6
    fi
fi

ln -sfn "$selected" "$LOCAL_REAL_CODEX"
launcher_temp="$(mktemp "${LOCAL_BIN}/codex-jumpbridge-launcher.XXXXXX")"
cat > "$launcher_temp" <<'LAUNCHER'
#!/bin/sh
# CODEX_JUMPBRIDGE_HOME_LAUNCHER
REAL_CODEX="${HOME}/.local/bin/codex-jumpbridge-real"
if [ "${1:-}" = 'app-server' ]; then
    cd "$HOME" || exit 1
    PWD="$HOME"
    export PWD
fi
exec "$REAL_CODEX" "$@"
LAUNCHER
chmod 755 "$launcher_temp"
rm -f "$LOCAL_CODEX"
mv "$launcher_temp" "$LOCAL_CODEX"

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
printf 'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY\n'
printf 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY\n'
