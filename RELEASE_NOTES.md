## Codex JumpBridge 1.4.0

这一版是当前稳定 1.3 系列的冻结快照与正式版本升级。它保留已经实际跑通的
SSH 登录 Shell 适配、双向 app-server 数据流、网关提示过滤、多 Host 连接、
远端 MCP 隔离和代理注入，不引入新的历史数据库同步架构，也不改变普通 SSH。

### 下载

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.4.0.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.4.0.dmg`，将 App 拖入“应用程序”后运行。
- 下载后请使用同一 Release 中的 `SHA256SUMS.txt` 核对文件哈希。

### 本版说明

- 每个 Host 保持独立的 app-server 会话，多个 SSH 连接可同时使用。
- 保持 Codex 原生 app-server 双向协议，不增加 HTTP/WebSocket 转换层。
- 保持 1.3 的远端 `~/.codex` 使用方式，不复制、打包或上传个人对话数据库。
- 远端 MCP 默认关闭，避免不可达的 MCP 服务阻塞新建任务。
- 安装器扫描本机 `~/.ssh/config`，只检查 `IdentityFile` 是否存在，不读取私钥。
- 发布包不包含 Host、IP、代理地址、用户名或私钥。

> [!WARNING]
> Windows 和 macOS 安装包暂未进行商业代码签名。若内部杀毒软件、SmartScreen 或
> Gatekeeper 拦截，请在核对 SHA256 后仅允许 JumpBridge 安装程序/App 和安装后的
> SSH wrapper；不要关闭杀毒软件或放行整个目录。

macOS 首次运行若被拦截，请在 Finder 中右键 App，选择“打开”。
