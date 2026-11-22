# LoopForge Run 启动（internal/engine/run_start.go）解读

> 梳理 `internal/engine/run_start.go`（约 210 行）的主要逻辑：run 的"出生证明"——入口链、工作分支分配、快照冻结、执行位置决策、租约与排队，以及对应的测试覆盖。
> 前置阅读：`docs/learning/engine.md`（Engine struct 与包结构）、`docs/learning/node_execute.go`（run 启动后的调度执行）。

## 一、文件定位：run 是怎么"出生"的

本文件回答一个问题：**从一次 `Start` 调用到 `go e.execute(...)` 拉起调度循环之间发生了什么**。它决定 run 的全部"先天天赋"：

- 工作流快照（含沙箱、预览节点、仓库目录布局）；
- 多仓库的工作分支怎么分；
- 这个 run 在**哪台机器**上执行（责任人执行机器 / 云池 / 本机云模式）；
- 是否持有租约、是否被项目并发上限排队。

### 入口链（调用方 → 核心）

```
Start(workflowID, input)                                    // 最简：无仓库
StartWithContext(workflowID, input, repository)             // 单仓库（httpapi / 定时任务）
StartWithExecutionContext(..., executionContext)           // 单仓库 + 遥测上下文（Issue 派发）
StartWithRepositoriesContext(..., repositories, ...)        // 多仓库（最终汇聚点）
        ↓
startWorkflow(workflowID, ...)                              // 查目录 → 取工作流定义
        ↓
startWorkflowDefinition(wf, ..., workspace bool)            // ★ 全部逻辑在这里
        ↑
StartConversationWorkspace(...)（chat_workspace.go）         // workspace=true：对话工作区
```

### 协作函数地图

| 函数 | 所在文件 | 作用 |
| --- | --- | --- |
| `normalizeRepositories` | repository_workspace.go | 去空/去重，保序 |
| `domain.AssignRepositoryDirs` | domain/project.go | 给每个仓库分配一级子目录（WorkspaceDir），交付物留在 run 根 |
| `defaultWorkflowSandboxProfile` | workflow_graph.go | 空沙箱 ID 回退 `local` |
| `domain.AttachPreviewBuild` | domain/preview_build.go | 启用了预览契约但缺构建节点时，自动追加 `af-preview-build` 节点（幂等） |
| `validate` | workflow_graph.go | 工作流校验（含 RunOnWorkspaceRebuild 只许 script 节点等） |
| `resolveSandboxResources` / `resolvedSandboxSnapshot` | run_environment.go | 解析 dockerfile/environment 并**冻结**成 `SandboxSnapshot` |
| `workflowSandboxRequirements` | node_execute.go | 逐节点汇总 CLI provider 需求（agent 缺失/执行器缺失在此报错） |
| `defaultWorkBranch` | repository_workspace.go | 无 Issue 时生成分支名（时间戳 + 随机后缀） |
| `domain.DefaultWorkBranch` | domain/work_branch.go | 按 Issue 生成分支名（`feature/fix-issue-N-日期-时分`） |
| `e.repo.DefaultRunner` / `cloudPoolRunner` / `cloudPoolRequired` | repo / cloud_pool.go | 执行位置候选 |
| `requireWorkBranchCapabilities` | runner_dispatch.go | runner 版本门禁（见下） |
| `inheritSOPHandoff` | legacy_handoff.go | 子 SOP 继承父 run 的交接产物引用（跨项目拒绝） |
| `claimRunning` | run_recovery.go | 登记 `e.running`，防同一进程对同一 run 双开 execute |
| `e.event` / `e.publish` | run_events.go / run_state.go | 出生事件与订阅者广播 |
| `e.repo.PutRun` | repo/run_admission.go | **落库 + 项目并发准入**（超限置 `queued`） |

## 二、核心逻辑拆解

### 2.1 `assignWorkBranches` —— 多仓库工作分支分配

规则（注释即规格）：

1. **ReadOnly 仓库永远没有工作分支**（只读 checkout：可读、可构建、可测试，绝不 commit/push），残留的 stale 分支名清空；
2. 首仓库的分支**只有在"无特殊标志"时**才作为整条 run 的共享分支：`RequireExistingWorkBranch`（续已有分支）或 `CreateNewWorkBranch`（强制新建）标志的分支**只属于它自己**，不外溢；
3. 其余没有分支的仓库：继承共享分支；没有共享分支就用 `generate()` 生成一个（之后所有缺分支的仓库共用这个生成值）。

