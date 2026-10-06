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
2. patch 加 1；达到 10 时 patch 归零、minor 加 1，例如 `1.0.6 → 1.0.7`、`1.0.9 → 1.1.0`。新版本统一使用三段式 `X.Y.Z`；历史 `+N` 后缀只用于读取当前版本，不延续到新版本，例如 `1.0.6+1 → 1.0.7`。
3. 写回 pubspec，提交（仅此文件），推送 `main`。推送 `main` 会同时触发 rolling `latest` 预发布管线，属预期行为。
4. 打附注 tag `vX.Y.Z` 并推送。tag 去掉 `v` 后必须与写回的 pubspec version **精确一致**，否则 release.yml 的 validate-tag 步骤失败。

每步失败即停；脚本中止时错误消息内含恢复命令，先读消息再动手。

## 失败后恢复

| 失败点 | 状态 | 恢复 |
| --- | --- | --- |
| 前置检查 | 无任何改动 | 按提示解决（切 main / 提交改动 / 同步远端）后重跑 |
| push main | 版本提交仅在本地，本地领先远端 | `git push origin main`，然后手工 `git tag -a vX.Y.Z <commit>` 与 `git push origin vX.Y.Z`；直接重跑会被同步检查拦下 |
| push tag | main 已推送，tag 仅在本地 | `git push origin vX.Y.Z`（重跑脚本会被「部分失败」检查拦下并给出同一命令） |

`vX.Y.Z` 以脚本中止前打印的「发布 tag」为准；恢复历史发布失败时，同样使用当时打印的完整 tag。

版本规则与 dry-run 无副作用检查：`python3 scripts/test_release.py`。测试使用临时本地 Git 仓库和本地裸仓库，不访问 GitHub。

## 发版后验证

```sh
gh run list -R Ghost233/MacLauncher --workflow release.yml
```

管线绿灯且 GitHub Release 版本号与 `launcher/pubspec.yaml` 一致即完成。changelog 当前手工编写，Release notes 由管线生成固定文案。
