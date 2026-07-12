## Codex JumpBridge 1.3.2

本版修复 v1.3.1 中远端任务无法创建、续接或保存的 app-server 会话回归。

### 下载

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.3.2.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.3.2.dmg`，将 App 拖入“应用程序”后运行。

安装器会读取本机 `~/.ssh/config`、检查 `IdentityFile` 是否存在，并提示填写集群计算节点访问 OpenAI 的专用代理。发布包不包含任何 Host、IP、代理地址或私钥。

JumpBridge 仅在启动远端 Codex app-server 时进入 `$HOME`，以稳定使用 `~/.codex` 会话库；
普通 SSH 命令和用户选择的项目路径不会被改写。对话归组修复器仍保持移除。

doctor 现在会同时验证远端启动器、运行文件和 app-server 工作目录，避免连接在线但任务无法续接。

从旧版升级时，请先完全退出 Codex Desktop，再运行安装程序。

macOS App 尚未使用 Apple Developer ID 签名；首次运行请在 Finder 中右键 App，选择“打开”。
