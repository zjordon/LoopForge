# LoopForge MR 交付领域规则解读（internal/domain/mr.go）

> 解读 `internal/domain/mr.go` 的职责与设计，及其测试文件 `internal/domain/mr_test.go`、`internal/domain/mr_classify_test.go` 覆盖的场景。

## 一、mr.go 的作用

Go 没有"类"，该文件是 domain 层的一组**纯函数集合**（无状态、只依赖标准库），是 LoopForge 平台 **MR/PR 交付（Delivery）领域的核心业务规则库**。主要调用方：

- `internal/repo/delivery.go`（DeliveryRepo：MR 交付状态机与分析）
- `internal/repo/analytics_business_delivery.go`、`internal/repo/analytics_mr_merges.go`
- `internal/tracker/mr_delivery_sync.go`（基线提升 MR 的发现与同步）
- `internal/httpapi/assistant_workspace_mr.go`、`internal/httpapi/assistant_conversation_issue.go`

核心业务模型：**Agent 完成开发后产出 MR → MR 先合入集成基线分支（如 `agentflow/integration`）→ 再由"基线提升 MR"把基线合入默认主干（如 `master`）**。因此工蜂（Gongfeng，代码中以 `git.example.com` 代表托管域名）里的 `merged` 与"真正交付到主线"不是一回事，这个文件就是用来厘清这件事的。

按职责分为四大块：

### 1. MR 链接解析与规范化（多平台）

| 函数 | 作用 |
| --- | --- |
| `IsGitHubPRURL` | 判断文本是否**恰好是**一条 GitHub PR 链接（严格全匹配，而非"包含"） |
| `ParseGongfengMR` / `ParseGongfengMRs` | 从**自由文本**（如 run 产物、MR body）按出现顺序提取**去重**的工蜂 MR 引用；GitHub PR URL 会被等价映射成 `git.example.com/github:<owner>/<repo>/merge_requests/N` 统一处理；http 链接统一规范化为 https 的 `/-` 形式 |
| `ParseDeliveryMRURL` | 解析**存储的**单条 PR/MR 链接，支持 4 种形态：github.com PR、托管工蜂 MR、GitHub Enterprise PR（`https://host/owner/repo/pull/N` → `ghe:<host>/owner/repo`）、GitLab MR（`https://host/group/repo/-/merge_requests/N` → `gitlab:<host>/group/repo`）。**关键安全语义**：与 `ParseGongfengMRs` 不同，它不做自由文本搜索，避免 artifact 里"顺带引用"的其他主机链接被误认成 MR |
| `ExternalMRProject` | 把 `ghe:` / `gitlab:` 前缀的 project key 拆成 platform/host/path 并**严格校验**（host 必须是合法域名且不能是 `github.com`；路径段只能含 `[A-Za-z0-9_.-]` 且不能是 `.`/`..`；GHE 必须恰好 owner/repo 两段）——防止拼接出恶意目标 |
| `SameGongfengMR` | 两条 URL 是否指向同一 MR（忽略 `/-` 与非 `/-` 形式、http/https、大小写） |

### 2. 从 run 产物恢复 Issue 自身 MR 的优先级

`MRArtifactPriority`：当需要从多个 run 产物中挑选"哪个 MR 是这个 Issue 自己的"时打分排序：

- 名字/路径含 `patch`/`diff` → **0 分**（patch/diff 会引用**其他 Issue** 的 MR URL，最不可信）；
- `mr-body` → 40、`closeout` → 30、`e2e-report` → 20；
- nodeID 为 `mr` 或名字含 `mr` → 10；
- 其他 → 0。

### 3. 交付分析统计

