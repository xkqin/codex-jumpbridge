using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

internal static class CodexJumpBridge
{
    private static readonly string RealSsh = ResolveRealSsh();

    private static readonly HashSet<string> TClusterAliases =
        LoadJumpBridgeHosts();

    private static readonly HashSet<string> OptionsWithSeparateValue =
        new HashSet<string>(StringComparer.Ordinal)
        {
            "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i",
            "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R",
            "-S", "-W", "-w"
        };

    public static int Main(string[] args)
    {
        if (args.Length == 1 &&
            (args[0] == "--codex-jumpbridge-version" ||
             args[0] == "--codex-t-wrapper-version"))
        {
            Console.WriteLine("codex-jumpbridge 1.3.0");
            return 0;
        }

        int hostIndex = FindHostIndex(args);
        bool isTCluster = hostIndex >= 0 && TClusterAliases.Contains(args[hostIndex]);
        bool hasRemoteCommand = hostIndex >= 0 && hostIndex + 1 < args.Length;

        if (!isTCluster || !hasRemoteCommand || IsPlainShCommand(args, hostIndex))
        {
            return RunPassThrough(args);
        }

        string remoteCommand = JoinRemoteCommand(args, hostIndex + 1);
        string[] sshArgs = new string[hostIndex + 2];
        Array.Copy(args, sshArgs, hostIndex + 1);
        sshArgs[hostIndex + 1] = "sh";

        return RunThroughLoginShell(sshArgs, remoteCommand, args[hostIndex]);
    }

    private static string ResolveRealSsh()
    {
        string configured = Environment.GetEnvironmentVariable(
            "CODEX_JUMPBRIDGE_REAL_SSH");
        if (!String.IsNullOrWhiteSpace(configured))
        {
            return configured.Trim();
        }

        string windows = Environment.GetFolderPath(
            Environment.SpecialFolder.Windows);
        return Path.Combine(windows, "System32", "OpenSSH", "ssh.exe");
    }

