#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
STATE_PATH="${CODEX_HOME_DIR}/.codex-global-state.json"
STATE_BACKUP_PATH="${STATE_PATH}.bak"
LOG_PATH="${CODEX_HOME_DIR}/jumpbridge-thread-assignment-repair.log"
SSH_WRAPPER="${HOME}/.local/bin/ssh"
HOST_ALIAS=''
USER_NAME=''
THREAD_INDEX_PATH=''
AFTER_EXIT=0
CODEX_PID=''
RESTART=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            HOST_ALIAS="${2:-}"
            shift 2
            ;;
        --user)
            USER_NAME="${2:-}"
            shift 2
            ;;
        --thread-index)
            THREAD_INDEX_PATH="${2:-}"
            shift 2
            ;;
        --after-exit)
            AFTER_EXIT=1
            shift
            ;;
        --pid)
            CODEX_PID="${2:-}"
            shift 2
            ;;
        --restart)
            RESTART=1
            shift
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

case "$HOST_ALIAS" in
    ''|*[!A-Za-z0-9._-]*)
        printf '%s\n' 'A safe SSH Host alias is required via --host.' >&2
        exit 2
        ;;
esac
case "$USER_NAME" in
    ''|*[!A-Za-z0-9._-]*)
        printf '%s\n' 'A safe remote user name is required via --user.' >&2
        exit 2
        ;;
esac

LOGICAL_ROOT="/mnt/petrelfs/${USER_NAME}"
CANONICAL_ROOT="/mnt/hwfile/${USER_NAME}"

log_message() {
    mkdir -p "$CODEX_HOME_DIR"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH"
}

find_codex_pid() {
    pgrep -f '/Codex\.app/Contents/MacOS/(Codex|ChatGPT)( |$)' | head -n 1 || true
}

decode_base64() {
    base64 -D 2>/dev/null || base64 -d
}

path_within() {
    local candidate="${1%/}"
    local root="${2%/}"
    [ "$candidate" = "$root" ] || [[ "$candidate" == "$root/"* ]]
}

host_matches() {
    printf '%s\n' "$host_ids" | grep -Fqx "$1"
}

if [ "$AFTER_EXIT" -eq 0 ]; then
    running_pid="$(find_codex_pid)"
    if [ -n "$running_pid" ]; then
        args=(--host "$HOST_ALIAS" --user "$USER_NAME" --after-exit --pid "$running_pid")
        if [ -n "$THREAD_INDEX_PATH" ]; then
            args+=(--thread-index "$THREAD_INDEX_PATH")
        fi
        if [ "$RESTART" -eq 1 ]; then
            args+=(--restart)
        fi
        nohup "$0" "${args[@]}" >/dev/null 2>&1 &
        log_message "SCHEDULED pid=${running_pid} restart=${RESTART}"
        printf '%s\n' '[READY] Thread assignment repair is queued. Fully exit Codex Desktop once.'
        [ "$RESTART" -eq 0 ] || printf '%s\n' '[READY] Codex Desktop will reopen after the repair.'
        exit 0
    fi
fi

if [ "$AFTER_EXIT" -eq 1 ] && [ -n "$CODEX_PID" ]; then
    while kill -0 "$CODEX_PID" 2>/dev/null; do
        sleep 0.5
    done
    sleep 1
fi

work_plist=''
work_json=''
projects_file=''
threads_file=''
cleanup() {
    local rc=$?
    local path
    trap - EXIT
    for path in "$work_plist" "$work_json" "$projects_file" "$threads_file"; do
        [ -z "$path" ] || rm -f "$path"
    done
    if [ "$RESTART" -eq 1 ]; then
        open -a Codex || true
        log_message 'RESTARTED'
    fi
    exit "$rc"
}
trap cleanup EXIT

repair_rc=0
if [ ! -f "$STATE_PATH" ]; then
    printf 'Codex state file was not found: %s\n' "$STATE_PATH" >&2
    repair_rc=1
