## Codex JumpBridge 1.3.0

首个公开发行版，让 Codex Desktop 通过只提供登录 shell 的集群网关运行远端 app-server。

### 下载

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.3.0.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.3.0.dmg`，将 App 拖入“应用程序”后运行。

安装器会读取本机 `~/.ssh/config`、检查 `IdentityFile` 是否存在，并提示填写集群计算节点访问 OpenAI 的专用代理。发布包不包含任何 Host、IP、代理地址或私钥。

macOS App 尚未使用 Apple Developer ID 签名；首次运行请在 Finder 中右键 App，选择“打开”。
