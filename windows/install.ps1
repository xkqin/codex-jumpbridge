param(
    [string[]]$HostAlias,
    [string]$ProxyUrl,
    [switch]$SkipDoctor,
    [switch]$SkipSetup
)

$ErrorActionPreference = 'Stop'
$remotePrepareSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'shared\remote-prepare.sh'

trap {
    $message = $_.Exception.Message -replace '[\r\n]+', ' '
    [Console]::Error.WriteLine("CODEX_JUMPBRIDGE_ERROR=$message")
    exit 1
}

function Write-Step([string]$Status, [string]$Message) {
    Write-Host ("[{0}] {1}" -f $Status, $Message)
}

function Publish-EnvironmentChange {
    if (-not ('CodexJumpBridge.NativeEnvironment' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexJumpBridge {
    public static class NativeEnvironment {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result);
    }
}
'@
    }
    $broadcast = [IntPtr]0xffff
    $wmSettingChange = 0x001a
    $abortIfHung = 0x0002
    $result = [UIntPtr]::Zero
    [void][CodexJumpBridge.NativeEnvironment]::SendMessageTimeout(
        $broadcast,
        $wmSettingChange,
        [UIntPtr]::Zero,
        'Environment',
        $abortIfHung,
        5000,
        [ref]$result)
}

function Invoke-RemotePrepare(
    [string]$Wrapper,
    [string]$Alias,
    [string]$ScriptPath
) {
    $remoteScript = [IO.File]::ReadAllText(
        $ScriptPath,
        [Text.Encoding]::UTF8)
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($remoteScript))
    $output = & $Wrapper $Alias "printf %s $encoded | base64 -d | bash" 2>&1
    $wrapperExitCode = $LASTEXITCODE
    $outputText = $output | Out-String
    if ($outputText -notmatch 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY' -or
        $outputText -notmatch 'CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY') {
        if ($outputText -match 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=MISSING') {
            throw @"
Remote VS Code/Cursor OpenAI extension is missing on $Alias.
1. Connect to this host in VS Code or Cursor.
2. In the SSH window, install or update extension openai.chatgpt.
3. Login is not required for the runtime files to be installed.
4. Run install.ps1 again.
"@
        }
        if ($outputText -match 'CODEX_JUMPBRIDGE_EDITOR_BUNDLE=NO_MATCHING_VERSION') {
            throw @"
The remote editor extension does not match the existing Codex runtime on $Alias.
Update openai.chatgpt in the VS Code/Cursor SSH window, then run install.ps1 again.
"@
        }
        throw "Remote Codex preparation failed for ${Alias}. Run codex-jumpbridge-doctor.ps1 for details."
    }
    if ($wrapperExitCode -ne 0) {
        Write-Step 'WARN' "Gateway returned $wrapperExitCode after reporting READY on $Alias; continuing"
    }
    Write-Step 'OK' "Remote home launcher and codex-code-mode-host are ready on $Alias"
}

function Get-SshAliases([string]$Path) {
    $aliases = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*Host\s+(.+?)\s*$') {
            foreach ($name in ($Matches[1] -split '\s+')) {
                if ($name -and $name -notmatch '[*?!]') {
                    $aliases.Add($name)
                }
            }
        }
    }
    return $aliases | Select-Object -Unique
}

function Test-TClusterAlias(
    [string]$Alias,
    [string]$SshPath,
    [string]$ConfigPath
) {
    if ($Alias -match '(?i)^jump[-_]t[0-9]+(?:[-_]|$)') {
        return $true
    }
    $expanded = & $SshPath -F $ConfigPath -G $Alias 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    $userLine = ($expanded | Select-String '^user\s+' | Select-Object -First 1).Line
    $remoteUser = if ($userLine) { ($userLine -split '\s+', 2)[1] } else { '' }
    return $remoteUser -match '^[^@]+@[^@]+@[^@]+$'
}