- `AnalyticsDelivery.DeliveryMRList()`：兼容旧版"只有单个主 MR 字段"的分析数据。
- `SummarizeDeliveries`：把 Issue 级交付记录汇总成 `AnalyticsDeliverySummary`——SOP 成功数、需求/bugfix 分类计数、成本未知数、平均时长、执行时长 P50/P95、有 MR 的 Issue 数、直发（DirectDelivery）统计、**跨 Issue 去重后的 MR 总数及 merged/integrated 数**、token 与美元成本总额。
- 辅助函数：`recordDeliveryMRs`（同一 MR 多来源取最高状态）、`analyticsMRKey`（URL 形式不同但同一 MR 的去重键）、`analyticsPercentile`（最近邻分位数）、`NormalizeMetricCategory`（把 `需求开发/需求/feature/bug/bug修复/缺陷修复` 等中英文受控标签归一为 `requirement/bugfix/other`）。

### 4. 交付状态分类（最核心的业务规则）

- `NormalizeBranchName` / `SameGitBranch`：分支名归一（剥掉 `refs/heads/`、`origin/` 前缀，忽略大小写）。
- `IsMainlineBranch`：目标分支是否默认分支；默认分支未知时 `main` 和 `master` 都视为主线。
- `ClassifyMRDeliveryState`：把「工蜂 merge state + 目标分支」映射为分析状态：

| 工蜂状态 | 目标分支 | 结果 |
| --- | --- | --- |
| `merged` | 默认分支 | `merged`（已上主线） |
| `merged` | 集成基线或其他任何非默认分支 | `integrated`（只进了基线） |
| `merged` | 空 | `unknown`（绝不误报"已合入"） |
| `opened`/`closed` 等 | 任意 | 原样返回 |
| 空 state | 任意 | `unknown` |

- `AnalyticsMRRank`：状态优先级 `merged(3) > integrated(2) > opened/reopened/closed(1) > 其他(0)`，同一 MR 出现多条记录时取最优状态。
- `FinalizeAnalyticsDelivery`：补默认状态标签，并定义 **`Delivered =（SOP 成功或直发）且 MRState == "merged"`**——只有上了主线才算"已交付"。
- `BaselinePromoteIssueID`（哨兵值 `__baseline_promote__`）/ `IsBaselinePromoteIssueID`：标记"基线→默认分支"的提升 MR 行，**不是真实工作项**，所有统计排除它；repo 层保证它永不被降级。
- `EffectiveAnalyticsMRState`：工作 MR 只落在基线（`integrated`），但该 Issue 对应的基线提升 MR 已合入主线（issue 级状态为 `merged`）时，把工作 MR 升级为 `merged`。
- `KeepMainlineDeliveryLabel`：已标 `merged` 的记录不被后来查到的 `integrated`/`unknown`/空**回退覆盖**；但 `closed` 等确定性状态允许覆盖。
- `BranchListed`：commit 的 ref 名列表中是否含某分支（`origin/master` 能匹配 `master`）。
- `WorkLandedWithPromote`：只有时间数据时的兜底判断——工作合入时间 ≤ 提升 MR 合入时间则视为已上主线；任一时间缺失时不阻塞（返回 true）。

## 二、测试覆盖场景

测试与被测代码同包（`internal/domain`），属白盒测试，共两个文件。

### mr_test.go —— 链接解析 / 规范化 / 产物优先级

