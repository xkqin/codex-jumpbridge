$ErrorActionPreference = 'Stop'

$wrapper = Join-Path $HOME '.local\bin\ssh.exe'
$backupDir = Join-Path $HOME '.codex-jumpbridge\backup'

if (Test-Path -LiteralPath $wrapper) {
    $version = & $wrapper --codex-jumpbridge-version 2>$null
    if ($LASTEXITCODE -eq 0 -and $version -match '^codex-jumpbridge ') {
        Remove-Item -LiteralPath $wrapper -Force
        Write-Host '[OK] Removed Codex JumpBridge ssh.exe'
    } else {
        throw 'Refusing to remove ssh.exe because it is not Codex JumpBridge.'
    }
}

$backup = Get-ChildItem -LiteralPath $backupDir -Filter 'ssh.exe.*' -File `
    -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($backup) {
    Copy-Item -LiteralPath $backup.FullName -Destination $wrapper
    Write-Host "[OK] Restored previous ssh.exe from $($backup.Name)"
}

foreach ($helper in @(
    'codex-jumpbridge-doctor.ps1',
    'codex-jumpbridge-setup.ps1',
    'codex-jumpbridge-remote-prepare.sh',
    'codex-jumpbridge-repair-thread-assignments.ps1'
)) {
    Remove-Item -LiteralPath (Join-Path (Split-Path $wrapper) $helper) -Force -ErrorAction SilentlyContinue
}

$legacyTaskName = 'CodexJumpBridge-ThreadAssignmentRepair'
if (Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
}

Write-Host '[OK] SSH config, keys, remote files, and local Codex history were not changed.'
