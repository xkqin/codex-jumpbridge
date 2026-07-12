[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostAlias,
    [Parameter(Mandatory = $true)]
    [string]$UserName,
    [string]$ThreadIndexPath,
    [switch]$AfterExit,
    [int]$CodexPid = 0,
    [switch]$Restart,
    [string]$TaskName
)

$ErrorActionPreference = 'Stop'

if ($HostAlias -notmatch '^[A-Za-z0-9._-]+$') {
    throw 'SSH Host alias contains unsupported characters.'
}
if ($UserName -notmatch '^[A-Za-z0-9._-]+$') {
    throw 'Remote user name contains unsupported characters.'
}

$logicalRoot = "/mnt/petrelfs/$UserName"
$canonicalRoot = "/mnt/hwfile/$UserName"
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$statePath = Join-Path $codexHome '.codex-global-state.json'
$stateBackupPath = "$statePath.bak"
$logPath = Join-Path $codexHome 'jumpbridge-thread-assignment-repair.log'
$sshPath = Join-Path $HOME '.local\bin\ssh.exe'
$atomContainerKey = 'electron-persisted-atom-state'
$sidebarKey = 'flat-project-sidebar-preferences-v1'
$assignmentKey = 'thread-project-assignments'

function Write-RepairLog {
    param([string]$Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    [IO.File]::AppendAllText($logPath, "$line`r`n", [Text.UTF8Encoding]::new($false))
}

function New-JsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 256
    return $serializer
}

function Get-CodexMainProcess {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq 'ChatGPT.exe' -and
            $_.CommandLine -notmatch '\s--type=' -and
            $_.ExecutablePath -match '[\\/]OpenAI\.Codex_[^\\/]+[\\/]app[\\/]ChatGPT\.exe$'
        } |
        Select-Object -First 1
}