| 测试 | 覆盖场景 |
| --- | --- |
| `TestParseGongfengMR` | 从混合自由文本（含 `HEAD abc` 噪声）提取 `/-/merge_requests/138` 形式 MR；无 `/-` 的短形式 `x/y/merge_requests/1`；无 MR 文本返回 false |
| `TestParseGongfengMRAcceptsHTTPAndCanonicalizes` | 工蜂 MCP 返回的 **http** 链接被接受，并被规范化为 **https + `/-`** 的规范 URL；`SameGongfengMR` 能识别 http 与 https 是同一 MR |
| `TestSameGongfengMRIgnoresURLForm` | `/-` 与非 `/-` 两种 URL 形式指向同一 MR 时匹配；IID 不同（248 vs 183）则不匹配 |
| `TestParseGongfengMRsKeepsOrderAndDedups` | 多个 MR **按出现顺序**输出；同一 MR 以两种 URL 形式出现（`!282` 出现两次）只计一次 |
| `TestMRArtifactPriorityIgnoresPatches` | `repository-patch` 即使 nodeID 是 `mr` 也得 **0 分**（patch 引用别人的 MR）；`mr-body`(40) 必须高于 `closeout`(30)；无关产物（`notes`）0 分 |
| `TestIsGitHubPRURL` | 合法（带首尾空格、尾斜杠、repo 名含点 `web.go`）通过；**拒绝**：工蜂 MR、http 协议、伪造域 `github.com.evil.example`、`#discussion` 锚点、前后有其他文字、issues（非 pull）链接——本质是防注入/防误判 |

### mr_classify_test.go —— "主线 vs 基线"状态分类与汇总统计

| 测试 | 覆盖场景 |
| --- | --- |
| `TestClassifyMRDeliveryState`（表驱动，12 个并行子测试） | `merged`→`master`（默认分支）= `merged`；`origin/master` 前缀归一后仍算主线；默认分支是 `release/2.0` 时合入它也算 `merged`；`merged`→集成基线 `agentflow/integration` = `integrated`；`merged`→侧分支 `feature/x` 也 = `integrated`；`merged` 但无 target = `unknown`（**不误报已合入**）；`opened`/`closed` 原样保留；空 state = `unknown`；默认分支未知时 `main`/`master` 都算主线、基线分支算 `integrated` |
| `TestFinalizeAnalyticsDeliveryRequiresMainline` | SOP 成功 + `merged` = 已交付；SOP 成功 + 仅 `integrated`（只进基线）**不算**交付 |
| `TestEffectiveAnalyticsMRStatePromotesIntegrated` | `integrated` + Issue 主线已 `merged` → 升级为 `merged`；`integrated`+`integrated` 不变；`opened` **不继承**旧的主线标签 |
| `TestKeepMainlineDeliveryLabel` | 已 `merged` 的记录不被后来查到的 `integrated`/`unknown` 回退（target_branch 同步期间的保护）；`closed` 可覆盖；当前非 `merged` 时不阻止升级 |
| `TestBranchListed` | ref 列表中的 `origin/master` 能匹配 `master`；`release` 不匹配无关分支 |
| `TestWorkLandedWithPromote` | 提升前 1 小时合入的工作算已落地；提升后 1 小时合入的留在基线；工作时间为零值时不阻塞 |
| `TestSummarizeDeliveriesSplitsMainlineAndBaseline` | 1 个 `merged` + 1 个 `integrated` → `MRMerged=1, MRIntegrated=1, Delivered=1` |
| `TestSummarizeDeliveriesCountsMRsSeparatelyFromIssues` | **去重语义**：同一 Issue 的 MR 列表里，同一 MR 以 https 与 http 两种 URL 形式出现只计 1 次，两个不同仓库的 MR 计 2（`TotalMRs=2, MRMerged=2`），但 Issue/需求计数不重复（`WithMR=1, IssuesWithMergedMR=1, Issues=1`）、token 与成本正确累计；另一条交付记录再次引用同一 MR 别名时，全局去重后总数仍为 2 |

## 三、一句话总结

`mr.go` 是平台 MR 交付领域的规则中枢：上半部分负责**把各平台（GitHub/GHE/GitLab/工蜂）的 MR 链接解析、校验、规范化并安全去重**；下半部分定义**"合入集成基线 ≠ 交付，只有落到默认主干才算 merged/delivered"** 这条核心交付判定规则（含基线提升 MR 的升级与防回退保护），并支撑运营侧交付指标汇总（去重 MR 数、P50/P95 等）。两个测试文件分别验证了"链接解析的健壮性与防误判/防注入"和"主线 vs 基线状态机的每条边界规则 + 汇总去重语义"。