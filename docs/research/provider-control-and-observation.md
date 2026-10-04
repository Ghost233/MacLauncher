# 终端服务与 Socktainer 的控制、状态和日志边界

研究时间：2026-10-04。对应 [核实终端服务与 Socktainer 的控制、状态和日志边界](https://github.com/Ghost233/MacLauncher/issues/4)，父地图为 [规划 MacLauncher：个人启动器、独立运行与 SDK 接管](https://github.com/Ghost233/MacLauncher/issues/1)。术语遵循根目录 `CONTEXT.md`；“终端服务”指通过命令启动的长驻服务。本笔记提供候选能力和验收依据，不选定最终项目配置格式或托管架构，不接入、修改或运行任何真实外部项目。

## 证据等级与本次实际操作

以下证据不能互相替代：

| 等级 | 来源 | 能够证明什么 |
| --- | --- | --- |
| 官方文档 | Docker 文档、Apple 文档和发布版本文档 | 提供者定义的接口语义，不能证明本机兼容实现已通过 |
| 固定版本源码 | Apple container `1.2.0`、Socktainer `v1.2.1` | 该 tag 的实现及静态限制，不能证明本机安装的二进制与源码完全一致 |
| 本机既有实测 | `/Users/ghost233/.codex/AGENTS.md` 的 Docker 运行时、镜像纪律、Socktainer 手册 | 用户已确立的本机运行基线，本次未重新执行那些实验 |
| 本次只读观察 | 下表中的命令及本机手册 | 该次读取的结果，不能推广成生命周期或接入验收通过 |
| 候选设计／推断 | 明确标注的建议 | 依据证据提出的契约下限，等待后续 HITL 决策 |

本次只读环境命令实际执行如下；未读任何真实项目容器的配置或日志：

| 命令 | 本次结果 | 限制 |
| --- | --- | --- |
| `docker context show` | `socktainer`，退出码 0 | 仅证明当前选择的上下文 |
| `container --version` | `container CLI version 1.2.0 (build: release, commit: unspeci)`，退出码 0 | 仅 CLI 自报版本；不能验证后台服务版本或构建提交 |
| `socktainer --version` | `socktainer: 1.2.1 (git commit: unspecified)`，退出码 0 | 不能将安装二进制定位到完整源码提交 |
| `container system status` | `Operation not permitted`，退出码 1 | 本次沙盒未获得状态；不能据此判定运行时停止 |
| `man launchctl`、`man launchd.plist`、`man nohup` | 成功读取本机手册及所需段落 | 读取说明，未调用管理动作 |

另读取了当前仓库 `AGENTS.md`、`docs/agents/domain.md`、`CONTEXT.md`、现有研究笔记与全局运行手册；使用 web 浏览第一方文档，并在部分源码页面无法被爬虫读取时以匿名 `curl` 将同一官方公开 tag 的源码读取到 stdout，未执行下载内容、未保存依赖。没有启动、停止或重启服务／容器，没有镜像操作、安装、构建、测试、DNS／网络更改、额外挂载、索引创建或 Git／GitHub 业务操作。

Socktainer `v1.2.1` 的包声明固定依赖 Apple container `1.2.0` 和 Containerization `0.40.1`，与用户给定版本基线相符；安装二进制提交不可得，所以以下代码结论始终标为“固定 tag 源码”，而非本机新验收。[Package.swift](https://github.com/socktainer/socktainer/blob/v1.2.1/Package.swift#L25-L32)

## 结论及必须分开的状态

声明式接入可以提供启动、停止、已有运行发现和日志读取，但配置本身不能赋予任意命令稳定的后台身份、退出历史或应用就绪接口。达到分离运行至少需要一个独立于启动器界面进程的执行／管理者，以及重启后仍可查询的实例身份和日志来源。终端服务的管理者选择留给生命周期工单；容器已有 Apple 后台运行组件，Socktainer 是其 Docker 接口适配层。[Apple 技术概览](https://github.com/apple/container/blob/1.2.0/docs/technical-overview.md#how-does-container-run-my-container)、[Apple launchd 要求](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html#//apple_ref/doc/uid/10000172i-SW10)

这里的分离运行目标限于启动器退出／重启后的找回，不证明用户登出、Mac 重启或 Apple `container system stop` 后仍继续运行；后者会停止后台 container 服务并从 launchd 注销，恢复语义需要分别验收。[Apple system stop 文档](https://github.com/apple/container/blob/1.2.0/docs/command-reference.md#container-system-stop)

候选契约应同时保留以下观测，不压成一个布尔值：

| 观测 | 含义及证据下限 | 不能推出的结论 |
| --- | --- | --- |
| 提供者可达 | Docker socket/API、独立管理者是否能响应；记录查询错误 | 可达不等于目标服务运行；不可达不等于目标服务停止 |
| 运行实例状态 | 可信实例是否存在、运行、已停止；记录来源与观测时间 | 有 PID／容器在运行不等于服务已经能处理请求 |
| 服务就绪 | 项目声明的服务探活结果及时间 | 端口打开、启动命令成功或旧健康记录不证明应用语义就绪 |
| 退出结果 | 提供者确实捕获的退出码／信号及其对应运行世代 | 缺记录不能填 0；适配命令失败不能直接当作服务退出 |
| 日志可用性 | 来源、范围、保留边界与读取结果 | “读取成功且无字节”与“来源不可用／已丢失”必须不同 |

这是候选状态拆分。依据是 Apple 独立后台组件、Docker 独立 healthcheck 语义，以及下述 Socktainer 占位字段与本机健康检查恢复故障；`unknown` 应携带权限拒绝、提供者不可达、身份不匹配、能力缺失等原因。[Apple 技术概览](https://github.com/apple/container/blob/1.2.0/docs/technical-overview.md#how-does-container-run-my-container)、[Docker healthchecks](https://docs.docker.com/engine/containers/run/#healthchecks)、[Socktainer inspect 实现](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift#L162-L182)；本机证据：[运行手册](/Users/ghost233/.codex/AGENTS.md:350)。

## Docker 通用语义与 Socktainer 实际边界

Docker 文档描述 `run -d` 的后台运行、容器名称／长 ID／短 ID，以及 `logs`、`inspect`、`wait`。这些是通用接口语义。Socktainer 的公开 API 兼容表自称草案，仍以 Apple `v0.10.0` 作比较基准；表中“Implemented”不能覆盖本机 runbook 或固定版本源码限制。[Docker 运行文档](https://docs.docker.com/engine/containers/run/#foreground-and-background)、[Docker wait](https://docs.docker.com/reference/cli/docker/container/wait/)、[Socktainer 兼容表](https://socktainer.github.io/docs/api-feature-parity)

| 能力 | 固定版本实现／本机基线 | 首版适配边界 |
| --- | --- | --- |
| create/start/stop/rm/ps/inspect/logs/wait | 本机既有手册列为可用；源码有对应路由 | 可以作为能力候选，仍须逐场景验收；具体返回字段不自动真实 |
| restart/kill | 源码明确实现；本任务未实测 | 控制请求后重新查询目标实例，不把请求成功当成已完成或已就绪 |
| 前台 attach | 本机既有实测失败：`unable to upgrade to tcp` | 启动长驻服务用分离运行；不依赖前台 attach 管线 |
| exec | 秒级短会话可用；分钟级会话本机实测随机退出 255，已禁用 | 主服务／长任务作为容器主进程运行；短 exec 只作有界查询或明确探活 |
| rename／Compose recreate | 本机手册记录 rename 未实现，recreate 失败 | 不自动将这些操作纳入“重启”；替换容器需独立的、有身份变化的流程 |
| Socktainer 后台服务故障 | 本机手册记录 socket 消失时 Apple 层容器继续运行 | 上报提供者不可达，保留上次事实及时间，禁止因此自动重复启动 |
| 健康检查 | 本机手册记录 Socktainer 重启后长期 `starting` | 优先声明服务自身 HTTP／API 探活；旧 Docker Health 作为有来源的辅助观测 |
| 镜像、文件复制、DNS、复杂 Compose | 本机只实现部分通道，有方向、大小、平台与网络限制 | 此研究不设计构建／传输／恢复管线；不能用通用 Docker 模板暗示已支持 |

表中本机结论均来自既有[通道能力表](/Users/ghost233/.codex/AGENTS.md:267)及[Compose／运行时实测记录](/Users/ghost233/.codex/AGENTS.md:328)，本次未重测。源码控制实现见 [ClientContainerService.start/stop/kill/restart](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Clients/ClientContainerService.swift#L267-L369)。

### inspect 与退出结果不能照单全收

固定 tag 的 `ContainerInspectRoute` 以 Apple snapshot 判断 `Running`、状态和 `StartedAt`，但将 `Pid` 固定为 0、`ExitCode` 固定为 0、`OOMKilled` 固定为 false，停止后的 `FinishedAt` 填 1970 时间。`Dead` 也只是由 `.stopped` 推导。这些值不能被显示成宿主 PID、成功退出、未 OOM、真实结束时刻或独立故障事实；首版应标为不可用／未知。[ContainerInspectRoute.swift:170–182](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift#L170-L182)

真实退出码由 start／attach 路径的 `process.wait()` 写入 `ContainerExitCodeStore`；该 store 是 Socktainer 进程内字典，没有这里可见的持久化。`wait` 依赖该记录，部分失败路径回退 0。**源码推断**：Socktainer 重启后对先前运行实例的退出码恢复没有保证，既有停止容器还可能无法使等待条件完成；不能把通用 `docker wait` 语义扩展成可靠的跨后台服务重启退出历史。应有超时与未知结果，并把这项列入后续验收。[退出码 store](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Clients/ClientContainerService.swift#L7-L75)、[wait 服务实现](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Clients/ClientContainerService.swift#L379-L431)、[wait 路由回退](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerWaitRoute.swift#L81-L114)

固定源码把 healthcheck 配置保存为容器 label，状态、最近五条健康记录和探测任务在进程内存中；启动时有尝试恢复探测循环的代码。这表明“存在恢复意图”，不能抹掉本机实测未恢复的记录，亦不能保证此前五条健康日志可恢复。[HealthCheckManager](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Utilities/HealthCheckManager.swift#L23-L87)、[configure 恢复路径](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/configure.swift#L188-L210)；本机反例：[手册](/Users/ghost233/.codex/AGENTS.md:360)。

## 可信实例识别与启动器重启后找回

Docker 容器 ID 标识容器对象；同一对象可多次 start／stop。项目中的“运行实例”是一次具体运行，因而稳定服务标识、容器对象标识与运行世代应分别记录。建议恢复时使用 full ID 及当次 `StartedAt`／明确的运行世代来核对，不单凭名称或截短 ID 对缓存实例下停止命令。这是基于 Docker 生命周期接口及本项目术语的候选设计。[Docker 容器标识](https://docs.docker.com/engine/containers/run/#container-identification)、[Apple start/stop 文档](https://github.com/apple/container/blob/1.2.0/docs/command-reference.md#container-start)；领域来源：[CONTEXT.md](/Users/ghost233/Ghost233Code/MacLauncher/CONTEXT.md)。

Socktainer 由 native ID（Apple 容器名称）和可解析的创建时间派生 SHA-256 Docker ID；没有创建时间时，只哈希 native ID。创建时间先读取容器 bundle 的文件创建时间，再回退旧 label。此实现旨在使映射跨 Socktainer 重启稳定、同名重建产生新 ID，但不能无条件保证缺时间／存储恢复场景中的唯一性。保存 full ID、预期名称与创建信息，并在每次发现时核验；不同提供者的 ID 不应混用。[DockerContainerID.swift](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Utilities/DockerContainerID.swift#L5-L55)、[AppleContainerTimestampResolver.swift](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Utilities/AppleContainerTimestampResolver.swift#L12-L38)

Docker label 是静态元数据，可通过 list filter 和 inspect 找回 project/service 对应容器；修改已有容器 labels 通常要求重建。Socktainer 源码实现 label 过滤、规范化与返回原始键，但键规范化可能碰撞。因此候选项目配置应使用确定的、小写无歧义键和值，发现结果必须唯一；不能把 label 当作密码、签名或控制授权。已有无标签容器是否可显式关联、是否补标签重建，需要 HITL 决定。[Docker labels](https://docs.docker.com/engine/manage-resources/labels/)、[Socktainer label 过滤](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Clients/ClientContainerService.swift#L135-L145)、[LabelUtility](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Utilities/LabelUtility.swift#L55-L92)

候选发现流程：确认配置指定的提供者和上下文可达 → 用稳定 service 选择器列出全部匹配对象（含已停止对象）→ 核验对象 full ID、绑定和运行世代 → 才报告运行状态并执行控制。无匹配、多匹配、身份改变、权限不足和提供者不可达都应给具体原因；遇到这些情况不自动创建替代实例。此流程是设计推断，依据本机“Socktainer 不可达时容器仍在运行”及上述可复用名称／运行对象事实。[本机故障记录](/Users/ghost233/.codex/AGENTS.md:357)、[Socktainer list 实现](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerListRoute.swift#L20-L45)

Docker CLI 应明确使用 `socktainer` 上下文；仅接受 socket 的客户端可在自身环境使用本机已记录端点 `unix:///opt/homebrew/var/run/socktainer/.socktainer/container.sock`。不能全局设置 `DOCKER_HOST`，也不能自动切换到其他引擎。此端点来自用户既有手册，本次没有验证 socket 可达。[本机运行纪律](/Users/ghost233/.codex/AGENTS.md:115)

## 终端服务的声明式命令适配下限

配置只描述既有可执行程序和能力，不要求其他语言项目增加 SDK。启动器自身可以实现适配器；SDK 项目可以额外报告精确实例身份与语义就绪，不能让首版非 SDK 项目依赖一个实际上不存在的状态接口。以下均为候选配置能力，不是已定 schema：

| 能力 | 最小声明／恢复证据 | 缺失时的诚实结果 |
| --- | --- | --- |
| 启动 | 可执行路径、argv、工作目录、明确的环境输入；声明它是长驻前台程序还是对既有管理者的一次控制请求 | 无独立管理者或运行记录时，不能宣称达到分离运行 |
| 停止 | 指向已核验实例／既有管理者的控制；可选优雅退出时限 | 只有模糊进程名或端口时，不提供自动停止 |
| 已有运行发现 | 稳定服务选择器，加管理者返回的实例身份；裸进程方案至少核对 PID、用户、启动时刻和预期程序 | 身份不确定时为未知，不能认领或杀死同名程序 |
| 就绪 | 可选 HTTP／API／短命令探活及成功条件、超时 | 未声明则“就绪未配置”；运行中不升级成已就绪 |
| 退出 | 独立管理者已保存的退出码／信号，对应明确实例 | 丢失／不可查询时为未知 |
| 日志 | 启动前确定的 stdout/stderr 文件，或项目已有明确日志路径／查询入口 | 未捕获或未声明日志源时为不可用；不能还原过去的终端输出 |

直接 argv 与固定工作目录／环境是可复现声明的候选下限，launchd 原语已有 `ProgramArguments`、`WorkingDirectory`、`EnvironmentVariables`、`StandardOutPath` 和 `StandardErrorPath`。托管程序必须保持前台，不能再次 daemonize；否则管理者观察到的退出与真正服务生命周期可能分离。深入托管取舍由 macOS 生命周期工单处理。[Apple 创建 launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)、本次读取的 `man launchd.plist` 对应键。

本机 `man nohup` 仅承诺忽略 SIGHUP，并在标准输出仍是终端时选择 `nohup.out`；多个实例还可能追加到同一文件。**设计推断**：`nohup ... &` 加 PID 文件不足以满足可信重连、按实例分离日志及退出历史的完整契约。`waitpid` 只等待调用者的子进程，启动器重启后不能凭保存的任意 PID 重新取得原子进程的退出码。[Apple wait(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/wait.2.html)、本次 `man nohup`。

`kill(pid, 0)` 只检查 PID／信号权限，不认证服务身份；`EPERM` 不能等同停止。Apple 公开内核结构包含进程用户、PID、进程组及启动时间，能用于身份核对，但这些快照检查不自动消除检查后发信号的竞态，也不提供稳定控制协议。对缺少可信管理者的任意既有进程，自动认领／停止的安全性仍未验证。[Apple kill(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kill.2.html)、[Apple proc_info.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h#L54-L77)

`launchctl print` 可供诊断，其本机手册明确说明输出不是 API，不能依赖输出结构。旧 `launchctl list` 的 PID／上次退出状态也不是服务就绪或按运行实例的持久历史。故首版不能将解析诊断文字视为已验证的稳定状态协议；允许哪些现有命令输出、是否由独立适配者产生结构化状态，留给后续决策。来源：本次 `man launchctl` 的 `print`、`list` 段落。

SDK 若使用 XPC 可增强可信控制方身份；Apple DTS 推荐公开的代码签名 requirement API。该机制校验收到的消息，不能假设设置 requirement 就阻止首条请求发往不可信接收者。实例 ID／握手和运行世代仍是应用契约，不能用裸 PID 代替；具体 SDK 安全握手不在此工单定案。[Apple DTS 身份校验](https://developer.apple.com/forums/thread/681053)、[Apple DTS 消息边界说明](https://developer.apple.com/forums/thread/837286)

## 已有日志的来源、恢复与不可用边界

| 日志来源 | 能力与恢复边界 |
| --- | --- |
| 终端服务 stdout/stderr 文件 | 只有执行者启动前建立捕获，或项目原本写文件，启动器重启后才有内容可读；需关联实例、流、路径及文件身份。权限拒绝、文件丢失、轮转／截断要显示原因。仅临时 UI pipe 无法恢复已有输出 |
| 项目已有应用日志文件 | 配置可声明现有来源；不会自动获得写入时间、格式、归属实例或轮转保证。不能为读取日志静默新增宿主挂载 |
| Docker 通用 logs | 通常读取 endpoint 程序的 stdout/stderr；应用仅写内部文件或 logging driver 不提供本地读取时，可能无有用输出。不能据此判断服务没有日志 |
| Socktainer `logs` | 固定源码向 Apple `ContainerClient.logs` 请求 stdio 文件句柄，支持 backlog、tail、follow；这是既有内容读取，区别于启动器自己的 UI 缓存 |
| Apple native `container logs` | 支持 stdio 或 `--boot` 的启动日志；`ContainerClient.logs` 返回文件句柄。native 日志不是 Docker logging driver 的实现证明 |
| Apple `container system logs` | 是后台 container 服务的诊断日志；不能当作某个项目服务的应用日志。若运行时以 `--log-root` 启动，该命令不显示那里的服务日志；该选项不做轮转 |
| Docker Health.Log | Socktainer 中为内存中的最近五条健康探测记录；不能充当应用历史日志或保证跨 daemon 重启恢复 |

外部语义来源：[Docker 日志来源](https://docs.docker.com/engine/logging/)、[Docker logging drivers](https://docs.docker.com/engine/logging/configure/)、[Socktainer logs 路由](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerLogsRoute.swift#L30-L159)、[Apple native logs 实现](https://github.com/apple/container/blob/1.2.0/Sources/ContainerCommands/Container/ContainerLogs.swift#L24-L57)、[Apple system logs／log-root 文档](https://github.com/apple/container/blob/1.2.0/docs/command-reference.md#container-system-logs)、[Socktainer 健康记录](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Utilities/HealthCheckManager.swift#L42-L87)。终端文件与读取器行为是基于上述原语的候选设计，未作新实测。

Socktainer `v1.2.1` 日志接口的具体限制必须暴露：

- 请求的 `stdout/stderr` 仅验证至少选择一项；读取的是统一 stdio 文件，non-TTY 的输出 frames 全部标为 stdout。**不能承诺按 stderr 过滤或正确分流**。TTY 输出为 raw stream。[日志路由:20–47](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerLogsRoute.swift#L20-L47)、[frame 输出:262–268](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerLogsRoute.swift#L262-L268)
- `timestamps` 对历史行加入读取时的“现在”，不是原始写入时间；源码没有处理 `since/until` 查询参数。不能据此做准确时间筛选、按 timestamp 恢复游标或宣称亚秒级日志时间精度。[日志处理:222–259](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerLogsRoute.swift#L222-L259)、[完整 handler](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerLogsRoute.swift#L14-L169)
- `tail` 会读过 backlog 再保留尾部；返回有界行数并不代表底层读取成本有界。follow 连接需要取消和重连；UI 断开不应停止服务。[backlog/follow 实现](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerLogsRoute.swift#L69-L159)
- REST model 虽接受 `LogConfig`，本次对完整 create handler 的字段检索未发现使用该字段；inspect 构造的 `HostConfig.LogConfig` 与 `LogPath` 为 nil。因此 Docker `json-file/local/none`、轮转及 `--log-opt` 行为均不能从参数接受或 Docker 文档推出支持；这些能力在本机仍未验证。[RESTConfig](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Models/RESTConfig.swift#L30-L171)、[create handler](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift)、[inspect 的 LogPath](https://github.com/socktainer/socktainer/blob/v1.2.1/Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift#L185-L205)
- Apple CLI 源码的 follow 路径提示容器重启时日志文件可能截断。**不能承诺跨容器重启、移除、自动移除或重建保留完整历史**；本任务未验证保存期限与轮转方式。启动器重启后读取同一仍存在对象的日志是验收目标，长期归档是另一个待决定的能力。[Apple ContainerLogs follow 注释](https://github.com/apple/container/blob/1.2.0/Sources/ContainerCommands/Container/ContainerLogs.swift#L112-L124)

候选日志记录应包括 service/instance、来源及提供者、捕获／读取时刻的区别、文件或对象身份、当前范围及可用性。对 Socktainer 默认返回合并流，不添加伪造的写入时间；恢复时可以有界重读已有尾部并明确重复／缺口，不承诺精确一次交付。没有原始捕获的历史无法靠配置补回。这些是设计推断，依据上述原始字节流与时间／分流限制。

## Apple 原生 API 的边界

Apple `container-apiserver`、image/network helpers 与每个容器的 runtime helper 是独立后台组件，CLI 经客户端库及 XPC 访问。原生 API 有 `ContainerClient.list/get/bootstrap/stop/logs`，`ClientProcess.wait` 可取得受管进程退出码；这是 native API 原语，不代表 Socktainer 已将相同信息忠实、持久地映射到 Docker inspect。[Apple 技术概览](https://github.com/apple/container/blob/1.2.0/docs/technical-overview.md#how-does-container-run-my-container)、[ContainerClient](https://github.com/apple/container/blob/1.2.0/Sources/Services/ContainerAPIService/Client/ContainerClient.swift)、[ClientProcess](https://github.com/apple/container/blob/1.2.0/Sources/Services/ContainerAPIService/Client/ClientProcess.swift#L30-L42)

`container system status` 查询后台服务及 apiserver 健康；`container list/inspect` 查询容器；服务自己的就绪探活是第三层。native `ContainerStatus` 包含 state、network attachments、startedDate，没有这里可见的应用就绪、完整退出历史。候选首版沿用本机 Docker/Socktainer 控制，原生 CLI 作为受限诊断或明确定义的替代适配；不能自动混用两条控制路径后再把结果算成一次原子操作。[Apple system status 文档](https://github.com/apple/container/blob/1.2.0/docs/command-reference.md#container-system-status)、[ContainerStatus](https://github.com/apple/container/blob/1.2.0/Sources/ContainerResource/Container/ContainerStatus.swift#L19-L33)；路径选择是设计候选。

## 后续 HITL 必须决定的取舍

1. 终端服务使用哪一个独立执行／管理者，以及配置如何声明 foreground argv、既有管理者控制命令与其机器可读返回。此处不决定新增 wrapper、常驻 broker 或 launchd 注册形式。
2. 首版是否只认领带稳定选择器且唯一匹配的实例；已有无标签容器／裸进程如何显式关联；身份不充分时允许“只观察”还是不接入。
3. 运行世代由谁产生／保存，外部 start/restart 后如何识别新运行实例；不能用容器名称或静态 service label 充当单次运行 ID。
4. 就绪探活接受哪些成功条件；无就绪接口显示“未配置”，还是必须补配置才接受关联。SDK 增强保持可选。
5. 首版日志是否接受 Socktainer 合并流、无可靠写入时间、无 since/until 和可能截断的限制；是否需要独立归档、其保留／轮转责任归谁。
6. 退出码跨提供者重启不可恢复时是否接受“未知”；若必须可靠恢复，应选择经验证的持久来源，不使用 inspect 的 0 占位值。
7. 提供者不可达时是否仅报告并给用户恢复入口，或按已声明策略恢复运行时；这一产品策略尚未确定，本次研究未执行任何恢复动作。

## 未来验收场景（均未在本任务执行）

| 场景 | 必须观察到的结果 |
| --- | --- |
| 配置关联后启动，关闭启动器界面及结束其进程，再重开 | 原运行实例继续；重新发现相同对象与运行世代；恢复读取关闭期间产生的日志；不重复启动 |
| 服务先由项目独立启动，再关联配置 | 唯一匹配时识别已有运行；无匹配／多匹配／身份不足给明确原因；不误停其他实例 |
| 启动命令返回成功，但应用仍初始化或探活失败 | 运行中与未就绪分别显示；不立即显示已就绪 |
| 读取提供者时权限拒绝／socket 不可达 | 显示未知及错误来源；保留最后观测时间；不推断停止或自动再启动 |
| 启动器关闭期间服务退出 0、非 0、被信号终止 | 有可信持久记录时恢复真实结果；没有记录时明确未知，不填成功 |
| 容器 stop/start 同一对象，或同名 remove/create | 辨别运行世代变化与容器对象变化；旧实例记录不能控制新实例 |
| Socktainer 重启且容器继续运行 | 恢复对象发现及日志读取；应用探活重新采样；健康日志／退出码丢失如实反映 |
| stdout/stderr、TTY、非 TTY、无换行尾部、较大 backlog | 列出真实支持的读取方式；合并流与时间属性不伪造；UI 读取可取消 |
| 日志文件轮转／截断／删除、容器重启／自动移除 | 显示截断、来源变更或历史丢失；保留策略只在实际验证后承诺 |
| 外部同名进程／PID 重用、端口由其他程序占用 | 身份不匹配时拒绝控制；端口可达不当作本服务的可信就绪 |
| 状态／日志短查询成功，但长 exec 随机退出 255 | 不把 CLI 通道错误当服务退出；长驻工作始终交给独立主进程／管理者 |

这些场景在后续实施工单中使用隔离 fixture 验证，遵守当前容器运行纪律；当前研究的完成不等于实现或运行验收通过。
