# LoopForge 源码学习手册（五大主题定向阅读）

> 基于 2026-11-21 的 main 分支（0.4.0+）实测代码坐标整理。配合知识库会话给出的「五样要偷的东西」框架，把每个主题落到**具体文件、具体行号、具体符号**，并给出阅读顺序、行为规格测试与动手验证方法。所有行号以当期检出为准，漂移时按符号名搜索。

## 第 0 步：全局地图（30 分钟，不要跳过）

1. 读 `docs/architecture.zh-CN.md`（10 行级别的目录职责表）；
2. 记住三条纵向边界：`internal/httpapi`（每域一个 handler）→ `internal/engine`（编排）→ `internal/repo`（每域一个 Repo）/`internal/runtime`(执行) 。规则契约见根目录 `AGENTS.md`；
3. **把 CHANGELOG.md 当索引用**：每个特性带 PR 号（如 #717 发起 MR 节点、#974 工作区绑定），`git log --grep "#717"` 可直接定位实现提交；
4. 体量预期：engine ≈ 3.5 万行 / repo ≈ 3.8 万 / runtime ≈ 4.4 万，其中 engine 61% 是 `_test.go`——**测试就是行为规格**，读不懂实现时先读测试；
5. 跑一遍测试建立手感（Linux/WSL，需 Go 1.26+）：
   ```bash
   bash scripts/build-chatbot.sh && go test -p=2 ./internal/engine/... -count=1
   ```

---

## 主题一：MR 双门禁——引擎侧如何防住 agent 谎报（半天）

**为什么值得学**：LLM 节点的自述不可信。LoopForge 的答案是让**引擎**用两道独立门禁复核交付：命令门禁（确定性 shell 检查）+ `mr` 门禁（引擎直查 Git host）。这是所有「AI 产出需要验证」系统的通用范式。我们部署中亲历过它的价值：0.3.x 时代没有这道门，agent 说「分支已就绪」但没推送，工作区一清理代码就没了。

**阅读顺序与坐标**：

| 顺序 | 位置 | 看什么 |
|---|---|---|
| 1 | `internal/domain/mr.go` | MR 工件解析：从 `mr-body.md` 提取链接/分支/SHA 的纯函数，先建立数据形状 |
| 2 | `internal/engine/gate_submit.go:44-128` | 门禁结论回流：`readGateResultFrom`（Agent 经 MCP 写盘的 JSON）→ `applyGateResult`（pass/rework/fail/human 四态） |
| 3 | `internal/engine/gate_mr.go:40` | **核心**：`verifyRunMRs`——引擎以 run 身份查 GitHub/工蜂，验证「每个有新提交的工作分支都有 MR 且 head=推送的 tip」；`mrCoverageProblem:88` 是不通过时的判定文案，读它等于读验收规则 |
| 4 | `internal/engine/node_execute.go:786-999` | 门禁在节点循环里的位置：`runOnce` → 读门禁 → 命令门禁 `gateExec` → 轮次耗尽转人工 |
| 5 | `migrations/033_generic_sop_mr_node.sql` | 出厂定义：两道门禁的完整 JSON（命令门禁的 shell 脚本值得逐行读——检查未提交改动/工作分支/远端 tip） |

**行为规格（读测试当文档）**：`internal/engine/gate_mr_test.go`（MR 查证矩阵：开/合/旧 head/错分支）、`engine_test.go:660-740`（mr 节点产物契约）。

**动手验证**：在我们实例上跑一条需求到「发起 MR」，故意在 GitHub 上把 PR 关掉，观察 `mr-opened` 门禁失败 → 自动带反馈重试一次 → 转人工（run 页会出现在「待我确认」）。

---

## 主题二：requirements 数据模型——一条需求贯穿 chat/SOP/成本（半天）

**为什么值得学**：LoopForge 没有独立的"conversations"表，**Issue（需求）是贯穿一切的锚**：GitHub 同步进来的工作项、chat 里创建的需求、SOP run 的 `issueId`、成本归集，全部挂在同一实体上。想理解「需求 → 交付 → 度量」闭环怎么建模，看这里。

**阅读顺序与坐标**：