function Test-SshPrivateKey(
    [string]$Alias,
    [string]$SshPath,
    [string]$ConfigPath
) {
    $expanded = & $SshPath -F $ConfigPath -G $Alias 2>$null
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

$sshConfig = Join-Path $HOME '.ssh\config'
if (-not (Test-Path -LiteralPath $sshConfig)) {
    throw "SSH config not found: $sshConfig"
}
Write-Step 'OK' "Found SSH config: $sshConfig"

$realSsh = $env:CODEX_JUMPBRIDGE_REAL_SSH
if ([string]::IsNullOrWhiteSpace($realSsh)) {
    $realSsh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
}
if (-not (Test-Path -LiteralPath $realSsh)) {
    throw "SSH client not found: $realSsh"
}
Write-Step 'OK' "Found SSH client: $realSsh"

$detected = @(Get-SshAliases $sshConfig | Where-Object {
    Test-TClusterAlias -Alias $_ -SshPath $realSsh -ConfigPath $sshConfig
})
if (-not $HostAlias -or $HostAlias.Count -eq 0) {
    $HostAlias = $detected
} else {
    $HostAlias = @($HostAlias) + $detected
}
if (-not $HostAlias -or $HostAlias.Count -eq 0) {
    throw 'No jump-host alias was detected. Re-run with -HostAlias your-ssh-host.'
}
$HostAlias = @($HostAlias | Where-Object { $_ } | Select-Object -Unique)
Write-Step 'OK' ("Hosts: " + ($HostAlias -join ', '))
foreach ($alias in $HostAlias) {
    if (-not (Test-SshPrivateKey `
        -Alias $alias -SshPath $realSsh -ConfigPath $sshConfig)) {
        throw @"
No local SSH private key referenced by $alias was found.
Each user must use their own private key (for example ~/.ssh/id_rsa) and register
the matching public key. Never copy a colleague's private key or commit it to GitHub.
"@
    }
}
Write-Step 'OK' 'Local SSH private key is available for every T-cluster Host'

$bundledWrapper = Join-Path $PSScriptRoot 'codex-jumpbridge.exe'
$wrapperSource = Join-Path $PSScriptRoot 'CodexJumpBridge.cs'
$bundledVersion = if (Test-Path -LiteralPath $bundledWrapper) {
    & $bundledWrapper --codex-jumpbridge-version 2>$null
} else {
    ''
}
$sourceIsNewer = (Test-Path -LiteralPath $bundledWrapper) -and
    (Test-Path -LiteralPath $wrapperSource) -and
    ((Get-Item -LiteralPath $wrapperSource).LastWriteTimeUtc -gt
     (Get-Item -LiteralPath $bundledWrapper).LastWriteTimeUtc)
if ($bundledVersion -ne 'codex-jumpbridge 1.4.3' -or $sourceIsNewer) {
    & (Join-Path $PSScriptRoot 'build.ps1') | Out-Null
    Write-Step 'OK' 'Built Codex JumpBridge'
} else {
    Write-Step 'OK' 'Using bundled Codex JumpBridge runtime'
}

$binDir = Join-Path $HOME '.local\bin'
$configDir = Join-Path $HOME '.codex-jumpbridge'
$backupDir = Join-Path $configDir 'backup'
New-Item -ItemType Directory -Force -Path $binDir, $configDir, $backupDir | Out-Null

$targetSsh = Join-Path $binDir 'ssh.exe'
$expectedVersion = 'codex-jumpbridge 1.4.3'
$installedVersion = if (Test-Path -LiteralPath $targetSsh) {
    ((& $targetSsh --codex-jumpbridge-version 2>$null) | Out-String).Trim()
} else {
    ''
}
$bundledHash = (Get-FileHash -LiteralPath $bundledWrapper -Algorithm SHA256).Hash
$installedHash = if (Test-Path -LiteralPath $targetSsh) {
    (Get-FileHash -LiteralPath $targetSsh -Algorithm SHA256).Hash
} else {
    ''
}
if ($installedVersion -eq $expectedVersion -and $installedHash -eq $bundledHash) {
    Write-Step 'OK' 'Existing JumpBridge runtime is already current; keeping the active ssh.exe'
} else {
    if (Test-Path -LiteralPath $targetSsh) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $targetSsh -Destination (
            Join-Path $backupDir "ssh.exe.$stamp")
    }
    try {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'codex-jumpbridge.exe') -Destination $targetSsh -Force
    } catch {
        throw @"
Codex JumpBridge is currently serving an active Codex SSH connection, so Windows cannot update ssh.exe.
Disconnect Codex SSH Hosts (ordinary VS Code/Cursor SSH sessions may stay open), wait a few seconds, then run the same install command again.
"@
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'doctor.ps1') -Destination (
    Join-Path $binDir 'codex-jumpbridge-doctor.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'setup.ps1') -Destination (
    Join-Path $binDir 'codex-jumpbridge-setup.ps1') -Force
Copy-Item -LiteralPath $remotePrepareSource -Destination (
    Join-Path $binDir 'codex-jumpbridge-remote-prepare.sh') -Force
$legacyThreadRepairPath = Join-Path $binDir 'codex-jumpbridge-repair-thread-assignments.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'repair-thread-assignments.ps1') `
    -Destination $legacyThreadRepairPath -Force

foreach ($taskName in @(
    'CodexJumpBridge-ThreadAssignmentRepair',
    'CodexJumpBridge-ProjectPathRepair',
    'CodexJumpBridge-SidebarRepair'
)) {
    $legacyTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($legacyTask) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
foreach ($legacyHelper in @(
    'codex-jumpbridge-repair-project-path.ps1',
    'codex-jumpbridge-repair-sidebar.ps1'
)) {
    Remove-Item -LiteralPath (Join-Path $binDir $legacyHelper) `
        -Force -ErrorAction SilentlyContinue
}

$hostsPath = Join-Path $configDir 'hosts.txt'
$enabledHosts = [Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $hostsPath) {
    foreach ($line in Get-Content -LiteralPath $hostsPath) {
        $name = $line.Trim()
        if ($name -and $name -notmatch '^#' -and -not $enabledHosts.Contains($name)) {
            $enabledHosts.Add($name)
        }
    }
}
foreach ($alias in $HostAlias) {
    if (-not $enabledHosts.Contains($alias)) {
        $enabledHosts.Add($alias)
    }
}
[IO.File]::WriteAllLines(
    $hostsPath,
    [string[]]$enabledHosts,
    [Text.UTF8Encoding]::new($false))

if ($ProxyUrl) {
    $proxyUri = $null
    if (-not [Uri]::TryCreate($ProxyUrl, [UriKind]::Absolute, [ref]$proxyUri) -or
        $proxyUri.Scheme -notin @('http', 'https') -or
        -not $proxyUri.Host -or
        $proxyUri.UserInfo) {
        throw 'Invalid proxy URL. Use an http(s) URL without embedded credentials.'
    }
    $proxyMap = @{}
    $proxiesPath = Join-Path $configDir 'proxies.txt'
    if (Test-Path -LiteralPath $proxiesPath) {
        foreach ($line in Get-Content -LiteralPath $proxiesPath) {
            $parts = $line.Trim() -split "`t", 2
            if ($parts.Count -eq 2 -and $parts[0]) {
                $proxyMap[$parts[0]] = $parts[1]
            }
        }
    }
    foreach ($alias in $HostAlias) {
        $proxyMap[$alias] = $ProxyUrl
    }
    $proxyLines = $proxyMap.GetEnumerator() |
        Sort-Object Key |
        ForEach-Object { "{0}`t{1}" -f $_.Key, $_.Value }
    [IO.File]::WriteAllLines(
        $proxiesPath,
        [string[]]$proxyLines,
        [Text.UTF8Encoding]::new($false))
    Write-Step 'OK' 'Saved app-server proxy settings'
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathParts = @($userPath -split ';' | Where-Object { $_ })
if ($pathParts -notcontains $binDir) {
    [Environment]::SetEnvironmentVariable(
        'Path',
        (($binDir) + ';' + ($pathParts -join ';')).TrimEnd(';'),
        'User')
}
if (($env:PATH -split ';') -notcontains $binDir) {
    $env:PATH = "$binDir;$env:PATH"
}
try {
    Publish-EnvironmentChange
    Write-Step 'OK' 'Refreshed the Windows desktop environment for new Codex launches'
} catch {
    Write-Step 'WARN' 'Could not notify the Windows desktop about PATH; fully sign out or restart Windows before using Codex'
}

Write-Step 'OK' "Installed: $targetSsh"
Write-Step 'OK' "Config: $(Join-Path $configDir 'hosts.txt')"

if (-not $ProxyUrl -and -not $SkipSetup) {
    $setupProcess = Start-Process -FilePath 'powershell.exe' -PassThru -Wait -ArgumentList @(
        '-Sta',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $binDir 'codex-jumpbridge-setup.ps1'),
        '-HostAlias', $HostAlias[0])
    if ($setupProcess.ExitCode -ne 0) {
        throw "Connection setup exited with code $($setupProcess.ExitCode)"
    }
}

$remotePreparePath = $remotePrepareSource
foreach ($alias in $HostAlias) {
    Invoke-RemotePrepare -Wrapper $targetSsh -Alias $alias -ScriptPath $remotePreparePath
}

if (-not $SkipDoctor) {
    foreach ($alias in $HostAlias) {
        & (Join-Path $binDir 'codex-jumpbridge-doctor.ps1') -HostAlias $alias
    }
}

Write-Host ''
Write-Host 'Codex JumpBridge is installed. Restart Codex Desktop before adding the remote project.'
