param(
    [string]$HostAlias,
    [string]$WrapperPath
)

$ErrorActionPreference = 'Stop'
$failed = $false

function Report([string]$Status, [string]$Message) {
    Write-Host ("[{0}] {1}" -f $Status, $Message)
}

function Fail([string]$Message) {
    $script:failed = $true
    Report 'FAIL' $Message
}

$binDir = Join-Path $HOME '.local\bin'
$wrapper = if ($WrapperPath) { $WrapperPath } else { Join-Path $binDir 'ssh.exe' }
$hostsFile = Join-Path $HOME '.codex-jumpbridge\hosts.txt'
$proxiesFile = Join-Path $HOME '.codex-jumpbridge\proxies.txt'

if (-not (Test-Path -LiteralPath $wrapper)) {
    throw "JumpBridge is not installed: $wrapper"
}

$version = & $wrapper --codex-jumpbridge-version
if ($LASTEXITCODE -eq 0 -and $version -match '^codex-jumpbridge ') {
    Report 'OK' $version
} else {
    Fail 'Installed ssh.exe is not Codex JumpBridge'
}

if (-not $HostAlias) {
    if (Test-Path -LiteralPath $hostsFile) {
        $HostAlias = Get-Content -LiteralPath $hostsFile |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Select-Object -First 1
    }
}
if (-not $HostAlias) {
    throw 'No host configured. Pass -HostAlias or run install.ps1 again.'
}
Report 'OK' "Checking host: $HostAlias"

$resolved = & $wrapper -G $HostAlias 2>$null
if ($LASTEXITCODE -eq 0 -and $resolved -match '(?m)^hostname\s+') {
    Report 'OK' 'SSH config resolves'
} else {
    Fail 'ssh -G failed; check ~/.ssh/config'
}

$probe = & $wrapper $HostAlias 'printf CODEX_JUMPBRIDGE_REMOTE_OK' 2>$null
if ($LASTEXITCODE -eq 0 -and $probe -match 'CODEX_JUMPBRIDGE_REMOTE_OK') {
    Report 'OK' 'Gateway shell bridge works'
} else {
    Fail 'Remote shell probe failed; verify the host alias and key permissions'
}

$homeProbe = & $wrapper $HostAlias (
    'printf "__CODEX_JUMPBRIDGE_CWD__=%s__CODEX_JUMPBRIDGE_HOME__=%s__CODEX_JUMPBRIDGE_END__" "$PWD" "$HOME"') 2>$null
$homeMatch = [regex]::Match(
    ($homeProbe -join "`n"),
    '__CODEX_JUMPBRIDGE_CWD__=(.*?)__CODEX_JUMPBRIDGE_HOME__=(.*?)__CODEX_JUMPBRIDGE_END__')
if ($LASTEXITCODE -eq 0 -and $homeMatch.Success -and
    $homeMatch.Groups[1].Value -eq $homeMatch.Groups[2].Value -and
    $homeMatch.Groups[2].Value.StartsWith('/mnt/petrelfs/')) {
    Report 'OK' "Remote commands start in $($homeMatch.Groups[2].Value)"
} else {
    Fail 'Remote commands do not start in /mnt/petrelfs home; update JumpBridge'
}

$remotePreparePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'shared\remote-prepare.sh'
if (-not (Test-Path -LiteralPath $remotePreparePath)) {
    $remotePreparePath = Join-Path $binDir 'codex-jumpbridge-remote-prepare.sh'
}
if (Test-Path -LiteralPath $remotePreparePath) {
    $remotePrepareScript = [IO.File]::ReadAllText(
        $remotePreparePath,
        [Text.Encoding]::UTF8)
    $remotePrepareEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($remotePrepareScript))
    $remotePrepareOutput = & $wrapper $HostAlias (
        "printf %s $remotePrepareEncoded | base64 -d | bash") 2>$null
    if ($LASTEXITCODE -eq 0 -and
        $remotePrepareOutput -match 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY' -and
        $remotePrepareOutput -match 'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY') {
        Report 'OK' 'Remote home launcher and codex-code-mode-host are ready'
    } else {
        Fail 'Remote code host is missing; open VS Code/Cursor on the cluster and rerun install.ps1'
    }
} else {
    Fail 'Remote preparation helper is missing; rerun install.ps1'
}

$codexProbe = & $wrapper $HostAlias (
    'PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"; ' +
    'export PATH; command -v codex >/dev/null && codex --version') 2>$null
if ($LASTEXITCODE -eq 0 -and $codexProbe -match 'codex') {
    Report 'OK' ("Remote " + (($codexProbe | Select-Object -Last 1) -join ''))
} else {
    Fail 'Remote Codex was not found in ~/.local/bin or PATH'
}

$proxyUrl = $null
if (Test-Path -LiteralPath $proxiesFile) {
    foreach ($line in Get-Content -LiteralPath $proxiesFile) {
        $parts = $line.Trim() -split "`t", 2
        if ($parts.Count -eq 2 -and $parts[0] -eq $HostAlias) {
            $proxyUrl = $parts[1].Trim()
            break
        }
    }
}

$proxyPrefix = ''
if ($proxyUrl) {
    $quote = [string][char]39
    $replacement = ([string][char]39) + ([char]92) + ([char]39) + ([char]39)
    $quotedProxy = $quote + $proxyUrl.Replace($quote, $replacement) + $quote
    $proxyPrefix =
        "env HTTP_PROXY=$quotedProxy HTTPS_PROXY=$quotedProxy " +
        "http_proxy=$quotedProxy https_proxy=$quotedProxy "
    Report 'OK' "App-server proxy configured for $HostAlias"
}

$networkProbe = & $wrapper $HostAlias (
    $proxyPrefix +
    "curl -sS --connect-timeout 8 --max-time 15 -o /dev/null " +
    "-w 'CODEX_JUMPBRIDGE_HTTP=%{http_code}' " +
    'https://api.openai.com/v1/models') 2>$null
$networkExitCode = $LASTEXITCODE
$httpMatch = [regex]::Match(
    ($networkProbe -join "`n"),
    'CODEX_JUMPBRIDGE_HTTP=(200|401)')
if ($networkExitCode -eq 0 -and $httpMatch.Success) {
    Report 'OK' "OpenAI route works (HTTP $($httpMatch.Groups[1].Value))"
} else {
    Fail 'OpenAI route failed; open codex-jumpbridge-setup.ps1 and test the cluster proxy'
}

if ($failed) {
    Write-Host ''
    Write-Host 'Status: NOT READY'
    exit 1
}

Write-Host ''
Write-Host 'Status: READY'
Write-Host 'Restart Codex Desktop, add this SSH host, then open /mnt/petrelfs/<user>.'
Write-Host 'Codex may display the canonical /mnt/hwfile/<user> path; remote commands still use petrelfs.'
