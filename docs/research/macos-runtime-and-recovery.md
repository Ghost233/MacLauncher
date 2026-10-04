# macOS 独立运行、登录启动与运行实例找回

研究日期：2026-10-04。对应[核实 macOS 独立运行、登录启动与实例找回机制](https://github.com/Ghost233/MacLauncher/issues/2)，父[规划 MacLauncher：个人启动器、独立运行与 SDK 接管](https://github.com/Ghost233/MacLauncher/issues/1)。本文提供事实与候选方案，不选定首版架构。

## 范围与证据等级

产品前提来自本次工单：Flutter macOS 启动器默认菜单栏驻留、可选主窗口；项目配置可以声明多项服务；项目保留独立运行能力；首版 Dart SDK 可选，其他语言先通过配置接入。对于 SDK 项目，启动器接管控制和菜单栏入口，保留项目原窗口；启动器崩溃时项目归还入口，服务继续运行。运行状态与就绪状态分开。术语沿用根目录 `CONTEXT.md`。

- **已核实**：Apple 公共文档、Apple DTS 的明确答复，或当前机器 Apple 随系统/SDK 提供的手册和头文件。
- **候选**：由已核实原语推导的产品/协议设计，不是 Apple 提供的完整能力，也没有在 MacLauncher 中实现。
- **尚未实测**：真实签名构建、注册、用户批准、登录/注销、崩溃、更新、沙盒、日志读取及 Flutter 桥接均未运行。

本机只读 `sw_vers` 返回 `macOS 27.0.1`、构建 `26A434`；`xcrun --show-sdk-path` 返回 Xcode 内的 MacOSX SDK。这里只记录本机基线，不把它推断为全部用户的系统版本。只读取版本、手册、SDK 头文件和公开来源；没有安装依赖、启动/停止服务、修改登录项或系统设置。

## 已核实结论

1. **launchd agent 是独立后台生命周期的受支持原语。** Apple 将 LaunchAgent 定义为由 launchd 管理、代表登录用户运行的进程。macOS 13 起，`SMAppService.agent(plistName:)` 可登记它；登记后立即 bootstrap，并在该用户后续登录时再次 bootstrap。UI 退出后继续提供服务，正是 Apple DTS 描述的独立 agent 与 UI 配对用途。[Service Management][S1]、[register()][S2]、[DTS：独立 agent 与主应用 UI][S3]
2. **SMAppService 是登记与授权接口，底层生命周期由 launchd 负责。** 它的 `status` 表示未登记、已启用、需要批准或找不到；不能据此宣布运行实例存在或服务已就绪。[SMAppService][S4]、[Status][S5]
3. **稳定作业名、可信代码身份和某一次运行不是同一身份。** launchd 的 `Label` 标识作业；XPC 可以验证收到消息的对端代码身份；PID 会复用。MacLauncher 若要重连“同一运行实例”，仍需把这些证据与项目/服务/运行实例的应用层身份组合，而不能只保存 PID。[本机 launchd.plist 手册][L1]、[PID 文档][S6]、[代码签名要求][S7]
4. **入口接管与入口归还是应用之间的协议责任。** AppKit 提供创建/移除自身 `NSStatusItem` 的 API；研究范围内没有找到由平台自动完成跨独立应用接管、保留窗口、崩溃归还的一体接口。因此 SDK 协作与失联恢复属于候选设计，不能写成 SMAppService 已提供的能力。[NSStatusBar][S8]、[statusItem(withLength:)][S9]

## 生命周期原语与候选方案比较

下面的能力描述来自 Apple 文档；“对本产品的含义”是推论。可组合这些原语，但没有在这里选择组合。

| 原语 | 已核实的生命周期/启动行为 | 对本产品的含义与取舍 |
| --- | --- | --- |
| `SMAppService.mainApp` | 把主应用登记为登录项；登记后在后续登录启动。[S2] | 可以启动菜单栏 UI。服务若仍在 UI 内运行，不能因此满足分离运行。 |
| `SMAppService.loginItem(identifier:)` | 包内 helper app 登记后立即启动，后续登录启动；崩溃或非零退出会重启。[S2] | 独立 helper 可承担菜单栏入口或后台工作；与 mainApp 的行为不同。正常退出、服务控制与实例身份仍需契约。 |
| `SMAppService.agent(plistName:)` | 包内 plist 对应用户 agent；登记后 bootstrap，后续登录 bootstrap；运行条件来自 launchd plist。[S2][S10] | 适合用户范围的后台托管候选。可以是一项固定 helper，也可以由项目自己的独立应用登记自己的 agent。动态多服务如何映射不是 API 自动完成的。 |
| 传统用户 `~/Library/LaunchAgents/<Label>.plist` | 用户 agent 的受支持位置；SMAppService 的 agent 登记是此种安装方式的现代替代。[S4][S11] | 可把每项服务映射为外部可执行文件对应的作业，适合配置接入的候选。需自行管理 plist、权限、路径、更新和清理；仍受背景项控制及隐私权限约束。[L1][L2] |
| `SMAppService.daemon(plistName:)` / 系统 LaunchDaemon | 系统范围，可在用户登录前运行；SMAppService daemon 必须获管理员批准才 bootstrap，后续系统启动 bootstrap。[S1][S2] | 适用于跨用户或登录前任务的候选；当前“用户登录后启动”要求本身没有推出需要 root。daemon 不承担项目窗口或菜单栏 UI。[S12] |
| 应用包内普通 `.xpc` service | launchd 按需启动、崩溃后重启，也可在空闲时被终止；服务应少持有状态。[S13] | 可用来做隔离的短任务和 IPC；不能仅因它是独立进程就假定有持久生命周期或自动启动保障。 |

旧归档指南把传统 Login Item 描述为不受持续托管；本文对 **SMAppService 登记的包内 login helper** 使用当前 `register()` 明确的崩溃/非零退出重启说明，不把旧表格覆盖到现代接口上。[S2][S12]

### 用户级范围与运行条件

- 本机 `launchctl` 手册区分 `user/<uid>`、`login/<asid>` / `gui/<uid>` 和 `system`。用户 domain 可以独立于图形登录存在；GUI domain 是登录会话 domain。二者共享一些 Mach 名称查找资源，但作业集合不同。“用户级”不能直接等同于“当前 GUI 会话”，也不能据此承诺注销后持续运行。系统 domain 修改需要 root；读取/查询不需要。[L2]
- Apple 对用户 agent 的通常说明是只在该用户登录期间执行；SMAppService 要为多个用户登记 agent，需各用户运行应用时分别调用 API。本产品若要注销后继续运行，须另行决定是否引入系统范围托管，而不是从登录自启动扩张出该要求。[S11][S2]
- `RunAtLoad` 让作业加载时启动一次；`KeepAlive` 控制持续运行/有条件重启；快速失败会被节流。启用 `KeepAlive` 后单纯让进程退出可能触发重启。要区分“暂时停止当前运行”“不再自动启动”“卸载后台项”和“启动器退出”。这些是候选产品操作语义，不能全部映射为一个退出命令。[L1]
- launchd 期望直接托管的进程留在前台，不应自行 `daemon()` 或 fork 后让父进程退出；它建议处理 SIGTERM 并快速收尾。多服务依赖没有显式声明模型，应通过 IPC 协调。因此“已 bootstrap”或“进程正在运行”不表示它的依赖或监听端点已就绪。[L1]、[创建 launchd 作业][S11]

### 动态项目配置与打包边界

**已核实：** `agent(plistName:)` 的 plist 必须位于调用应用的 `Contents/Library/LaunchAgents`；daemon 相应位于 `Contents/Library/LaunchDaemons`。`BundleProgram` 是包内相对可执行路径，支持包被移动后的定位；它只适用于 SMAppService 安装的 plist。现代迁移指南要求把 helper 与 plist 放入包内，减少写系统目录的安装脚本。[S10]、[迁移 helper][S14]、[本机 SDK][L3]、[L1]

**已核实：** SMAppService 应用须代码签名；包含其 LaunchDaemon 的应用须 notarize，这是本机官方 SDK 的明确约束。代码签名保护包内资源和嵌套代码；不能把已签名应用包当作可随意追加项目 plist 的运行时配置目录。[L3]、[签名哈希与资源保护][S15]

**候选映射：**

- 固定的包内用户 helper 读取包外项目配置，再启动/控制各项服务：固定包装符合登记结构；需要自行实现多服务托管、日志和恢复。helper 若只作为总父进程，其失败可能波及所有子服务——本机手册说明作业死亡时默认清理同进程组的残留进程；`AbandonProcessGroup` 可改变此行为，但它本身不提供对子进程的监控/重新识别。[L1]
- 每项服务有自己的用户 LaunchAgent：launchd 按作业分别管理；要求服务遵循 launchd 的前台运行与退出约定，并承担可执行路径、配置同步及用户可见归属问题。[L1][S11]
- 项目独立应用自己登记后台项，MacLauncher 只发现/接管控制与入口：项目自主性更强；会引入每个项目的安装/更新责任和共同协议。这是组织责任的取舍，不是 Apple API 要求。

这里没有确认 SMAppService 能把任意已运行的外部服务进程“收编”为它直接托管的作业；官方登记文档描述的是已知 helper 的 bootstrap/启动。对已经独立启动的 SDK 项目，候选做法是协议上接入并核实已有运行实例，不把接入行为等同于换一个进程所有者。[S2]

## 可靠找回与可信控制

### 已核实的身份和 IPC 原语

- `xpc_connection_get_pid` 文档明确警告 PID 不保证在整个开机周期唯一；连接建立后也可能变旧；远端消失通知没有固定送达时限。因此 PID 文件、端口占用或命令名不能独自证明“仍是那次运行”，更不能单独授权停止操作。[S6]
- `NSXPCConnection.setCodeSigningRequirement` 与 `NSXPCListener.setConnectionCodeSigningRequirement` 从 macOS 13 起公开；前者约束对端消息，后者可在 listener delegate 收到连接前拒绝不符合要求的连接。C XPC 的对应代码签名要求 API 从 macOS 12 起公开；新 lightweight requirement 从 14.4 起、`xpc_peer_requirement_t` 相关接口从 26 起提供。最低系统版本会改变可用接口，不必为当前机器而强制采用最新接口。[S16]、[Apple DTS 身份核实汇总][S17]、[本机 Foundation/XPC 头文件][L4][L5]
- 代码签名 requirement 可以约束签名标识、信任锚与团队，也可以精确到 cdhash；它建立的是软件代码身份，不是某一次运行的标识。对多项目接入，“只信任启动器团队”可能不符合第三方项目边界；开发签名、发行签名和更新后的二进制是否满足同一 requirement 需明确政策。[S7]
- Apple DTS 于 2026-07 明确：XPC 验证基于**收到的消息及其 audit trailer**，客户端设置 requirement 不保证第一条发出的消息先经过对端验证再送达。不能在首条消息直接交付凭据或有副作用的控制请求，再等签名错误出现。[S18]
- interruption handler 表示远端退出/崩溃，可能发送后续消息重建；invalidation handler 表示连接不能建立或不能再重建。连接恢复并不意味着远端还是原来的运行实例；按需 Mach service 的请求可能触发一次新启动。[S19][S20][S11]

### 候选重连契约，不是已实现能力

把以下信息分层，便于后续 HITL 决定最少需要的保证：

| 层次 | 用途 | 证据/边界 |
| --- | --- | --- |
| 项目、服务稳定标识 | 对应项目绑定、项目配置与服务定义 | MacLauncher/SDK 自定义；路径与显示名改变时是否仍为同一服务待定。 |
| 托管定位信息 | 找到用户 domain、作业 label、Mach service 或其他端点 | label 和端点可被下一次运行复用，不是运行实例 ID。[L1][L2] |
| 可信对端身份 | 授权谁能报告状态、谁能发控制请求 | 使用公开代码 requirement 或另行定义的认证协议；同 UID 本身不等于受信任项目。[S7][S16] |
| 运行实例 ID / generation | 区分同一服务的每次启动、拒绝旧实例控制 | 可由实例在启动时生成并经可信握手返回；它是合作软件声明，不是平台提供的、跨任意进程可比较的绝对实例证据。 |
| 运行与就绪报告 | 区分存在、启动中、可接受工作与不可用 | 需项目/适配器定义探针；登记状态和进程存在不能替代业务就绪。[S5][L1] |

候选重连流程为：先定位端点，进行无敏感内容且无业务副作用的握手；验证收到回复的对端身份；取得并比较项目、服务、实例 ID 和协议版本；再恢复控制/状态订阅。所有控制请求带期望的实例 generation，服务重启后拒绝旧 generation。持久记录只作定位线索，超时或签名不匹配时显示未知/待确认，不直接向记录的 PID 发送终止信号。此流程是由 PID 与 XPC 边界推导的安全契约，尚未实测。[S6][S18]

只有配置、未实现 SDK/协议的服务，不能自动获得“接管任意已有运行实例”的同等保证。适配器可以提供启动、检查和停止手段，但要在能力声明中给出身份/就绪证据与限制；这部分与命令 Provider 的研究衔接，而非由 UI 假装已证明实例身份。

`launchctl print`、`blame`、`procinfo` 可用于人工排障。本机手册明确 `print` 输出不是 API，新命令输出不保证跨版本稳定；`blame` 与 `procinfo` 也只供诊断。没有在本研究中找到可替代应用层握手的现代、稳定 launchd 运行实例查询 API。[L2]

## 入口接管/归还与退出行为

**已核实：** 独立应用可以持有自己的 `NSStatusItem`，移除它，之后重新创建；AppKit 不保证菜单栏项目总能显示（空间有限）。这与服务进程是否存在没有绑定关系。[S8][S9]

**候选：** SDK 把入口接管设为独立于服务控制的状态：可信的启动器 UI 会话确认接管后，项目收起自己的菜单栏入口；项目保留窗口和服务；UI 会话中断/失效或接管租约超时后，项目恢复入口。若另设一个持续运行的总 helper，不能只检测 helper 存活，因为 UI 已崩溃、helper 仍活着时仍需入口归还。

租约、心跳或 XPC 中断可以帮助检测失联，但系统未承诺瞬时通知；需决策故障检测时限、睡眠/唤醒与暂时卡顿如何处理，以及多启动器会话的排他接管。入口归还必须由仍在运行的项目协作者完成；平台不会为已经退出的项目自动重建其菜单栏。以上是基于 AppKit、异步断连语义与产品前提的推论。[S6][S19][S20]

**已核实且影响 UI 操作：** `SMAppService.unregister()` 对正在运行的包内 login helper、agent、daemon 会让系统终止它；mainApp 对应的注销只取消后续登录启动、保留当前主应用运行。本机 SDK 还说明同步注销不等待进程被回收；异步注销成功 completion 在运行进程终止后到达。[S21]、[本机 SDK][L3]

因此“退出启动器、保留服务”和“取消自启动、保留当前服务”不能默认调用 agent 的 unregister。后者若为产品要求，可以研究固定 helper 登记与服务自身的自动启动偏好分离，或其他明确区分当前执行与未来启动的控制策略；这里仅指出必要取舍，没有选择方案。

## 安装、权限、更新与沙盒

### 安装/批准/注销

- SMAppService agent 按调用用户登记；daemon 的系统范围启动需管理员批准。用户可以在 System Settings 禁用背景项。应把需要批准的状态展示为授权问题，允许用户自行恢复，不应重复登记绕过禁用。[S2][S5]、[持续后台处理][S22]
- 传统 plist 的所有者和写权限受约束：用户自己的 LaunchAgents 属于该用户，`/Library/LaunchAgents` 与系统 daemon 配置通常须 root 所有，配置不得允许 group/world 写入。传统 `Program` 是绝对路径；工作目录与环境变量必须按作业配置，不应假设交互 shell 的环境。[L1][L2]
- 系统目录安装、system domain 修改与普通用户登记是不同权限面；管理员批准后台进程不等于授予受保护文件的访问权。当前手册明确 agent/daemon 仍受 macOS 隐私保护，敏感路径甚至可能使作业无法运行。[L1][L2]
- 对包外传统作业，`AssociatedBundleIdentifiers` 可用于 System Settings 归属，迁移指南要求所关联应用与可执行文件的 Team Identifier 匹配；未签名程序可能按可执行名显示。任意外部项目不能仅写启动器 bundle ID 就保证统一归属。[S14]

### 更新

Apple 官方 SDK 说明：agent/daemon 的 plist 或可执行文件更新后需重新登记，改动可执行文件时建议先注销。异步注销完成后按契约可以再登记；DTS 将完成后立即登记仍失败的报告视为 bug。因此要实际验证所支持系统上的升级过程，不能把等待固定秒数写成平台保证。[L3]、[DTS：helper 更新][S23]

注销正在运行的 helper 会终止它，因此更新是否允许中断、能否先停止/排空工作、如何核实新实例版本及就绪，需要单独设计。把应用包替换就假定当前服务已换为新版本不成立；托管名称持续存在也不意味着是同一运行实例。上游讨论包含用户实测现象，本文只采用 Apple 的 SDK 契约和 DTS 答复，不把论坛用户的机器结果当作本机验证。[S21][S23]

### App Sandbox 与发布形态

- Mac App Store 分发要求 App Sandbox。Apple 当前文件访问文档明确：用户选择文件的 entitlement 不允许运行应用包、sandbox container 或 app group container 以外的程序；获得项目目录读写权不等于任意执行权。这直接影响“配置任意本机项目命令”的候选方案。[App Sandbox][S24]、[访问文件][S25]
- Apple DTS 的 SMAppService 入门文档给出受支持组合：非沙盒应用可登记非沙盒或沙盒作业；沙盒应用登记作业时要求作业也沙盒化。它还区分独立 command-line target 的自身 sandbox 与普通 `posix_spawn` 子工具继承 sandbox。此处记录 Apple 的支持说明，不能用其他开发者的成功运行报告推导所有组合均受支持或能通过 App Review。[S26]
- `posix_spawn` / NSTask 的 sandbox inheritance 与独立 launchd job 的权限不是一回事；继承只包含静态权限，启动后用户选目录得到的动态访问不能自动沿用，需传数据/书签。未沙盒化的发布形态也不自动绕过 TCC 或文件权限。[继承权限][S27][L1]
- 沙盒进程可通过 app group 进行 IPC；Mach/XPC 名称须为 group ID 的子名称，Unix socket 需在 group container 中。文档把 app group 描述为同一开发团队应用的共享机制；不能将其直接视为任意第三方项目共享的通道。若选择沙盒方案，跨团队 SDK 与配置服务接入仍需独立验证。[App Groups][S28]

Flutter 的 Swift/Objective-C 原生桥接、Dart SDK 如何传递身份/端点、实际 entitlement 与发布签名组合在本研究中未实现；不能据此报告 Flutter 包装已经通过验证。

## 日志与状态证据

| 来源 | 已核实能力 | 首版仍需决定/验证 |
| --- | --- | --- |
| `StandardOutPath` / `StandardErrorPath` | launchd 可以将 stdout/stderr 写入指定文件，并按用户/组及 umask 建立文件。[L1] | 文件目录权限、实例关联、截断/轮转、读取游标、磁盘保留、输出含敏感信息时的处理。不能从管道脱离就推断日志可恢复。 |
| Unified Logging：`Logger` / `os_log` | 日志在统一系统的内存/磁盘中集中，Console、`log` 工具和 OSLog framework 可读取。[S29] | 跨服务日志关联与默认过滤；不把日志文本当运行/就绪状态接口。 |
| `OSLogStore` | 支持日志档案和本机日志存储及位置/条件查询；`.currentProcessIdentifier` 是当前进程范围，不能用它承诺启动器自动读取所有服务历史。[S30] | 全系统读取权限需验证；`local()` 文档明确要求管理员账户及 `com.apple.logging.local-store` entitlement。不能默认普通 Flutter UI 有此能力。[S31] |
| launchctl 人工诊断 | 可观察作业上下文、当前状态、上次退出等，但新命令文本不是稳定 API。[L2] | 只作为故障证据；Provider 不宜把解析 `print` 输出作为唯一生产契约。 |

日志实时流、历史读取、当前运行状态与业务就绪是不同能力；SDK 可主动报告，配置服务可由探针提供。未提供就绪探针时应呈现未知，而不是以“端口占用”推断属于该运行实例且健康。此为候选状态契约，由本研究的身份与启动边界推导。

## 下一张 HITL 工单需要决定的取舍

建议下一张工单以“确定 macOS 首版托管与重连边界”为决策主题，至少确定：

1. 最低 macOS 版本和发布形态：个人非沙盒/Developer ID，还是计划 Mac App Store 沙盒；签名、第三方项目信任与外部命令执行范围。
2. 托管责任：MacLauncher 固定用户 helper、每服务用户作业、项目自行托管，或按接入类型组合；哪些故障必须保持已有运行实例存续。
3. 自动启动与停止语义：登录后启动哪些服务，是否要求注销后存续；取消自动启动是否保留当前运行；禁止将这些选择隐含为 root daemon。
4. 已有运行实例接入保证：合作 SDK 的双向认证/运行实例标识、配置服务的可验证能力等级，以及不能可靠识别时的允许操作。
5. 入口接管期限：UI 崩溃/卡顿后多久归还、睡眠唤醒与多会话如何处理；已有服务不得因归还菜单栏入口被停止。
6. 更新/日志策略：是否容许 helper 更新中断及如何排空；历史日志来源、权限和保留范围。

这些是尚待用户选择的产品/架构取舍，本文没有替用户作决策。

## 未来验收场景（本轮未执行）

| 场景 | 可操作的测试动作 | 必须观察的验收证据 |
| --- | --- | --- |
| UI 崩溃与重启 | 项目服务已就绪且已入口接管；强制结束启动器 UI，再重启 UI。 | 服务连续完成请求、原窗口仍可用；项目在约定时限归还入口；重连返回同一实例 ID，未重复启动服务。 |
| 后台 helper 崩溃 | 明确 UI/helper 分离后结束 helper。 | 根据选定故障保证检查各服务是否仍在原实例；若系统重启了服务，必须显示新的实例 ID，不伪装连续运行。 |
| 独立启动后接入 | 先从项目独立应用启动 SDK 项目，再打开启动器接入。 | 不重启服务、不关闭原窗口；完成可信握手后接管入口；项目脱离启动器仍可运行。 |
| PID/端点/旧记录混淆 | 结束一次服务，保留其定位记录；启动新实例或同名测试端点；发送带旧 generation 的控制。 | 不误认、不误停；拒绝旧 generation；不向未经验证的端点发送敏感内容或有副作用的请求。 |
| 运行与就绪分离 | 服务进程先启动但延迟监听；另测依赖失败与 readiness 撤销。 | 状态分别呈现运行、就绪未知/未就绪及后续变化；不以 enabled 或 PID 存在替代就绪。 |
| 用户禁用背景项 | 通过 System Settings 禁用，再启动 UI；随后由用户重新允许。 | 明确需要批准，不重复登记绕过；恢复后重新核实实例和 readiness。 |
| 退出/停止/关自启动 | 分别退出 UI、停止一项服务、取消自启动。 | 行为符合已决定的语义；KeepAlive 不把用户停止变成不断重启；需保留的服务未被 unregister 终止。 |
| 登录/注销/多用户 | 登录、注销并在另一用户会话验证范围。 | 登录按偏好启动；注销行为符合范围决策；不跨用户接管、读取私有日志或控制服务。 |
| 包移动与更新 | 移动已安装包；更新 helper 和 plist；测试异步注销后重新登记。 | 能按 bundle 相对路径启动；重登记失败可见且可恢复；新实例版本/ID/readiness 已确认；中断符合策略。 |
| 签名/沙盒/项目路径 | 测试正式签名及开发签名、受保护目录、SDK 跨团队和配置命令。 | 每一种被声明支持的组合真实启动/重连；权限拒绝可解释；未验证组合不能标记可用。 |
| 日志恢复 | 服务输出 stdout/stderr 和 unified log；重启 UI、轮转日志，再请求历史。 | 按实例关联，无跨用户泄漏；游标/轮转/保留规则正确；无权限读取时清楚显示限制。 |
| 睡眠/卡顿/重复启动 | 睡眠唤醒、短时 UI 卡顿、同时打开两次启动器。 | 不因临时失联停止服务；入口接管/归还按契约收敛；不同时出现两名有效控制所有者。 |

## 来源与本机核对位置

所有外部论据来自 Apple 官方文档/Apple 员工明确答复。JavaScript 文档页无法直接抽取时，读取同一 Apple URL 的 `.md` 官方版本；引用链接保留常规文档 URL。归档资料用于基本模型，现代 SMAppService 行为以当前 API 文档与本机 SDK 为准。Apple 开源 [launchd 手册仓库](https://github.com/apple-oss-distributions/launchd/tree/main/man) 是历史版本，未用它冒充当前 `launchctl` 文本格式保证。

- [L1：本机 launchd.plist(5)](/usr/share/man/man5/launchd.plist.5)：读取 `man launchd.plist`；含 Label、BundleProgram、KeepAlive、RunAtLoad、MachServices、进程组、日志、隐私与依赖约束。
- [L2：本机 launchctl(1)](/usr/share/man/man1/launchctl.1)：读取 `man launchctl`；含 domain、bootstrap/bootout、enable/disable、kickstart、诊断输出限制和配置权限。
- [L3：本机 SMAppService.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/ServiceManagement.framework/Headers/SMAppService.h)：签名/包装、更新重登记、同步/异步注销、状态注释。
- [L4：本机 NSXPCConnection.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSXPCConnection.h)：公开代码要求接口及 macOS 13 availability。
- [L5：本机 xpc/connection.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/xpc/connection.h)：PID 复用、消息级代码要求及 API availability。

本研究没有证明实际服务在本机 macOS 27.0.1 上通过上述验收，也没有证明任何包装能通过 Mac App Store 审核。尤其尚未实测后台项用户操作、注销/重新登记时序、第三方签名身份、Dart/Flutter 原生桥接和跨进程日志权限。后续实现与真实验收在相应实施工单中进行；研究工单的结论仅是原语与边界核实。

[S1]: https://developer.apple.com/documentation/servicemanagement
[S2]: https://developer.apple.com/documentation/servicemanagement/smappservice/register()
[S3]: https://developer.apple.com/forums/thread/791948
[S4]: https://developer.apple.com/documentation/servicemanagement/smappservice
[S5]: https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum
[S6]: https://developer.apple.com/documentation/xpc/xpc_connection_get_pid(_:)
[S7]: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
[S8]: https://developer.apple.com/documentation/appkit/nsstatusbar
[S9]: https://developer.apple.com/documentation/appkit/nsstatusbar/statusitem(withlength:)
[S10]: https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)
[S11]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html
[S12]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/DesigningDaemons.html
[S13]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html
[S14]: https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos
[S15]: https://developer.apple.com/documentation/technotes/tn3126-inside-code-signing-hashes
[S16]: https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)
[S17]: https://developer.apple.com/forums/thread/681053
[S18]: https://developer.apple.com/forums/thread/837286
[S19]: https://developer.apple.com/documentation/foundation/nsxpcconnection/interruptionhandler
[S20]: https://developer.apple.com/documentation/foundation/nsxpcconnection/invalidationhandler
[S21]: https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()
[S22]: https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac
[S23]: https://developer.apple.com/forums/thread/783539
[S24]: https://developer.apple.com/documentation/security/app-sandbox
[S25]: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
[S26]: https://developer.apple.com/forums/thread/802443
[S27]: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
[S28]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups
[S29]: https://developer.apple.com/documentation/os/logging
[S30]: https://developer.apple.com/documentation/oslog/oslogstore
[S31]: https://developer.apple.com/documentation/oslog/oslogstore/local()
[L1]: /usr/share/man/man5/launchd.plist.5
[L2]: /usr/share/man/man1/launchctl.1
[L3]: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/ServiceManagement.framework/Headers/SMAppService.h
[L4]: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSXPCConnection.h
[L5]: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/xpc/connection.h
