## Codex JumpBridge 1.4.0

这一版保留已经跑通的 SSH 登录 Shell 适配、双向 app-server 数据流、网关提示过滤、
多 Host 连接、远端 MCP 隔离、代理注入和普通 SSH 直通，并为每个 SSH Host 隔离
Codex 运行数据库。连接与断开时会同步远端对话历史，解决多个计算节点共用
`~/.codex/state_5.sqlite` 时出现的任务归组错乱、重启后“无任务”和 thread 冲突。

### 下载

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.4.0.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.4.0.dmg`，将 App 拖入“应用程序”后运行。
- 下载后请使用同一 Release 中的 `SHA256SUMS.txt` 核对文件哈希。

### 本版说明

- 每个 Host 使用独立的 app-server 和 SQLite；rollout 历史在连接时同步、断开时回写。
- 远端 `~/.codex` 仅作为只读导入源；自动同步不会覆盖 VS Code/Cursor 正在使用的历史文件。
- app-server 使用节点本地短 socket 路径，安装和 doctor 都会先执行真实 AF_UNIX bind 检查。
- 同一集群账号一次只激活一个历史 Host；第二个连接会被互斥锁拒绝，避免 thread 重复加载。
- 保留旧版兼容回退；远端助手缺失或显式关闭历史同步时，仍使用原 app-server 启动链。
- 保持 Codex 原生 app-server 双向协议，不增加 HTTP/WebSocket 转换层。
- 远端 MCP 默认关闭，避免不可达的 MCP 服务阻塞新建任务。
- 安装器扫描本机 `~/.ssh/config`，只检查 `IdentityFile` 是否存在，不读取私钥。
- 发布包不包含 Host、IP、代理地址、用户名或私钥。

> [!WARNING]
> Windows 安装包暂未签名；macOS App 仅进行 ad-hoc 签名，未进行 Apple Developer ID
> 公证。若内部杀毒软件、SmartScreen 或
> Gatekeeper 拦截，请在核对 SHA256 后仅允许 JumpBridge 安装程序/App 和安装后的
> SSH wrapper；不要关闭杀毒软件或放行整个目录。

macOS 首次运行若被拦截，请在 Finder 中右键 App，选择“打开”。
