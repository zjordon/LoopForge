# LoopForge 节点执行核心（internal/engine/node_execute.go）解读

> 梳理 `internal/engine/node_execute.go`（包内最大文件，约 1200 行）的主要逻辑：run 级调度循环 `execute`、单节点执行管线 `executeNode`，以及各自的测试覆盖。
> 阅读建议：先看第二节的"执行管线 15 步"建立整体框架，再按第三节的测试映射表对照阅读源码。

## 一、文件定位：它在 engine 包里扮演什么角色

如果把整个 engine 包看作一个"SOP 执行虚拟机"，`node_execute.go` 就是它的**指令调度器 + 指令执行器**：

- `execute`（run 级调度循环）：决定**哪些节点现在可以跑**、什么时候 run 算完成/失败/等待、如何续租与响应取消/暂停；
- `executeNode`（节点执行管线）：把一个节点从 `pending` 推到 `succeeded / failed / waiting_approval`，串起沙箱、凭据、仓库、输入物化、Agent/脚本调用、门禁、产物收集的全过程。

engine.go 里的 `Engine` struct 只是状态载体，`Start*`（run_start.go）负责创建 run 并拉起调度，真正"跑起来"之后的一切都在本文件。

### 协作文件地图（executeNode 管线用到的关键函数都在哪）

| 协作文件 | 提供的能力 | 在管线中的位置 |
| --- | --- | --- |
| `workflow_graph.go` | `readyNodes / allSucceeded / hasWaiting / hasFailed / cancelledNode`（图状态判定） | execute 调度循环 |
| `lifecycle.go` | `settleStatusForCompletedGraph`、`continuingInterruptedAttempt` | 非 owner 实例结算、中断续跑 |
| `parallel_exec.go` | `lockNodeExec / lockAgentInvocation / registerNodeExecution / reconcileNodeExecutions` | 节点互斥、同角色 CLI 排队、可取消注册 |
| `node_outcome.go` | `waitApproval / nodeFailedAt / finishAt / pauseAt / finishInterruptedAt / requeueInterruptedNode / shouldCommitNodeOutcome / isMaxTurnsErr / applyGateResult 的失败策略判定` | 节点结局落盘 |
| `gate_submit.go` | `gateResultPath / readGateResultFrom / clearGateResult / applyGateResult / appendSubmitGateInstruction` | 提交门禁协议 |
| `gate_mr.go` | `verifyRunMRs` + MR 待合入命令 | MR 模式门禁 |
| `gate_bind.go` | `bindVerificationCommand`（grep/git diff 防呆改写） | command 门禁 |
| `execution_scope.go` | `executionTarget / bindExecutionTarget / executeForTargets` | run/repositories 两种执行作用域 |
| `run_environment.go` | `acquireRunEnvironment`、`resolveSandboxResources` | run 级共享环境 |
| `repository_workspace.go` | `prepareRepositories`（内部循环调 prepareRepository） | 仓库 checkout |
| `git_auth.go` | `withRunGitCredentials / withGitIdentity / withSSHKnownHosts` | 凭据注入 context |
| `assets.go` | `resolveAssets / resolveScriptMCPAssets / workflowAgent` | 角色资产解析 |
| `prompt.go` | `renderPromptWithStore / appendArtifactContract` | 任务书渲染 |
| `runner_dispatch.go` | `dispatchRunnerTask / dispatchRunnerScript / dispatchRunnerCommand / defaultExecutionRunner` | 执行机器（CLI Runner）模式 |
| `cloud_pool.go` | `bindPoolRunner` | 云池执行机绑定 |
| `sop_node.go` | `executeSOPNode` | 子 SOP 容器节点 |
| `workspace_preparation.go` | `PrepareNodeWorkspace / recordNodeWorkspacePreparation` | RunOnWorkspaceRebuild 准备脚本 |
| `codebuddy_auth.go` | `sponsoredExecutor` | 平台共享 CodeBuddy Key |
| `observability.go` | `attachLoopRetro / observe / flushAllObservations` | loop 复盘与遥测 |

