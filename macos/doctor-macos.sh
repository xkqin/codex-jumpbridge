#!/bin/bash

set -u

BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.codex-jumpbridge"
WRAPPER="${BIN_DIR}/ssh"
HOST_ALIAS=''
FAILED=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            HOST_ALIAS="${2:-}"
            shift 2
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

report() {
    printf '[%s] %s\n' "$1" "$2"
}

fail() {
    FAILED=1
    report FAIL "$1"
}

posix_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

read_proxy() {
    local target="$1"
    local line configured value
    [ -f "${CONFIG_DIR}/proxies.txt" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == *$'\t'* ]]; then
            configured="${line%%$'\t'*}"
            value="${line#*$'\t'}"
            if [ "$configured" = "$target" ]; then
                printf '%s' "$value"
                return 0
            fi
        fi
    done < "${CONFIG_DIR}/proxies.txt"
    return 1
}

if [ ! -x "$WRAPPER" ]; then
    printf 'JumpBridge is not installed: %s\n' "$WRAPPER" >&2
    exit 1
fi

version="$($WRAPPER --codex-jumpbridge-version 2>/dev/null || true)"
case "$version" in
    codex-jumpbridge*) report OK "$version" ;;
    *) fail 'Installed ssh is not Codex JumpBridge' ;;
esac

if [ -z "$HOST_ALIAS" ] && [ -f "${CONFIG_DIR}/hosts.txt" ]; then
    HOST_ALIAS="$(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "${CONFIG_DIR}/hosts.txt" | head -n 1)"
fi
if [ -z "$HOST_ALIAS" ]; then
    printf 'No host configured. Pass --host or run install.sh again.\n' >&2
    exit 1
fi
report OK "Checking host: $HOST_ALIAS"

resolved="$($WRAPPER -G "$HOST_ALIAS" 2>/dev/null || true)"
if printf '%s\n' "$resolved" | grep -q '^hostname[[:space:]]'; then
    report OK 'SSH config resolves'
else
    fail 'ssh -G failed; check ~/.ssh/config'
fi

probe="$($WRAPPER "$HOST_ALIAS" 'printf CODEX_JUMPBRIDGE_REMOTE_OK' 2>/dev/null || true)"
if printf '%s' "$probe" | grep -q 'CODEX_JUMPBRIDGE_REMOTE_OK'; then
    report OK 'Gateway shell bridge works'
else
    fail 'Remote shell probe failed; verify the host alias and key permissions'
fi

home_probe="$($WRAPPER "$HOST_ALIAS" 'printf "__CODEX_JUMPBRIDGE_CWD__=%s__CODEX_JUMPBRIDGE_HOME__=%s__CODEX_JUMPBRIDGE_END__" "$PWD" "$HOME"' 2>/dev/null || true)"
remote_cwd="${home_probe#*__CODEX_JUMPBRIDGE_CWD__=}"
remote_cwd="${remote_cwd%%__CODEX_JUMPBRIDGE_HOME__=*}"
remote_home="${home_probe#*__CODEX_JUMPBRIDGE_HOME__=}"
remote_home="${remote_home%%__CODEX_JUMPBRIDGE_END__*}"
case "$remote_home" in
    /mnt/petrelfs/*)
        if [ "$remote_cwd" = "$remote_home" ]; then
            report OK "Remote commands start in $remote_home"
        else
            fail 'Remote commands do not start in the remote home; update JumpBridge'
        fi
        ;;
    *) fail 'Remote commands do not start in /mnt/petrelfs home; update JumpBridge' ;;
esac

prepare_path="${BIN_DIR}/codex-jumpbridge-remote-prepare"
if [ -f "$prepare_path" ]; then
    encoded="$(base64 < "$prepare_path" | tr -d '\r\n')"
    prepare_output="$($WRAPPER "$HOST_ALIAS" "printf %s $encoded | base64 -d | bash" 2>/dev/null || true)"
    if printf '%s' "$prepare_output" | grep -q 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY' &&
        printf '%s' "$prepare_output" | grep -q 'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY'; then
        report OK 'Remote home launcher and codex-code-mode-host are ready'
    else
        fail 'Remote code host is missing; open VS Code/Cursor on the cluster and rerun install.sh'
    fi
else
    fail 'Remote preparation helper is missing; rerun install.sh'
fi

codex_probe="$($WRAPPER "$HOST_ALIAS" 'PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"; export PATH; command -v codex >/dev/null && codex --version' 2>/dev/null || true)"
if printf '%s' "$codex_probe" | grep -q 'codex'; then
    report OK "Remote $(printf '%s\n' "$codex_probe" | tail -n 1)"
else
    fail 'Remote Codex was not found in VS Code/Cursor or ~/.local/bin'
fi

proxy_url="$(read_proxy "$HOST_ALIAS" 2>/dev/null || true)"
proxy_prefix=''
if [ -n "$proxy_url" ]; then
    quoted="$(posix_quote "$proxy_url")"
    proxy_prefix="env HTTP_PROXY=$quoted HTTPS_PROXY=$quoted http_proxy=$quoted https_proxy=$quoted "
    report OK "Cluster OpenAI egress proxy configured for $HOST_ALIAS"
fi

network_probe="$($WRAPPER "$HOST_ALIAS" "${proxy_prefix}curl -sS --connect-timeout 8 --max-time 15 -o /dev/null -w 'CODEX_JUMPBRIDGE_HTTP=%{http_code}' https://api.openai.com/v1/models" 2>/dev/null || true)"
case "$network_probe" in
    *CODEX_JUMPBRIDGE_HTTP=200*) report OK 'OpenAI route works (HTTP 200)' ;;
    *CODEX_JUMPBRIDGE_HTTP=401*) report OK 'OpenAI route works (HTTP 401)' ;;
    *) fail 'OpenAI route failed; run codex-jumpbridge-setup and test the cluster egress proxy' ;;
esac

printf '\n'
if [ "$FAILED" -ne 0 ]; then
    printf 'Status: NOT READY\n'
    exit 1
fi

printf 'Status: READY\n'
printf 'Restart Codex Desktop, add this SSH host, then open /mnt/petrelfs/<user>.\n'
printf 'Codex may display the canonical /mnt/hwfile/<user> path; remote commands still use petrelfs.\n'
