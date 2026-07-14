using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class CodexJumpBridgeSetup
{
    private const string Version = "1.4.3";
    private const string PayloadResource = "CodexJumpBridge.Payload";

    [STAThread]
    public static int Main(string[] commandLineArgs)
    {
        if (commandLineArgs.Length == 1 &&
            commandLineArgs[0] == "--verify-payload")
        {
            return VerifyEmbeddedPayload();
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        Form progress = CreateProgressForm();
        Label status = (Label)progress.Controls[0];
        progress.Show();
        Application.DoEvents();

        string workDirectory = Path.Combine(
            Path.GetTempPath(),
            "CodexJumpBridge-" + Guid.NewGuid().ToString("N"));

        try
        {
            status.Text = "正在准备 Codex JumpBridge 安装文件...";
            ExtractPayload(workDirectory);

            string installScript = Path.Combine(
                workDirectory, "windows", "install.ps1");
            if (!File.Exists(installScript))
            {
                throw new FileNotFoundException(
                    "安装载荷中缺少 windows/install.ps1。", installScript);
            }

            status.Text = "正在扫描 SSH 配置并启动连接设置...";
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");
            startInfo.Arguments =
                "-Sta -NoProfile -ExecutionPolicy Bypass -File " +
                QuoteWindowsArgument(installScript);
            startInfo.WorkingDirectory = workDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            StringBuilder output = new StringBuilder();
            using (Process installer = new Process())
            {
                installer.StartInfo = startInfo;
                installer.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
                {
                    if (args.Data != null)
                    {
                        lock (output)
                        {
                            output.AppendLine(args.Data);
                        }
                    }
                };
                installer.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
                {
                    if (args.Data != null)
                    {
                        lock (output)
                        {
                            output.AppendLine(args.Data);
                        }
                    }
                };

                if (!installer.Start())
                {
                    throw new InvalidOperationException("无法启动 PowerShell 安装器。");
                }
                installer.BeginOutputReadLine();
                installer.BeginErrorReadLine();

                while (!installer.WaitForExit(100))
                {
                    Application.DoEvents();
                }
                installer.WaitForExit();

                if (installer.ExitCode != 0)
                {
                    string details = output.ToString();
                    string friendlyError = FindMarkedError(details);
                    throw new InvalidOperationException(
                        friendlyError ??
                        ("安装器返回错误代码 " + installer.ExitCode + "。\r\n\r\n" +
                         Tail(details, 4000)));
                }
            }

            progress.Close();
            MessageBox.Show(
                "Codex JumpBridge 已安装完成。\r\n\r\n" +
                "请完全退出并重新打开 Codex Desktop，再添加远程项目。",
                "Codex JumpBridge " + Version,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return 0;
        }
        catch (Exception ex)
        {
            progress.Close();
            MessageBox.Show(
                ex.Message,
                "Codex JumpBridge 安装失败",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try
            {
                if (Directory.Exists(workDirectory))
                {
                    Directory.Delete(workDirectory, true);
                }
            }
            catch
            {
            }
        }
    }

    private static int VerifyEmbeddedPayload()
    {
        string workDirectory = Path.Combine(
            Path.GetTempPath(),
            "CodexJumpBridgeVerify-" + Guid.NewGuid().ToString("N"));
        try
        {
            ExtractPayload(workDirectory);
            string[] required =
            {
                Path.Combine(workDirectory, "windows", "install.ps1"),
                Path.Combine(workDirectory, "windows", "setup.ps1"),
                Path.Combine(workDirectory, "windows", "codex-jumpbridge.exe"),
                Path.Combine(workDirectory, "shared", "remote-prepare.sh")
            };
            foreach (string path in required)
            {
                if (!File.Exists(path))
                {
                    return 2;
                }
            }
            return 0;
        }
        catch
        {
            return 1;
        }
        finally
        {
            try
            {
                if (Directory.Exists(workDirectory))
                {
                    Directory.Delete(workDirectory, true);
                }
            }
            catch
            {
            }
        }
    }

    private static Form CreateProgressForm()
    {
        Form form = new Form();
        form.Text = "Codex JumpBridge " + Version;
        form.ClientSize = new Size(500, 120);
        form.FormBorderStyle = FormBorderStyle.FixedDialog;
        form.MaximizeBox = false;
        form.MinimizeBox = false;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.Font = new Font("Microsoft YaHei UI", 10F);

        Label status = new Label();
        status.Location = new Point(24, 22);
        status.Size = new Size(452, 28);
        status.Text = "正在启动...";
        form.Controls.Add(status);

        ProgressBar bar = new ProgressBar();
        bar.Location = new Point(24, 64);
        bar.Size = new Size(452, 22);
        bar.Style = ProgressBarStyle.Marquee;
        bar.MarqueeAnimationSpeed = 25;
        form.Controls.Add(bar);

        return form;
    }

    private static void ExtractPayload(string destination)
    {
        Directory.CreateDirectory(destination);
        Stream resource = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream(PayloadResource);
        if (resource == null)
        {
            throw new InvalidDataException("安装程序内嵌载荷缺失。");
        }

        string root = Path.GetFullPath(destination + Path.DirectorySeparatorChar);
        using (resource)
        using (ZipArchive archive = new ZipArchive(resource, ZipArchiveMode.Read))
        {
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                string outputPath = Path.GetFullPath(
                    Path.Combine(destination, entry.FullName));
                if (!outputPath.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("安装载荷包含无效路径。");
                }

                if (String.IsNullOrEmpty(entry.Name))
                {
                    Directory.CreateDirectory(outputPath);
                    continue;
                }

                string parent = Path.GetDirectoryName(outputPath);
                if (!String.IsNullOrEmpty(parent))
                {
                    Directory.CreateDirectory(parent);
                }
                entry.ExtractToFile(outputPath, true);
            }
        }
    }

    private static string Tail(string value, int maximumLength)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            return "没有更多错误输出。";
        }
        string trimmed = value.Trim();
        return trimmed.Length <= maximumLength
            ? trimmed
            : trimmed.Substring(trimmed.Length - maximumLength);
    }

    private static string FindMarkedError(string output)
    {
        const string Marker = "CODEX_JUMPBRIDGE_ERROR=";
        if (String.IsNullOrEmpty(output))
        {
            return null;
        }

        string[] lines = output.Replace("\r", String.Empty).Split('\n');
        for (int i = lines.Length - 1; i >= 0; i--)
        {
            if (lines[i].StartsWith(Marker, StringComparison.Ordinal))
            {
                string message = lines[i].Substring(Marker.Length).Trim();
                if (message == "CODEX_JUMPBRIDGE_RUNTIME_IN_USE")
                {
                    return "Codex 正在使用旧版 JumpBridge。请完全退出 Codex Desktop 后重新运行安装器。";
                }
                return message;
            }
        }
        return null;
    }

    private static string QuoteWindowsArgument(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