## 二、核心逻辑拆解

### 2.1 `execute(ctx, runID)` —— run 级调度循环

一个 run 一个 goroutine 跑这个循环。整体结构是"**心跳线程 + 就绪节点扇出 + 每轮重读 run 状态**"：

**入口守卫（不调度的情况）**

- run 不存在 / 是会话工作区（`IsWorkspace`）/ 是历史编组（`HistoricalGroup`）/ 状态 `queued` / `AdmissionState == "unstarted"` → 直接清理返回；
- 本实例**不拥有**该 run（租约不在手）→ 尝试用 `settleStatusForCompletedGraph` 给已完成的图结算终态，然后退出。这保证多实例部署下只有 owner 推进 run。

**心跳 goroutine**（每 `leaseTTL/3` 一次）

1. `renewRunLease` 续租，失败即自我取消（丢了租约就不能再写状态）；
2. `runControlRequested` 检查暂停/取消标志；
3. `reconcileNodeExecutions` 清理已陈旧的节点执行注册。

**并行调度模型**

- `readyNodes(wf, r)` 算出就绪节点（依赖全部成功且自身 pending），减去 `inflight` 集合后**立即逐个起 goroutine** —— 分支各自独立推进，没有"波次等待最慢成员"；
- 每个节点 goroutine 结束时从 `inflight` 移除自己并向 `wake` channel 发信号唤醒主循环；
- `stopNodes()`：写终态/暂停前先 `cancel` + `nodesWG.Wait()` 排干在飞节点 —— **保证终态永远不会写在还有分支在跑的时候**；
- `defer`：cancel → 等节点 → 等心跳退出 → 释放租约 → 从 `e.running` 删除。

**每轮循环的状态机判定**（顺序即优先级）

| 条件 | 动作 |
| --- | --- |
| `ctx.Done()`（进程退出/丢失租约/控制中断） | `finishInterruptedAt` → 节点标记 interrupted 待恢复 |
| run 消失 / 已终态 / 工作区 | 直接退出 |
| `CancelRequested` | stopNodes → `finishAt("cancelled")` |
| `PauseRequested` | stopNodes → `pauseAt` |
| `Generation != 本轮世代` 或失去所有权 | 退出（新世代由 Retry/Reject 重新拉起） |
| 无就绪节点但有在飞节点 | 等 `wake` / 500ms 超时再转（**失败分支不得抢先结算 run**） |
| 全部成功 | `integrateScheduledRun`（定时 SOP 合入 integration 基线，可能触发 rework 再继续）→ `finishAt("succeeded")` |
| 有 `waiting_approval` 节点 | align 专用工作流自动通过审批；否则 run 置 `waiting` 后退出（等 Approve/Reject 重新拉起） |
| 有 `failed` 节点 | `finishAt("failed", pipelineFailedMessage)` |
| 有 `cancelled` 节点 | `finishAt("failed", "节点已取消，流水线无法继续；请从该节点重跑")`（不主动重排） |
| 其他（如刚被 reset 的节点） | sleep 80ms 重试 |

### 2.2 `resolveNodeExecutor` / `workflowSandboxRequirements` —— 执行器与沙箱需求解析

- **executor 选择优先级**：`agent.ExecutorID` > `node.ExecutorID` > 默认 `"codebuddy"`；
- `mock` 只允许出现在内置目录与测试/旧快照中；
- **legacy 兼容**：历史 Agent/快照持久化了任意 executor ID（自定义 binary/args），解析时只取其 `Kind` 映射到**内置 CLI**，绝不复用旧的 binary 和参数（安全），agent 未指定 Model 时继承 legacy Model；
- `agent.Model / agent.Effort` 覆盖执行器默认值；
- `workflowSandboxRequirements`：`script/command/approval/sop` 节点跳过（无需 CLI provider 环境），其余节点按"agent → executor → `runtime.ProviderRequirements(kind)`"汇总合并 —— 用于创建沙箱时预装 CLI。

