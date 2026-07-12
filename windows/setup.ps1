param(
    [string]$HostAlias
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

$configDir = Join-Path $HOME '.codex-jumpbridge'
$hostsPath = Join-Path $configDir 'hosts.txt'
$proxiesPath = Join-Path $configDir 'proxies.txt'
$sshConfigPath = Join-Path $HOME '.ssh\config'
$sshPath = Join-Path $HOME '.local\bin\ssh.exe'
$realSshPath = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'

function Get-SshAliases {
    $aliases = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $hostsPath) {
        foreach ($line in Get-Content -LiteralPath $hostsPath) {
            $value = $line.Trim()
            if ($value -and -not $value.StartsWith('#')) {
                $aliases.Add($value)
            }
        }
    }
    if (Test-Path -LiteralPath $sshConfigPath) {
        foreach ($line in Get-Content -LiteralPath $sshConfigPath) {
            if ($line -match '^\s*Host\s+(.+?)\s*$') {
                foreach ($name in ($Matches[1] -split '\s+')) {
                    if ($name -and $name -notmatch '[*?!]') {
                        $aliases.Add($name)
                    }
                }
            }
        }
    }
    return @($aliases | Select-Object -Unique)
}

function Test-TClusterAlias([string]$Alias) {
    if ($Alias -match '(?i)^jump[-_]t[0-9]+(?:[-_]|$)') {
        return $true
    }
    if (-not (Test-Path -LiteralPath $realSshPath)) {
        return $false
    }
    $expanded = & $realSshPath -G $Alias 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    $userLine = ($expanded | Select-String '^user\s+' | Select-Object -First 1).Line
    $remoteUser = if ($userLine) { ($userLine -split '\s+', 2)[1] } else { '' }
    return $remoteUser -match '^[^@]+@[^@]+@[^@]+$'
}

function Get-SshHostPriority([string]$Alias) {
    if (Test-TClusterAlias $Alias) {
        return 0
    }
    if (-not (Test-Path -LiteralPath $realSshPath)) {
        return 2
    }
    $expanded = & $realSshPath -G $Alias 2>$null
    $hostLine = ($expanded | Select-String '^hostname\s+' | Select-Object -First 1).Line
    $hostName = if ($hostLine) { ($hostLine -split '\s+', 2)[1] } else { '' }
    if ($hostName -match '(?i)^jump\.') {
        return 1
    }
    return 2
}

function Test-SshPrivateKey([string]$Alias) {
    $expanded = & $realSshPath -G $Alias 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    foreach ($line in $expanded | Select-String '^identityfile\s+') {
        $path = ($line.Line -split '\s+', 2)[1].Trim('"')
        $path = $path.Replace('%d', $HOME)
        if ($path.StartsWith('~/') -or $path.StartsWith('~\')) {
            $path = Join-Path $HOME $path.Substring(2)
        }
        $path = [Environment]::ExpandEnvironmentVariables($path)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $true
        }
    }
    return $false
}

