#!/bin/bash

set -u

CONFIG_DIR="${HOME}/.codex-jumpbridge"
HOSTS_FILE="${CONFIG_DIR}/hosts.txt"
PROXIES_FILE="${CONFIG_DIR}/proxies.txt"
REMOTE_MCP_HOSTS_FILE="${CONFIG_DIR}/remote-mcp-hosts.txt"
SSH_CONFIG="${HOME}/.ssh/config"
SSH_WRAPPER="${HOME}/.local/bin/ssh"
HOST_ALIAS=''

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

if [ "$(uname -s)" != 'Darwin' ]; then
    printf 'This setup UI is for macOS.\n' >&2
    exit 1
fi

if [ ! -x "$SSH_WRAPPER" ]; then
    osascript -e 'display alert "Codex JumpBridge 未安装" message "请先运行 install.sh。" as critical' >/dev/null
    exit 1
fi

list_hosts() {
    [ -f "$HOSTS_FILE" ] || return 0
    sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$HOSTS_FILE"
}

ssh_aliases() {
    [ -f "$SSH_CONFIG" ] || return 0
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
    if printf '%s' "$alias" | grep -Eqi 't(208|209|210)'; then
        return 0
    fi
    expanded="$(/usr/bin/ssh -F "$SSH_CONFIG" -G "$alias" 2>/dev/null || true)"
    remote_user="$(printf '%s\n' "$expanded" | awk '$1 == "user" { print $2; exit }')"
    printf '%s' "$remote_user" | grep -Eq '^[^@]+@[^@]+@[^@]+$'
}

is_jump_gateway() {
    local alias="$1"
    local expanded host_name
    expanded="$(/usr/bin/ssh -F "$SSH_CONFIG" -G "$alias" 2>/dev/null || true)"
    host_name="$(printf '%s\n' "$expanded" | awk '$1 == "hostname" { print tolower($2); exit }')"
    printf '%s' "$host_name" | grep -Eq '^jump\.'
}

available_hosts() {
    { list_hosts; ssh_aliases; } | awk 'NF && !seen[$0]++'
}

prioritized_hosts() {
    local alias all_hosts
    all_hosts="$(available_hosts)"
    while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        if is_t_cluster_alias "$alias" || is_jump_gateway "$alias"; then
            printf '%s\n' "$alias"
        fi
    done <<EOF
$all_hosts
EOF
    while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        if ! is_t_cluster_alias "$alias" && ! is_jump_gateway "$alias"; then
            printf '%s\n' "$alias"
        fi
    done <<EOF
$all_hosts
EOF
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
    done < <(/usr/bin/ssh -F "$SSH_CONFIG" -G "$alias" 2>/dev/null |
        awk '$1 == "identityfile" { print $2 }')
    return 1
}

