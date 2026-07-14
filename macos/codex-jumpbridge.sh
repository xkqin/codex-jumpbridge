#!/bin/bash

# macOS SSH compatibility wrapper for Codex Desktop and PJLab-style gateways.

set -u

VERSION='1.4.0'
REAL_SSH="${CODEX_JUMPBRIDGE_REAL_SSH:-/usr/bin/ssh}"
CONFIG_DIR="${HOME}/.codex-jumpbridge"
HOSTS_FILE="${CONFIG_DIR}/hosts.txt"
PROXIES_FILE="${CONFIG_DIR}/proxies.txt"
REMOTE_MCP_HOSTS_FILE="${CONFIG_DIR}/remote-mcp-hosts.txt"

if [ "$#" -eq 1 ] && {
    [ "$1" = '--codex-jumpbridge-version' ] ||
    [ "$1" = '--codex-t-wrapper-version' ];
}; then
    printf 'codex-jumpbridge %s\n' "$VERSION"
    exit 0
fi

if [ ! -x "$REAL_SSH" ]; then
    printf 'Codex JumpBridge: real SSH client not found: %s\n' "$REAL_SSH" >&2
    exit 255
fi

option_takes_value() {
    case "$1" in
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_configured_host() {
    local target="$1"
    local file

    if [ -n "${CODEX_JUMPBRIDGE_HOSTS:-}" ] &&
        printf '%s' "$CODEX_JUMPBRIDGE_HOSTS" |
            tr ',;' '\n\n' |
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
            grep -Fqx -- "$target"; then
        return 0
    fi

    for file in \
        "$HOSTS_FILE" \
        "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/codex-jumpbridge-hosts.txt"; do
        if [ -f "$file" ] && grep -Fqx -- "$target" "$file"; then
            return 0
        fi
    done

    return 1
}

load_proxy_for_host() {
    local target="$1"
    local line configured_host value

    if [ -n "${CODEX_JUMPBRIDGE_PROXY:-}" ]; then
        printf '%s' "$CODEX_JUMPBRIDGE_PROXY"
        return 0
    fi

    [ -f "$PROXIES_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac

        if [[ "$line" == *$'\t'* ]]; then
            configured_host="${line%%$'\t'*}"
            value="${line#*$'\t'}"
        elif [[ "$line" == *=* ]]; then
            configured_host="${line%%=*}"
            value="${line#*=}"
        else
            continue
        fi

        if [ "$configured_host" = "$target" ]; then
            printf '%s' "$value"
            return 0
        fi
    done < "$PROXIES_FILE"

    return 1
}

valid_proxy_url() {
    local value="$1"
    local authority

    case "$value" in
        http://*|https://*) ;;
        *) return 1 ;;
    esac

    if printf '%s' "$value" | LC_ALL=C grep -q '[[:space:]]'; then
        return 1
    fi

    authority="${value#*://}"
    authority="${authority%%/*}"
    case "$authority" in
        ''|*@*) return 1 ;;
    esac

    return 0
}

remote_mcp_enabled() {
    local target="$1"
    [ -f "$REMOTE_MCP_HOSTS_FILE" ] &&
        grep -Fqx -- "$target" "$REMOTE_MCP_HOSTS_FILE"
}

posix_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

make_token() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr -d '-'
    else
        printf '%s%s%s' "$$" "$RANDOM" "$(date +%s)"
    fi
}

