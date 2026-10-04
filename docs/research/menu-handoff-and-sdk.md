# Flutter 菜单栏入口接管、归还与 Dart SDK 研究

核实日期：2026-10-04。研究工单：[核实 Flutter 菜单栏接管与失联归还机制](https://github.com/Ghost233/MacLauncher/issues/3)，父地图：[规划 MacLauncher：个人启动器、独立运行与 SDK 接管](https://github.com/Ghost233/MacLauncher/issues/1)。术语沿用 [CONTEXT.md](../../CONTEXT.md)。本文只核实官方原语、整理协议所需合作能力和待决策问题；没有运行应用、构建插件或实测完整协议。

## 已确定目标与研究结论

本轮目标是 Flutter macOS 菜单栏应用和供其他项目接入的 Dart SDK。独立应用先自行启动；MacLauncher 出现后成为统一入口，显示项目的状态、日志并调用其已声明的控制能力。独立应用收起自己的菜单栏入口，保留原窗口和运行能力；启动器崩溃或失联后恢复自身入口，已有运行实例不重启；启动器重新出现后找回同一已有运行实例。终端和容器服务可按自己的控制、查询和日志能力接入；GUI 入口协作另外需要 SDK 或协议。这些是本轮要求，不是平台自动提供的行为。

官方材料确认了可实现这一路径的局部原语：AppKit 可以控制自身 `NSStatusItem` 的可见性；Flutter 的 macOS 平台通道可以把 Dart API 接到本应用的原生实现；Dart socket 和原生 XPC 可作为另设的跨进程通信候选。[S1], [S4], [S6], [S7], [S9] **材料尚未证明完整入口接管、失联归还和已有运行恢复协议已经可靠工作。** 连接建立、应用身份、控制归属、显示确认、失联时机与服务生命周期都仍需项目自己的协议和后续验收。

## 平台事实与边界

| 已核实事实 | 对接入的含义 | 一手来源 |
| --- | --- | --- |
| `NSStatusBar.statusItem(withLength:)` 创建状态项；调用方必须保留其引用，否则对象析构时会从状态栏移除。 | 菜单栏入口的对象和生命周期由创建它的应用维护。 | [S2] |
| macOS 10.12 起，`NSStatusItem.isVisible` 可以显示或隐藏状态项；用户手动移除也可能改变该属性，支持 KVO。 | 可用自身原生桥接或既有菜单栏库的合作接口完成入口接管/归还；隐藏动作不是关闭窗口或停止服务的 API。 | [S1] |
| 可见性按 `autosaveName` 自动持久化并恢复；未设置名字时系统自动选名，设置 `nil` 也会回到自动命名。 | **`autosaveName = nil` 不能当作关闭隐藏状态持久化。** “上次因启动器接管而隐藏”不能直接代表本次仍有有效接管方。 | [S1], [S3] |
| 菜单栏空间不足而暂时不可见时，`isVisible` 仍可能返回 `true`。 | API 回读与用户肉眼能够找到入口不是同一验收项；需要菜单栏拥挤场景的 UI 验证。 | [S1] |
| Flutter macOS 官方例子在 Swift 中创建 `FlutterMethodChannel`，使用 `flutterViewController.engine.binaryMessenger`；插件包支持 Dart API 加 macOS 原生实现。 | Dart SDK 可以包含 macOS 插件；既有应用也可以提供自己的显示/隐藏回调，避免再造第二个状态项。 | [S4], [S5] |
| 平台通道连接 Flutter 客户端与其 host；官方 macOS 例子绑定本应用引擎。 | **平台通道不是两个独立 `.app` 的跨进程通信。** 同名 channel 不会自动让 MacLauncher 和项目相互发现；平台通道在各自进程内接原生 API，IPC 另选。此项是依据 API 结构的推导。 | [S4] |
| 官方平台通道说明要求原生侧发往 Flutter 的调用在平台主线程进行；macOS 例子的 handler 在 UI 线程调用。 | IPC 回调需要与 UI 操作协调，不能把网络/连接回调直接当成任意线程的菜单栏操作入口。 | [S4] |
| `applicationShouldTerminateAfterLastWindowClosed` 返回 `false` 会继续应用主事件循环。 | 关闭窗口、隐藏菜单栏入口、应用退出是不同生命周期动作。SDK 不能靠隐藏图标保证应用退出后服务存活。 | [S18] |
| Flutter 文档说明 macOS 构建默认签名并启用 App Sandbox；client 网络权限和 release 的 server 网络权限需要按能力配置，debug/profile 成功不能代表 release 成功。 | IPC 候选必须同时检查两端的分发形态和 entitlements。这里没有修改任何 entitlement。 | [S16] |

上述“自身状态项可合作隐藏”有明确公开 API 支持。此次材料没有建立一个由 MacLauncher 任意接管未合作应用状态项的公开 API；不能把 SDK 合作要求改写成所有 GUI 项目都能仅靠配置完成入口接管。

## 跨进程通信与发现候选

这里比较原语，不选定传输、端点路径、端口、消息格式或租约时长。

| 候选 | 官方证据 | 尚需决定或验证 |
| --- | --- | --- |
| Dart loopback socket | `ServerSocket.bind` 支持 loopback 地址，仅接受本机连接；端口 `0` 可由系统分配。`Socket` 提供收取字节的 stream 和发送字节的 sink。[S6], [S8] | 固定端口还是端点记录、端口占用处理、谁监听、如何找回后启动的一方、应用级消息边界、请求/回复、身份校验与 release 网络权限。仅绑定 loopback 不等于核实了项目绑定或调用方身份。 |
| Dart Unix domain socket | `InternetAddress` 的 `unix` 类型使用文件路径；Dart 官方变更记录说明 Linux/Android/macOS 支持 Unix socket，官方 SDK 测试包含路径地址的 bind/connect 和已有同名文件导致 bind 失败的断言。[S7], [S20], [S21] | 两端可访问的位置、路径长度、权限、端点占用、崩溃后的残留物与安全清理。测试源码存在不代表已在本机或本项目通过；不能不核实端点所有者就删除路径。 |
| 原生 XPC 匿名 listener | `NSXPCConnection` 是双向跨进程通道；匿名 listener 可以通过 `NSXPCListenerEndpoint` 被另一进程连接，endpoint 可以经已有连接传递。[S9], [S10], [S11] | 独立启动的两个应用首先如何获得 endpoint；该 API 本身没有解决启动顺序或共享发现。不要把 endpoint 当作已经确定的可持久文件格式。Swift/Objective-C 桥接和接口维护也需评估。 |
| 原生 XPC 命名 Mach service | `init(machServiceName:options:)` 连接的是在 `launchd.plist` 宣告名字的 LaunchAgent/LaunchDaemon。[S12] | 是否接受额外 agent、安装与注册职责、sandbox 与签名边界。不能只给 GUI app 填一个字符串，就声称获得可发现的跨应用服务。 |
| 分布式通知辅助发现 | `DistributedNotificationCenter` 可跨本机任务广播；官方明确延迟无上界、队列满时会丢通知，且内容不可信。[S15] | 可研究为“可能有新启动器/项目出现”的提示，收到后再主动握手；基于这些约束，不能作为唯一归属证据、唯一心跳或可靠控制命令通道。此用途判断是推导。 |

发现和控制需要分别验证：一个端点存在，只说明有线索；连接成功，仍不能直接说明对端是已关联项目或可用的统一入口。端点记录和通知都应触发实时核验，而非直接触发隐藏。

XPC 提供连接对端的 PID、EUID 等属性供 listener 接受/拒绝连接；macOS 13 起还可设置对端 code-signing requirement。[S9], [S19] 这些是可用校验原语，并非已经确定的 MacLauncher 信任契约。采用固定签名身份会影响本地未签名或不同团队的项目；采用绑定级凭证也需定义生成、保存和校验职责。socket 的本机地址和协议里自报的项目名同样不能替代这样的决定。

App Groups 是另一项约束，而非通用 SDK 的现成答案：Apple 文档将其用于同一开发团队的应用共享容器和 IPC；Unix socket 路径须在 app group 容器内，Mach/XPC 服务命名也有规则。[S17] 要面向哪些签名团队、是否同时支持 sandboxed/nonsandboxed 项目，应先由 HITL 决定。SDK 不应暗中要求所有独立项目加入同一个 App Group。

## 入口归属与服务控制必须分开

以下是从既定目标和原语边界推出的协议要求，尚非最终接口或已验收实现。

- **入口归属**表示谁承担用户可用的菜单栏入口；**服务控制归属**表示哪个当前会话可提交哪些服务命令。隐藏本地图标并不改变服务的创建者、退出策略或真实运行位置。
- 项目一端需要保留恢复自己入口的能力。若只有启动器负责发“归还”消息，启动器崩溃时该消息无法发出，目标不能成立。
- “项目已绑定”“socket 已连接”“启动器已有可操作入口”“项目已隐藏入口”应是分别可确认的事实。候选交接过程至少要覆盖握手、真实状态快照、统一入口准备、接管确认和本地可见性反馈，失败时重新核对当前会话。
- 独立进程之间的确认可能被中断。短暂双入口与短暂无入口哪个更可接受，决定准备/隐藏/确认的顺序；本文不替用户选择。启动器的 IPC 活着也不等于其 UI 可用，探测标准要覆盖用户要使用的入口。
- 服务命令要针对确切服务定义和运行实例；重复请求、过期连接和错误项目归属不能使同一启动/停止执行多次或落到新运行上。需要一种可区分启动器本次运行、独立应用本次运行和当前控制会话的机制；会话代次、唯一请求标识与去重/拒绝旧请求是候选方案，不是固定字段设计。
- 项目 ID、服务 ID、运行实例标识、应用进程会话和入口归属会话不宜混为一项。新启动器应重新核验旧服务，而不是把“本地记录说在运行”当作真实状态，或为重新获得入口而重新启动服务。

JevManager [参考快照](jevmanager-reference-snapshot.md) 尚未建立真实运行发现、可信实例身份、持久日志或重连契约；其历史退出规划还会停止自行创建的实例。因此本研究没有把这些能力视为现成 API。若某项服务仅活在独立应用进程内，独立应用自身退出/崩溃后的存续另需服务生命周期设计；入口接管协议不能恢复已经结束的那一次运行。

## 失联原语与候选归还策略

| 候选信号/机制 | 已核实原语与用途 | 局限和待决策点 |
| --- | --- | --- |
| 明确释放入口 | 两端 IPC 可以约定正常退出前的释放消息；消息含义由项目协议定义。[S8], [S9] | 可用于正常退出、解绑或用户选择退出接管；不能承担崩溃归还的唯一职责。退出中断和消息未达仍需其他路径覆盖。 |
| 连接关闭/错误 | socket 有收取 stream、错误/结束回调；XPC 的 interruption handler 会在远端退出/崩溃时调用，连接可能可重建；invalidation handler 表示连接不可建立或不能再重建。[S8], [S13], [S14] | 决定是否立即归还；恢复连接后必须重新握手。XPC interruption 不等于必须重建，invalidation 后不能继续发送；两者都不能直接等同于服务退出。仍需覆盖连接未断而启动器无响应。 |
| 心跳或探测回复 | 可在 IPC 上定义当前会话的请求/响应。Dart `Timer.periodic` 的实际调用间隔可能短于或长于设定间隔。[S8], [S9], [S22] | 漏一次不能证明对端死亡；谁发送、探测 UI 还是协议层、连续失败条件、重试和恢复策略待定。不能把定时器 tick 数当作精确失联时间。 |
| 时间有限的接管承诺（租约） | 可将“本次入口/控制归属仅在当前会话及时续约时有效”定义为应用协议；底层 IPC 和时钟只是实现材料。[S8], [S9], [S23] | 时长、续约频率、时钟、到期归还顺序、服务命令拒绝旧会话的规则都未决定；平台没有替本项目完成这份协议。超时代表当前承诺失效，不能证明服务失败。 |
| 睡眠/唤醒协作 | `NSWorkspace.willSleepNotification`、`didWakeNotification` 提供设备睡眠/唤醒通知，需在 workspace 的 notificationCenter 注册；Swift `ContinuousClock` 睡眠中继续计时，`SuspendingClock` 睡眠中暂停。[S23], [S26], [S24], [S25] | 睡眠是否消耗接管有效期、唤醒后重新确认再隐藏还是延长等待，需选策略。两种 Swift clock 均要求 macOS 13；不能假设 Dart timer 等价于其中某一种，也不能把跨进程、跨启动的原始 Instant 当作统一持久时间戳。 |

“快速归还”和“避免负载高、暂停、睡眠导致的假失联”有直接取舍。没有官方文档可以替个人使用场景选定心跳/租约时长，本文不给出秒数，也不把 TCP keepalive 或 XPC 断连当作可用性完整证明。

监测代码所在位置也影响覆盖范围：Dart 事件处理被阻塞时，在同一事件循环执行的检查和回调无法及时完成；把检测放到原生侧可能改变覆盖范围，但还必须把 UI 恢复交回可工作的 UI 路径。[S4], [S22] 这是实现约束的推导。独立应用自身卡死、主线程不能处理 UI、系统休眠或菜单栏空间不足时，不能承诺立即出现可点击图标。[S1] 后续验收要明确这些边界，而不是用“永不失联”掩盖。

## 最小 SDK 合作能力

以下是满足本轮目标需要的能力清单，不固定函数名、消息结构、包拆分或传输实现。

| SDK/项目合作能力 | 必须可观察的结果 |
| --- | --- |
| Dart 接入和 macOS 本地入口适配 | 项目可脱离 MacLauncher 启动；操作其实际状态项，且可以读取/报告当前显示结果；保留原窗口与打开窗口的动作。已有菜单栏库由项目合作适配，不能与 SDK 重复创建入口。[S1], [S4], [S5] |
| 绑定、能力声明、身份与发现 | 区分哪个项目已关联、哪项服务可控制、状态/日志从何处读取；端点发现后校验本次对端和协议兼容性。socket/XPC 支持传输，但这些语义由 SDK/项目定义。[S6], [S9], [S19] |
| 入口接管确认和本地归还 | 对当前会话确认统一入口可用，再执行双方约定的可见性转换；失联、解绑、协商失败可以由项目端恢复入口。显示失败必须可报告，不能先宣布接管成功。[S1], [S13], [S14] |
| 真正的服务适配回调 | 项目声明并执行其支持的启动、停止、状态/就绪查询；按能力报告不支持。入口变化和连接变化不触发隐含的服务停止/重启。这是目标要求，不是 Flutter 默认行为。 |
| 运行实例快照和重连 | 新启动器可以查询、核验已有运行实例及其身份，重新订阅状态，而非重新执行启动。应用自身重启后能否找回独立存活的服务由项目适配能力决定，不能伪造同一实例。 |
| 真实日志来源与恢复读取 | 声明真实日志来源、对应服务和运行实例、是否支持重连后补读；可表达缺口和不支持。SDK 可通过流传输字节/事件，但日志持久性、游标和保留策略仍需另定。[S8], [S9] |
| 当前会话命令约束与清理 | 拒绝旧归属/错误实例的命令；处理重复连接和请求，解除订阅、计时器和原生监听后不让旧回调改变新会话。多 Flutter engine 的插件实例可能有独立生命周期，不能假定永远只有一个注册实例。[S5] |

如果只登记项目配置而无 GUI 合作实现，可以展示其原有服务能力；不能因此声称已实现该独立应用的入口接管。SDK 没有理由强制成为服务宿主进程；服务由谁运行、谁停止、如何分离运行应由服务生命周期方案说明。

## 交给 HITL 的取舍

1. **接入和分发范围**：仅本机个人项目，还是同时面向不同签名团队、sandbox/App Store 和直接分发应用？这将约束 IPC 路径、entitlements 与身份方案。[S16], [S17], [S19]
2. **传输与发现**：选 Dart loopback/Unix socket，还是原生 XPC？谁监听，另一端先启动时如何发现，是否接受额外 LaunchAgent？官方原语不替项目完成发现。[S6], [S7], [S10], [S12]
3. **入口确认标准与过渡体验**：启动器哪一项状态算“入口可用”？交接/重连时可否短暂同时显示两个入口？可接受的归还延迟与假失联频率是什么？据此再决定探测、租约和时长。
4. **睡眠与无响应范围**：睡眠是否消耗有效期，唤醒如何重新确认；是否要求覆盖 Dart 阻塞或启动器 UI 卡死；主线程无法处理 UI 时的承诺边界是什么？[S4], [S22], [S23], [S24], [S25]
5. **临时隐藏与用户偏好**：用户自己移除图标与接管临时隐藏如何区分；新应用启动时如何避免恢复一份过期的隐藏状态；是否由 SDK 维护意图并覆盖 autosave 回读？`nil` 不是关闭持久化的方法。[S1], [S3]
6. **服务命令和实例身份**：统一控制是否独占、哪些动作可由原窗口并行触发、旧控制会话如何失效、真实状态/日志契约由各项目提供到什么程度？入口归还不应替用户重新解释成停止服务。

## 未来验收场景

下表是待执行验收，不是本次测试结果。需要记录状态项 API 回读、实际 UI、双方会话/协议事件、服务真实实例身份及日志连续性，才能证明目标。

| 场景 | 验收目标 |
| --- | --- |
| 独立应用先启动，MacLauncher 不存在/未关联/不兼容 | 自身入口和原窗口可用，服务按自身能力运行；不会为连接启动器而重启服务。 |
| MacLauncher 后启动；或启动器先启动、项目后启动 | 两种顺序均发现并核验对端，显示真实快照，双方确认后接管；同一已有运行实例不变化。 |
| 接管协商期间任意一端退出、连接中断或确认丢失 | 不永久丢失入口；未完成交接不误报成功，旧确认不覆盖新的会话。 |
| MacLauncher 正常退出、崩溃/强制终止、IPC 断开、UI 无响应 | 按已确定的归还规则恢复项目入口；原服务不中断、不新建实例；具体延迟与假失联标准须先确定。 |
| MacLauncher 重启，与旧回调/旧心跳同时到达 | 找回同一已有运行实例；旧会话不能续租、隐藏本地入口或执行服务命令。 |
| 独立应用自身退出/崩溃后重启 | 新应用会话重新确认入口归属，不沿用过期接管；仅在服务实际独立存活并可核验时重新接入旧实例。 |
| 双方同时重启、重复连接、两个启动器进程竞争 | 归属冲突可检测；若选择独占控制，项目只接受一个当前有效归属；旧会话不能继续提交有效命令，也不会创建重复服务实例。 |
| 系统睡眠、长睡眠后唤醒、锁屏/会话切换、事件处理延迟 | 按已决定的时间语义重核验，原运行实例保持；可说明何时短暂归还，何时重新接管。 |
| 接管隐藏后项目退出，下一次启动器缺席；用户手动移除图标 | 不因 autosave 恢复旧隐藏状态而永久无入口；临时接管与用户偏好遵循明确规则。 |
| 错误项目声明、过期端点/同名文件、错误签名或凭证 | 不接受错误归属，不发送服务控制、不隐藏入口；清理不删除仍属于活跃对端的资源。 |
| 重复启动/停止请求，停止旧实例请求与新实例出现竞争，退出中仍有命令 | 命令的目标和归属均核验；不误停新实例，不重复执行，不因 SDK 清理而停止本应继续的服务。 |
| 原窗口在接管前后打开/关闭；菜单栏空间不足 | 窗口行为保留；可见性 API 与实际入口可达性分别验证，项目不因入口适配退出。 |
| debug/profile/release 两端组合、受支持 macOS 最低版本、多 engine | 权限和原生插件生命周期在真实分发组合通过；不把 mock channel、文档示例或官方测试源码当作此结果。 |
| 状态/日志订阅断连重连，恢复窗口内日志发生变化 | 真状态重新查询；同一实例可识别；按声明能力补读或明确报告日志缺口。 |

## 未验证限制

- 未选定 IPC、发现协议、身份策略、控制归属机制、租约/心跳时长、消息版本或日志恢复格式。
- 未实测任何 Flutter macOS 插件、菜单栏库、跨 `.app` 连接、sandbox/release 权限、签名约束、睡眠行为或端点残留清理。
- 只确认平台原语存在，未证明“启动器退出时入口自动恢复”由 macOS/Flutter 自动完成；该行为必须由项目端合作实现。
- 入口接管不证明服务的分离运行；服务自身崩溃、独立应用宿主崩溃或用户明确停止后，不能把重新启动的实例说成原实例。
- 文档版本是读取时的材料，不是本项目安装版本：Flutter 页面反映 3.47，Dart API 页面反映 3.13.5。[S16], [S7] 部分原语有 macOS 10.12 或 13 的要求，最终最低系统版本尚未确定。[S1], [S19], [S23]

## 一手来源

Apple 页面若正文需要 JavaScript，本次同时读取其官方 `.md` 或 `tutorials/data` JSON 正文；下列链接指向正常文档页面。Dart SDK 测试文件只作为源码证据，没有运行。

- [S1 — Apple NSStatusItem.isVisible][S1]
- [S2 — Apple NSStatusBar.statusItem][S2]
- [S3 — Apple NSStatusItem.autosaveName][S3]
- [S4 — Flutter 平台通道与 macOS 示例][S4]
- [S5 — Flutter 插件开发与多引擎生命周期][S5]
- [S6 — Dart ServerSocket.bind][S6]
- [S7 — Dart InternetAddress 构造器][S7]
- [S8 — Dart Socket][S8]
- [S9 — Apple NSXPCConnection][S9]
- [S10 — Apple NSXPCListener.anonymous][S10]
- [S11 — Apple NSXPCListener.endpoint][S11]
- [S12 — Apple NSXPCConnection Mach service 初始化][S12]
- [S13 — Apple XPC interruptionHandler][S13]
- [S14 — Apple XPC invalidationHandler][S14]
- [S15 — Apple DistributedNotificationCenter][S15]
- [S16 — Flutter macOS sandbox 与 release entitlements][S16]
- [S17 — Apple App Groups entitlement 与 IPC 约束][S17]
- [S18 — Apple 最后窗口关闭后的退出决策][S18]
- [S19 — Apple XPC code-signing requirement][S19]
- [S20 — Dart 官方 changelog 中 Unix socket 的平台支持][S20]
- [S21 — Dart SDK 官方 Unix socket 测试源码][S21]
- [S22 — Dart Timer.periodic][S22]
- [S23 — Apple Swift ContinuousClock][S23]
- [S24 — Apple NSWorkspace.willSleepNotification][S24]
- [S25 — Apple NSWorkspace.didWakeNotification][S25]
- [S26 — Apple Swift SuspendingClock][S26]

[S1]: https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible
[S2]: https://developer.apple.com/documentation/appkit/nsstatusbar/statusitem(withlength:)
[S3]: https://developer.apple.com/documentation/appkit/nsstatusitem/autosavename-swift.property
[S4]: https://docs.flutter.dev/platform-integration/platform-channels
[S5]: https://docs.flutter.dev/packages-and-plugins/developing-packages
[S6]: https://api.dart.dev/dart-io/ServerSocket/bind.html
[S7]: https://api.dart.dev/dart-io/InternetAddress/InternetAddress.html
[S8]: https://api.dart.dev/dart-io/Socket-class.html
[S9]: https://developer.apple.com/documentation/foundation/nsxpcconnection
[S10]: https://developer.apple.com/documentation/foundation/nsxpclistener/anonymous()
[S11]: https://developer.apple.com/documentation/foundation/nsxpclistener/endpoint
[S12]: https://developer.apple.com/documentation/foundation/nsxpcconnection/init(machservicename:options:)
[S13]: https://developer.apple.com/documentation/foundation/nsxpcconnection/interruptionhandler
[S14]: https://developer.apple.com/documentation/foundation/nsxpcconnection/invalidationhandler
[S15]: https://developer.apple.com/documentation/foundation/distributednotificationcenter
[S16]: https://docs.flutter.dev/platform-integration/macos/building
[S17]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups
[S18]: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminateafterlastwindowclosed(_:)
[S19]: https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)
[S20]: https://dart.googlesource.com/sdk/+show/30e003e9a75453d15c62828c24763b052c414745/CHANGELOG.md
[S21]: https://github.com/dart-lang/sdk/blob/main/tests/standalone/io/unix_socket_test.dart
[S22]: https://api.dart.dev/dart-async/Timer/Timer.periodic.html
[S23]: https://developer.apple.com/documentation/swift/continuousclock
[S24]: https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification
[S25]: https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification
[S26]: https://developer.apple.com/documentation/swift/suspendingclock

时钟差异补充：[Apple WWDC22 Meet Swift Async Algorithms](https://developer.apple.com/videos/play/wwdc2022/110355/)。
