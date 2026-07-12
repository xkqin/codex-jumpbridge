#!/bin/bash

# macOS SSH compatibility wrapper for Codex Desktop and PJLab-style gateways.

set -u

VERSION='1.3.1'
REAL_SSH="${CODEX_JUMPBRIDGE_REAL_SSH:-/usr/bin/ssh}"
CONFIG_DIR="${HOME}/.codex-jumpbridge"
HOSTS_FILE="${CONFIG_DIR}/hosts.txt"
PROXIES_FILE="${CONFIG_DIR}/proxies.txt"

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
if [ "$is_streaming" -eq 1 ]; then
    wrapped_command="${start_command}${proxy_exports}export CODEX_HOME=\"\${CODEX_HOME:-\$HOME/.codex}\"; exec /bin/sh -c $(posix_quote "$remote_command")"
else
    wrapped_command="${start_command}${proxy_exports}/bin/sh -c $(posix_quote "$remote_command"); __codex_jumpbridge_rc=\$?; printf '%s%s%d\\n' $(posix_quote "$completion_first") $(posix_quote "$completion_second") \"\$__codex_jumpbridge_rc\""
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

awk -v start="$start_marker" \
    -v prefix="$([ "$is_streaming" -eq 1 ] && printf '' || printf '%s' "$completion_prefix")" \
    -v started="$started_file" '
BEGIN { remote_rc = 0; completed = 0 }
{
    start_pos = index($0, start)
    if (start_pos > 0) {
        before = substr($0, 1, start_pos - 1)
        after = substr($0, start_pos + length(start))
        system("/usr/bin/touch \"" started "\"")
        if (before != "") print before
        if (after != "") print after
        fflush()
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
