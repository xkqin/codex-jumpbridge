#!/bin/bash

set -u

CONTENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
LOG_DIR="${HOME}/Library/Logs/Codex JumpBridge"
LOG_FILE="${LOG_DIR}/install.log"

mkdir -p "$LOG_DIR"

{
    printf 'Codex JumpBridge installer started at %s\n' "$(date)"
    /bin/bash "${RESOURCES_DIR}/macos/install.sh"
} >"$LOG_FILE" 2>&1
result=$?

if [ "$result" -ne 0 ]; then
    detail="$(tail -n 12 "$LOG_FILE" 2>/dev/null || true)"
    /usr/bin/osascript - "$LOG_FILE" "$detail" <<'APPLESCRIPT' >/dev/null
on run argv
    set logPath to item 1 of argv
    set detailText to item 2 of argv
    display alert "Codex JumpBridge 安装未完成" message (detailText & return & return & "日志：" & logPath) as critical buttons {"好"} default button "好"
end run
APPLESCRIPT
    exit "$result"
fi

/usr/bin/osascript <<'APPLESCRIPT' >/dev/null
display alert "Codex JumpBridge 安装完成" message "请完全退出并重新打开 Codex Desktop，再添加远程项目。" as informational buttons {"完成"} default button "完成"
APPLESCRIPT

exit 0