function Get-ProxyMap {
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $proxiesPath)) {
        return $map
    }
    foreach ($line in Get-Content -LiteralPath $proxiesPath) {
        $value = $line.Trim()
        if (-not $value -or $value.StartsWith('#')) {
            continue
        }
        $parts = $value -split "`t", 2
        if ($parts.Count -eq 2 -and $parts[0].Trim()) {
            $map[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $map
}

function Test-ProxyUrl([string]$Value) {
    if (-not $Value -or
        $Value -match '\s' -or
        $Value.Contains([char]39) -or
        $Value.Contains([char]34) -or
        $Value.Contains([char]96)) {
        return $false
    }
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    return $uri.Scheme -in @('http', 'https') -and
        [bool]$uri.Host -and
        -not $uri.UserInfo
}

function Invoke-Remote([string]$Alias, [string]$Command) {
    if (-not (Test-Path -LiteralPath $sshPath)) {
        throw "JumpBridge 尚未安装：$sshPath"
    }
    $output = & $sshPath $Alias $Command 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Test-RemoteProxy([string]$Alias, [string]$Url) {
    $quoted = "'$Url'"
    $command = @(
        "env HTTP_PROXY=$quoted HTTPS_PROXY=$quoted"
        "http_proxy=$quoted https_proxy=$quoted"
        "curl -sS --connect-timeout 8 --max-time 15"
        "-o /dev/null -w '%{http_code}' https://api.openai.com/v1/models"
    ) -join ' '
    $result = Invoke-Remote $Alias $command
    $code = [regex]::Match($result.Output, '(?m)(\d{3})\s*$').Groups[1].Value
    return [pscustomobject]@{
        Success = $result.ExitCode -eq 0 -and $code -in @('200', '401')
        HttpCode = $code
        Detail = $result.Output.Trim()
    }
}

function Find-EditorProxy([string]$Alias) {
    $python = @'
import os
from pathlib import Path

uid = os.getuid()
keys = (b'HTTPS_PROXY=', b'https_proxy=', b'HTTP_PROXY=', b'http_proxy=')
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit():
        continue
    try:
        if proc.stat().st_uid != uid:
            continue
        command = (proc / 'cmdline').read_bytes().replace(b'\0', b' ')
        if b'openai.chatgpt' not in command or b'app-server' not in command:
            continue
        values = (proc / 'environ').read_bytes().split(b'\0')
        for key in keys:
            for item in values:
                if item.startswith(key):
                    print('__CODEX_JUMPBRIDGE_PROXY__=' + item[len(key):].decode())
                    raise SystemExit(0)
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        pass
raise SystemExit(1)
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($python))
    $result = Invoke-Remote $Alias "printf %s $encoded | base64 -d | python3 -"
    $match = [regex]::Match(
        $result.Output,
        '(?m)^__CODEX_JUMPBRIDGE_PROXY__=(https?://\S+)\s*$')
    if ($result.ExitCode -eq 0 -and $match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

function Prepare-RemoteRuntime([string]$Alias) {
    $scriptDirectory = $PSScriptRoot
    $preparePath = Join-Path $scriptDirectory 'codex-jumpbridge-remote-prepare.sh'
    if (-not (Test-Path -LiteralPath $preparePath)) {
        $preparePath = Join-Path (Split-Path $scriptDirectory -Parent) 'shared\remote-prepare.sh'
    }
    if (-not (Test-Path -LiteralPath $preparePath)) {
        return [pscustomobject]@{
            Success = $false
            Missing = $false
            Mismatch = $false
            Detail = 'Remote preparation helper is missing.'
        }
    }

    $remoteScript = [IO.File]::ReadAllText(
        $preparePath,
        [Text.Encoding]::UTF8)
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($remoteScript))
    $result = Invoke-Remote $Alias "printf %s $encoded | base64 -d | bash"
    return [pscustomobject]@{
        Success = $result.ExitCode -eq 0 -and
            $result.Output -match 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY' -and
            $result.Output -match 'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY'
        Missing = $result.Output -match 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=MISSING'
        Mismatch = $result.Output -match 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=NO_MATCHING_VERSION'
        Detail = $result.Output.Trim()
    }
}

function Show-MissingRuntime([string]$Alias, [bool]$Mismatch) {
    $reason = if ($Mismatch) {
        '远端扩展版本与现有 Codex 版本不一致。'
    } else {
        '远端没有找到 Codex 所需的运行文件。'
    }
    $message = @"
$reason

缺少或不匹配：
~/.local/bin/codex（JumpBridge app-server 启动器）
~/.local/bin/codex-jumpbridge-real（编辑器扩展二进制）
~/.local/bin/codex-code-mode-host

请先在 VS Code 或 Cursor 中连接 $Alias，在 SSH 远程窗口的扩展页安装或更新：
openai.chatgpt（Codex - OpenAI's coding agent）

不需要先登录；扩展安装完成即可。然后回到 Codex 发送：
“继续安装并启动 Codex JumpBridge”
"@
    [Windows.Forms.MessageBox]::Show(
        $message,
        '集群缺少 Codex 运行文件',
        'OK',
        'Warning') | Out-Null
}

function Save-Proxy([string]$Alias, [string]$Url, [bool]$Enabled) {
    $map = Get-ProxyMap
    $targets = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $hostsPath) {
        foreach ($line in Get-Content -LiteralPath $hostsPath) {
            $name = $line.Trim()
            if ($name -and $name -notmatch '^#' -and -not $targets.Contains($name)) {
                $targets.Add($name)
            }
        }
    }
    if (-not $targets.Contains($Alias)) {
        $targets.Add($Alias)
    }
    if ($Enabled) {
        foreach ($target in $targets) {
            $map[$target] = $Url
        }
    } else {
        foreach ($target in $targets) {
            $map.Remove($target)
        }
    }
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $lines = foreach ($entry in $map.GetEnumerator()) {
        "{0}`t{1}" -f $entry.Key, $entry.Value
    }
    [IO.File]::WriteAllLines(
        $proxiesPath,
        [string[]]$lines,
        [Text.UTF8Encoding]::new($false))
}

function Enable-BridgeHost([string]$Alias) {
    if ($Alias -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'SSH Host 别名包含不支持的字符。'
    }

    $enabledHosts = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $hostsPath) {
        foreach ($line in Get-Content -LiteralPath $hostsPath) {
            $name = $line.Trim()
            if ($name -and $name -notmatch '^#' -and -not $enabledHosts.Contains($name)) {
                $enabledHosts.Add($name)
            }
        }
    }
    if (-not $enabledHosts.Contains($Alias)) {
        $enabledHosts.Add($Alias)
    }

    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    [IO.File]::WriteAllLines(
        $hostsPath,
        [string[]]$enabledHosts,
        [Text.UTF8Encoding]::new($false))
}

$hosts = @(Get-SshAliases)
if ($HostAlias -and $hosts -notcontains $HostAlias) {
    $hosts = @($HostAlias) + $hosts
}
$hosts = @($hosts | Sort-Object `
        @{ Expression = { Get-SshHostPriority $_ } },
        @{ Expression = { $_ } })
if ($hosts.Count -eq 0) {
    [Windows.Forms.MessageBox]::Show(
        '没有找到 SSH 别名。请先配置 ~/.ssh/config。',
        'Codex JumpBridge',
        'OK',
        'Error') | Out-Null
    exit 1
}
$clusterHosts = @($hosts | Where-Object { Test-TClusterAlias $_ })
$missingKeyHosts = @($clusterHosts | Where-Object { -not (Test-SshPrivateKey $_) })
if ($missingKeyHosts.Count -gt 0) {
    [Windows.Forms.MessageBox]::Show(
        "以下 T 集群 Host 没有找到 IdentityFile 引用的本机私钥：`r`n$($missingKeyHosts -join "`r`n")`r`n`r`n每位用户必须使用自己的私钥并登记对应公钥；不要复制同事的 id_rsa。",
        '缺少 SSH 私钥',
        'OK',
        'Error') | Out-Null
    exit 1
}
foreach ($clusterHost in $clusterHosts) {
    Enable-BridgeHost $clusterHost
}

$form = [Windows.Forms.Form]::new()
$form.Text = 'Codex JumpBridge 设置'
$form.ClientSize = [Drawing.Size]::new(720, 430)
$form.MinimumSize = [Drawing.Size]::new(736, 469)
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(248, 249, 250)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi

$title = [Windows.Forms.Label]::new()
$title.Text = '连接设置'
$title.Font = [Drawing.Font]::new('Microsoft YaHei UI', 18, [Drawing.FontStyle]::Bold)
$title.Location = [Drawing.Point]::new(28, 24)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = [Windows.Forms.Label]::new()
$subtitle.Text = '填写集群计算节点访问 OpenAI 的专用代理。'
$subtitle.ForeColor = [Drawing.Color]::FromArgb(92, 99, 106)
$subtitle.Location = [Drawing.Point]::new(30, 66)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

$hostLabel = [Windows.Forms.Label]::new()
$hostLabel.Text = 'SSH 主机'
$hostLabel.Location = [Drawing.Point]::new(30, 116)
$hostLabel.AutoSize = $true
$form.Controls.Add($hostLabel)

$hostBox = [Windows.Forms.ComboBox]::new()
$hostBox.DropDownStyle = 'DropDownList'
$hostBox.Location = [Drawing.Point]::new(30, 146)
$hostBox.Size = [Drawing.Size]::new(660, 34)
[void]$hostBox.Items.AddRange([object[]]$hosts)
$form.Controls.Add($hostBox)

$hostHint = [Windows.Forms.Label]::new()
$hostHint.Text = "已读取 ~/.ssh/config：发现 $($hosts.Count) 个连接；推荐网关已优先排序"
$hostHint.ForeColor = [Drawing.Color]::FromArgb(92, 99, 106)
$hostHint.Location = [Drawing.Point]::new(30, 184)
$hostHint.AutoSize = $true
$form.Controls.Add($hostHint)

$proxyToggle = [Windows.Forms.CheckBox]::new()
$proxyToggle.Text = '启用集群 OpenAI 专用代理'
$proxyToggle.Location = [Drawing.Point]::new(30, 224)
$proxyToggle.AutoSize = $true
$proxyToggle.Checked = $true
$form.Controls.Add($proxyToggle)

$detectButton = [Windows.Forms.Button]::new()
$detectButton.Text = '从 VS Code / Cursor 检测'
$detectButton.Location = [Drawing.Point]::new(440, 214)
$detectButton.Size = [Drawing.Size]::new(250, 40)
$detectButton.FlatStyle = 'System'
$form.Controls.Add($detectButton)

$proxyBox = [Windows.Forms.TextBox]::new()
$proxyBox.Location = [Drawing.Point]::new(30, 268)
$proxyBox.Size = [Drawing.Size]::new(660, 32)
$proxyBox.Text = ''
$proxyBox.UseSystemPasswordChar = $true
$form.Controls.Add($proxyBox)

$hint = [Windows.Forms.Label]::new()
$hint.Text = '仅注入远端 Codex app-server；不是本机代理、SSH 代理或跳板地址。'
$hint.ForeColor = [Drawing.Color]::FromArgb(92, 99, 106)
$hint.Location = [Drawing.Point]::new(30, 306)
$hint.AutoSize = $true
$form.Controls.Add($hint)

$showProxyToggle = [Windows.Forms.CheckBox]::new()
$showProxyToggle.Text = '显示地址'
$showProxyToggle.Location = [Drawing.Point]::new(590, 304)
$showProxyToggle.AutoSize = $true
$showProxyToggle.Checked = $false
$form.Controls.Add($showProxyToggle)

$status = [Windows.Forms.Label]::new()
$status.Text = '尚未测试'
$status.ForeColor = [Drawing.Color]::FromArgb(92, 99, 106)
$status.Location = [Drawing.Point]::new(30, 356)
$status.Size = [Drawing.Size]::new(390, 34)
$form.Controls.Add($status)

$testButton = [Windows.Forms.Button]::new()
$testButton.Text = '测试连接'
$testButton.Location = [Drawing.Point]::new(440, 346)
$testButton.Size = [Drawing.Size]::new(110, 42)
$testButton.FlatStyle = 'System'
$form.Controls.Add($testButton)

$saveButton = [Windows.Forms.Button]::new()
$saveButton.Text = '保存设置'
$saveButton.Location = [Drawing.Point]::new(560, 346)
$saveButton.Size = [Drawing.Size]::new(130, 42)
$saveButton.FlatStyle = 'System'
$form.AcceptButton = $saveButton
$form.Controls.Add($saveButton)

$loadHost = {
    $proxyToggle.Checked = $true
    $proxyBox.Clear()
    $showProxyToggle.Checked = $false
    $status.Text = '尚未测试'
    $status.ForeColor = [Drawing.Color]::FromArgb(92, 99, 106)
}

$hostBox.Add_SelectedIndexChanged($loadHost)
$proxyToggle.Add_CheckedChanged({
    $proxyBox.Enabled = $proxyToggle.Checked
    $testButton.Enabled = $proxyToggle.Checked
    $detectButton.Enabled = $proxyToggle.Checked
})
$showProxyToggle.Add_CheckedChanged({
    $proxyBox.UseSystemPasswordChar = -not $showProxyToggle.Checked
})

$detectButton.Add_Click({
    $status.Text = '正在读取远端 VS Code / Cursor 配置...'
    $status.ForeColor = [Drawing.Color]::FromArgb(92, 99, 106)
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $detectButton.Enabled = $false
    [Windows.Forms.Application]::DoEvents()
    try {
        $alias = [string]$hostBox.SelectedItem
        Enable-BridgeHost $alias
        $detected = Find-EditorProxy $alias
        if ($detected -and (Test-ProxyUrl $detected)) {
            $proxyBox.Text = $detected
            $status.Text = '已从 VS Code / Cursor 检测到代理，请测试连接'
            $status.ForeColor = [Drawing.Color]::FromArgb(20, 128, 74)
        } else {
            $status.Text = '未检测到代理，请手动填写'
            $status.ForeColor = [Drawing.Color]::Firebrick
        }
    } catch {
        $status.Text = "检测失败：$($_.Exception.Message)"
        $status.ForeColor = [Drawing.Color]::Firebrick
    } finally {
        $form.Cursor = [Windows.Forms.Cursors]::Default
        $detectButton.Enabled = $proxyToggle.Checked
    }
})

$testButton.Add_Click({
    $url = $proxyBox.Text.Trim()
    if (-not (Test-ProxyUrl $url)) {
        $status.Text = '代理地址格式不正确'
        $status.ForeColor = [Drawing.Color]::Firebrick
        return
    }
    $status.Text = '正在从集群测试...'
    $status.ForeColor = [Drawing.Color]::FromArgb(92, 99, 106)
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $testButton.Enabled = $false
    [Windows.Forms.Application]::DoEvents()
    try {
        $alias = [string]$hostBox.SelectedItem
        Enable-BridgeHost $alias
        $result = Test-RemoteProxy $alias $url
        if ($result.Success) {
            $status.Text = "连接成功（OpenAI HTTP $($result.HttpCode)）"
            $status.ForeColor = [Drawing.Color]::FromArgb(20, 128, 74)
        } else {
            $status.Text = '连接失败，请检查代理地址或权限'
            $status.ForeColor = [Drawing.Color]::Firebrick
        }
    } catch {
        $status.Text = "测试失败：$($_.Exception.Message)"
        $status.ForeColor = [Drawing.Color]::Firebrick
    } finally {
        $form.Cursor = [Windows.Forms.Cursors]::Default
        $testButton.Enabled = $proxyToggle.Checked
    }
})

$saveButton.Add_Click({
    $alias = [string]$hostBox.SelectedItem
    $url = $proxyBox.Text.Trim()
    if ($proxyToggle.Checked -and -not (Test-ProxyUrl $url)) {
        $status.Text = '代理地址格式不正确，未保存'
        $status.ForeColor = [Drawing.Color]::Firebrick
        return
    }
    try {
        Enable-BridgeHost $alias
        Save-Proxy $alias $url $proxyToggle.Checked
        $runtime = Prepare-RemoteRuntime $alias
        if ($runtime.Success) {
            $status.Text = '代理与远端运行文件已就绪；重新连接后生效'
            $status.ForeColor = [Drawing.Color]::FromArgb(20, 128, 74)
        } elseif ($runtime.Missing -or $runtime.Mismatch) {
            $status.Text = '代理已保存；集群仍缺少 Codex 运行文件'
            $status.ForeColor = [Drawing.Color]::Firebrick
            Show-MissingRuntime $alias $runtime.Mismatch
        } else {
            $status.Text = '代理已保存；远端运行文件检查失败'
            $status.ForeColor = [Drawing.Color]::Firebrick
        }
    } catch {
        $status.Text = "保存失败：$($_.Exception.Message)"
        $status.ForeColor = [Drawing.Color]::Firebrick
    }
})

$initialIndex = 0
if ($HostAlias) {
    $found = $hostBox.Items.IndexOf($HostAlias)
    if ($found -ge 0) {
        $initialIndex = $found
    }
}
$hostBox.SelectedIndex = $initialIndex

[void]$form.ShowDialog()