### 2.3 Docker 镜像构建辅助

`dockerImageBuildLabel`（镜像名 → ID → 兜底"沙箱镜像"）、`dockerImageNeedsBuild`（无快照或镜像未缓存视为首次构建）、`formatElapsedCN`（"12 秒"/"2 分 15 秒"）、`bindDockerWorkspace`：绑定工作区前后发 `sandbox.image.building` / `sandbox.image.ready` 遥测并强制 flush —— 让用户在构建耗时数分钟时看到实时提示而不是黑盒等待。

### 2.4 `executeNode` —— 单节点执行管线（15 步）

这是全文件的心脏。按源码顺序分步（步骤号即代码出现顺序）：

**① 入口与互斥**：`lockNodeExec(runID, node.ID)` —— 只有**同一节点的重复执行**（resume/rework/接管竞态）串行，兄弟分支照常并行。节点必须仍是 `pending` 才启动；若残留错误是 cwd-mount 失败（exit 126）则直接判 failed 不再重试；`Attempt++`（续跑被中断的 attempt 不加，`continuingInterruptedAttempt`），置 running、发 `node.started` 事件。

**② 注册可取消执行**：`registerNodeExecution` 登记 cancel 函数，供 Cancel/心跳 reconcile 使用。

**③ `failNode` 闭包**：统一失败出口。ctx 已取消则忽略（区分"节点失败"与"run 被中断"）；`IsSandboxInterrupt` → `requeueInterruptedNode`（重新排队而不是失败）；否则走 `nodeFailedAt`（带 `allowReject` 决定是否可打回上游）。

**④ 节点类型分派**：`sop` → `executeSOPNode`（子 SOP 容器，见 sop_node.go）；`approval` → align 工作流自动通过（`gate.auto_approved`），否则 `waitApproval` 等人工批准。

**⑤ 执行机器绑定与沙箱获取**：`bindPoolRunner`（云池）；沙箱 profile 优先取**冻结快照** `WorkflowSnapshot.SandboxSnapshot`，无快照才查目录。关键分支：**责任人选择了默认执行机器时，控制面只建 `local` staging 工作区**（`xxx-runner-staging`）—— 真正的 Docker 隔离必须在执行机器上创建，在控制面建会把隔离放错宿主。`acquireRunEnvironment` 拿到 run 级共享环境（同 run 的所有节点复用一个沙箱）。

**⑥ 凭据注入**：把 git HTTP token、SSH key、git 身份写入 context，供后续 checkout 与脚本/门禁使用。

**⑦ 仓库 checkout（prepareRepositoriesOnce）**：`stagingCheckout` 判定 —— 执行机器自己负责 integrate 时控制面不 clone。失败处理是本文件的特色：**若本节点是"首个仓库 Agent"（`firstRepositoryAgent`）**，checkout 失败不判节点失败，而是记 `repositoryFallback`、发 `repository.preparation.fallback` 告警，把仓库准备交给这个 Agent 在其执行中兜底修复（prompt 前置一段修复说明）。

**⑧ 输入物化（两种模式）**：
- 执行机器支持 `SupportsReportedOutputs`：输入文件随任务下发（`runnerArtifactInputs`），产物由机器**上报**回来（`beginReportedOutputs`）；
- 否则本地模式：`materializeInputs`（祖先产物挂到 `.agentflow/inputs/`）+ `writeHumanContextFile`（人工上下文）+ `RestoreMissingWorkspaceArtifacts`（历史归档恢复）。

**⑨ Docker 绑定**：checkout 之后才 `bindDockerWorkspace`（见 2.3）。

**⑩ 预览构建节点特判**：`af-preview-build` 节点检测不到前端工程时 `completeSkippedPreviewBuild` 直接跳过成功（不影响业务交付）。