choose_host() {
    local hosts_text="$1"
    osascript - "$hosts_text" <<'APPLESCRIPT'
on run argv
    set hostItems to paragraphs of item 1 of argv
    set picked to choose from list hostItems with title "Codex JumpBridge" with prompt "选择 ~/.ssh/config 中的连接（推荐网关已排在前面）" OK button name "继续" cancel button name "取消"
    if picked is false then error number -128
    return item 1 of picked
end run
APPLESCRIPT
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

ask_for_proxy() {
    local default_value="$1"
    local detected_note="$2"
    osascript - "$HOST_ALIAS" "$default_value" "$detected_note" <<'APPLESCRIPT'
on run argv
    set hostName to item 1 of argv
    set defaultProxy to item 2 of argv
    set detectedNote to item 3 of argv
    set bodyText to "这是集群计算节点访问 OpenAI 的专用代理。" & return & "它不是本机代理、SSH 跳板地址，也不会把流量转回 localhost。" & return & return & detectedNote
    set dialogResult to display dialog bodyText with title "Codex JumpBridge - " & hostName default answer defaultProxy buttons {"取消", "不使用代理", "测试连接"} default button "测试连接" cancel button "取消"
    return (button returned of dialogResult) & linefeed & (text returned of dialogResult)
end run
APPLESCRIPT
}

show_error() {
    osascript - "$1" <<'APPLESCRIPT' >/dev/null
on run argv
    display alert "代理连接失败" message (item 1 of argv) as critical buttons {"返回修改"} default button "返回修改"
end run
APPLESCRIPT
}

show_success() {
    osascript - "$HOST_ALIAS" <<'APPLESCRIPT'
on run argv
    display alert "连接设置已保存" message ((item 1 of argv) & " 已能通过集群 OpenAI 专用代理访问 OpenAI。重新连接该 SSH Host 后生效。") as informational buttons {"完成"} default button "完成"
end run
APPLESCRIPT
}

show_missing_runtime() {
    local reason="$1"
    osascript - "$HOST_ALIAS" "$reason" <<'APPLESCRIPT' >/dev/null
on run argv
    set hostName to item 1 of argv
    set reasonText to item 2 of argv
    set bodyText to reasonText & return & return & "缺少或不匹配：" & return & "~/.local/bin/codex（JumpBridge 家目录启动器）" & return & "~/.local/bin/codex-jumpbridge-real（编辑器扩展二进制）" & return & "~/.local/bin/codex-code-mode-host" & return & return & "请先在 VS Code 或 Cursor 中连接 " & hostName & "，在 SSH 远程窗口的扩展页安装或更新：" & return & "openai.chatgpt（Codex - OpenAI's coding agent）" & return & return & "不需要先登录。安装完成后回到 Codex 发送：" & return & "继续安装并启动 Codex JumpBridge"
    display alert "集群缺少 Codex 运行文件" message bodyText as warning buttons {"知道了"} default button "知道了"
end run
APPLESCRIPT
}

prepare_remote_runtime() {
    local helper encoded
    helper="${HOME}/.local/bin/codex-jumpbridge-remote-prepare"
    [ -f "$helper" ] || return 5
    encoded="$(base64 < "$helper" | tr -d '\r\n')"
    RUNTIME_OUTPUT="$($SSH_WRAPPER "$HOST_ALIAS" "printf %s $encoded | base64 -d | bash" 2>/dev/null || true)"
    if printf '%s' "$RUNTIME_OUTPUT" | grep -q 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY' &&
        printf '%s' "$RUNTIME_OUTPUT" | grep -q 'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY'; then
        return 0
    fi
    if printf '%s' "$RUNTIME_OUTPUT" | grep -q 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=NO_MATCHING_VERSION'; then
        return 4
    fi
    if printf '%s' "$RUNTIME_OUTPUT" | grep -q 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=MISSING'; then
        return 3
    fi
    return 5
}

save_proxy() {
    local target="$1"
    local value="$2"
    local temp targets_file alias
    mkdir -p "$CONFIG_DIR"
    temp="$(mktemp "${CONFIG_DIR}/proxies.XXXXXX")"
    targets_file="$(mktemp "${CONFIG_DIR}/proxy-targets.XXXXXX")"
    if [ -f "$HOSTS_FILE" ]; then
        sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$HOSTS_FILE" > "$targets_file"
    fi
    grep -Fqx "$target" "$targets_file" || printf '%s\n' "$target" >> "$targets_file"
    if [ -f "$PROXIES_FILE" ]; then
        awk -F '\t' 'NR == FNR { targets[$1] = 1; next } !($1 in targets) { print }' \
            "$targets_file" "$PROXIES_FILE" > "$temp"
    fi
    if [ -n "$value" ]; then
        while IFS= read -r alias; do
            printf '%s\t%s\n' "$alias" "$value" >> "$temp"
        done < "$targets_file"
    fi
    rm -f "$targets_file"
    chmod 600 "$temp"
    mv "$temp" "$PROXIES_FILE"
}

save_remote_mcp() {
    local target="$1"
    local enabled="$2"
    local temp
    mkdir -p "$CONFIG_DIR"
    temp="$(mktemp "${CONFIG_DIR}/remote-mcp-hosts.XXXXXX")"
    if [ -f "$REMOTE_MCP_HOSTS_FILE" ]; then
        awk -v target="$target" 'NF && $0 !~ /^[[:space:]]*#/ && $0 != target { print }' \
            "$REMOTE_MCP_HOSTS_FILE" > "$temp"
    fi
    if [ "$enabled" = '1' ]; then
        printf '%s\n' "$target" >> "$temp"
    fi
    chmod 600 "$temp"
    mv "$temp" "$REMOTE_MCP_HOSTS_FILE"
}

ask_remote_mcp() {
    osascript <<'APPLESCRIPT'
set answer to display dialog "远端 MCP 会在新建任务时从集群连接外部服务。若服务不可达，可能触发 Codex Timeout。建议保持禁用。" with title "远端 MCP" buttons {"保持禁用", "启用"} default button "保持禁用" cancel button "保持禁用" with icon caution
return button returned of answer
APPLESCRIPT
}

enable_bridge_host() {
    local target="$1"
    local temp
    case "$target" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    mkdir -p "$CONFIG_DIR"
    temp="$(mktemp "${CONFIG_DIR}/hosts.XXXXXX")"
    if [ -f "$HOSTS_FILE" ]; then
        awk -v target="$target" 'NF && $0 !~ /^[[:space:]]*#/ && $0 != target { print }' \
            "$HOSTS_FILE" > "$temp"
    fi
    printf '%s\n' "$target" >> "$temp"
    chmod 600 "$temp"
    mv "$temp" "$HOSTS_FILE"
}

test_proxy() {
    local value="$1"
    local quoted output
    quoted="$(posix_quote "$value")"
    output="$($SSH_WRAPPER "$HOST_ALIAS" \
        "env HTTP_PROXY=$quoted HTTPS_PROXY=$quoted http_proxy=$quoted https_proxy=$quoted curl -sS --connect-timeout 8 --max-time 15 -o /dev/null -w 'CODEX_JUMPBRIDGE_HTTP=%{http_code}' https://api.openai.com/v1/models" \
        2>/dev/null || true)"
    case "$output" in
        *CODEX_JUMPBRIDGE_HTTP=200*|*CODEX_JUMPBRIDGE_HTTP=401*) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -f "$SSH_CONFIG" ]; then
    while IFS= read -r alias; do
        if is_t_cluster_alias "$alias"; then
            enable_bridge_host "$alias"
        fi
    done < <(
        awk '
            /^[[:space:]]*Host[[:space:]]+/ {
                for (i = 2; i <= NF; i++) {
                    if ($i !~ /[*?!]/) print $i
                }
            }
        ' "$SSH_CONFIG" | awk '!seen[$0]++'
    )