else
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    safety_copy="${STATE_PATH}.thread-assignment-backup-${timestamp}"
    work_plist="$(mktemp "${TMPDIR:-/tmp}/jumpbridge-state.XXXXXX")"
    work_json="$(mktemp "${TMPDIR:-/tmp}/jumpbridge-state.XXXXXX")"
    projects_file="$(mktemp "${TMPDIR:-/tmp}/jumpbridge-projects.XXXXXX")"
    threads_file="$(mktemp "${TMPDIR:-/tmp}/jumpbridge-threads.XXXXXX")"
    cp -p "$STATE_PATH" "$safety_copy"
    plutil -convert xml1 -o "$work_plist" "$STATE_PATH"

    host_ids=''
    index=0
    while /usr/libexec/PlistBuddy -c "Print :codex-managed-remote-connections:${index}" \
        "$work_plist" >/dev/null 2>&1; do
        alias_value="$(/usr/libexec/PlistBuddy -c \
            "Print :codex-managed-remote-connections:${index}:alias" \
            "$work_plist" 2>/dev/null || true)"
        display_value="$(/usr/libexec/PlistBuddy -c \
            "Print :codex-managed-remote-connections:${index}:displayName" \
            "$work_plist" 2>/dev/null || true)"
        if [ "$alias_value" = "$HOST_ALIAS" ] || [ "$display_value" = "$HOST_ALIAS" ]; then
            host_id="$(/usr/libexec/PlistBuddy -c \
                "Print :codex-managed-remote-connections:${index}:hostId" "$work_plist")"
            host_ids="${host_ids}${host_ids:+
}${host_id}"
        fi
        index=$((index + 1))
    done

    if [ -z "$host_ids" ]; then
        printf 'Codex has no saved SSH connection named %s.\n' "$HOST_ALIAS" >&2
        repair_rc=1
    fi

    root_id=''
    root_host=''
    index=0
    while [ "$repair_rc" -eq 0 ] && /usr/libexec/PlistBuddy -c \
        "Print :remote-projects:${index}" "$work_plist" >/dev/null 2>&1; do
        project_id="$(/usr/libexec/PlistBuddy -c \
            "Print :remote-projects:${index}:id" "$work_plist")"
        project_host="$(/usr/libexec/PlistBuddy -c \
            "Print :remote-projects:${index}:hostId" "$work_plist")"
        project_path="$(/usr/libexec/PlistBuddy -c \
            "Print :remote-projects:${index}:remotePath" "$work_plist")"
        if host_matches "$project_host"; then
            printf '%s\t%s\t%s\n' "$project_id" "$project_host" "$project_path" >> "$projects_file"
            if [ "${project_path%/}" = "$CANONICAL_ROOT" ]; then
                root_id="$project_id"
                root_host="$project_host"
            fi
        fi
        index=$((index + 1))
    done

    if [ "$repair_rc" -eq 0 ] && [ -z "$root_id" ]; then
        printf 'Codex canonical root project was not found: %s\n' "$CANONICAL_ROOT" >&2
        repair_rc=1
    fi

    if [ "$repair_rc" -eq 0 ]; then
        if [ -n "$THREAD_INDEX_PATH" ]; then
            if [ ! -f "$THREAD_INDEX_PATH" ]; then
                printf 'Thread index fixture was not found: %s\n' "$THREAD_INDEX_PATH" >&2
                repair_rc=1
            else
                cp "$THREAD_INDEX_PATH" "$threads_file"
            fi
        else
            python='import base64,json; from pathlib import Path; rows={}; root=Path.home()/".codex"/"sessions";'
            python+='\nif root.is_dir():'
            python+='\n for path in root.rglob("*.jsonl"):'
            python+='\n  try:'
            python+='\n   event=json.loads(path.open("r",encoding="utf-8").readline()); payload=event.get("payload") or {}'
            python+='\n   if event.get("type")=="session_meta" and isinstance(payload.get("id"),str) and isinstance(payload.get("cwd"),str): rows[payload["id"]]=payload["cwd"]'
            python+='\n  except (OSError,UnicodeError,json.JSONDecodeError): pass'
            python+='\nfor key,value in rows.items(): print("__CODEX_JUMPBRIDGE_THREAD__="+key+"|"+base64.b64encode(value.encode()).decode()+"__CODEX_JUMPBRIDGE_THREAD_END__",end="")'
            encoded="$(printf '%b' "$python" | base64 | tr -d '\r\n')"
            remote_output="$($SSH_WRAPPER "$HOST_ALIAS" \
                "printf %s $encoded | base64 -d | python3 -" 2>&1 || true)"
            printf '%s' "$remote_output" | sed 's/__CODEX_JUMPBRIDGE_THREAD_END__/\
/g' | sed -n \
                's/.*__CODEX_JUMPBRIDGE_THREAD__=\([0-9A-Fa-f-]*\)|\([A-Za-z0-9+\/=]*\)$/\1\t\2/p' |
                while IFS="$(printf '\t')" read -r thread_id encoded_cwd; do
                    cwd="$(printf '%s' "$encoded_cwd" | decode_base64)"
                    printf '%s\t%s\n' "$thread_id" "$cwd"
                done > "$threads_file"
        fi
    fi

    if [ "$repair_rc" -eq 0 ] && [ ! -s "$threads_file" ]; then
        printf '%s\n' 'No remote Codex thread metadata was found.' >&2
        repair_rc=1
    fi

    assignments=':thread-project-assignments'
    if [ "$repair_rc" -eq 0 ] && ! /usr/libexec/PlistBuddy -c \
        "Print ${assignments}" "$work_plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Add ${assignments} dict" "$work_plist"
    fi

    assigned_count=0
    if [ "$repair_rc" -eq 0 ]; then
        while IFS="$(printf '\t')" read -r thread_id cwd; do
            [ -n "$thread_id" ] && [ -n "$cwd" ] || continue
            selected_id=''
            selected_host=''
            selected_path=''
            selected_length=0
            while IFS="$(printf '\t')" read -r project_id project_host project_path; do
                mirrored_path=''
                if path_within "$project_path" "$CANONICAL_ROOT"; then
                    mirrored_path="${LOGICAL_ROOT}${project_path#${CANONICAL_ROOT}}"
                elif path_within "$project_path" "$LOGICAL_ROOT"; then
                    mirrored_path="${CANONICAL_ROOT}${project_path#${LOGICAL_ROOT}}"
                fi
                if { path_within "$cwd" "$project_path" ||
                    { [ -n "$mirrored_path" ] && path_within "$cwd" "$mirrored_path"; }; } &&
                    [ "${#project_path}" -gt "$selected_length" ]; then
                    selected_id="$project_id"
                    selected_host="$project_host"
                    selected_path="${project_path%/}"
                    selected_length="${#project_path}"
                fi
            done < "$projects_file"
            if [ -z "$selected_id" ] && {
                path_within "$cwd" "$LOGICAL_ROOT" || path_within "$cwd" "$CANONICAL_ROOT";
            }; then
                selected_id="$root_id"
                selected_host="$root_host"
                selected_path="$CANONICAL_ROOT"
            fi
            [ -n "$selected_id" ] || continue

            if path_within "$selected_path" "$CANONICAL_ROOT"; then
                selected_path="${LOGICAL_ROOT}${selected_path#${CANONICAL_ROOT}}"
            fi

            entry="${assignments}:${thread_id}"
            /usr/libexec/PlistBuddy -c "Delete ${entry}" "$work_plist" >/dev/null 2>&1 || true
            /usr/libexec/PlistBuddy -c "Add ${entry} dict" "$work_plist"
            /usr/libexec/PlistBuddy -c "Add ${entry}:projectKind string remote" "$work_plist"
            /usr/libexec/PlistBuddy -c "Add ${entry}:projectId string ${selected_id}" "$work_plist"
            /usr/libexec/PlistBuddy -c "Add ${entry}:path string ${selected_path}" "$work_plist"
            /usr/libexec/PlistBuddy -c "Add ${entry}:cwd string ${cwd}" "$work_plist"
            /usr/libexec/PlistBuddy -c "Add ${entry}:hostId string ${selected_host}" "$work_plist"
            /usr/libexec/PlistBuddy -c "Add ${entry}:pendingCoreUpdate bool false" "$work_plist"
            assigned_count=$((assigned_count + 1))
        done < "$threads_file"
    fi

    if [ "$repair_rc" -eq 0 ] && [ "$assigned_count" -eq 0 ]; then
        printf '%s\n' 'No remote threads matched the configured projects.' >&2
        repair_rc=1
    fi

    sidebar=':electron-persisted-atom-state:flat-project-sidebar-preferences-v1'
    if [ "$repair_rc" -eq 0 ]; then
        if ! /usr/libexec/PlistBuddy -c "Print ${sidebar}" "$work_plist" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c "Add ${sidebar} dict" "$work_plist"
        fi
        if ! /usr/libexec/PlistBuddy -c "Set ${sidebar}:mode project" "$work_plist" 2>/dev/null; then
            /usr/libexec/PlistBuddy -c "Add ${sidebar}:mode string project" "$work_plist"
        fi
        if ! /usr/libexec/PlistBuddy -c "Set ${sidebar}:initialized true" "$work_plist" 2>/dev/null; then
            /usr/libexec/PlistBuddy -c "Add ${sidebar}:initialized bool true" "$work_plist"
        fi
        plutil -convert json -o "$work_json" "$work_plist"
        chmod 600 "$work_json"
        mv "$work_json" "$STATE_PATH"
        work_json=''
        cp -p "$STATE_PATH" "$STATE_BACKUP_PATH"

        verified_count=0
        while IFS="$(printf '\t')" read -r thread_id _cwd; do
            if plutil -extract "thread-project-assignments.${thread_id}.projectId" \
                raw "$STATE_PATH" >/dev/null 2>&1; then
                verified_count=$((verified_count + 1))
            fi
        done < "$threads_file"
        if [ "$verified_count" -lt "$assigned_count" ]; then
            printf '%s\n' 'Thread assignment repair verification failed.' >&2
            repair_rc=1
        fi
    fi

    if [ "$repair_rc" -eq 0 ]; then
        log_message "DONE host=${HOST_ALIAS} assigned=${assigned_count} root=${CANONICAL_ROOT} backup=${safety_copy}"
        printf '[OK] Assigned %s remote threads without changing their cwd.\n' "$assigned_count"
        printf '[OK] Sidebar paths and execution cwd use %s; the saved project ID is unchanged.\n' \
            "$LOGICAL_ROOT"
        printf '[OK] Backup: %s\n' "$safety_copy"
    else
        log_message 'FAILED thread assignment repair'
    fi
fi

exit "$repair_rc"
