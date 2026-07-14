## Codex JumpBridge 1.4.4

本版本仅修复 macOS 安装与 doctor 进程回收问题，不改变集群节点路由策略：

- 修复 macOS 自带 Bash 3.2 在自动扫描首个 SSH Host 时因空数组触发 `unbound variable`。
- doctor 完成 WebSocket 101 检查后会可靠结束测试 SSH；子进程不响应 TERM 时自动升级为 KILL，避免安装永久卡住。
- macOS wrapper 收到 HUP、INT 或 TERM 后会退出并清理 OpenSSH/输入转发子进程，不再留下失败重试。
- CI 覆盖无 `--host` 自动扫描和不响应 TERM 的测试 SSH，防止上述问题回归。

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.4.4.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.4.4.dmg`，将 App 拖入“应用程序”后运行。

## Codex JumpBridge 1.4.3

本版本把“新用户第一次安装即可连接和对话”纳入 Windows/macOS 自动回归：

- Windows 与 macOS 都会在空安装状态执行真实安装脚本、远端准备和完整 doctor。
- SSH alias 与私钥检查显式使用刚扫描的 `~/.ssh/config`，避免 Codex HOME 与系统默认目录不一致时误判。
- 继续直接使用远端原生 `~/.codex`，不恢复共享历史锁；多个计算节点仍可同时在线。
- 已验证 Desktop WebSocket 协议可完成 `initialize`、`thread/start`、`turn/start` 并收到模型回复。

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.4.3.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.4.3.dmg`，将 App 拖入“应用程序”后运行。

## Codex JumpBridge 1.4.2

本版本移除运行时共享历史锁，让多个计算节点按 VS Code/Cursor Codex 插件的方式直接使用
远端原生 `~/.codex`：

- 208/209/210 等多个 SSH Host 可以同时连接，不再因其他 Host 在线返回退出码 87。
- 每个 Host 继续使用节点本地 app-server socket，同时保留登录 Shell、启动门、WebSocket、代理和进程清理修复。
- Windows/macOS 安装器不再上传或启动共享历史 helper，doctor 会明确验证原生 `~/.codex`。
- 从 `v1.4.1` 升级时，只补回旧专用 master 中缺失的 session 和索引记录，不覆盖或删除原有历史。

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.4.2.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.4.2.dmg`，将 App 拖入“应用程序”后运行。

## Codex JumpBridge 1.4.1

本版本修复新版 Codex Desktop 下的 SSH 连接与历史加载稳定性问题：

- 保留 `~/.ssh/config` 中 Host alias 的原始大小写，兼容 Codex 的小写化行为。
- 旧历史在安装阶段一次合并，连接时直接使用互斥保护的专用主历史，避免共享存储扫描超过 websocket 超时。
- 兼容新版 Desktop 的嵌套登录 Shell 启动格式，并在历史准备前正确返回 8 字节启动门。
- Windows wrapper 退出时自动结束其 OpenSSH 子进程，防止失败重试堆积。
- Windows 安装后广播 PATH 变化；macOS 同步更新登录环境，避免 Codex 重启后仍调用系统 SSH。
- Windows 安装器按文件内容更新同版本热修复；macOS 修复单 Host 配置解析。
- Windows/macOS doctor 只有完成真实 Desktop 启动门与 WebSocket 101 检查后才报告 `READY`。

- **Windows 10/11：**运行 `Codex-JumpBridge-Windows-v1.4.1.exe`。
- **macOS 11+：**打开 `Codex-JumpBridge-macOS-v1.4.1.dmg`，将 App 拖入“应用程序”后运行。

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