function Get-CodexExecutable {
    $process = Get-CodexMainProcess
    if ($process -and $process.ExecutablePath) {
        return $process.ExecutablePath
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Write-JsonAtomically {
    param(
        [string]$Path,
        [string]$Json
    )

    $temporaryPath = '{0}.tmp-{1}-{2}' -f $Path, $PID, ([guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($temporaryPath, $Json, [Text.UTF8Encoding]::new($false))
    $replaceBackupPath = '{0}.replace-backup-{1}' -f $Path, $PID
    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporaryPath, $Path, $replaceBackupPath, $true)
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-HostIds {
    param([Collections.IDictionary]$State)

    $ids = [Collections.Generic.List[string]]::new()
    if ($State.ContainsKey('codex-managed-remote-connections')) {
        foreach ($connection in $State['codex-managed-remote-connections']) {
            if (($connection['alias'] -eq $HostAlias -or
                    $connection['displayName'] -eq $HostAlias) -and
                $connection['hostId']) {
                $ids.Add([string]$connection['hostId'])
            }
        }
    }
    return @($ids | Select-Object -Unique)
}

function Get-RemoteThreadIndex {
    param([System.Web.Script.Serialization.JavaScriptSerializer]$Serializer)

    if ($ThreadIndexPath) {
        if (-not (Test-Path -LiteralPath $ThreadIndexPath)) {
            throw "Thread index fixture was not found: $ThreadIndexPath"
        }
        return @($Serializer.DeserializeObject(
                [IO.File]::ReadAllText($ThreadIndexPath, [Text.Encoding]::UTF8)))
    }

    if (-not (Test-Path -LiteralPath $sshPath)) {
        throw "JumpBridge SSH wrapper was not found: $sshPath"
    }

    $python = @'
import base64
import json
from pathlib import Path

threads = {}
sessions = Path.home() / '.codex' / 'sessions'
if sessions.is_dir():
    for path in sessions.rglob('*.jsonl'):
        try:
            with path.open('r', encoding='utf-8') as handle:
                event = json.loads(handle.readline())
            if event.get('type') != 'session_meta':
                continue
            payload = event.get('payload') or {}
            thread_id = payload.get('id')
            cwd = payload.get('cwd')
            if isinstance(thread_id, str) and isinstance(cwd, str):
                threads[thread_id] = {'id': thread_id, 'cwd': cwd}
        except (OSError, UnicodeError, json.JSONDecodeError):
            pass

encoded = base64.b64encode(
    json.dumps(list(threads.values()), separators=(',', ':')).encode('utf-8')
).decode('ascii')
print('__CODEX_JUMPBRIDGE_THREADS__=' + encoded + '__CODEX_JUMPBRIDGE_THREADS_END__', end='')
'@
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($python))
    $output = & $sshPath $HostAlias "printf %s $encodedScript | base64 -d | python3 -" 2>&1
    $exitCode = $LASTEXITCODE
    $text = $output -join "`n"
    $match = [regex]::Match(
        $text,
        '__CODEX_JUMPBRIDGE_THREADS__=([A-Za-z0-9+/=]+)__CODEX_JUMPBRIDGE_THREADS_END__')
    if ($exitCode -ne 0 -or -not $match.Success) {
        throw 'Could not read remote Codex thread metadata.'
    }

    $json = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($match.Groups[1].Value))
    return @($Serializer.DeserializeObject($json))
}

function Normalize-RemotePath {
    param([string]$Path)

    if (-not $Path) {
        return ''
    }
    if ($Path -eq '/') {
        return '/'
    }
    return $Path.TrimEnd('/')
}

function Test-PathWithin {
    param(
        [string]$Path,
        [string]$Root
    )

    $candidate = Normalize-RemotePath $Path
    $base = Normalize-RemotePath $Root
    return $candidate -eq $base -or $candidate.StartsWith("$base/")
}

function Get-MirroredRemotePath {
    param([string]$Path)

    $candidate = Normalize-RemotePath $Path
    if (Test-PathWithin -Path $candidate -Root $canonicalRoot) {
        return $logicalRoot + $candidate.Substring($canonicalRoot.Length)
    }
    if (Test-PathWithin -Path $candidate -Root $logicalRoot) {
        return $canonicalRoot + $candidate.Substring($logicalRoot.Length)
    }
    return ''
}

function Get-LogicalRemotePath {
    param([string]$Path)

    $candidate = Normalize-RemotePath $Path
    if (Test-PathWithin -Path $candidate -Root $canonicalRoot) {
        return $logicalRoot + $candidate.Substring($canonicalRoot.Length)
    }
    return $candidate
}

function Set-ThreadAssignments {
    if (-not (Test-Path -LiteralPath $statePath)) {
        throw "Codex state file was not found: $statePath"
    }

    $serializer = New-JsonSerializer
    $state = $serializer.DeserializeObject(
        [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8))
    $hostIds = @(Get-HostIds -State $state)
    if ($hostIds.Count -eq 0) {
        throw "Codex has no saved SSH connection named $HostAlias."
    }
    if (-not $state.ContainsKey('remote-projects')) {
        throw 'Codex has no saved remote projects.'
    }

    $projects = @($state['remote-projects'] | Where-Object {
            $hostIds -contains [string]$_['hostId']
        })
    $rootProject = $projects | Where-Object {
        (Normalize-RemotePath ([string]$_['remotePath'])) -eq $canonicalRoot
    } | Select-Object -First 1
    if (-not $rootProject) {
        throw "Codex canonical root project was not found: $canonicalRoot"
    }

    $threads = @(Get-RemoteThreadIndex -Serializer $serializer)
    if ($threads.Count -eq 0) {
        throw 'No remote Codex thread metadata was found.'
    }

    if (-not $state.ContainsKey($assignmentKey) -or
        $state[$assignmentKey] -isnot [Collections.IDictionary]) {
        $state[$assignmentKey] = @{}
    }
    $assignments = $state[$assignmentKey]
    $assignedCount = 0

    foreach ($thread in $threads) {
        $threadId = [string]$thread['id']
        $cwd = Normalize-RemotePath ([string]$thread['cwd'])
        if (-not $threadId -or -not $cwd) {
            continue
        }

        $project = $projects | Where-Object {
            $projectPath = Normalize-RemotePath ([string]$_['remotePath'])
            $mirroredPath = Get-MirroredRemotePath -Path $projectPath
            (Test-PathWithin -Path $cwd -Root $projectPath) -or
                ($mirroredPath -and
                    (Test-PathWithin -Path $cwd -Root $mirroredPath))
        } | Sort-Object { ([string]$_['remotePath']).Length } -Descending |
            Select-Object -First 1

        if (-not $project -and
            ((Test-PathWithin -Path $cwd -Root $logicalRoot) -or
                (Test-PathWithin -Path $cwd -Root $canonicalRoot))) {
            $project = $rootProject
        }
        if (-not $project) {
            continue
        }

        $assignments[$threadId] = [ordered]@{
            projectKind = 'remote'
            projectId = [string]$project['id']
            path = Get-LogicalRemotePath ([string]$project['remotePath'])
            cwd = $cwd
            hostId = [string]$project['hostId']
            pendingCoreUpdate = $false
        }
        $assignedCount++
    }

    if ($assignedCount -eq 0) {
        throw 'No remote threads matched the configured projects.'
    }

    if (-not $state.ContainsKey($atomContainerKey)) {
        $state[$atomContainerKey] = @{}
    }
    $atoms = $state[$atomContainerKey]
    if (-not $atoms.ContainsKey($sidebarKey) -or
        $atoms[$sidebarKey] -isnot [Collections.IDictionary]) {
        $atoms[$sidebarKey] = @{}
    }
    $sidebar = $atoms[$sidebarKey]
    if (-not $sidebar.ContainsKey('chatSortMode')) {
        $sidebar['chatSortMode'] = 'priority'
    }
    if (-not $sidebar.ContainsKey('projectSortMode')) {
        $sidebar['projectSortMode'] = 'priority'
    }
    $sidebar['initialized'] = $true
    $sidebar['mode'] = 'project'

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safetyCopy = "$statePath.thread-assignment-backup-$timestamp"
    Copy-Item -LiteralPath $statePath -Destination $safetyCopy -Force

    $updatedJson = $serializer.Serialize($state)
    Write-JsonAtomically -Path $statePath -Json $updatedJson
    Write-JsonAtomically -Path $stateBackupPath -Json $updatedJson

    $verified = $serializer.DeserializeObject(
        [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8))
    $verifiedAssignments = $verified[$assignmentKey]
    $verifiedCount = @($verifiedAssignments.Keys | Where-Object {
            $verifiedAssignments[$_]['hostId'] -in $hostIds
        }).Count
    $verifiedRoot = @($verified['remote-projects'] | Where-Object {
            $_['id'] -eq $rootProject['id'] -and
            $_['remotePath'] -eq $canonicalRoot
        }).Count
    if ($verifiedCount -lt $assignedCount -or $verifiedRoot -ne 1) {
        throw 'Thread assignment repair verification failed.'
    }

    Write-RepairLog "DONE host=$HostAlias assigned=$assignedCount root=$canonicalRoot backup=$safetyCopy"
    Write-Host "[OK] Assigned $assignedCount remote threads without changing their cwd."
    Write-Host "[OK] Sidebar paths and execution cwd use $logicalRoot; the saved project ID is unchanged."
    Write-Host "[OK] Backup: $safetyCopy"
}

function Start-IndependentRepair {
    param(
        [int]$ProcessId,
        [bool]$ShouldRestart
    )

    $scheduledTaskName = 'CodexJumpBridge-ThreadAssignmentRepair'
    $existingTask = Get-ScheduledTask -TaskName $scheduledTaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Stop-ScheduledTask -TaskName $scheduledTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $scheduledTaskName -Confirm:$false
    }

    $taskArguments = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
        '-File "{0}" -HostAlias "{1}" -UserName "{2}" ' +
        '-AfterExit -CodexPid {3} -TaskName "{4}"') -f
        $PSCommandPath.Replace('"', ''),
        $HostAlias,
        $UserName,
        $ProcessId,
        $scheduledTaskName
    if ($ThreadIndexPath) {
        $taskArguments += ' -ThreadIndexPath "{0}"' -f $ThreadIndexPath.Replace('"', '')
    }
    if ($ShouldRestart) {
        $taskArguments += ' -Restart'
    }

    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') `
        -Argument $taskArguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(12)
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12)

    Register-ScheduledTask `
        -TaskName $scheduledTaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'One-time Codex remote thread project assignment repair' `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $scheduledTaskName
    return $scheduledTaskName
}

$mainProcess = Get-CodexMainProcess
$codexExecutable = Get-CodexExecutable

if (-not $AfterExit -and $mainProcess) {
    $scheduledTaskName = Start-IndependentRepair `
        -ProcessId $mainProcess.ProcessId `
        -ShouldRestart $Restart.IsPresent
    Write-RepairLog "SCHEDULED task=$scheduledTaskName pid=$($mainProcess.ProcessId) restart=$Restart"
    Write-Host '[READY] Thread assignment repair is queued. Fully exit Codex Desktop once.'
    if ($Restart) {
        Write-Host '[READY] Codex Desktop will reopen after the repair.'
    }
    exit 0
}

$repairError = $null
try {
    if ($AfterExit -and $CodexPid -gt 0) {
        Wait-Process -Id $CodexPid -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
    Set-ThreadAssignments
} catch {
    $repairError = $_
    Write-RepairLog "FAILED $($_.Exception.Message)"
} finally {
    if ($Restart -and $codexExecutable) {
        Start-Process -FilePath $codexExecutable | Out-Null
        Write-RepairLog 'RESTARTED'
    }
    if ($TaskName) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

if ($repairError) {
    throw $repairError
}
