## Codex JumpBridge 1.3.1

精简版连接桥，只适配 T 集群 SSH 命令传输、远端 Codex 运行文件和 OpenAI 专用代理。

### 下载

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.3.1.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.3.1.dmg`，将 App 拖入“应用程序”后运行。

安装器会读取本机 `~/.ssh/config`、检查 `IdentityFile` 是否存在，并提示填写集群计算节点访问 OpenAI 的专用代理。发布包不包含任何 Host、IP、代理地址或私钥。

本版不再改写远端 `HOME`、`PWD` 或项目路径，并移除了对话归组修复器。

从旧版升级时，请先完全退出 Codex Desktop，再运行安装程序。

macOS App 尚未使用 Apple Developer ID 签名；首次运行请在 Finder 中右键 App，选择“打开”。