fi

missing_key_hosts=''
while IFS= read -r alias; do
    if is_t_cluster_alias "$alias" && ! has_private_key "$alias"; then
        missing_key_hosts="${missing_key_hosts}${missing_key_hosts:+
}${alias}"
    fi
done < <(list_hosts)
if [ -n "$missing_key_hosts" ]; then
    osascript - "$missing_key_hosts" <<'APPLESCRIPT' >/dev/null
on run argv
    display alert "缺少 SSH 私钥" message ("以下 T 集群 Host 没有找到 IdentityFile 引用的本机私钥：" & return & (item 1 of argv) & return & return & "每位用户必须使用自己的私钥并登记对应公钥；不要复制同事的 id_rsa。") as critical
end run
APPLESCRIPT
    exit 1
fi

if [ -z "$HOST_ALIAS" ]; then
    host_count="$(prioritized_hosts | wc -l | tr -d ' ')"
    if [ "$host_count" -eq 0 ]; then
        osascript -e 'display alert "没有找到 SSH Host" message "请先配置 ~/.ssh/config 并重新运行安装器。" as critical' >/dev/null
        exit 1
    elif [ "$host_count" -eq 1 ]; then
        HOST_ALIAS="$(prioritized_hosts | head -n 1)"
    else
        HOST_ALIAS="$(choose_host "$(prioritized_hosts)")" || exit 0
    fi
fi

enable_bridge_host "$HOST_ALIAS"
remote_mcp_answer="$(ask_remote_mcp 2>/dev/null || printf '保持禁用')"
if [ "$remote_mcp_answer" = '启用' ]; then
    save_remote_mcp "$HOST_ALIAS" 1
else
    save_remote_mcp "$HOST_ALIAS" 0
fi
detected_note='请填写团队提供的、供集群计算节点访问 OpenAI 的专用代理。'
initial_proxy=''

while true; do
    answer="$(ask_for_proxy "$initial_proxy" "$detected_note")" || exit 0
    action="$(printf '%s\n' "$answer" | head -n 1)"
    proxy_value="$(printf '%s\n' "$answer" | tail -n +2)"

    if [ "$action" = '不使用代理' ]; then
        save_proxy "$HOST_ALIAS" ''
        prepare_remote_runtime
        runtime_rc=$?
        if [ "$runtime_rc" -eq 0 ]; then
            osascript -e 'display alert "已关闭代理" message "远端运行文件已就绪；重新连接该 SSH Host 后生效。" as informational' >/dev/null
            exit 0
        elif [ "$runtime_rc" -eq 4 ]; then
            show_missing_runtime '远端扩展版本与现有 Codex 版本不一致。'
            exit 4
        else
            show_missing_runtime '远端没有找到 Codex 所需的运行文件。'
            exit 3
        fi
    fi

    if ! valid_proxy_url "$proxy_value"; then
        show_error '请输入 http:// 或 https:// 开头、且不包含用户名或密码的代理地址。'
        initial_proxy="$proxy_value"
        detected_note='代理地址格式不正确。'
        continue
    fi

    if test_proxy "$proxy_value"; then
        save_proxy "$HOST_ALIAS" "$proxy_value"
        prepare_remote_runtime
        runtime_rc=$?
        if [ "$runtime_rc" -eq 0 ]; then
            show_success >/dev/null
            exit 0
        elif [ "$runtime_rc" -eq 4 ]; then
            show_missing_runtime '远端扩展版本与现有 Codex 版本不一致。'
            exit 4
        elif [ "$runtime_rc" -eq 3 ]; then
            show_missing_runtime '远端没有找到 Codex 所需的运行文件。'
            exit 3
        else
            show_missing_runtime '远端运行文件检查失败。'
            exit 5
        fi
    fi

    show_error '集群未能通过该地址到达 OpenAI。请确认这是计算节点可访问的出网代理，而不是本机 localhost 代理。'
    initial_proxy="$proxy_value"
    detected_note='上一次测试失败，请修改后重试。'
done
