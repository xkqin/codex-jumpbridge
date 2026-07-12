#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_PREPARE_SOURCE="${SCRIPT_DIR}/../shared/remote-prepare.sh"
CONFIG_DIR="${HOME}/.codex-jumpbridge"
BIN_DIR="${HOME}/.local/bin"
BACKUP_DIR="${CONFIG_DIR}/backup"
SSH_CONFIG="${HOME}/.ssh/config"
PROXY_URL=''
SKIP_DOCTOR=0
SKIP_SETUP=0
HOSTS=()

step() {
    printf '[%s] %s\n' "$1" "$2"
}

usage() {
    cat <<'EOF'
Usage: ./install.sh [--host SSH_ALIAS] [--proxy URL] [--skip-doctor] [--skip-setup]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            HOSTS+=("${2:-}")
            shift 2
            ;;
        --proxy)
            PROXY_URL="${2:-}"
            shift 2
            ;;
        --skip-doctor)
            SKIP_DOCTOR=1
            shift
            ;;
        --skip-setup)
            SKIP_SETUP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(uname -s)" != 'Darwin' ]; then
    printf 'install.sh currently supports macOS. On Windows, run install.ps1.\n' >&2
    exit 1
fi

if [ ! -f "$SSH_CONFIG" ]; then
    printf 'SSH config not found: %s\n' "$SSH_CONFIG" >&2
    exit 1
fi
step OK "Found SSH config: $SSH_CONFIG"

ssh_aliases() {
    awk '
        /^[[:space:]]*Host[[:space:]]+/ {
            for (i = 2; i <= NF; i++) {
                if ($i !~ /[*?!]/) print $i
            }
        }
    ' "$SSH_CONFIG" | awk '!seen[$0]++'
}

is_t_cluster_alias() {
    local alias="$1"
    local expanded remote_user
    if printf '%s' "$alias" | grep -Eqi '^jump[-_]t[0-9]+([-_]|$)'; then
        return 0
    fi
    expanded="$(/usr/bin/ssh -G "$alias" 2>/dev/null || true)"
    remote_user="$(printf '%s\n' "$expanded" | awk '$1 == "user" { print $2; exit }')"
    printf '%s' "$remote_user" | grep -Eq '^[^@]+@[^@]+@[^@]+$'
}