make_host_token() {
    local target
    target="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local hash=2166136261
    local i code
    for ((i = 0; i < ${#target}; i++)); do
        printf -v code '%d' "'${target:i:1}"
        hash=$(( ((hash ^ code) * 16777619) & 0xffffffff ))
    done
    printf '%08x' "$hash"
}

host_priority_delay() {
    local target="$1"
    local index=0
    local line
    if [ -f "$HOSTS_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line#${line%%[![:space:]]*}}"
            line="${line%${line##*[![:space:]]}}"
            case "$line" in
                ''|'#'*) continue ;;
            esac
            if [ "$line" = "$target" ]; then
                if [ "$index" -gt 3 ]; then
                    index=3
                fi
                printf '%s' "$((index * 2))"
                return 0
            fi
            index=$((index + 1))
        done < "$HOSTS_FILE"
    fi
    printf '0'
}

host_scoped_proxy_command() {
    local host_token="$1"
    local enable_remote_mcp="$2"
    local command secure_run
    secure_run='python3 -c "import os,stat,sys; p=sys.argv[1]; os.makedirs(p,mode=0o700,exist_ok=True); f=os.open(p,os.O_RDONLY|os.O_DIRECTORY|getattr(os,\"O_NOFOLLOW\",0)); os.fchmod(f,0o700); s=os.fstat(f); os.close(f); sys.exit(0 if stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and (stat.S_IMODE(s.st_mode)&0o077)==0 else 1)"'
    command='__codex_jb_run="${CODEX_JUMPBRIDGE_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/codex-jumpbridge-$(id -u)}"; __codex_jb_sock="$__codex_jb_run/as-__TOKEN__.sock"; __codex_jb_log="$__codex_jb_run/as-__TOKEN__.log"; __codex_jb_pid="$__codex_jb_run/as-__TOKEN__.pid"; __codex_jb_lock="$__codex_jb_sock.lock"; __codex_jb_enable_mcp=__MCP__; umask 077; if ! __SECURE_RUN__ "$__codex_jb_run"; then echo "Codex JumpBridge: unsafe remote runtime directory" >&2; exit 84; fi; if [ "${#__codex_jb_sock}" -gt 100 ]; then echo "Codex JumpBridge: remote socket path is too long" >&2; exit 85; fi; __codex_jb_probe='"'"'python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(1); s.connect(sys.argv[1]); s.close()"'"'"'; if ! eval "$__codex_jb_probe \"$__codex_jb_sock\"" >/dev/null 2>&1; then __codex_jb_wait=0; until eval "$__codex_jb_probe \"$__codex_jb_sock\"" >/dev/null 2>&1; do if mkdir "$__codex_jb_lock" 2>/dev/null; then if ! eval "$__codex_jb_probe \"$__codex_jb_sock\"" >/dev/null 2>&1; then rm -f "$__codex_jb_sock"; set --; if [ "$__codex_jb_enable_mcp" != "1" ] && [ "${CODEX_JUMPBRIDGE_ENABLE_REMOTE_MCP:-0}" != "1" ] && [ -f "${CODEX_HOME:-$HOME/.codex}/config.toml" ]; then for __codex_jb_mcp in $(sed -n '"'"'s/^[[:space:]]*\[mcp_servers\.\([A-Za-z0-9_-]*\)\][[:space:]]*$/\1/p'"'"' "${CODEX_HOME:-$HOME/.codex}/config.toml"); do set -- "$@" -c "mcp_servers.$__codex_jb_mcp.enabled=false"; done; fi; nohup codex "$@" app-server --listen "unix://$__codex_jb_sock" >"$__codex_jb_log" 2>&1 </dev/null & __codex_jb_server_pid=$!; printf '"'"'%s\n'"'"' "$__codex_jb_server_pid" >"$__codex_jb_pid"; __codex_jb_owner_wait=0; until eval "$__codex_jb_probe \"$__codex_jb_sock\"" >/dev/null 2>&1; do __codex_jb_owner_wait=$((__codex_jb_owner_wait + 1)); if [ "$__codex_jb_owner_wait" -ge 150 ]; then rmdir "$__codex_jb_lock" 2>/dev/null || true; echo "Codex JumpBridge: remote app-server did not become ready" >&2; exit 86; fi; sleep 0.1; done; fi; rmdir "$__codex_jb_lock" 2>/dev/null || true; else sleep 0.1; fi; __codex_jb_wait=$((__codex_jb_wait + 1)); if [ "$__codex_jb_wait" -ge 200 ]; then echo "Codex JumpBridge: remote app-server did not become ready" >&2; exit 86; fi; done; fi; exec codex app-server proxy --sock "$__codex_jb_sock"'
    command="${command//__TOKEN__/$host_token}"
    command="${command//__MCP__/$enable_remote_mcp}"
    printf '%s%s%s' \
        "${command%%__SECURE_RUN__*}" \
        "$secure_run" \
        "${command#*__SECURE_RUN__}"
}

args=("$@")
host_index=-1
after_double_dash=0
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    if [ "$after_double_dash" -eq 1 ]; then
        host_index="$i"
        break
    fi
    if [ "$arg" = '--' ]; then
        after_double_dash=1
        i=$((i + 1))
        continue
    fi
    case "$arg" in
        -*)
            if option_takes_value "$arg"; then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
            ;;
        *)
            host_index="$i"
            break
            ;;
    esac
done

if [ "$host_index" -lt 0 ]; then
    exec "$REAL_SSH" "$@"
fi

host_alias="${args[$host_index]}"
command_index=$((host_index + 1))
if ! is_configured_host "$host_alias" ||
    [ "$command_index" -ge "${#args[@]}" ]; then
    exec "$REAL_SSH" "$@"
fi

if [ "${#args[@]}" -eq $((host_index + 2)) ] &&
    [ "${args[$command_index]}" = 'sh' ]; then
    exec "$REAL_SSH" "$@"
fi

remote_command="${args[*]:$command_index}"
ssh_args=("${args[@]:0:$command_index}" 'sh')

is_streaming=0
case "$remote_command" in
    *'app-server proxy'*) is_streaming=1 ;;
