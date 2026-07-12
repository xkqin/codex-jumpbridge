$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'CodexJumpBridge.cs'
$output = Join-Path $PSScriptRoot 'codex-jumpbridge.exe'
$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "C# compiler not found at $compiler"
}

& $compiler /nologo /optimize+ /target:exe "/out:$output" $source
if ($LASTEXITCODE -ne 0) {
    throw "C# compiler exited with code $LASTEXITCODE"
}

Write-Output $output