**⑪ 工作区准备脚本**：`PrepareNodeWorkspace`（RunOnWorkspaceRebuild 标记的脚本）；失败同样可交给首个仓库 Agent 兜底。

**⑫ 释放准备锁**：环境就绪即释放 `sb.nodeMu` —— 并行分支从这里开始自由使用环境；**兜底 Agent 例外**：它持锁直到 `completeRepositoryFallback`（校验 git 准备通过后）才释放，防止并行节点踩到半成品仓库。

**⑬ 构造 `runOnce` 闭包**（按节点类型）：
- `script/command`：python 用 `python3 -c` 包装；执行机器 → `dispatchRunnerScript`；本地 → 注入 MCP 资产后 `sb.Exec`；空输出自动生成中文执行摘要；发 `script.completed` 遥测；
- `agent`：解析 agent + executor（②的 `resolveNodeExecutor`）；`mergeArtifactContracts` 合并产物契约；组装门禁列表（agent 的 `Verification` + 必选 `Interventions` 转为 manual 门禁）；Loop 配置（`maxIterations / OnExhausted`）；`lockAgentInvocation` 让**同角色节点排队**使用共享 CLI 控制目录；渲染 prompt（占位符 + `{{artifacts}}` 替换 + 产物契约说明 + loop 反馈 + 断点续跑指令 + submit_gate_result 指令 + 仓库兜底前置）；`resolveAssets` + 知识库跳过告警；CodeBuddy 赞助 Key 替换（`sponsoredExecutor`，换模型并提示原模型不生效）；执行机器 → `dispatchRunnerTask`（门禁也调度到同一台机器、同一工作区）；本地 → `PrepareMCPServers` 后 `e.runner.Run`。

**⑭ 主执行循环**（iteration 1..maxIterations，即 Agent 自纠 Loop）：
1. 清掉上一轮的 `GateResult` 与结果文件；
2. `runOnce(loopFeedback)`；CLI 会话丢失 → `dropLostCLISession` 后重跑一次；"无终态 result"错误 → **不再重跑 Agent**，按工作区产物继续走门禁；
3. **提交门禁协议**（agent 节点）：读 `submit_gate_result` 结果文件；没提交且有 session → 发 `gate.submit.missing`、带 `gateMissingRetryMarker` 续跑同会话要求重新提交；仍未提交 → `failedAction=human`；提交成功 → `gate.submit.received` + `applyGateResult`（pass/rework/fail/human 路由）；**terminal 决策（rework/fail）短路后续客观校验**，并显式发 `gate.terminal` 遥测注明"跳过了 N 个 command 门禁、M 个产物契约"—— 审计时能区分"证据没跑"和"证据跑了没过"；
4. `completeRepositoryFallback`（兜底 Agent 修好仓库后解锁并行）；
5. `recoverMisplacedArtifacts`（写错位置的交付物收回沙箱）→ `validateArtifactOutputs`（产物契约）→ `artifact.contract.validated`；
6. **门禁执行**：manual/submit 跳过；MR 门禁走 `verifyRunMRs`（不可验证时转 human）；command 门禁经 `joinGateCommands`（每条先 `bindVerificationCommand` 防呆改写，多条拼成一个脚本并前置 `set -e`）后按 `ExecutionScope`（run / repositories 逐仓库）执行；
7. 失败且 `failedAction == "loop"` 且还有轮次 → 把错误作为反馈进入下一轮（`agent.loop` 遥测）。

