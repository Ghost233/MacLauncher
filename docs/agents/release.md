# 标准发布流程

所有者要求发正式版时，运行 `scripts/release.sh`。脚本完成版本进位、提交、推送与打 tag；tag 触发 [release.yml](../../.github/workflows/release.yml) 正式发布管线。无 tag 不发正式版。

## 用法

```sh
scripts/release.sh --dry-run   # 先空跑：打印版本计算与将执行的步骤
scripts/release.sh             # 确认无误后真实执行
```

前置条件由脚本强制检查，任一不满足即中止并说明原因：当前分支是 `main`、工作树干净、本地 `main` 与 `origin/main` 一致。

## 脚本行为

1. 从 `launcher/pubspec.yaml` 读取 `version`（版本唯一来源）。
2. patch 进位 +0.0.1；build 号（`+N`）重置为 1——它是单个语义版本内的构建计数，新语义版本从 1 重新计。pubspec 本不带 build 号时新版本也不带。
3. 写回 pubspec，提交（仅此文件），推送 `main`。推送 `main` 会同时触发 rolling `latest` 预发布管线，属预期行为。
4. 打附注 tag `vX.Y.Z+N` 并推送。tag 必须与 pubspec version **精确一致（含 build 号）**，否则 release.yml 的 validate-tag 步骤失败——所以 tag 带 `+N`，不是裸 `vX.Y.Z`。

每步失败即停；脚本中止时错误消息内含恢复命令，先读消息再动手。

## 失败后恢复

| 失败点 | 状态 | 恢复 |
| --- | --- | --- |
| 前置检查 | 无任何改动 | 按提示解决（切 main / 提交改动 / 同步远端）后重跑 |
| push main | 版本提交仅在本地，本地领先远端 | `git push origin main`，然后手工 `git tag -a vX.Y.Z+N <commit>` 与 `git push origin vX.Y.Z+N`；直接重跑会被同步检查拦下 |
| push tag | main 已推送，tag 仅在本地 | `git push origin vX.Y.Z+N`（重跑脚本会被「部分失败」检查拦下并给出同一命令） |

`vX.Y.Z+N` 以脚本中止前打印的「发布 tag」为准。

## 发版后验证

```sh
gh run list -R Ghost233/MacLauncher --workflow release.yml
```

管线绿灯且 GitHub Release 版本号与 `launcher/pubspec.yaml` 一致即完成。changelog 当前手工编写，Release notes 由管线生成固定文案。
