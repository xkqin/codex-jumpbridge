#!/bin/bash

set -u

BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.codex-jumpbridge"
WRAPPER="${BIN_DIR}/ssh"
PATH_AGENT="${HOME}/Library/LaunchAgents/com.xkqin.codex-jumpbridge-path.plist"
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

stop_probe_process() {
    local pid="$1"
    local attempt=0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 20 ]; do
            sleep 0.1
            attempt=$((attempt + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
}

desktop_protocol_probe() {
    local login gate payload remote work request output error pid attempt ok
    login='CODEX_REMOTE_PAYLOAD="$1"; export CODEX_REMOTE_PAYLOAD; exec /bin/sh -c "$CODEX_REMOTE_PAYLOAD"'
    gate="printf '%b' '\107\101\124\105\061\062\063\064'"
    payload="${gate}; PATH=\"\${CODEX_INSTALL_DIR:-\$HOME/.local/bin}:\$PATH\"; export PATH; codex app-server proxy"
    remote="sh -c $(posix_quote "$login") sh $(posix_quote "$payload")"
    work="$(mktemp -d "${TMPDIR:-/tmp}/codex-jumpbridge-doctor.XXXXXX")" || return 1
    request="${work}/request"
    output="${work}/output"
    error="${work}/error"
    printf 'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' > "$request"
    "$WRAPPER" "$HOST_ALIAS" "$remote" < "$request" > "$output" 2> "$error" &
    pid=$!
    ok=1
    attempt=0
    while [ "$attempt" -lt 300 ]; do
        if grep -a -q 'GATE1234HTTP/1.1 101 Switching Protocols' "$output" 2>/dev/null; then
            ok=0
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    stop_probe_process "$pid"
    rm -rf "$work"
    return "$ok"
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

if [ -f "$PATH_AGENT" ] && plutil -lint "$PATH_AGENT" >/dev/null 2>&1; then
    report OK 'macOS login PATH helper is installed'
else
    fail 'macOS login PATH helper is missing; rerun install.sh'
fi

gui_path="$(launchctl getenv PATH 2>/dev/null || true)"
case ":${gui_path}:" in
    *":${BIN_DIR}:"*) report OK 'Codex Desktop GUI PATH includes the SSH wrapper' ;;
    *) fail 'Codex Desktop GUI PATH does not include ~/.local/bin; rerun install.sh' ;;
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

native_home_probe="$($WRAPPER "$HOST_ALIAS" 'umask 077; mkdir -p "$HOME/.codex" && test -w "$HOME/.codex" && printf "CODEX_JUMPBRIDGE_NATIVE_CODEX_HOME=READY\n"' 2>/dev/null || true)"
if printf '%s' "$native_home_probe" | grep -q 'CODEX_JUMPBRIDGE_NATIVE_CODEX_HOME=READY'; then
    report OK 'Remote native ~/.codex home is ready (no history lock)'
else
    fail 'Remote native ~/.codex home is unavailable or not writable'
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

if desktop_protocol_probe; then
    report OK 'Codex Desktop startup gate and WebSocket upgrade work'
else
    fail 'Codex Desktop protocol probe failed; update JumpBridge and disconnect stale SSH sessions'
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
    printf 'Status: NOT READY\n'
    exit 1
fi

printf 'Status: READY\n'
printf 'Restart Codex Desktop, add this SSH host, then open /mnt/petrelfs/<user>.\n'
printf 'Codex may display the canonical /mnt/hwfile/<user> path; remote commands still use petrelfs.\n'
