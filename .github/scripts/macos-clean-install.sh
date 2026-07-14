#!/bin/bash

set -eu

if [ "$(uname -s)" != 'Darwin' ] || [ "${CI:-}" != 'true' ]; then
    printf 'This destructive clean-home fixture only runs on a macOS CI runner.\n' >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/codex-jumpbridge-clean.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

rm -rf "${HOME}/.codex-jumpbridge"
rm -f \
    "${HOME}/.local/bin/ssh" \
    "${HOME}/.local/bin/codex-jumpbridge-setup" \
    "${HOME}/.local/bin/codex-jumpbridge-doctor" \
    "${HOME}/.local/bin/codex-jumpbridge-remote-prepare" \
    "${HOME}/.local/bin/codex-jumpbridge-history-sync" \
    "${HOME}/Library/LaunchAgents/com.xkqin.codex-jumpbridge-path.plist"
mkdir -p "${HOME}/.ssh" "${HOME}/.local/bin" "${HOME}/Library/LaunchAgents"
printf 'fixture\n' > "${HOME}/.ssh/id_fixture"
chmod 600 "${HOME}/.ssh/id_fixture"
cat > "${HOME}/.ssh/config" <<EOF
Host jump-T208-CI
    HostName 127.0.0.1
    User ci
    IdentityFile ${HOME}/.ssh/id_fixture
EOF
chmod 600 "${HOME}/.ssh/config"

cat > "${WORK}/launchctl" <<'EOF'
#!/bin/bash
set -eu
case "${1:-}" in
    bootout|bootstrap) exit 0 ;;
    setenv)
        if [ "${2:-}" = 'PATH' ]; then
            printf '%s' "${3:-}" > "${FAKE_LAUNCHCTL_PATH_FILE}"
        fi
        ;;
    getenv)
        if [ "${2:-}" = 'PATH' ] && [ -f "${FAKE_LAUNCHCTL_PATH_FILE}" ]; then
            cat "${FAKE_LAUNCHCTL_PATH_FILE}"
        fi
        ;;
esac
EOF
chmod 755 "${WORK}/launchctl"

cat > "${WORK}/fake-ssh" <<'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = '-G' ]; then
    printf '%s\n' 'hostname 127.0.0.1' 'user ci'
    exit 0
fi
if [ "$#" -ne 2 ] || [ "${1}" != 'jump-T208-CI' ] || [ "${2}" != 'sh' ]; then
    exit 94
fi
IFS= read -r bootstrap
marker_tail="${bootstrap#*__CODEX_JUMPBRIDGE_}"
marker_tail="${marker_tail%%; cd*}"
marker_tail="$(printf '%s' "$marker_tail" | tr -cd '[:alnum:]_')"
if [ -z "$marker_tail" ]; then
    exit 93
fi
marker="__CODEX_JUMPBRIDGE_${marker_tail}"
printf '%s\n' "$marker"
if [[ "$bootstrap" == *'app-server proxy'* ]]; then
    sleep 0.25
    printf 'GATE1234HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
    sleep 0.25
    exit 0
fi
printf '%s\n' \
    'CODEX_JUMPBRIDGE_REMOTE_OK' \
    '__CODEX_JUMPBRIDGE_CWD__=/mnt/petrelfs/ci__CODEX_JUMPBRIDGE_HOME__=/mnt/petrelfs/ci__CODEX_JUMPBRIDGE_END__' \
    'CODEX_JUMPBRIDGE_REMOTE_CODEX=codex-cli fixture' \
    'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY' \
    'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY' \
    'CODEX_JUMPBRIDGE_NATIVE_CODEX_HOME=READY' \
    'CODEX_JUMPBRIDGE_HTTP=401' \
    'codex-cli fixture'
EOF
chmod 755 "${WORK}/fake-ssh"

export FAKE_LAUNCHCTL_PATH_FILE="${WORK}/gui-path"
export CODEX_JUMPBRIDGE_REAL_SSH="${WORK}/fake-ssh"
export PATH="${WORK}:${PATH}"

bash "${ROOT}/macos/install.sh" \
    --host jump-T208-CI \
    --proxy http://proxy.invalid:8080 \
    > "${WORK}/install.out" 2> "${WORK}/install.err"

grep -q 'Status: READY' "${WORK}/install.out"
test -x "${HOME}/.local/bin/ssh"
test "$("${HOME}/.local/bin/ssh" --codex-jumpbridge-version)" = \
    'codex-jumpbridge 1.4.3'
test "$(cat "${HOME}/.codex-jumpbridge/hosts.txt")" = 'jump-T208-CI'
grep -q $'^jump-T208-CI\thttp://proxy\.invalid:8080$' \
    "${HOME}/.codex-jumpbridge/proxies.txt"
test -f "${HOME}/Library/LaunchAgents/com.xkqin.codex-jumpbridge-path.plist"
test ! -e "${HOME}/.local/bin/codex-jumpbridge-history-sync"
printf 'MACOS_CLEAN_INSTALL_AND_DOCTOR=PASS\n'