`generate` 闭包的取名优先级：执行上下文带 `IssueID` 且能查到 Issue → `domain.DefaultWorkBranch(issue, now)`（`feature/fix-issue-5-20260817-2254`）；否则 `defaultWorkBranch(issueNumber, issueID, now)`（无 Issue 时 `feature/fix-20261030-1938-<随机>`，同分钟两次启动也不同名）。

**分支标志的下游契约**（由 `repository_workspace.go` 的 `prepareRepository` 与 runner 侧共同兑现）：`RequireExistingWorkBranch` 续远端分支、远端缺失即报错绝不另建替身；`CreateNewWorkBranch` 从基线新建、远端已有同名分支即报错（别人的分支不能悄悄续上）；两者互斥；共享基线分支不能当工作分支。runner 侧旧版本会忽略这些标志，所以启动时还有**版本门禁**：`RunnerVersionExistingWorkBranch = 0.7.0`、`RunnerVersionCreateNewWorkBranch = 0.9.1` 以下的 daemon 直接拒绝启动该 run（`requireWorkBranchCapabilities`），防止老 daemon 静默续上错误分支。

### 2.2 `startWorkflowDefinition` —— 十步出生流程

**① 归一化与目录分配**：`normalizeRepositories`（去空/去重）+ `AssignRepositoryDirs`（每仓库一级子目录；多仓库平权，注释明确"each is checked out into a first-level sub-directory, gets the same work branch"）。

**② 排空检查**：实例处于 draining（进程正在优雅退出）→ `ErrExecutionDisabled`。

**③ 剥离协作字段**：`CollaborationMode / TaskTitle / GroupMembers / SOPCheckpoint / GroupSOPHandoff / GroupHistory` 一律清空 —— 这些属于"编组协作"运行时语义，**不允许**从目录模板带进单次 run。

**④ 通用模板校验**（中文错误直接面向用户）：generic 工作流直接运行必须先选项目；项目不存在提示刷新重试。

**⑤ 补全与校验**：`defaultWorkflowSandboxProfile`（空 → `local`）→ `AttachPreviewBuild`（幂等注入预览构建节点）→ `validate` → 查沙箱 profile（不存在报错）→ workspace 模式额外校验 `ConversationSandbox` → `resolveSandboxResources` + `workflowSandboxRequirements`（agent/执行器缺失在这里提前失败，而不是等第一个节点跑挂）。

**⑥ 分配工作分支**：`assignWorkBranches`（见 2.1）。

**⑦ 执行位置三选一**（写进 `executionContext`）：

| 优先级 | 条件 | 结果 |
| --- | --- | --- |
| 1 | 子 SOP（`ParentRunID != ""`）或 `ExecutionPinned` | 沿用调用方给定的执行机器，不重新解析 |
| 2 | 责任人配置了默认执行机器（`DefaultRunner`） | `ExecutionRunnerID` = 该机器 |
| 3 | 项目云池有在线 runner（`cloudPoolRunner`）或云池强制（`cloudPoolRequired`） | `ExecutionPool = cloud`（runner 缺席时留空，等首个节点在线时绑定） |
| 4 | 都没有 | 本机云模式（`ExecutionMode = cloud`） |

命中 1–3 任一 → `ExecutionMode = runner` + `RunnerWorkspaceLayoutShared`（共享布局）。随后 `requireWorkBranchCapabilities` 做 runner 版本门禁（见 2.1）。

**⑧ 组装 Run 与冻结**：`wf.SandboxSnapshot = resolvedSandboxSnapshot(...)`（沙箱规格随快照冻结）；run ID 为 `run-<UnixNano>`；所有节点初始化为 `pending`；`RunID / TraceID / WorkflowID / WorkflowVersion` 回填执行上下文。

**⑨ 子 SOP 交接继承**：`ParentRunID` 非空 → 父 run 必须存在（否则"父 SOP 运行不存在"），`inheritSOPHandoff` 把父 run 的交接产物引用**复制进子 run**（而不是假设父目录里的文件对子 run 可见——跨机器执行时不成立）；跨项目继承被拒绝。

**⑩ 落库、事件与拉起调度**：