esac

if [ "$is_streaming" -eq 0 ] &&
    [[ "$remote_command" == *'CODEX_SSH_SKIP_APP_SERVER_BOOT'* ]] &&
    [[ "$remote_command" == *'app-server --listen unix://'* ]]; then
    remote_command="CODEX_SSH_SKIP_APP_SERVER_BOOT=true ${remote_command}"
fi

history_busy_marker=''
if [ "$is_streaming" -eq 1 ]; then
    host_token="$(make_host_token "$host_alias")"
    enable_remote_mcp=0
    if remote_mcp_enabled "$host_alias"; then
        enable_remote_mcp=1
    fi
    proxy_command="$(host_scoped_proxy_command "$host_token" "$enable_remote_mcp")"
    proxy_placeholder='codex app-server proxy'
    remote_prefix="${remote_command%%"$proxy_placeholder"*}"
    remote_suffix="${remote_command#*"$proxy_placeholder"}"
    remote_command="${remote_prefix}${proxy_command}${remote_suffix}"
    history_helper='${HOME}/.local/bin/codex-jumpbridge-history-sync'
    quoted_history_command="$(posix_quote "$remote_command")"
    priority_delay="$(host_priority_delay "$host_alias")"
    delay_command=''
    if [ "$priority_delay" -gt 0 ]; then
        delay_command="if [ \"\${CODEX_JUMPBRIDGE_DISABLE_PRIORITY_DELAY:-0}\" != \"1\" ]; then sleep ${priority_delay}; fi; "
    fi
    remote_command="if [ -x \"${history_helper}\" ] && [ \"\${CODEX_JUMPBRIDGE_DISABLE_HISTORY_SYNC:-0}\" != \"1\" ] && \"${history_helper}\" preflight >/dev/null 2>&1; then ${delay_command}CODEX_JUMPBRIDGE_EXPECT_APP_SERVER=1 CODEX_JUMPBRIDGE_BUSY_MARKER=$(posix_quote "$history_busy_marker") \"${history_helper}\" run ${host_token} -- /bin/sh -c ${quoted_history_command}; __codex_jb_history_rc=\$?; exit \"\$__codex_jb_history_rc\"; else exec /bin/sh -c ${quoted_history_command}; fi"
fi

launches_app_server=0
case "$remote_command" in
    *'app-server'*) launches_app_server=1 ;;
esac

proxy_exports=''
if [ "$launches_app_server" -eq 1 ]; then
    proxy_url="$(load_proxy_for_host "$host_alias" 2>/dev/null || true)"
    if [ -n "$proxy_url" ] && valid_proxy_url "$proxy_url"; then
        quoted_proxy="$(posix_quote "$proxy_url")"
        proxy_exports="export HTTP_PROXY=${quoted_proxy} HTTPS_PROXY=${quoted_proxy} http_proxy=${quoted_proxy} https_proxy=${quoted_proxy}; "
    fi
fi