has_private_key() {
    local alias="$1"
    local path
    while IFS= read -r path; do
        path="${path#\"}"
        path="${path%\"}"
        path="${path//%d/${HOME}}"
        case "$path" in
            \~/*) path="${HOME}/${path:2}" ;;
        esac
        [ -f "$path" ] && return 0
    done < <(/usr/bin/ssh -G "$alias" 2>/dev/null | awk '$1 == "identityfile" { print $2 }')
    return 1
}

while IFS= read -r alias; do
    if is_t_cluster_alias "$alias"; then
        found=0
        for configured_host in "${HOSTS[@]}"; do
            if [ "$configured_host" = "$alias" ]; then
                found=1
                break
            fi
        done
        [ "$found" -eq 1 ] || HOSTS+=("$alias")
    fi
done < <(ssh_aliases)

if [ "${#HOSTS[@]}" -eq 0 ]; then
    printf 'No jump-host alias was detected. Re-run with --host your-ssh-host.\n' >&2
    exit 1
fi
step OK "Hosts: ${HOSTS[*]}"
for alias in "${HOSTS[@]}"; do
    if ! has_private_key "$alias"; then
        printf 'No local SSH private key referenced by %s was found.\n' "$alias" >&2
        printf '%s\n' 'Each user needs their own private key and must register the matching public key.' >&2
        printf '%s\n' "Never copy a colleague's private key or commit it to GitHub." >&2
        exit 1
    fi
done
step OK 'Local SSH private key is available for every T-cluster Host'

for required in \
    "$SCRIPT_DIR/codex-jumpbridge.sh" \
    "$SCRIPT_DIR/setup-macos.sh" \
    "$SCRIPT_DIR/doctor-macos.sh" \
    "$REMOTE_PREPARE_SOURCE" \
    "$SCRIPT_DIR/repair-thread-assignments.sh"; do
    if [ ! -f "$required" ]; then
        printf 'Required file missing: %s\n' "$required" >&2
        exit 1
    fi
done

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

if [ -n "$PROXY_URL" ] && ! valid_proxy_url "$PROXY_URL"; then
    printf 'Invalid proxy URL. Use http(s) without embedded credentials.\n' >&2
    exit 1
fi

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$BACKUP_DIR"
chmod 700 "$CONFIG_DIR" "$BACKUP_DIR"

TARGET_SSH="${BIN_DIR}/ssh"
if [ -e "$TARGET_SSH" ] || [ -L "$TARGET_SSH" ]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -pP "$TARGET_SSH" "${BACKUP_DIR}/ssh.${stamp}"
fi

cp "$SCRIPT_DIR/codex-jumpbridge.sh" "$TARGET_SSH"
cp "$SCRIPT_DIR/setup-macos.sh" "${BIN_DIR}/codex-jumpbridge-setup"
cp "$SCRIPT_DIR/doctor-macos.sh" "${BIN_DIR}/codex-jumpbridge-doctor"
cp "$REMOTE_PREPARE_SOURCE" "${BIN_DIR}/codex-jumpbridge-remote-prepare"
cp "$SCRIPT_DIR/repair-thread-assignments.sh" \
    "${BIN_DIR}/codex-jumpbridge-repair-thread-assignments"
rm -f \
    "${BIN_DIR}/codex-jumpbridge-repair-project-path" \
    "${BIN_DIR}/codex-jumpbridge-repair-sidebar"
chmod 755 \
    "$TARGET_SSH" \
    "${BIN_DIR}/codex-jumpbridge-setup" \
    "${BIN_DIR}/codex-jumpbridge-doctor" \
    "${BIN_DIR}/codex-jumpbridge-remote-prepare" \
    "${BIN_DIR}/codex-jumpbridge-repair-thread-assignments"

hosts_file="${CONFIG_DIR}/hosts.txt"
hosts_temp="$(mktemp "${CONFIG_DIR}/hosts.XXXXXX")"
if [ -f "$hosts_file" ]; then
    awk 'NF && $0 !~ /^[[:space:]]*#/ && !seen[$0]++ { print }' \
        "$hosts_file" > "$hosts_temp"
fi
for alias in "${HOSTS[@]}"; do
    if ! grep -Fqx "$alias" "$hosts_temp"; then
        printf '%s\n' "$alias" >> "$hosts_temp"
    fi
done
chmod 600 "$hosts_temp"
mv "$hosts_temp" "$hosts_file"

if [ -n "$PROXY_URL" ]; then
    proxies_file="${CONFIG_DIR}/proxies.txt"
    proxies_temp="$(mktemp "${CONFIG_DIR}/proxies.XXXXXX")"
    if [ -f "$proxies_file" ]; then
        cp "$proxies_file" "$proxies_temp"
    fi
    for alias in "${HOSTS[@]}"; do
        next_temp="$(mktemp "${CONFIG_DIR}/proxies.XXXXXX")"
        awk -F '\t' -v target="$alias" '$1 != target { print }' "$proxies_temp" > "$next_temp"
        printf '%s\t%s\n' "$alias" "$PROXY_URL" >> "$next_temp"
        mv "$next_temp" "$proxies_temp"
    done
    chmod 600 "$proxies_temp"
    mv "$proxies_temp" "$proxies_file"
    step OK 'Saved cluster OpenAI egress proxy settings'
fi

add_path_block() {
    local profile="$1"
    local temp
    local begin='# BEGIN CODEX_JUMPBRIDGE'
    local end='# END CODEX_JUMPBRIDGE'
    temp="$(mktemp "${TMPDIR:-/tmp}/codex-jumpbridge-profile.XXXXXX")"
    if [ -f "$profile" ]; then
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { skipping = 1; next }
            $0 == end { skipping = 0; next }
            !skipping { print }
        ' "$profile" > "$temp"
    fi
    {
        cat "$temp"
        printf '\n%s\n' "$begin"
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
        printf '%s\n' "$end"
    } > "$profile"
    rm -f "$temp"
}

add_path_block "${HOME}/.zprofile"
add_path_block "${HOME}/.zshrc"
case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) export PATH="${BIN_DIR}:${PATH}" ;;
esac
if command -v launchctl >/dev/null 2>&1; then
    launchctl setenv PATH "$PATH" >/dev/null 2>&1 || true
fi

if [ -z "$PROXY_URL" ] && [ "$SKIP_SETUP" -eq 0 ]; then
    "${BIN_DIR}/codex-jumpbridge-setup" --host "${HOSTS[0]}"
fi

remote_encoded="$(base64 < "$REMOTE_PREPARE_SOURCE" | tr -d '\r\n')"
for alias in "${HOSTS[@]}"; do
    remote_output="$($TARGET_SSH "$alias" "printf %s $remote_encoded | base64 -d | bash" 2>&1)"
    remote_rc=$?
    if ! printf '%s' "$remote_output" | grep -q 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY' ||
        ! printf '%s' "$remote_output" | grep -q 'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY'; then
        if printf '%s' "$remote_output" | grep -q 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=MISSING'; then
            cat >&2 <<EOF

Remote VS Code/Cursor OpenAI extension is missing on ${alias}.
1. Connect to this host in VS Code or Cursor.
2. In the SSH window, install or update extension openai.chatgpt.
3. Login is not required for the runtime files to be installed.
4. Run ./install.sh again.
EOF
        elif printf '%s' "$remote_output" | grep -q 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=NO_MATCHING_VERSION'; then
            printf '\nUpdate openai.chatgpt in the VS Code/Cursor SSH window, then run ./install.sh again.\n' >&2
        else
            printf 'Remote Codex preparation failed on %s.\n' "$alias" >&2
        fi
        exit 1
    fi
    if [ "$remote_rc" -ne 0 ]; then
        step WARN "Gateway returned ${remote_rc} after reporting READY on ${alias}; continuing"
    fi
    step OK "Remote home launcher and codex-code-mode-host are ready on $alias"
done

if [ "$SKIP_DOCTOR" -eq 0 ]; then
    for alias in "${HOSTS[@]}"; do
        "${BIN_DIR}/codex-jumpbridge-doctor" --host "$alias"
    done
fi

step OK "Installed: $TARGET_SSH"
printf '\nCodex JumpBridge is installed. Restart Codex Desktop before adding the remote project.\n'