**⑮ 收尾结局**（err 是否为空两条路）：
- `attachLoopRetro`：多轮执行后附 loop 复盘报告（问题清单、轮次统计）；
- **失败路**：先 `freezeAvailableArtifacts`（失败也冻结已产出的产物）；中断类 → requeue；max-turns → `waiting_approval`（`agent.turns.exhausted`，让人工决定是否重试）；`failedAction=human` → `waiting_approval`（`gate.waiting`，细节裁剪到 300 字）；Loop 耗尽且 `OnExhausted=human` → `waiting_approval`（`agent.loop.exhausted`）；其余 → `failNode`（是否打回由 `allowRejectOnFailure` 等判定）；
- **成功路**：有必选 manual 门禁 → `waiting_approval`；否则 `collectArtifactsMode` 收集产物追加到 run、`node.succeeded` 事件、逐产物发 `artifact.published`；预览构建节点成功后立即 `archivePreviewAfterBuild`（后续门禁/演示确认时预览已可打开）。
- 所有结局写盘前都过 `shouldCommitNodeOutcome`（generation/attempt 匹配防陈旧写入；成功的判定比失败宽松——agent 活着过了门禁不因 attempt 错位被丢弃）。

### 2.5 辅助函数

| 函数 | 作用 |
| --- | --- |
| `lostCLISession` / `dropLostCLISession` | 识别执行器输出里的 "no conversation found / session not found / no such session / conversation does not exist"，丢弃失效的 ResumeSessionID 并重跑节点（部署迁移/换机器后旧会话不可用时，避免误入空的人工确认） |
| `clipHumanGateDetail` | 人工门禁提示细节压成单行并裁剪到 300 字（防长错误刷屏） |
| `joinGateCommands` | 门禁多行命令拼接为**一个脚本**（保留逐行防呆绑定，多条时前置 `set -e` 保持 fail-fast）—— 修复 web UI 按 `\n` 切分导致 if/for/heredoc 被拆散的回归 |
| `scriptLanguageLabel` | python → "Python"，其余 "Shell"（中文执行摘要用） |
| `archivePreviewAfterBuild` / `completeSkippedPreviewBuild` | 预览站点的"构建后归档"与"非前端仓库跳过" |

## 三、测试覆盖映射

与 `engine_test.go` 不同，本文件的测试**分散**在 engine_test.go 与多个专题测试文件中。下表按第二节的结构分组列出（测试文件标在测试名后）。

### 3.1 `execute` 调度循环

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestSettleStatusForCompletedGraphWaitsForActiveNodes`（settle_active_node_test.go） | **失败分支不得抢先结算 run**：兄弟节点 running / pending_input 时图不结算；全部结束后才 failed；快照之外的活跃节点同样阻止结算 |
| `TestParallelNodesDoNotOverwriteEachOther`（engine_test.go） | 并行分支共享 run 级沙箱（SandboxID 一致）互不覆盖；run 成功后统一清理 |
| `TestCancelMarksActiveNodeCancelled` / `TestRetryCancelledRunFromNodeAfterImmediateCleanup`（engine_test.go） | Cancel 把在跑节点标 cancelled（Error 为空）；cancelled 节点不自动重排（错误信息引导"从该节点重跑"） |
| `TestRunUsesFrozenWorkflowSnapshotDuringConcurrentEdits`（engine_test.go） | 调度使用启动时快照，运行中编辑工作流不影响 run |
| `TestAlignOnlyApprovalDoesNotWait`（engine_test.go） | align 工作流的 approval 自动通过（`gate.auto_approved`），run 不停留 |
| `TestRunWaitsForGateAndCompletes`（engine_test.go） | 有 waiting 节点时 run 置 `waiting` 并退出调度，`Approve` 后重新拉起到 succeeded |

### 3.2 执行器 / 沙箱需求解析

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestResolveNodeExecutorPrefersAgentModel`（engine_test.go） | agent 的 ExecutorID/Model/Effort 覆盖节点声明；legacy executor 只按 Kind 映射到内置 CLI（不复用自定义 binary/args）；未知 executor 报 `not found` |
| `TestResolveSandboxResourcesRequiresDockerfileForDocker`（engine_test.go） | docker profile 缺 DockerfileID 报错；dockerfile/environment 从目录正确解析 |
| `TestGenericCatalogAssetsIgnoreStoredCrossProjectCollisions`（engine_test.go） | `workflowSandboxRequirements` 遍历节点时不受其他项目写入的同 ID 角色碰撞污染 |
| `TestDockerImageBuildNotice`（engine_test.go） | `dockerImageBuildLabel` 兜底"沙箱镜像"；无快照/未知 tag 视为需构建；`formatElapsedCN` 中文耗时；构建提示要进实时日志 |