token="$(make_token)"
start_marker="__CODEX_JUMPBRIDGE_START_${token}"
completion_prefix="__CODEX_JUMPBRIDGE_DONE_${token}:"
start_split=$((${#start_marker} / 2))
completion_split=$((${#completion_prefix} / 2))
start_first="${start_marker:0:$start_split}"
start_second="${start_marker:$start_split}"
completion_first="${completion_prefix:0:$completion_split}"
completion_second="${completion_prefix:$completion_split}"

start_command="printf '%s%s\\n' $(posix_quote "$start_first") $(posix_quote "$start_second"); "
home_command='cd "$HOME" || exit 1; '
if [ "$is_streaming" -eq 1 ]; then
    wrapped_command="${start_command}${home_command}${proxy_exports}export CODEX_HOME=\"\${CODEX_HOME:-\$HOME/.codex}\"; exec /bin/sh -c $(posix_quote "$remote_command")"
else
    wrapped_command="${start_command}${home_command}${proxy_exports}/bin/sh -c $(posix_quote "$remote_command"); __codex_jumpbridge_rc=\$?; printf '%s%s%d\\n' $(posix_quote "$completion_first") $(posix_quote "$completion_second") \"\$__codex_jumpbridge_rc\""
fi
bootstrap="exec /bin/sh -c $(posix_quote "$wrapped_command")"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-jumpbridge.XXXXXX")" || exit 255
input_fifo="${temp_dir}/stdin"
output_fifo="${temp_dir}/stdout"
started_file="${temp_dir}/started"
mkfifo "$input_fifo" "$output_fifo" || {
    rm -rf "$temp_dir"
    exit 255
}

ssh_pid=''
writer_pid=''
cleanup() {
    if [ -n "$writer_pid" ]; then
        kill "$writer_pid" 2>/dev/null || true
        wait "$writer_pid" 2>/dev/null || true
        writer_pid=''
    fi
    if [ -n "$ssh_pid" ]; then
        kill "$ssh_pid" 2>/dev/null || true
        wait "$ssh_pid" 2>/dev/null || true
        ssh_pid=''
    fi
    rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

"$REAL_SSH" "${ssh_args[@]}" < "$input_fifo" > "$output_fifo" &
ssh_pid=$!

exec 9<&0
(
    exec 3> "$input_fifo"
    printf '%s\n' "$bootstrap" >&3
    if [ "$is_streaming" -eq 1 ]; then
        cat <&9 >&3
    fi
) &
writer_pid=$!
exec 9<&-

# The proxy carries an HTTP Upgrade followed by binary WebSocket frames. Read
# only the textual gateway preamble, then hand the remaining descriptor to cat
# so no line-oriented tool can rewrite protocol bytes.
if [ "$is_streaming" -eq 1 ]; then
    while IFS= read -r gateway_line; do
        case "$gateway_line" in
            *"$start_marker"*)
                : > "$started_file"
                cat
                break
                ;;
        esac
    done < "$output_fifo"
    filter_rc=$?
else
    # Non-streaming commands are textual and end with a private exit marker.
    awk -v start="$start_marker" \
        -v prefix="$completion_prefix" \
        -v started="$started_file" '
BEGIN { remote_rc = 0; completed = 0; seen_start = 0 }
{
    if (!seen_start) {
        start_pos = index($0, start)
        if (start_pos > 0) {
            after = substr($0, start_pos + length(start))
            seen_start = 1
            system("/usr/bin/touch \"" started "\"")
            if (after != "") print after
            fflush()
        }
        next
    }

    done_pos = prefix == "" ? 0 : index($0, prefix)
    if (done_pos > 0) {
        before = substr($0, 1, done_pos - 1)
        rest = substr($0, done_pos + length(prefix))
        if (before != "") print before
        if (match(rest, /^[0-9]+/)) {
            remote_rc = substr(rest, RSTART, RLENGTH) + 0
        } else {
            remote_rc = 255
        }
        completed = 1
        fflush()
        exit remote_rc
    }

    print
    fflush()
}
END {
    if (!completed) exit 0
}
' "$output_fifo"
    filter_rc=$?
fi

if [ ! -f "$started_file" ]; then
    result=255
elif [ "$is_streaming" -eq 1 ]; then
    wait "$ssh_pid"
    result=$?
    ssh_pid=''
else
    result="$filter_rc"
fi

exit "$result"
