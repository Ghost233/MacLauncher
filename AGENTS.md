## Agent skills

### Issue 跟踪器

Issue 和规格保存在 `Ghost233/MacLauncher` 的 GitHub Issues，使用 `gh` CLI。参见 `docs/agents/issue-tracker.md`。

### 分类标签

使用默认的五种分类标签。参见 `docs/agents/triage-labels.md`。

### 领域文档

采用单上下文布局：根目录 `CONTEXT.md` 和 `docs/adr/`。参见 `docs/agents/domain.md`。

## 工程规范

- 修改 Dart、Flutter、原生桥接或检查脚本前，读取 [工程规范](docs/engineering.md)，执行与改动相关的检查并报告实际结果。
- 审查时以工程规范核对代码标准，以来源工单、领域文档与相关 ADR 核对产品行为；例外必须说明适用规则、原因及验证结果。