- workspace 模式：`Kind = workspace`、状态 `waiting`（对话工作区永远不被调度，等第一条消息再起任务）、事件 `workspace.created`；SOP 则状态 `running`、事件 `run.started`；
- **租约**：本实例可执行且非 workspace → 写 `OwnerInstanceID / Generation=1 / LeaseUntil`。注释阐明部署语义："控制面持久化一行**无主**的 running 记录，worker 通过 `ResumeInterruptedRuns` 认领；混合实例则**带着租约**插入，防止另一进程对同一 run 启动第二个 execute()"；
- `PutRun` 落库 —— **repo 层的并发准入**可能把 run 改置 `queued`（项目并发上限），落库后重读拿真实状态，`publish` 通知订阅者；
- 收尾分支：`!executeRuns || queued || workspace` → 直接返回（不调度）；否则 `claimRunning` 抢占本进程执行权（防双开），成功则 `go e.execute(ctx, id)` 交给调度循环（见 node_execute.md 第二节）。

### 2.3 `executes()` —— 小而关键

`executeRuns && !draining`。控制面专用实例（`ConfigureExecution(..., enabled=false)`）与正在排空的实例都不执行 run；`ResumeInterruptedRuns`、`Drain` 等恢复/退出路径都先问它。

## 三、测试覆盖映射

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestAssignWorkBranchesKeepsExplicitBranchesToTheirRepository`（conversation_branch_choice_test.go） | 2.1 的全部分支规则：显式分支（无标志）成为 run 共享分支；`CreateNewWorkBranch` 的分支**不外溢**到其他仓库（其余仓库用生成值）；ReadOnly 仓库分支被清空；未带标志的首仓库分支仍作为 run 分支共享 |
| `TestStartUsesFreshWorkBranchPerSOP`（engine_test.go） | 同一 Issue 的**新 SOP run** 用全新分支（带时间戳，不复用上次失败的 `feature/old-sop-branch`）；分支名经 `domain.DefaultWorkBranch` 从 store 里的 Issue 生成 |
| `TestDefaultWorkBranchIncludesHourMinute`（engine_test.go） | Issue 分支命名含"日-时分"：`feature/fix-issue-5-20260817-2254` |
| `TestDefaultWorkBranchKeepsUnrelatedRunsApart`（work_branch_name_test.go） | 无 Issue 的 run（对话工作区/自由协作）**同一分钟两次启动也各自得名**（随机后缀），且用 `git check-ref-format` 验证是合法分支名 |
| `TestPrepareRepositoryCreatesCallerNamedBranchOnly` / `TestResumeRejectsRemoteBranchCreatedElsewhere`（repository_workspace_new_branch_test.go） | 分支标志的**下游契约**（2.1 末段）：新建分支不随 checkout 发布；远端已有同名分支报"已存在"而非静默续上；共享基线分支拒绝当工作分支；续+建互斥；缓存的 workspace resume 时同样执行"远端他建的分支"检查（#80 回归），不切分支、不检出他人文件、不丢本地工作；自己创建并推送过的分支 resume 不误报碰撞 |
| `TestStartDefaultsEmptySandboxProfileToLocal`（engine_test.go） | ⑤ 空 SandboxProfileID 默认 `local`，且冻结进 run 快照 |
| `TestStartInjectsPreviewBuildNode`（preview_finalizer_test.go）+ `TestAttachPreviewBuildAppendsCodeBuddyNode` / `TestAttachPreviewBuildIsIdempotentAndStrippedFromCatalog`（domain/preview_build_test.go） | ⑤ 预览契约启用时启动自动注入 CodeBuddy 构建节点；注入幂等；用户手放的节点保留位置 |
| `TestRunUsesFrozenWorkflowSnapshotDuringConcurrentEdits`（engine_test.go） | ⑧ 快照冻结：run 启动后目录中的工作流被编辑（删节点）不影响进行中的 run |
| `TestQueuedSOPDoesNotStartAndCancelDoesNotOccupy`（run_admission_test.go） | ⑩ 准入排队：项目并发满员时 `PutRun` 返回 `queued` —— 无 OwnerInstanceID、无调度器（`ActiveRunCount()==0`）、节点保持 pending、只有一条 `run.queued` 事件；排队 run 不可删除；Cancel 生效且 `AdmissionState=unstarted`、不占用晋升名额 |
| `TestQueuedSOPAutomaticallyStartsAfterSuccess`（run_admission_test.go） | 排队 run 在占用者成功后自动晋升启动（`ResumeInterruptedRuns` 驱动），晋升通过订阅通道发布（不能还是 queued） |
| `TestStartInsertsLeasedRunAndBlocksOtherResume`（run_lease_test.go） | ⑩ 租约：可执行实例启动即带租约插入，阻止另一实例 resume 抢跑（双开防护） |
| `inheritSOPHandoff` 断言（state_helpers_cases_test.go / ops_validation_cases_test.go） | ⑨ 子 SOP 继承交接产物引用；**跨项目继承被拒绝**；父 run 缺失报"父 SOP 运行不存在" |
| `TestRepositoryScopedRoleGateAndScriptArtifacts`（execution_scope_test.go）/ `TestSingleRepositoryKeepsDeliverablesAtRunRoot`（engine_test.go） | ① 目录分配的实际效果：多仓库各占一级子目录、产物带 `RepositoryDir`；单仓库交付物留在 run 根 |
| conversation_workspace_test.go 一族（engine 包） | workspace=true 路径：`Kind=workspace`、状态 `waiting`、不被 `execute` 调度（`IsWorkspace` 守卫）；由 `StartConversationWorkspace` 进入 |

## 四、贯穿全文件的设计不变量

1. **出生即冻结**：工作流定义、沙箱规格（`SandboxSnapshot`）、仓库目录布局、执行上下文在 `startWorkflowDefinition` 一次性确定；此后目录再怎么改都不影响本 run —— 与 node_execute.md 的"快照隔离"不变量首尾呼应。
2. **多仓库平权，交付物居根**：每个仓库一等公民（一级子目录 + 同一工作分支 + 定时 run 各自的集成合并与 MR），SOP 交付物永远在 run 工作区根、不进任何 checkout。
3. **分支归属精确到意图**：显式续/建的分支只属于声明的仓库；ReadOnly 无分支；生成的分支同分钟不同名 —— 配合下游 prepareRepository 的"绝不静默续别人的分支"契约与 runner 版本门禁，构成完整的分支安全链。
4. **执行位置在出生时决定**：子 SOP 沿用父 run、否则责任人默认机器 → 云池 → 本机；位置写进执行上下文，后续节点执行（node_execute.go ⑤）只读不再猜。
5. **建 run 与执行 run 分离**：控制面可写"无主 running 行"交给 worker 认领（`ResumeInterruptedRuns`）；混合实例带租约插入 + `claimRunning` 双保险，同一 run 永远只有一个 execute()。
6. **排队是一等状态**：项目并发准入在 repo 层生效，启动路径尊重 `queued`（不调度、不占位、可取消），晋升后自动接续。
7. **失败要早**：generic 模板没选项目、沙箱缺失、agent/执行器缺失、runner 版本不支持分支标志 —— 全部在启动时以中文可读错误拒绝，不带病开跑。

## 五、如何运行相关测试

```bash
# 工作分支分配与命名
go test ./internal/engine -run 'TestAssignWorkBranches|TestDefaultWorkBranch|TestStartUsesFreshWorkBranch|TestPrepareRepositoryCreatesCallerNamed|TestResumeRejectsRemoteBranch' -v

# 启动、快照、排队、租约
go test ./internal/engine -run 'TestStartDefaultsEmptySandboxProfile|TestStartInjectsPreviewBuild|TestRunUsesFrozenWorkflowSnapshot|TestQueuedSOP|TestStartInsertsLeasedRun' -v

# 预览注入（domain 层）
go test ./internal/domain -run 'TestAttachPreviewBuild' -v
```

注意事项与前两篇相同：engine 测试依赖 Unix 独有 syscall，只能在 Linux/macOS（或 WSL/容器）下构建运行；分支类测试需要 PATH 中的 `git`。

---

*本文基于 `internal/engine/run_start.go`（约 210 行）静态梳理，并核对了 conversation_branch_choice_test.go、work_branch_name_test.go、repository_workspace_new_branch_test.go、run_admission_test.go、run_lease_test.go、preview_finalizer_test.go、domain/preview_build_test.go 及 engine_test.go 中相关断言。run 启动之后的调度与执行见 `docs/learning/node_execute.md`，人机操作（Approve/Reject/Retry/Pass）见 `docs/learning/engine.md` 第六节。*