    private static HashSet<string> LoadJumpBridgeHosts()
    {
        HashSet<string> hosts = new HashSet<string>(
            StringComparer.OrdinalIgnoreCase);

        AddHosts(
            hosts,
            Environment.GetEnvironmentVariable("CODEX_JUMPBRIDGE_HOSTS"));

        string userProfile = Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile);
        AddHostsFromFile(
            hosts,
            Path.Combine(userProfile, ".codex-jumpbridge", "hosts.txt"));
        AddHostsFromFile(
            hosts,
            Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "codex-jumpbridge-hosts.txt"));

        return hosts;
    }

    private static void AddHostsFromFile(
        HashSet<string> hosts,
        string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return;
            }

            foreach (string line in File.ReadAllLines(path))
            {
                string value = line.Trim();
                if (value.Length == 0 || value.StartsWith("#"))
                {
                    continue;
                }
                hosts.Add(value);
            }
        }
        catch
        {
            // A bad optional config must not break ordinary SSH passthrough.
        }
    }

    private static void AddHosts(HashSet<string> hosts, string value)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            return;
        }

        foreach (string item in value.Split(
            new[] { ',', ';', '\r', '\n' },
            StringSplitOptions.RemoveEmptyEntries))
        {
            string host = item.Trim();
            if (host.Length > 0)
            {
                hosts.Add(host);
            }
        }
    }

    private static int FindHostIndex(string[] args)
    {
        bool afterDoubleDash = false;

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];

            if (afterDoubleDash)
            {
                return i;
            }

            if (arg == "--")
            {
                afterDoubleDash = true;
                continue;
            }

            if (!arg.StartsWith("-", StringComparison.Ordinal) || arg == "-")
            {
                return i;
            }

            if (OptionsWithSeparateValue.Contains(arg))
            {
                i++;
            }
        }

        return -1;
    }

    private static bool IsPlainShCommand(string[] args, int hostIndex)
    {
        return args.Length == hostIndex + 2 && args[hostIndex + 1] == "sh";
    }

    private static string JoinRemoteCommand(string[] args, int startIndex)
    {
        StringBuilder result = new StringBuilder();
        for (int i = startIndex; i < args.Length; i++)
        {
            if (result.Length > 0)
            {
                result.Append(' ');
            }
            result.Append(args[i]);
        }
        return result.ToString();
    }

    private static int RunPassThrough(string[] args)
    {
        ProcessStartInfo startInfo = CreateStartInfo(args, false);
        try
        {
            using (Process child = Process.Start(startInfo))
            {
                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ssh wrapper failed to start the Windows SSH client: " + ex.Message);
            return 255;
        }
    }

    private static int RunThroughLoginShell(
        string[] sshArgs,
        string remoteCommand,
        string hostAlias)
    {
        ProcessStartInfo startInfo = CreateStartInfo(sshArgs, true);
        bool isStreamingProxy = remoteCommand.IndexOf(
            "app-server proxy",
            StringComparison.Ordinal) >= 0;
        bool launchesAppServer = remoteCommand.IndexOf(
            "app-server",
            StringComparison.Ordinal) >= 0;
        string configuredProxy = launchesAppServer
            ? LoadProxyForHost(hostAlias)
            : null;
        string proxyExports = BuildProxyExports(configuredProxy);

        try
        {
            using (Process child = Process.Start(startInfo))
            {
                string completionPrefix = "__CODEX_T_SSH_DONE_" +
                    Guid.NewGuid().ToString("N") + ":";
                string startMarker = "__CODEX_T_SSH_START_" +
                    Guid.NewGuid().ToString("N");
                int completionSplit = completionPrefix.Length / 2;
                string completionPrefixFirst = completionPrefix.Substring(0, completionSplit);
                string completionPrefixSecond = completionPrefix.Substring(completionSplit);
                int startSplit = startMarker.Length / 2;
                string startMarkerFirst = startMarker.Substring(0, startSplit);
                string startMarkerSecond = startMarker.Substring(startSplit);
                CompletionMarkerRelay stdoutRelay = new CompletionMarkerRelay(
                    child.StandardOutput.BaseStream,
                    Console.OpenStandardOutput(),
                    startMarker,
                    isStreamingProxy ? null : completionPrefix);
                Thread stdoutThread = stdoutRelay.Start();
                Thread stderrThread = StartCopyThread(
                    child.StandardError.BaseStream,
                    Console.OpenStandardError());

                string wrappedCommand;
                string startCommand =
                    "printf '%s%s\\n' " + PosixSingleQuote(startMarkerFirst) + " " +
                    PosixSingleQuote(startMarkerSecond) + "; ";
                string homeCommand = "cd \"$HOME\" || exit 1; ";
                if (isStreamingProxy)
                {
                    wrappedCommand = startCommand +
                        homeCommand +
                        proxyExports +
                        "export CODEX_HOME=\"${CODEX_HOME:-$HOME/.codex}\"; " +
                        "exec /bin/sh -c " + PosixSingleQuote(remoteCommand);
                }
                else
                {
                    wrappedCommand = startCommand +
                        homeCommand +
                        proxyExports +
                        "/bin/sh -c " + PosixSingleQuote(remoteCommand) +
                        "; __codex_t_rc=$?; printf '%s%s%d\\n' " +
                        PosixSingleQuote(completionPrefixFirst) + " " +
                        PosixSingleQuote(completionPrefixSecond) +
                        " \"$__codex_t_rc\"";
                }
                byte[] bootstrap = new UTF8Encoding(false).GetBytes(
                    "exec /bin/sh -c " + PosixSingleQuote(wrappedCommand) + "\n");
                child.StandardInput.BaseStream.Write(bootstrap, 0, bootstrap.Length);
                child.StandardInput.BaseStream.Flush();

                ManualResetEvent processExited = new ManualResetEvent(false);
                Thread processWaitThread = new Thread(delegate()
                {
                    try
                    {
                        child.WaitForExit();
                    }
                    finally
                    {
                        processExited.Set();
                    }
                });
                processWaitThread.IsBackground = true;
                processWaitThread.Start();

                int started = WaitHandle.WaitAny(
                    new WaitHandle[] { stdoutRelay.StartEvent, processExited },
                    30000);
                if (started == 0)
                {
                    StartInputThread(
                        Console.OpenStandardInput(),
                        child.StandardInput.BaseStream);
                }
                else if (started == 1)
                {
                    stdoutThread.Join(2000);
                    stderrThread.Join(2000);
                    return child.ExitCode;
                }
                else
                {
                    throw new IOException("Timed out waiting for the remote T-cluster shell bootstrap");
                }

                int completed = isStreamingProxy
                    ? WaitHandle.WaitAny(new WaitHandle[] { processExited })
                    : WaitHandle.WaitAny(
                        new WaitHandle[] { stdoutRelay.CompletionEvent, processExited });
                int result;

                if (!isStreamingProxy && completed == 0)
                {
                    result = stdoutRelay.RemoteExitCode;
                    try
                    {
                        child.Kill();
                    }
                    catch
                    {
                    }
                    processExited.WaitOne(5000);
                }
                else
                {
                    result = child.ExitCode;
                }

                stdoutThread.Join(2000);
                stderrThread.Join(2000);
                return result;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ssh wrapper failed while adapting the T-cluster command: " + ex.Message);
            return 255;
        }
    }

    private static string LoadProxyForHost(string hostAlias)
    {
        string environmentProxy = NormalizeProxyUrl(
            Environment.GetEnvironmentVariable("CODEX_JUMPBRIDGE_PROXY"));
        if (environmentProxy != null)
        {
            return environmentProxy;
        }

        string userProfile = Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile);
        string path = Path.Combine(
            userProfile,
            ".codex-jumpbridge",
            "proxies.txt");

        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            foreach (string rawLine in File.ReadAllLines(path))
            {
                string line = rawLine.Trim();
                if (line.Length == 0 || line.StartsWith("#"))
                {
                    continue;
                }

                int separator = line.IndexOf('\t');
                if (separator < 0)
                {
                    separator = line.IndexOf('=');
                }
                if (separator <= 0)
                {
                    continue;
                }

                string configuredHost = line.Substring(0, separator).Trim();
                if (!String.Equals(
                    configuredHost,
                    hostAlias,
                    StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                return NormalizeProxyUrl(line.Substring(separator + 1));
            }
        }
        catch
        {
            // Proxy configuration is optional; ordinary SSH must still work.
        }

        return null;
    }

    private static string NormalizeProxyUrl(string value)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        string candidate = value.Trim();
        foreach (char ch in candidate)
        {
            if (Char.IsControl(ch))
            {
                return null;
            }
        }

        Uri proxyUri;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out proxyUri) ||
            (proxyUri.Scheme != Uri.UriSchemeHttp &&
             proxyUri.Scheme != Uri.UriSchemeHttps) ||
            String.IsNullOrWhiteSpace(proxyUri.Host) ||
            !String.IsNullOrEmpty(proxyUri.UserInfo))
        {
            return null;
        }

        return candidate;
    }

    private static string BuildProxyExports(string proxyUrl)
    {
        if (proxyUrl == null)
        {
            return String.Empty;
        }

        string quoted = PosixSingleQuote(proxyUrl);
        return "export HTTP_PROXY=" + quoted +
            " HTTPS_PROXY=" + quoted +
            " http_proxy=" + quoted +
            " https_proxy=" + quoted + "; ";
    }

    private static ProcessStartInfo CreateStartInfo(string[] args, bool redirectStreams)
    {
        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = RealSsh;
        startInfo.Arguments = BuildWindowsCommandLine(args);
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = redirectStreams;
        startInfo.RedirectStandardInput = redirectStreams;
        startInfo.RedirectStandardOutput = redirectStreams;
        startInfo.RedirectStandardError = redirectStreams;
        return startInfo;
    }

    private static Thread StartCopyThread(Stream source, Stream destination)
    {
        Thread thread = new Thread(delegate()
        {
            try
            {
                source.CopyTo(destination);
                destination.Flush();
            }
            catch (IOException)
            {
            }
            catch (ObjectDisposedException)
            {
            }
        });
        thread.IsBackground = true;
        thread.Start();
        return thread;
    }

    private static Thread StartInputThread(Stream source, Stream destination)
    {
        Thread thread = new Thread(delegate()
        {
            try
            {
                byte[] buffer = new byte[4096];
                int count;
                while ((count = source.Read(buffer, 0, buffer.Length)) > 0)
                {
                    destination.Write(buffer, 0, count);
                    destination.Flush();
                }
            }
            catch (IOException)
            {
            }
            catch (ObjectDisposedException)
            {
            }
            finally
            {
                try
                {
                    destination.Close();
                }
                catch
                {
                }
            }
        });
        thread.IsBackground = true;
        thread.Start();
        return thread;
    }

    private static string PosixSingleQuote(string value)
    {
        return "'" + value.Replace("'", "'\\''") + "'";
    }

    private static string BuildWindowsCommandLine(string[] args)
    {
        StringBuilder commandLine = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0)
            {
                commandLine.Append(' ');
            }
            commandLine.Append(QuoteWindowsArgument(args[i]));
        }
        return commandLine.ToString();
    }

    private static string QuoteWindowsArgument(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return value;
        }

        StringBuilder quoted = new StringBuilder();
        quoted.Append('"');
        int backslashes = 0;

        foreach (char ch in value)
        {
            if (ch == '\\')
            {
                backslashes++;
                continue;
            }

            if (ch == '"')
            {
                quoted.Append('\\', backslashes * 2 + 1);
                quoted.Append('"');
                backslashes = 0;
                continue;
            }

            quoted.Append('\\', backslashes);
            backslashes = 0;
            quoted.Append(ch);
        }

        quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private sealed class CompletionMarkerRelay
    {
        private readonly Stream source;
        private readonly Stream destination;
        private readonly byte[] startMarker;
        private readonly byte[] prefix;
        private readonly ManualResetEvent startEvent = new ManualResetEvent(false);
        private readonly ManualResetEvent completionEvent = new ManualResetEvent(false);
        private int remoteExitCode = 255;

        public CompletionMarkerRelay(
            Stream source,
            Stream destination,
            string startMarker,
            string prefix)
        {
            this.source = source;
            this.destination = destination;
            this.startMarker = Encoding.ASCII.GetBytes(startMarker);
            this.prefix = prefix == null ? null : Encoding.ASCII.GetBytes(prefix);
        }

        public WaitHandle StartEvent
        {
            get { return startEvent; }
        }

        public WaitHandle CompletionEvent
        {
            get { return completionEvent; }
        }

        public int RemoteExitCode
        {
            get { return remoteExitCode; }
        }

        public Thread Start()
        {
            Thread thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
            return thread;
        }

        private void Run()
        {
            List<byte> pending = new List<byte>();
            byte[] chunk = new byte[8192];
            bool started = false;

            try
            {
                while (true)
                {
                    int count = source.Read(chunk, 0, chunk.Length);
                    if (count <= 0)
                    {
                        FlushPending(pending);
                        return;
                    }

                    for (int i = 0; i < count; i++)
                    {
                        pending.Add(chunk[i]);
                    }

                    if (!started)
                    {
                        int startIndex = IndexOf(pending, startMarker);
                        if (startIndex >= 0)
                        {
                            WriteRange(pending, 0, startIndex);
                            int startEnd = startIndex + startMarker.Length;
                            if (startEnd < pending.Count && pending[startEnd] == (byte)'\r')
                            {
                                startEnd++;
                            }
                            if (startEnd < pending.Count && pending[startEnd] == (byte)'\n')
                            {
                                startEnd++;
                            }
                            pending.RemoveRange(0, startEnd);
                            destination.Flush();
                            started = true;
                            startEvent.Set();
                        }
                        else
                        {
                            int safeStartCount = pending.Count - (startMarker.Length - 1);
                            if (safeStartCount > 0)
                            {
                                WriteRange(pending, 0, safeStartCount);
                                pending.RemoveRange(0, safeStartCount);
                            }
                            continue;
                        }
                    }

                    if (prefix == null)
                    {
                        WriteRange(pending, 0, pending.Count);
                        pending.Clear();
                        destination.Flush();
                        continue;
                    }

                    int markerIndex = IndexOf(pending, prefix);
                    if (markerIndex >= 0)
                    {
                        WriteRange(pending, 0, markerIndex);
                        int codeStart = markerIndex + prefix.Length;
                        int newlineIndex = IndexOfByte(pending, (byte)'\n', codeStart);

                        while (newlineIndex < 0)
                        {
                            count = source.Read(chunk, 0, chunk.Length);
                            if (count <= 0)
                            {
                                return;
                            }
                            for (int i = 0; i < count; i++)
                            {
                                pending.Add(chunk[i]);
                            }
                            newlineIndex = IndexOfByte(pending, (byte)'\n', codeStart);
                        }

                        string codeText = Encoding.ASCII.GetString(
                            pending.GetRange(codeStart, newlineIndex - codeStart).ToArray());
                        int parsedCode;
                        if (int.TryParse(codeText, out parsedCode))
                        {
                            remoteExitCode = parsedCode;
                        }
                        destination.Flush();
                        completionEvent.Set();
                        return;
                    }

                    int safeCount = pending.Count - (prefix.Length - 1);
                    if (safeCount > 0)
                    {
                        WriteRange(pending, 0, safeCount);
                        pending.RemoveRange(0, safeCount);
                    }
                }
            }
            catch (IOException)
            {
            }
            catch (ObjectDisposedException)
            {
            }
        }

        private void FlushPending(List<byte> pending)
        {
            WriteRange(pending, 0, pending.Count);
            destination.Flush();
        }

        private void WriteRange(List<byte> data, int index, int count)
        {
            if (count <= 0)
            {
                return;
            }
            byte[] bytes = data.GetRange(index, count).ToArray();
            destination.Write(bytes, 0, bytes.Length);
        }

        private static int IndexOf(List<byte> data, byte[] value)
        {
            int last = data.Count - value.Length;
            for (int i = 0; i <= last; i++)
            {
                bool match = true;
                for (int j = 0; j < value.Length; j++)
                {
                    if (data[i + j] != value[j])
                    {
                        match = false;
                        break;
                    }
                }
                if (match)
                {
                    return i;
                }
            }
            return -1;
        }

        private static int IndexOfByte(List<byte> data, byte value, int start)
        {
            for (int i = start; i < data.Count; i++)
            {
                if (data[i] == value)
                {
                    return i;
                }
            }
            return -1;
        }
    }
}