### 3.3 执行作用域（executionTarget / executeForTargets）

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestRepositoryScopedRoleGateAndScriptArtifacts`（execution_scope_test.go） | 多仓库 + `ExecutionScope: repositories`：脚本在**每个仓库目录各执行一次**（`AGENTFLOW_REPOSITORY_ID/NAME/PWD` 环境变量正确），产物按 `RepositoryDir` 分别收集；`run` 作用域节点又能读到所有仓库产物 |
| `TestRepositoryExecutionScopeRequiresRepository`（execution_scope_test.go） | repositories 作用域遇到无仓库 run 报错 |
| `TestGateExecutionScopeIsExplicit`（gate_test.go） | 门禁作用域严格按声明：`run` 作用域在 run 根（`test ! -e .git` 通过）、`repositories` 作用域在 checkout 内（`git rev-parse` 通过），同一 agent 两个门禁各得其所 |
| `TestRunScopedGitGateDoesNotEnterCheckout`（gate_test.go） | **反向断言**：`run` 作用域的 git 门禁必须失败 —— 门禁不得隐式继承 checkout 的 cwd |
| `TestAppendArtifactContractDescribesRunLayout`（gate_test.go） | prompt 中的产物契约说明工作区布局：命名 checkout 子目录（`./gateway`）、交付物留在 run 根；legacy 根布局不虚构子目录 |

### 3.4 脚本 / 命令节点（runOnce script 分支）

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestShellAndPythonScriptNodesExecuteInOrder`（engine_test.go） | shell→python 顺序执行、python 读取 shell 输出、产物契约收集、空输出保留中文执行摘要（`# 脚本执行结果`、`标准输出：无`） |
| `TestScriptNodeCanCallProjectMCP` / `TestVerificationGateCanCallProjectMCP`（engine_test.go） | 脚本与门禁命令能通过 `agentflow` CLI 访问项目 MCP，且输出不含凭据 |

