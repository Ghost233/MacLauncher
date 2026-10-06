# Issue 跟踪器：GitHub

当前仓库的 issue 和规格保存在 `Ghost233/MacLauncher` 的 GitHub Issues 中。所有操作使用 `gh` CLI。

## GitHub 账号

必须使用 `Ghost233`。执行需要身份验证的 `gh` 业务命令前，先运行 `gh auth switch --hostname github.com --user Ghost233`，再运行 `gh api --hostname github.com user --jq .login`。只有实际身份返回 `Ghost233` 才能继续；环境中的 `GH_TOKEN` 或 `GITHUB_TOKEN` 也必须满足该要求。切换或验证失败时，停止后续操作并告知用户。

deck 插件的建票/改票工具（`deck_issue_create`、`deck_issue_patch` 等）内部走 `gh` 活跃账号，同样适用上述前置：调用它们之前必须先完成验证，否则票会以错误账号创建（真实事故：#39/#40 以 Charlotte-765 创建后删除重建）。

## 约定

- **创建 issue**：`gh issue create --title "..." --body-file <正文文件>`。多行正文先写入临时文件，保留真实换行。
- **读取 issue**：`gh issue view <number> --comments`，使用 `jq` 过滤评论，并同时获取标签。
- **列出 issue**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，按需使用 `--label` 和 `--state` 过滤。
- **评论 issue**：`gh issue comment <number> --body-file <正文文件>`。
- **添加/移除标签**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`。
- **关闭**：`gh issue close <number> --comment "..."`。
- **并行实施 worktree**：一律建在仓库外的 sibling 目录 `../MacLauncher.worktrees/<name>`。仓库内的 `MacLauncher.worktrees/` 不在 .gitignore，建在 repo 内会污染 `git status`。

在当前 clone 内运行时，`gh` 从 Git remote 推断仓库。需要明确目标时使用 `--repo Ghost233/MacLauncher`；`gh api` 的仓库端点使用 `repos/Ghost233/MacLauncher/...`。

## 把 Pull Request 作为分类入口

**把 PR 作为请求入口：no。** _（如果当前仓库把外部 PR 视为功能请求，改为 `yes`；`$triage` 会读取此标志。）_

设为 `yes` 时，PR 使用与 issue 相同的标签和状态，并改用对应的 `gh pr` 命令。

GitHub 的 issue 与 PR 共用编号空间，因此单独的 `#42` 可能是任一类型。先运行 `gh pr view 42`，失败后再运行 `gh issue view 42`。

## Skill 要求“发布到 issue 跟踪器”时

创建 GitHub issue。

## Skill 要求“获取相关工单”时

运行 `gh issue view <number> --comments`。

## 寻路操作

供 `$wayfinder` 使用。**地图**是一个 issue，**子 issue**作为工单。

- **地图**：带 `wayfinder:map` 标签的单个 issue，正文保存 Notes / Decisions-so-far / Fog。使用 `gh issue create --label wayfinder:map`。
- **子工单**：作为 GitHub sub-issue 连接到地图的 issue（对 sub-issues 端点使用 `gh api`）。未启用 sub-issues 时，把子项加入地图正文的任务列表，并在子 issue 正文顶部写 `Part of #<map>`。标签使用 `wayfinder:<type>`（`research`/`prototype`/`grilling`/`task`）。认领后把工单分配给主导开发者。
- **阻塞**：优先使用 GitHub **原生 issue 依赖**，这是规范且 UI 可见的表示。使用 `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>` 添加边；`<blocker-db-id>` 是阻塞项的数字 **database id**（`gh api repos/<owner>/<repo>/issues/<n> --jq .id`），_不是_ `#number` 或 `node_id`。`issue_dependencies_summary.blocked_by` 只报告开放阻塞项，是实时关卡。依赖功能不可用时，在子 issue 正文顶部使用 `Blocked by: #<n>, #<n>`。所有阻塞项关闭后工单解除阻塞。
- **前沿查询**：列出地图的开放子项（`gh issue list --state open`，限定到地图 sub-issues/任务列表），排除存在开放阻塞项（`issue_dependencies_summary.blocked_by > 0`，或 `Blocked by` 行中的某个 issue 仍然开放）或已有 assignee 的工单；按地图顺序取第一个。
- **认领**：`gh issue edit <n> --add-assignee @me`，这是会话第一次写操作。
- **解决**：运行 `gh issue comment <n> --body-file <回答文件>`，再运行 `gh issue close <n>`，最后把上下文指针（摘要 + 链接）追加到地图的 Decisions-so-far。

## 网络抖动与重试

本仓库的 GitHub API 调用在部分网络环境下频繁出现 TLS handshake timeout。所有 `gh` 写操作（建 issue、评论、接线、合并）外加「读后立即依赖其副作用」的读操作，都应套重试（建议 4 次、间隔 5s），例如：

```sh
retry() { for i in 1 2 3 4; do "$@" && return 0; sleep 5; done; return 1; }
retry gh issue comment 27 -R Ghost233/MacLauncher --body-file report.md
```

一次失败后不要立刻改判「操作未发生」——先重试或先读回状态验证。重试只针对网络类失败；确定性报错（如 `Unknown JSON field`）重试无意义，直接修正命令。

gh 命令必须在仓库目录内运行或显式 `-R Ghost233/MacLauncher`。
