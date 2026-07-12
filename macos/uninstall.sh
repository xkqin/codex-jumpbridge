#!/bin/bash

set -u

BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.codex-jumpbridge"
WRAPPER="${BIN_DIR}/ssh"
BACKUP_DIR="${CONFIG_DIR}/backup"

if [ -x "$WRAPPER" ]; then
    version="$($WRAPPER --codex-jumpbridge-version 2>/dev/null || true)"
    case "$version" in
        codex-jumpbridge*)
            rm -f "$WRAPPER"
            printf '[OK] Removed Codex JumpBridge ssh wrapper\n'
            ;;
        *)
            printf 'Refusing to remove %s because it is not Codex JumpBridge.\n' "$WRAPPER" >&2
            exit 1
            ;;
    esac
fi

backup=''
if [ -d "$BACKUP_DIR" ]; then
    backup="$(ls -1t "$BACKUP_DIR"/ssh.* 2>/dev/null | head -n 1)"
fi
if [ -n "$backup" ]; then
    cp -pP "$backup" "$WRAPPER"
    printf '[OK] Restored previous ssh from %s\n' "$(basename "$backup")"
fi

rm -f \
    "${BIN_DIR}/codex-jumpbridge-setup" \
    "${BIN_DIR}/codex-jumpbridge-doctor" \
    "${BIN_DIR}/codex-jumpbridge-remote-prepare" \
    "${BIN_DIR}/codex-jumpbridge-repair-thread-assignments"

remove_path_block() {
    local profile="$1"
    local temp
    [ -f "$profile" ] || return 0
    temp="$(mktemp "${TMPDIR:-/tmp}/codex-jumpbridge-profile.XXXXXX")"
    awk '
        $0 == "# BEGIN CODEX_JUMPBRIDGE" { skipping = 1; next }
        $0 == "# END CODEX_JUMPBRIDGE" { skipping = 0; next }
        !skipping { print }
    ' "$profile" > "$temp"
    mv "$temp" "$profile"
}

remove_path_block "${HOME}/.zprofile"
remove_path_block "${HOME}/.zshrc"

printf '[OK] SSH config, keys, remote files, and Codex history were not changed.\n'