| 顺序 | 位置 | 看什么 |
|---|---|---|
| 1 | `internal/repo/models.go:8-14` | 全库表设计的元模式：「少量过滤/锁列 + payload JSON 列」——理解它，60 张表就看懂了一半 |
| 2 | `internal/repo/models.go:250-300` | `issues` / `issue_comments` / `tasks` / `runs` 四张表的关联列（`repositoryId`、`workflowId`、`ExternalRef`） |
| 3 | `internal/domain/issue*.go` + `internal/tracker/github.go:194-240` | 需求实体与同步映射：`pullGitHubIssues` 如何把 GitHub Issue upsert 成需求（open→todo、本地澄清不被覆盖的合并逻辑在 `applyExistingIssue`） |
| 4 | `internal/repo/runs_conversation_test.go:92-102` | 成本归集：`AddConversationUsage` 按 issue 把 token 用量记账——「human touches 度量」的数据源 |
| 5 | `internal/repo/repo.go:169-223` | Store 装配：21 个领域 Repo 如何组合、跨域指针如何显式注入（RunsRepo 持 issues/catalog） |

**行为规格**：`internal/tracker/github_test.go:57-74`（同步不覆盖本地澄清）、`internal/repo/provider_credentials_test.go`。

**动手验证**：浏览器控制台（已登录实例）`fetch("/api/issues").then(r=>r.json()).then(l=>console.table(l.slice(0,5).map(i=>({id:i.id,src:i.source,wf:i.workflowId,st:i.status}))))`——直接看到主题二+主题五的联动。

---

## 主题三：SOP 图引擎——租约、并行、回退（一天，最大主题）

**为什么值得学**：这是一个**用 MySQL 行级租约做无主协调**的 DAG 执行器，没有 Redis/MQ。多 worker 认领、崩溃接管、分支并行、取消后复活兄弟分支、打回任意节点——分布式工作流引擎的核心问题它都用最朴素的构件解决了。我们亲历过它的行为：手动触发不走集成（`ScheduleJobID` 门）、成功后 1 分钟清工作区。

**三个核心文件先行的顺序**（体量实测 11-21：1245 / 1025 / 907 行）：

| 顺序 | 文件 | 抓主线索 |
|---|---|---|
| 1 | `internal/engine/engine.go:19-93` | Engine 结构体=全部状态的目录：`running`（每 run 一个调度器）、`runEnvs`、`cloudPool`、`execLocks` |
| 2 | `internal/engine/node_execute.go:16` | **主循环** `execute`：心跳（leaseTTL/3 续租+检查 pause/cancel）→ `readyNodes` 取就绪分支 → 每节点一个 goroutine（:166-185）→ `allSucceeded` 后 `integrateScheduledRun`（:128-140，注意 :130 处的 ScheduleJobID 门）。然后 `executeNode:316`（五类节点分派）、`resolveNodeExecutor:189`（执行器三级回退：角色→节点→默认 codebuddy） |
| 3 | `internal/engine/run_ops.go` | 人工干预面：`Approve:140`、`Reject:271`（目标+后代重置）、`Retry:359`；**重点精读 :560-572**——重跑时复活被取消的并行兄弟分支，这是图引擎最微妙的行为 |
| 4（补充） | `workflow_graph.go:11`（readyNodes 拓扑）、`run_recovery.go:66/107`（租约 CAS 与崩溃接管）、`parallel_exec.go:26`（keyedLocks 分层锁）、`integrate.go:53-90`（交付集成与集成分支门） |

**行为规格**：`run_ops_test.go`（审批/打回矩阵）、`run_recovery` 相关测试（接管语义）、`integrate_test.go:465-801`（冲突返工）。

**动手验证**：跑一条需求，开两个终端分别 `SELECT id,owner_instance_id,lease_until,generation FROM runs WHERE status='running'` 每 2 秒刷一次——亲眼看租约心跳与认领。

---

## 主题四：十 CLI 统一接入协议——Provider 抽象（半天）

**为什么值得学**：十种异构编码 CLI（CodeBuddy/Codex/Claude Code/OpenCode/Cursor/Antigravity/Kimi/Pi/DSH/ZCode）归一到一套接口+四种流协议，凭据按用户/Agent 隔离。任何「多供应商 LLM/Agent 接入层」都可以抄这个骨架。我们亲历：GLM 就是从 `BindClaudeCode` 这条缝接进来的。

**阅读顺序与坐标**：