### 3.5 提交门禁与 Loop（⑭ 主执行循环）

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestSubmitReworkWithoutRejectToDegradesToFail`（engine_test.go） | rework 无 RejectTo 降级失败，`GateResult` 留档 |
| `TestSubmitReworkRejectsUpstreamInsteadOfRetrying`（engine_test.go） | rework 打回上游而非本地重试（`[[mock:gate=rework,pass]]` 序列证明） |
| `TestSubmitReworkBudgetExhaustedWaitsForHuman`（engine_test.go） | MaxReworks 用尽转人工门禁，错误文案含"返工次数已用尽"与具体配置值 |
| `TestSubmitTerminalDecisionSkipsGatesTelemetry`（engine_test.go） | terminal 决策发 `gate.terminal`，attributes 带 decision 与跳过计数 |
| `TestSubmitGateResumesSessionWhenResultIsMissing`（engine_test.go） | 缺 submit_gate_result → `gate.submit.missing` → 同 session 续跑直至提交 |
| `TestLostCLISessionRestartsInsteadOfWaiting`（engine_test.go） | CLI 会话丢失 → `agent.session.dropped` → 重启节点，绝不落入 `gate.waiting` |
| `TestGateOnFailureIsConfiguredNotInferred`（engine_test.go） | 门禁 onFailure 显式优先 / 非法回退 / 只有 loop 自纠；max-turns 与 cwd-mount 126 不自动重试不自动打回；"无终态 result" 可重试 |
| `isMaxTurnsErr` 断言（core_cases_test.go） | max-turns 错误识别 |
| `TestBuildLoopRetroDoesNotBlameMaxTurnsOnMissingResult`（engine_test.go） | loop 复盘不误怪 `--max-turns`，改给 `type:result` 协议诊断 |
| `TestCollectLoopRetroSignalsCountsOnlyTheNode` / `TestBuildLoopRetroRendersCollectedSignals`（loop_retro_signals_test.go） | 复盘信号**只统计本节点**（agent.completed / 门禁通过失败 / 自修正轮数 / "退出 0 但无 agent.completed"疑点），正确渲染中文报告 |

### 3.6 门禁命令执行（joinGateCommands / gateExec）

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestVerificationGateRunsMultiLineCommandsAsOneScript`（engine_test.go） | 多行命令（if/else 块）拼成一个脚本执行，不允许拆行语法错误（带回归注释，说明 web UI 按 `\n` 切分的由来） |
| `TestBindGrepToArtifacts` / `TestVerdictGrepIgnoresMentionAndMatchesConclusionLine` / `TestBindGitDiffQuietExcludesDeliverables`（engine_test.go） | 每条命令执行前的防呆改写：裸 grep 绑定报告文件、verdict grep 锚定行首、git diff 排除交付物 |
| `TestAutomaticGatesAndArtifactsCompleteBeforeManualApproval` / `TestArtifactContractIsValidatedBeforeAutomaticGate`（engine_test.go） | 人工等待时自动门禁与产物已完成（telemetry Sequence 顺序）；产物契约先于门禁（缺产物时门禁 marker 文件不产生） |
| gate_mr_test.go（整文件） | MR 模式门禁：待合入 MR 的发现与校验、不可验证转 human |

