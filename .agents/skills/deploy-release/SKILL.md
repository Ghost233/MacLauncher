---
name: deploy-release
description: 发布 MacLauncher 正式版（版本进位、推送、打 tag、触发 release.yml 出 DMG）。适用于用户要求发版、发布新版本、打 release tag 或 deploy release 时。仅在用户明确要求发正式版时使用。
---

# deploy-release

发布 MacLauncher 正式版。唯一执行入口是仓库脚本 `scripts/release.sh`；脚本行为与失败恢复的唯一事实来源是仓库文档 `docs/agents/release.md`，本 skill 不复述其实现。

## 步骤

1. 确认当前工作区是 MacLauncher 仓库，且用户明确要求发正式版。两者都成立才继续，否则停止并说明。
2. 空跑 `scripts/release.sh --dry-run`，向用户展示将发布的版本号与 tag。dry-run 输出无异常即继续下一步。
3. 执行 `scripts/release.sh`。完成标准：脚本输出「完成：vX.Y.Z+N 已推送」。脚本中途失败时，按错误消息与 `docs/agents/release.md` 的恢复表执行对应的 git 命令；恢复路径以该文档为准。
4. 验证：跟踪 release.yml 管线直到结束：

   ```sh
   gh run list -R Ghost233/MacLauncher --workflow release.yml
   ```

   gh 网络抖动时重试几次再下结论。完成标准：管线绿灯，且 GitHub Release 的版本号与 `launcher/pubspec.yaml` 的 version 一致。
