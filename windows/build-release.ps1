param(
    [string]$Version = '1.4.0',
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist')
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw "C# compiler not found at $compiler"
}

& (Join-Path $PSScriptRoot 'build.ps1') | Out-Null

$work = Join-Path ([IO.Path]::GetTempPath()) (
    'codex-jumpbridge-release-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $work 'payload'
$payloadWindows = Join-Path $payload 'windows'
$payloadShared = Join-Path $payload 'shared'
$payloadZip = Join-Path $work 'payload.zip'

try {
    New-Item -ItemType Directory -Force -Path @(
        $payloadWindows, $payloadShared, $OutputDirectory) | Out-Null

    foreach ($name in @(
        'build.ps1',
        'CodexJumpBridge.cs',
        'codex-jumpbridge.exe',
        'doctor.ps1',
        'install.ps1',
        'repair-thread-assignments.ps1',
        'setup.ps1',
        'uninstall.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) `
            -Destination $payloadWindows -Force
    }
    Copy-Item -LiteralPath (Join-Path $root 'shared\remote-prepare.sh') `
        -Destination $payloadShared -Force

    foreach ($script in Get-ChildItem -LiteralPath $payloadWindows -Filter '*.ps1') {
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count) {
            $parseErrors | Format-List | Out-String | Write-Error
            throw "Packaged PowerShell syntax check failed: $($script.Name)"
        }
    }

    Compress-Archive -Path (Join-Path $payload '*') `
        -DestinationPath $payloadZip -CompressionLevel Optimal

    $output = Join-Path $OutputDirectory (
        "Codex-JumpBridge-Windows-v$Version.exe")
    $references = @(
        '/reference:System.Drawing.dll',
        '/reference:System.IO.Compression.dll',
        '/reference:System.IO.Compression.FileSystem.dll',
        '/reference:System.Windows.Forms.dll'
    )
    $resource = "/resource:$payloadZip,CodexJumpBridge.Payload"
    $compilerArguments = @(
        '/nologo',
        '/optimize+',
        '/target:winexe',
        '/platform:anycpu',
        "/out:$output"
    ) + $references + @(
        $resource,
        (Join-Path $PSScriptRoot 'CodexJumpBridgeSetup.cs')
    )
    & $compiler $compilerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "C# compiler exited with code $LASTEXITCODE"
    }

    $verification = Start-Process -FilePath $output `
        -ArgumentList '--verify-payload' -PassThru -Wait
    if ($verification.ExitCode -ne 0) {
        throw "Packaged installer payload verification failed with code $($verification.ExitCode)"
    }

    Write-Output $output
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