### 3.7 产物收集与 reported outputs（⑧ / ⑮）

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestReportedOutputsValidateRepositoryScopedContracts`（node_outputs_test.go） | **执行机器上报产物**的校验：repositories 作用域契约要求每个仓库目录都有文件（缺 `svc-b` 时错误点名 `svc-b`）；无变化的仓库不产生 repository-patch；超大文件（TooLarge）明确报 "exceeds" |
| `TestReadGateResultFromReportedOutputs`（node_outputs_test.go） | submit_gate_result 从上报文件读取（执行机器模式下没有本地结果文件） |
| `TestRunnerArtifactInputsMatchWorkspaceMount`（node_outputs_test.go） | 下发给执行机器的输入文件路径与本地 `materializeInputs` 挂载路径完全一致（`.agentflow/inputs/impl/svc-a/notes.md`），manifest 注明 "source of truth" |
| 产物契约系列（engine_test.go） | best-effort 收集、错位交付物回收、契约校验与版本化（详见 `docs/learning/engine.md` 第 3 组） |

### 3.8 仓库准备兜底（⑦ / ⑫）

| 测试（文件） | 验证的行为 |
| --- | --- |
| `TestRepositoryFallbackIsOwnedByTheFirstAgent`（git_preparation_fallback_test.go） | **只有"首个仓库 Agent"能接手 checkout 兜底**：前面是 approval 也可以，前面已有 script/agent 则不行；script 节点本身永远不能接兜底（它没有修复能力） |

### 3.9 预览构建节点（⑩ / ⑮）

| 测试（文件） | 验证的行为 |
| --- | --- |
| preview_finalizer_test.go / local_workspace_cases_test.go | 构建成功立即归档静态预览（`archivePreviewAfterBuild` 幂等：run 缺失 / 未启用静态预览 / 节点未成功都安全跳过）；非前端仓库走 `completeSkippedPreviewBuild` 跳过路径并写明原因 |

### 3.10 赞助 Key 与其他

| 测试（文件） | 验证的行为 |
| --- | --- |
| codebuddy_auth_test.go | `sponsoredExecutor` 把 CodeBuddy 模型替换为平台共享 Key 允许的模型，每次调用发"共享 Key…原模型不生效"节点提示（run 事件去重后只记一次） |
| has_run_event_test.go | run 事件存在性判定的大小写敏感等边界 |

## 四、贯穿全文件的设计不变量

1. **终态写入的排他性**：写 cancelled/paused/终态前必须先排干在飞节点（`stopNodes`）；失败分支不得在兄弟节点活跃时结算 run —— 两个方向都保证"运行中的分支之上永远不会盖上终态"。
2. **世代与尝试的双重防陈旧**：run 有 `Generation`（Retry/Reject 递增）、节点有 `Attempt`；所有结局落盘都过 `shouldCommitNodeOutcome`，且**成功的判定比失败宽松**（活着的 agent 过了门禁不因 attempt 错位被丢弃，失败必须严格对齐）。
3. **中断与失败的严格区分**：ctx 取消 / 沙箱中断 → requeue 待恢复（节点不算失败）；只有真正的执行失败才走 failNode —— 这是崩溃恢复（recovery_test.go 一族）的基石。
4. **门禁的可审计性**：每个决策路径都有专属事件（`gate.waiting / gate.terminal / gate.submit.missing / gate.submit.received / agent.session.dropped / agent.turns.exhausted / agent.loop*`），terminal 决策还显式记录"跳过了哪些客观校验"。
5. **凡可能卡死人的地方都转人工或自愈**：max-turns、返工预算耗尽、Loop 耗尽、会话丢失、submit 缺失，分别有确定的降级路径，不允许节点无限等待或误等人工。
6. **执行位置的清醒**：控制面 vs 执行机器的职责切分贯穿始终 —— Docker 隔离、CLI 登录、门禁命令都跟随执行机器；控制面只保留 staging/编排；执行机器上报的产物与本地挂载路径语义一致（source of truth 在 runner checkout）。
7. **对用户输入的防御性改写**：门禁命令执行前统一防呆（grep 绑文件、verdict 锚定、git diff 排除交付物、多行拼脚本 + `set -e`），把"配置写错"从运行期故障变成自动纠正。

## 五、如何运行相关测试

```bash
# 本文件直接相关的单测（纯函数，跑得快）
go test ./internal/engine -run 'TestResolveNodeExecutor|TestDockerImageBuildNotice|TestSettleStatusForCompletedGraph|TestRepositoryFallbackIsOwnedByTheFirstAgent' -v

# 执行作用域
go test ./internal/engine -run 'TestRepositoryScopedRoleGateAndScriptArtifacts|TestGateExecutionScopeIsExplicit|TestRunScopedGitGateDoesNotEnterCheckout' -v

# 提交门禁 / Loop / 门禁命令
go test ./internal/engine -run 'TestSubmit|TestLostCLISession|TestVerificationGateRunsMultiLine|TestBindGrep|TestVerdictGrep|TestBindGitDiffQuiet|TestLoopRetro|TestCollectLoopRetro' -v

# reported outputs
go test ./internal/engine -run 'TestReportedOutputs|TestReadGateResultFrom|TestRunnerArtifactInputs' -v
```

注意事项与 `docs/learning/engine.md` 第五节相同：本仓库 engine 测试依赖 Unix 独有 syscall，**只能在 Linux/macOS（或 WSL/容器）下构建运行**；需要 PATH 中有 `git`；端到端类测试并行执行、`waitFor` 上限 30 秒。

---

*本文基于 `internal/engine/node_execute.go`（约 1200 行）静态梳理，并核对了 engine_test.go、execution_scope_test.go、gate_test.go、node_outputs_test.go、loop_retro_signals_test.go、settle_active_node_test.go、git_preparation_fallback_test.go、codebuddy_auth_test.go 等测试文件的断言。执行机器分发（runner_dispatch.go）、子 SOP（sop_node.go）、MR 门禁（gate_mr.go）等协作文件各有专门测试，可循第一节的地图继续扩展阅读。*




