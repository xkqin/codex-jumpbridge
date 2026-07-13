## Codex JumpBridge 1.3.3

这一版保持每条 SSH 连接独立启动远端 Codex app-server，并适配当前 Codex Desktop
的远端启动流程。它会过滤集群网关在协议启动前输出的登录提示，降低连接更新失败、
新建任务超时和历史任务无法继续的概率。

### 下载

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.3.3.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.3.3.dmg`，将 App 拖入“应用程序”后运行。
- 下载后请使用同一 Release 中的 `SHA256SUMS.txt` 核对文件哈希。

### 本版说明

- 每个 Host 保持独立的 app-server 会话，多个 SSH 连接可同时使用。
- 远端 MCP 默认关闭，避免不可达的 MCP 服务阻塞新建任务。
- 安装器扫描本机 `~/.ssh/config`，只检查 `IdentityFile` 是否存在，不读取私钥。
- 发布包不包含 Host、IP、代理地址、用户名或私钥。

> [!WARNING]
> Windows 和 macOS 安装包暂未进行商业代码签名。若内部杀毒软件、SmartScreen 或
> Gatekeeper 拦截，请在核对 SHA256 后仅允许 JumpBridge 安装程序/App 和安装后的
> SSH wrapper；不要关闭杀毒软件或放行整个目录。受统一策略管理的电脑请联系内部 IT。

macOS 首次运行若被拦截，请在 Finder 中右键 App，选择“打开”。