| 顺序 | 位置 | 看什么 |
|---|---|---|
| 1 | `internal/runtime/provider.go:50` | `Provider` 接口本体（8 个方法）；:124 注册表：4 原生 Provider + 1 个 `agentCLIProvider` 统管其余 7 家 |
| 2 | `internal/runtime/protocol.go:19-28` | 四种流协议分类；`protocolTranslated` 的实现 `agent_cli_stream.go:162`——把 7 家原生流**改写成 Claude stream-json** 再复用一套解析器（关键复用技巧） |
| 3 | `internal/runtime/provider_agentcli.go:104-228` | `AgentCLICommand`：逐家拼 headless argv（opencode `run --format json`、cursor `-p --output-format stream-json`、dsh `--profile headless`…），对照着看最直观 |
| 4 | `internal/runtime/command_binding.go` | **凭据安全模型**：:46 先清空宿主全部凭据环境变量 → :114-123 `BindClaudeCode` 注入 `ANTHROPIC_API_KEY/BASE_URL` 到私有 HOME；对照 :87-94 `BindCodeBuddy` 的硬失败（就是我们最初撞到的「未配置 CodeBuddy API Key」） |
| 5 | `internal/runtime/sandbox_manager.go:14` + `sandbox_docker.go` | 沙箱池：信号量限并发、四种驱动、`--add-host host-gateway`（我们刚给上游提的 PR #1174 就在这） |

**行为规格**：`provider_credentials_test.go:35-62`（凭据注入/隔离矩阵）、`docker_cases_test.go`（容器参数）。

**动手验证**：在实例个人配置里切换执行器后发一条消息，`GET /api/bootstrap` 看 `executors` 目录如何随凭据变化。

---

## 主题五：chat 工作区 ↔ SOP 绑定（#974，半天）

**为什么值得学**：对话工作区可以**绑定到一个 SOP run 的工作区**（共享同一份检出），Main Bot 由此能接管/续跑 SOP——这是「@提及需求/角色」能力的地基，也是 chat 与 SOP 两条产品线合流的机制。

**阅读顺序与坐标**：

| 顺序 | 位置 | 看什么 |
|---|---|---|
| 1 | `internal/domain/assistant.go:207-213` | `WorkspaceRunID`（Main Bot 绑定的外部 run 工作区）与 `OwnWorkspaceRunIDs`（会话自己开的工作区）——先分清「绑别人的」和「自己的」 |
| 2 | `internal/engine/conversation_push.go:32` | 绑定判定的入口：什么时候把对话动作路由进已绑定的 run |
| 3 | `internal/engine/conversation_workspace.go` | 对话工作区生命周期：使用租约 token（:44）、空闲 checkpoint+清理（:301 起）——与 SOP run 工作区「终态即删」对照着读，理解为什么对话有恢复而 SOP 没有 |
| 4 | `internal/engine/sop_node.go:78` | Sub-SOP 通过 `WorkspaceRunID` 共享父 checkout——同一机制的图内用法 |

**行为规格**：`conversation_workspace_test.go`、`cloud_pool_test.go`、`domain/assistant_execution_target_test.go`（绑定目标的选择逻辑）。

**动手验证**：实例上从需求抽屉「创建并去对话澄清」，观察会话建立后 `GET /api/bootstrap` 里会话的 `workspaceRunId`；再在 chat 里 @ 一条需求看接管入口。

---

## 附：日程建议

| 天 | 上午 | 下午 |
|---|---|---|
| D1 | 主题三（SOP 图引擎）主循环+租约 | 主题三（run_ops 干预面）+ 主题一（MR 双门禁） |
| D2 | 主题二（repo/需求模型） | 主题四（CLI 协议） |
| D3 | 主题五（工作区绑定）+ 按兴趣回读 | 自由：挑一个 `_test.go` 全文精读当复盘 |

**三条通用读法**（对全部主题有效）：
1. **卡住就换测试读**：85 个 engine 测试文件是给行为写的说明书；
2. **CHANGELOG 反查**：看到不懂的行为，先在 CHANGELOG 搜关键词（十有八九有 PR 号和动机原文）；
3. **用运行实例对照**：本机 192.168.5.7:8090 的每条 run/需求/日志都是活教材，API（`/api/bootstrap`、`/api/runs/{id}`）比读代码更快建立数据形状直觉。

> 本手册的行号快照与实测体量基于 2026-11-21 检出（含 host-gateway 补丁）；上游演进后以符号名/测试名搜索为准。
