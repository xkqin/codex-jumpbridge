$ErrorActionPreference = 'Stop'

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$workRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $workRoot ('codex-jumpbridge-clean-' + [Guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
$fakeSource = Join-Path $work 'FakeSsh.cs'
$fakeSsh = Join-Path $work 'fake-ssh.exe'
$fakeLog = Join-Path $work 'fake-ssh.log'
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$savedHomeVariable = $HOME
$savedEnvironment = @{
    USERPROFILE = $env:USERPROFILE
    HOME = $env:HOME
    CODEX_JUMPBRIDGE_REAL_SSH = $env:CODEX_JUMPBRIDGE_REAL_SSH
    CODEX_JUMPBRIDGE_FAKE_LOG = $env:CODEX_JUMPBRIDGE_FAKE_LOG
    CODEX_JUMPBRIDGE_HOSTS = $env:CODEX_JUMPBRIDGE_HOSTS
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.ssh') | Out-Null
    $keyPath = Join-Path $fakeHome '.ssh\id_fixture'
    [IO.File]::WriteAllText($keyPath, 'fixture', [Text.UTF8Encoding]::new($false))
    $sshConfig = @"
Host T209
    HostName 127.0.0.1
    User ci
    IdentityFile $($keyPath.Replace('\', '/'))
Host h-ceph
    HostName 127.0.0.1
    User ci
    IdentityFile $($keyPath.Replace('\', '/'))
"@
    [IO.File]::WriteAllText(
        (Join-Path $fakeHome '.ssh\config'),
        $sshConfig,
        [Text.UTF8Encoding]::new($false))

    @'
using System;
using System.IO;
using System.Text;
using System.Threading;

internal static class FakeSsh
{
    public static int Main(string[] args)
    {
        if (Array.IndexOf(args, "-G") >= 0)
        {
            Console.WriteLine("hostname 127.0.0.1");
            Console.WriteLine("user ci");
            string home = Environment.GetEnvironmentVariable("HOME") ?? String.Empty;
            Console.WriteLine("identityfile " + Path.Combine(home, ".ssh", "id_fixture"));
            return 0;
        }
        if (args.Length != 2 ||
            !String.Equals(args[0], "T209", StringComparison.OrdinalIgnoreCase) ||
            args[1] != "sh")
        {
            return 94;
        }

        string bootstrap = Console.In.ReadLine() ?? String.Empty;
        string log = Environment.GetEnvironmentVariable("CODEX_JUMPBRIDGE_FAKE_LOG");
        if (!String.IsNullOrWhiteSpace(log))
        {
            File.AppendAllText(log,
                "ARGS=" + String.Join("|", args) + Environment.NewLine +
                "BOOTSTRAP=" + bootstrap + Environment.NewLine);
        }
        const string markerPrefix = "__CODEX_T_SSH_START_";
        int markerStart = bootstrap.IndexOf(markerPrefix, StringComparison.OrdinalIgnoreCase);
        int markerEnd = markerStart < 0
            ? -1
            : bootstrap.IndexOf("; cd", markerStart, StringComparison.Ordinal);
        if (markerStart < 0 || markerEnd < 0)
        {
            return 93;
        }
        StringBuilder marker = new StringBuilder(markerPrefix);
        for (int i = markerStart + markerPrefix.Length; i < markerEnd; i++)
        {
            char value = Char.ToLowerInvariant(bootstrap[i]);
            if ((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f'))
            {
                marker.Append(value);
            }
        }
        Console.WriteLine(marker.ToString());
        Console.Out.Flush();

        if (bootstrap.IndexOf("app-server proxy", StringComparison.Ordinal) >= 0)
        {
            Thread.Sleep(250);
            Console.Write(
                "GATE1234HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
            Console.Out.Flush();
            Thread.Sleep(250);
            return 0;
        }

        Console.WriteLine("CODEX_JUMPBRIDGE_REMOTE_OK");
        Console.WriteLine("__CODEX_JUMPBRIDGE_CWD__=/mnt/petrelfs/ci__CODEX_JUMPBRIDGE_HOME__=/mnt/petrelfs/ci__CODEX_JUMPBRIDGE_END__");
        Console.WriteLine("CODEX_JUMPBRIDGE_REMOTE_CODEX=codex-cli fixture");
        Console.WriteLine("CODEX_JUMPBRIDGE_HOME_LAUNCHER=READY");
        Console.WriteLine("CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY");
        Console.WriteLine("CODEX_JUMPBRIDGE_NATIVE_CODEX_HOME=READY");
        Console.WriteLine("CODEX_JUMPBRIDGE_HTTP=401");
        Console.WriteLine("codex-cli fixture");
        Console.Out.Flush();
        return 0;
    }
}
'@ | Set-Content -LiteralPath $fakeSource -Encoding UTF8

    & 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' `
        /nologo /target:exe "/out:$fakeSsh" $fakeSource
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not build the clean-install SSH fixture'
    }

    & (Join-Path $root 'windows\build.ps1') | Out-Null
    $env:USERPROFILE = $fakeHome
    $env:HOME = $fakeHome
    $env:CODEX_JUMPBRIDGE_REAL_SSH = $fakeSsh
    $env:CODEX_JUMPBRIDGE_FAKE_LOG = $fakeLog
    $env:CODEX_JUMPBRIDGE_HOSTS = 'T209'
    Set-Variable HOME -Value $fakeHome -Force
    & (Join-Path $root 'windows\install.ps1') `
        -ProxyUrl 'http://proxy.invalid:8080'

    $installed = Join-Path $fakeHome '.local\bin\ssh.exe'
    if (-not (Test-Path -LiteralPath $installed)) {
        throw 'Clean Windows install did not create ~/.local/bin/ssh.exe'
    }
    $remoteProbe = & $installed T209 'printf CI_PROBE' 2>&1
    if (($remoteProbe | Out-String) -notmatch 'CODEX_JUMPBRIDGE_CODE_MODE_HOST=READY') {
        $logText = if (Test-Path -LiteralPath $fakeLog) {
            Get-Content -LiteralPath $fakeLog -Raw
        } else { '<missing>' }
        throw "Installed Windows wrapper did not reach the SSH fixture. output=$remoteProbe log=$logText"
    }
    $version = (& $installed --codex-jumpbridge-version | Out-String).Trim()
    if ($version -ne 'codex-jumpbridge 1.4.5') {
        throw "Unexpected clean-install version: $version"
    }
    $hosts = @(Get-Content -LiteralPath (Join-Path $fakeHome '.codex-jumpbridge\hosts.txt'))
    if ($hosts.Count -ne 1 -or $hosts[0] -ne 'T209') {
        throw "Clean Windows install wrote unexpected Hosts: $($hosts -join ', ')"
    }
    $proxy = Get-Content -LiteralPath (Join-Path $fakeHome '.codex-jumpbridge\proxies.txt') -Raw
    if ($proxy -notmatch '^T209\thttp://proxy\.invalid:8080') {
        throw 'Clean Windows install did not persist the per-Host proxy'
    }
    if (Test-Path -LiteralPath (Join-Path $fakeHome '.local\bin\codex-jumpbridge-history-sync')) {
        throw 'Clean Windows install recreated the removed history lock helper'
    }
    Write-Host 'WINDOWS_CLEAN_INSTALL_AND_DOCTOR=PASS'
} finally {
    Set-Variable HOME -Value $savedHomeVariable -Force
    [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
    foreach ($name in $savedEnvironment.Keys) {
        $value = $savedEnvironment[$name]
        if ($null -eq $value) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:$name" $value
        }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
