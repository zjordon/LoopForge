# LoopForge 引擎（internal/engine）测试导读 —— 从 engine_test.go 入手

> 解读 `internal/engine/engine.go` 与整个 engine 包的结构，梳理 `internal/engine/engine_test.go`（约 4400 行 / 165KB，90 余个测试函数）的测试逻辑与覆盖场景。
> 阅读建议：先看第二节搞懂测试基础设施（否则很多测试会"看不懂"），再按第三节的分组对照源码阅读。

## 一、为什么 engine.go 代码量很少

`engine.go`（约 150 行）只是整个 engine 包的"类定义头"，它承担三件事：

1. **`Engine` struct 字段声明** —— 这是全包唯一的状态载体，字段可归为四类：
   - 基础依赖：`repo *repo.Store`（持久化）、`sandboxes *runtime.Manager`（沙箱管理）、`runner *runtime.ExecutorRunner`（执行器运行器）；
   - 并发控制：`mu / stateMu / runEnvMu / nodeExecMu / subMu / runnerTaskMu` 多把锁、`execLocks`（按 run/node/agent 粒度的键锁）、`conversationSaves`；
   - 运行时状态：`running`（runID→CancelFunc）、`runEnvs`、`subs`（run 订阅者）、`workspaceFacts`、`cloudPool`、`instanceID / workspaceHost / leaseTTL` 等；
   - 可插拔回调（依赖注入点）：`MergeIntoBranch`（工蜂 MR 合并）、`FindBranchMR / FindBranchMRsInto`、`runnerDispatchNotify / runnerControlNotify / runControlNotify`（跨进程通知）、`WorkspaceActive / WorkspaceCheckpointTransport`、`preview`、平台 MCP 绑定（`platformMCPBase / platformMCPToken`，注释明确 token 只来自环境变量、绝不落库）。
2. **构造函数 `New`** —— 只做字段初始化，不启动任何 goroutine；`StartMaintenance` 被刻意拆出来（`maintenanceOnce` 保证进程内只启动一次），注释写明原因：短生命周期调用方（尤其是测试）构造 Engine 时不会在 Store 关闭后留下后台 sweeper。
3. **少量配置/装配方法** —— `ConfigureExecution`（实例 ID、工作区宿主、租约 TTL、是否执行 run）、`ConfigurePlatformMCP`、`SetPreview`。

真正的执行逻辑全部在包内其他 60+ 个源文件里 —— Go 允许同一 struct 的方法分布在不同文件，`Engine` 的方法按领域拆到了 `run_start.go`、`run_ops.go`、`node_execute.go` 等文件中。而 `engine_test.go` 是**包内测试**（`package engine`），可以直接调用所有**私有**函数与方法（`resolveAssets`、`prepareRepository`、`finish`、`collectArtifacts`……），所以这一个测试文件就能横向覆盖整个包的主干路径 —— 这就是"类很小、测试很大"的原因。

### 源文件 ↔ 测试场景对照表

| 源文件 | 职责 | 对应测试组 |
| --- | --- | --- |
| `engine.go` | struct 定义、构造、配置 | 所有测试的 `New(...)` |
| `run_start.go` | `Start / StartWithContext / StartWithExecutionContext`、工作流快照 | 生命周期 |
| `run_ops.go` | `Approve / Reject / Retry / Pass / Cancel`、`overlayLatestNodeBindings` | 人机协作、重试回放 |
| `node_execute.go`（包内最大） | 节点执行、executor/沙箱资源解析、镜像构建提示 | 脚本节点、MCP 调用、执行器解析 |
| `node_outcome.go` | 节点结局判定：门禁 onFailure、重试/打回策略、`finish` | 返工、门禁策略 |
| `assets.go` | 角色资产解析（rules/skills/MCP/沙箱）、平台与知识库 MCP | 资产解析 |
| `artifacts.go` | 产物收集、`materializeInputs`、契约合并、错位产物回收 | 产物与交接 |
| `repository_patch.go` | 仓库补丁 = 文件名清单（委托 `internal/gitwork`） | 补丁排除规则 |
| `repository_workspace.go` / `workspace_preparation.go` | `prepareRepository`、工作分支与基线管理 | Git 工作区 |
| `git_auth.go` | git 身份 / token 的 context 注入 | Git 工作区 |
| `prompt.go` | prompt 占位符渲染、节点任务书编译、MR 提示 | Prompt 渲染 |
| `observability.go` / `run_events.go` | 用量累计、日志过滤、进度遥测合并、loop 复盘 | 遥测与用量 |
| `human_context.go` | 人工补充上下文的持久化与注入 | 人因上下文 |
| `parallel_exec.go` | 键锁、节点执行注册与取消 | 并行 |
| `conversation_workspace.go` | 会话工作区、检查点恢复 | 历史兼容回放 |
| `workspace_cleanup.go` | 工作区清理 | finish 清理语义 |

（engine 包还有约 50 个其他 `*_test.go` 文件，覆盖 runner 传输、run 租约、崩溃恢复、并行分支等场景，不在本文梳理范围内。）

## 二、测试基础设施（读懂这些测试的前提）

### 1. `TestMain`：测试二进制的"自我复用"（re-exec）

```go
func TestMain(m *testing.M) {
    if runtime.RunMCPCallCLI(os.Args[1:]) || runtime.RunGitHelperCLI(os.Args[1:]) {
        return
    }
    os.Exit(m.Run())
}
```

测试中的脚本节点会执行 `agentflow mcp list` 这类 CLI 命令。`agentflow` 二进制并不存在 —— 它被解析为**测试二进制自身**，再次进入 `TestMain` 后按参数分派给 `runtime.RunMCPCallCLI`（MCP 调用 CLI）或 `RunGitHelperCLI`（git 凭据 helper CLI）。这是 Go 测试里模拟"进程外 CLI 工具"的常见技巧，与生产入口 `cmd/agentflow/main.go` 的分派逻辑保持一致。

### 2. 测试替身与支撑组件

| 组件 | 来源 | 作用 |
| --- | --- | --- |
| `repo.OpenTest()` | `internal/repo/opentest.go` | 内存 SQLite + 测试默认数据（含 `developer`/`reviewer` 等种子 agent）。按 AGENTS.md 约定，生产代码不得引用 |
| `runtime.NewManager(dir)` / `NewManagerWithLimit(dir, 1)` | `internal/runtime/sandbox_manager.go` | 本地沙箱管理器（`local` driver），工作区根目录在 `t.TempDir()` 下随测试自动清理 |
| **mock 执行器** `ExecutorID: "mock"` | `internal/runtime/gate_mcp.go`、`runner.go` | 通过 agent 的 Prompt 中的 `[[mock:...]]` 指令控制行为：`[[mock:gate=rework]]`（门禁裁决=返工）、`[[mock:gate=rework,pass]]`（第 1 次 rework、之后 pass，可验证"没有本地重试"）、`[[mock:session=lost]]`（模拟 CLI 会话丢失） |
| `waitFor(t, s, runID, want)` | 本文件 | 轮询 run 状态直至目标（30 秒超时；注释说明并行测试共享机器所以放宽），失败时打印每个节点的状态与错误 |
| `waitForWorkspaceCleanup` | 本文件 | 轮询 `WorkspaceCleanedAt` 被记录 |
| `mustGit` / `writeGitRepoWithWorkBranch` / `assertCheckedOutWorkBranch` / `quoteGitCStyle` | 本文件 | 搭建**真实 git 仓库**（source 工作库 → bare remote → workspace clone），并校验分支/HEAD/内容 |

绝大多数测试 `t.Parallel()` 并行执行，且**不 mock git**：prepareRepository / 补丁收集相关测试全部跑在真实 git 仓库上，只把"远端"换成临时目录里的 bare 仓库。

## 三、测试场景全景图（按主题分组）

以下按"业务领域"把 90 余个测试分成 11 组。每组先概括领域，再用表格列出：测试函数 → 验证的行为（含关键断言细节）。

### 1. 角色资产解析 —— `resolveAssets`（assets.go）

一个"角色"（AgentDefinition）执行时要绑定哪些 rules / skills / MCP servers / 沙箱，全部在这里裁决。核心签名：`resolveAssets(agent, projectID, workflowID, userID)`。

| 测试 | 验证的行为 |
| --- | --- |
| `TestResolveAssetsLoadsSkillBinaryFiles` | 技能的**二进制文件**（如 `scripts/run.sh`，mode 0755）要完整打进资产包：`FileRefs` 清单 + `SkillFiles` 内容都存在 |
| `TestResolveAssetsLoadsSkillhubSnapshot` | SkillHub 安装的技能 = 带来源记录（Provider/Namespace/Version）的普通项目技能，快照文件（`SKILL.md`、`_meta.json`）与上传技能同等地解析 |
| `TestResolveAssetsEnforcesProjectAndPersonalScope` | **多租户作用域隔离**：无 scope 的 legacy 资产全局可见；`project` scope 只在本项目可见；`Shared: true` 可跨项目共享；`personal` scope 只归 OwnerUserID 本人。rules、skills、MCP servers 三类资产同规则；脚本节点走 `resolveScriptMCPAssets` 同样受限 |
| `TestResolveAssetsBindsPlatformMCP` | 平台自身 MCP（路径 `/mcp`）：角色 `PlatformMCP: true` 才注入；未配置平台基地址时**只带路径**（执行机改写到自己的 server 地址，云端执行丢弃并告警 `AGENTFLOW_PLATFORM_MCP_URL`）；配置后合成完整 URL + `Authorization: Bearer` 头 |
| `TestResolveAssetsBindsKnowledgeMCP` | 知识库 MCP：未接入时开关退化为无操作；接入后注入**代理 token**（`knowledge.VerifyProxyToken` 验证 claims 含 project/user/agent），**上游 token 绝不进资产包**；同时注入知识库用法 rule；`runtime.PrepareMCPServers` 在云端/执行机两种目标下去留正确 |
| `TestKnowledgeMCPWithoutPlatformBase` | 知识 MCP 在独立 worker（无平台基地址）下的降级：路径 only → runner 改写 → 云端丢弃且告警指名 `KnowledgeMCPServerID` |
| `TestGlobalRuleInjectsIntoEveryNodeOfBoundWorkflow` | `Global: true` + `WorkflowIDs` 的 SOP 规则注入**该工作流所有节点**的角色（不管角色是否显式绑定）；WorkflowIDs 带空格容错；角色已绑定同一条时**不重复**；空 workflowID 不注入；shared 的 global 规则跨项目生效 |
| `TestGenericMRRoleResolvesGongfengMarketAlias` | 通用 MR 角色（`repo.GenericAgentMR`）通过 `gongfeng` **别名**解析到本项目的市场安装（MarketID=61）；直接用目录 id `61` 仍可解析；别名解析**不能跨项目** |
| `TestGenericCatalogAssetsIgnoreStoredCrossProjectCollisions` | 通用目录模板内置的角色/规则不受其他项目**故意写入的同 ID 碰撞**污染 |
| `TestProjectSandboxNeverCrossesProjectBoundary` | 沙箱 profile 同 ID 优先本项目自有的，绝不借用其他项目的同名 profile |

### 2. Git 工作区准备 —— `prepareRepository`（repository_workspace.go / git_auth.go）

工作流绑定仓库后，每个 run 要把仓库准备成可执行工作区：刷新基线、检出/创建工作分支、处理凭据。这一组全部搭真实 git 仓库（source → bare remote → workspace），相当于**分支语义的规格说明**。

| 测试 | 验证的行为 |
| --- | --- |
| `TestPrepareRepositoryRefreshesBaseThenCreatesWorkBranch` | 基础路径：clone/fetch 刷新基线（内容最新）→ 检出 `WorkBranch` |
| `TestPrepareRepositoryAppliesResponsibleUserGitIdentityOnCloneAndResume` | 责任人 git 身份（`withGitIdentity` 注入 context）写入 workspace local config；**resume 时覆盖陈旧身份**；后续 commit 作者正确 |
| `TestPrepareRepositoryIgnoresMissingLocalPathWhenCloneURLExists` | `LocalPath` 指向的宿主 checkout 不存在时回退用 `CloneURL` |
| `TestPrepareRepositoryResumeKeepsLocalCommits` | resume（同 workspace 二次 prepare）**不重置**本地未推送的 commit |
| `TestPrepareRepositoryChecksOutExistingRemoteWorkBranch` | 远端已存在同名工作分支时检出它，且 `HEAD == origin/<WorkBranch>`（不覆盖已有工作） |
| `TestPrepareRepositoryResumeResetsNamesakeWorkBranch` | legacy 场景：single-branch clone 后本地手工建了**同名但历史不同**的分支（无 origin/branch 引用），resume 要重置回远端内容 |
| `TestPrepareRepositoryResumeKeepsLocalCommitsWhenRemoteWorkBranchExists` | 远端分支存在、但本地分支有**独有 commit**（master 谱系）时，保留本地历史 |
| `TestPrepareRepositoryKeepsExistingWorkspaceDirectory` / `TestResetCloneDestinationCreatesMissingDirectory` / `TestPrepareRepositoryRetryKeepsExistingWorkspaceDirectory` | **绝不替换 workspace 目录本身**（`os.SameFile` 断言 inode 不变）—— Docker bind-mount 挂的就是这个路径；目录缺失时创建；损坏的 clone（删 `.git/objects`）重克隆后仍在原目录 |
| `TestPrepareRepositoryUsesRemoteMasterNotStaleLocalPath` | 基线以**远端**为准，不被 stale 本地 checkout 误导；workspace 的 `origin` 指向 remote 而非本地路径 |
| `TestPrepareRepositoryWithTokenKeepsCleanOrigin` | 克隆 token：不落入 `origin` URL；askpass/include 等凭据文件用完即删，不留在 workspace |
| `TestStartUsesFreshWorkBranchPerSOP` | 同一 Issue 的新 SOP run 用**全新工作分支**（不复用上次失败分支）；`persistentSandboxID(run) == run.ID` —— 每个 run 一个专属持久沙箱 |
| `TestDefaultWorkBranchIncludesHourMinute` | 默认分支命名含"日-时分"避免冲突：`feature/fix-issue-5-20260817-2254` |

### 3. 产物收集与仓库补丁（artifacts.go / repository_patch.go / internal/gitwork）

节点产出的"交付物"（report/plan 等）与"代码变更"（repository-patch）的收集规则。这一组最大的主题是：**补丁必须是文件名清单而非全量 diff**，且要排除所有语言的依赖目录、构建产物、测试报告与缓存（避免把几十 MB 垃圾冻结进产物、撑爆下游 prompt）。

| 测试 | 验证的行为 |
| --- | --- |
| `TestCommittedWorkerChangesRemainInFrozenPatch` | 节点**已 commit** 的代码改动仍然进入冻结的 repository-patch 产物（不能只看未提交 diff） |
| `TestCollectRepositoryPatchIncludesUntrackedE2EAndOmitsDeliverables` | 未跟踪文件（如新增 e2e 测试）要进补丁；SOP 交付物（`e2e-cases.md`）**不进**补丁 |
| `TestRepositoryPatchIsFrozenAndAppliedToDownstreamSandbox` | 补丁作为不可变 artifact 冻结，并应用到下游节点沙箱（`repo/app.txt` 变更可见）；executor 的 MCP 配置文件（`mcporter.json` 含 `Bearer secret-token`）**不泄漏**进补丁 |
| `TestSingleRepositoryKeepsDeliverablesAtRunRoot` | 单仓库布局：代码在 `repo/` 子目录（有自己的 `.git`），交付物在 run 工作区根；两者的 `RepositoryDir` 标记正确、互不混入 |
| `TestRepositoryPatchHandoffIsFilenameSummary` | 补丁是**文件名摘要**（含 `files 1`），不内联 diff hunk（`@@`、函数体都不出现）；prompt 里引用 `{{artifact.x.repository-patch}}` 时同样只给文件名 |
| `TestCollectRepositoryPatchUsesNearerUpstreamAfterMerge` | merge 了集成基线后，diff 基点用**更近的 merge-base**，不能把已合并的上游历史（2000 行 padding）算进本次变更 |
| `TestCollectRepositoryPatchSkipsQuotedAgentflowModuleCache` | git ls-files 的 C 风格八进制转义路径（中文文件名）正确解码；`.agentflow` 私有 home 下的 Go module cache 不进补丁 |
| `TestUnquoteGitLsFilesPathDecodesOctalChineseName` | `gitwork.UnquoteLsFilesPath` 对八进制中文路径的解码与排除（纯单元测试） |
| `TestExcludeFromRepositoryPatchDependencies` / `TestCollectRepositoryPatchExcludesMultiLanguageDependencies` | **全语言排除表**：Go vendor/pkg mod、前端 node_modules/.pnpm-store/.yarn/.next/.nuxt、PHP vendor、Python venv/__pycache__/.pytest_cache、Java target/.gradle/.m2、Rust target、C/C++ .o/.so/CMakeFiles/vcpkg、Swift Pods/DerivedData、Android、.NET obj、Ruby、Elixir、Terraform……以及反向清单：`vendor.go`、`node_modules_test.js`、`phpunit.xml`、`tests/UserTest.php` 等**正常源码/配置不能被误排** |
| `TestIsTestArtifactOrCachePath` | 测试报告与缓存的精细判定表（coverage/lcov/junit/jacoco/gcda 等），配置文件（phpunit.xml、jest.config.js）和测试源码受保护 |
| `TestSOPRunHandoffE2EWithExcludedDependencies` | **SOP 交接端到端**：ws1 产生业务变更+大量依赖垃圾 → 补丁只含业务文件；共享工作区交接时 manifest 提示 `Skipped applying`（列文件不重放）；干净 clone 不被 summary 改写；`verifyDeliveryCompleteness` 在文件未提交时告警、提交后清零 |
| `TestCollectArtifactsBestEffortKeepsWrittenReport` | best-effort 收集（节点失败路径）仍保留已写出的必需报告 |
| `TestRecoverMisplacedArtifactsCopiesHostLeakIntoSandbox` | worker 把交付物写错位置（宿主 checkout 而非沙箱）时，复制回沙箱并删除宿主上的泄漏文件 |
| `TestMergeArtifactContractsLetsNodeRefineAgentContract` | 节点级产物契约可**细化/覆盖**角色级契约（同名合并、异名并集） |
| `TestArtifactsAreVersionedAndMaterializedForDownstreamNode` | 产物带 attempt 版本化；下游节点通过 `.agentflow/inputs/<node>/<file>` 读取上游产物 |

### 4. 输入物化 —— `materializeInputs`（artifacts.go）

下游节点启动前，把祖先节点的产物落成工作区文件并生成"输入清单"（prompt 目录）。

| 测试 | 验证的行为 |
| --- | --- |
| `TestMaterializeInputsMountsAncestorE2ECases` | 不只直接上游：**所有祖先**（跨两跳的 test 节点）产物都挂载；manifest 只列条目（`test / e2e-cases`），**不内联产物正文**（控制 prompt 体积） |
| `TestMaterializeInputsRejectsSymlinkedControlDirectory` | `.agentflow/inputs` 若是指向工作区外的 **symlink 则直接报错**（安全：防产物写逃逸），并断言外部目录确实没被写入 |
| `TestMaterializeInputsMountsCloseDeliveryArtifacts` | close（收尾）节点挂载全链路交付物：测试报告、e2e 报告、MR body 全部就位，manifest 依旧不含正文 |

### 5. 节点执行与并行（node_execute.go / parallel_exec.go / run_events.go）

| 测试 | 验证的行为 |
| --- | --- |
| `TestShellAndPythonScriptNodesExecuteInOrder` | script 节点支持 shell / python 两种语言；沿边顺序执行（python 读取 shell 的输出）；产出 artifact contract 声明的产物；节点 Output 保留中文执行摘要（`# 脚本执行结果`、`标准输出：无`） |
| `TestScriptNodeCanCallProjectMCP` | script 节点里执行 `agentflow mcp list`（经 `TestMain` re-exec 到测试二进制）能列出**本项目**的 MCP 安装（含 2214/configcenter）；输出**不含凭据**（`mcp_secret`、`Bearer` 均不得出现） |
| `TestVerificationGateCanCallProjectMCP` | 验证门禁的 command 同样能调用项目 MCP（门禁命令在 run 作用域执行） |
| `TestParallelNodesDoNotOverwriteEachOther` | 两个并行节点 + join 节点共享**同一个 run 级沙箱**（`SandboxID` 一致）互不覆盖；run 成功后沙箱统一清理（`SandboxID` 清空 + `WorkspaceCleanedAt` 记录） |
| `TestParallelProgressTelemetryCoalescesPerNode` | 并行流式进度遥测**按节点合并**（两个节点交错各发 50 条 progress → 合并为 2 条），避免 token 流刷屏 |

### 6. 运行生命周期与人机协作（run_start.go / run_ops.go / node_outcome.go）

这是最"业务"的一组：一个 SOP run 从启动、审批、失败打回、返工、重试到终结的完整状态机。测试大量使用 `[[mock:gate=...]]` 指令精确控制 agent 裁决。

**启动与快照**

| 测试 | 验证的行为 |
| --- | --- |
| `TestRunUsesFrozenWorkflowSnapshotDuringConcurrentEdits` | run 使用**启动时的工作流快照**（WorkflowSnapshot）：运行中编辑工作流（删节点）不影响进行中的 run |
| `TestStartDefaultsEmptySandboxProfileToLocal` / `TestRetryLegacyRunDefaultsEmptySandboxProfileToLocal` | 空 SandboxProfileID 默认回退 `local`（含历史 run 的 retry 路径，`workflowForRun` 兼容无快照的旧数据） |
| `TestAlignOnlyApprovalDoesNotWait` | 基线对齐工作流（`BaselineAlignWorkflowID`）里的 approval 节点**自动通过**，不阻塞 |

**审批 / 取消 / 人工门禁**

| 测试 | 验证的行为 |
| --- | --- |
| `TestRunWaitsForGateAndCompletes` | 基础链路：review 节点（manual 门禁）进入 `waiting_approval` → `Approve` → run `succeeded` |
| `TestHumanGateFailureWaitsForApprove` | 客观门禁失败 + `OnFailure: "human"` → 节点停在 `waiting_approval` 等人，而非直接失败 |
| `TestHumanGateFailureRetryRerunsNode` | 对 human gate 节点 `Retry`（带人工理由）会**重新执行节点**（再次落入等待） |
| `TestCancelMarksActiveNodeCancelled` | `Cancel` 把正在执行的节点标为 `cancelled`（且 Error 为空，不误报失败） |

**Retry / 回放（replay）**

| 测试 | 验证的行为 |
| --- | --- |
| `TestRetryCancelledRunFromNodeAfterImmediateCleanup` | 取消后的 run：workspace 已清理时空节点 Retry 报 `workspace has been cleaned`；指定节点 Retry 从该节点重跑并成功；**script 节点回放不会把 humanContext 写进 Feedback/HumanContext**（重放是确定性的，不注入人工上下文） |
| `TestRetrySucceededRunFromNodeAfterCleanup` | 成功的 run 也能从指定节点回放：上游节点保持 `succeeded` 不重跑，目标节点重跑成功 |
| `TestRetryLegacySucceededRunAfterMainBotMissingSnapshot` | 历史兼容：升级前目录已删、快照缺失的 run，检查点恢复失败（`EnsureConversationWorkspace` 如实报错）但 Retry 仍可回放；上游节点 Attempt 保持 1，目标节点 Attempt=2 |

**Reject / 自动打回（rework）**

| 测试 | 验证的行为 |
| --- | --- |
| `TestRejectResetsTargetAndDescendants` | 人工 `Reject`（review→implement）：目标节点 `ReworkCount=1`、`Attempt=2`、`Feedback` 带打回理由 |
| `TestNodeFailureAutomaticallyRejectsToConfiguredTarget` | 脚本节点失败 + `OnFailure: "reject"` 自动打回 `RejectTo` 目标，并记录 `gate.rejected` 事件（消息含"节点失败自动打回"） |

**提交门禁裁决（submit gate）—— agent 显式提交 pass/rework/human 决定**

| 测试 | 验证的行为 |
| --- | --- |
| `TestSubmitReworkWithoutRejectToDegradesToFail` | agent 裁决 rework 但节点没配 `RejectTo` → 降级为失败；错误含 `no rework target`；`GateResult` 保留供审计 |
| `TestSubmitReworkRejectsUpstreamInsteadOfRetrying` | rework 必须**打回上游**而不是本地重试：用 `[[mock:gate=rework,pass]]`（第 1 次 rework、第 2 次 pass）证明若错误地本地重试就会"假成功"；断言上游 `ReworkCount=1` 且有 `gate.rejected` 事件 |
| `TestSubmitReworkBudgetExhaustedWaitsForHuman` | `MaxReworks` 用尽后再收 rework → 停人工门禁而非失败；错误信息可读（含"返工次数已用尽"、"MaxReworks=1"）；人工 Approve 接受上游产出完成 run |
| `TestSubmitTerminalDecisionSkipsGatesTelemetry` | terminal 决策（rework）跳过客观门禁，并记录 `gate.terminal` 事件（attributes.decision、消息含"skipped by terminal decision"）供审计 |
| `TestSubmitGateResumesSessionWhenResultIsMissing` | agent 没写裁决结果文件 → **同会话续跑**（`gate.submit.missing` 事件）直到拿到裁决 |
| `TestLostCLISessionRestartsInsteadOfWaiting` | CLI 会话丢失（`[[mock:session=lost]]`）→ **重启节点**而非误入人工等待（不允许 `gate.waiting`），记录 `agent.session.dropped` 事件 |

**Pass（人工放行）与 finish（收尾）**

| 测试 | 验证的行为 |
| --- | --- |
| `TestPassFailedScriptContinuesDownstream` | 人工放行失败的 script 节点：**不重新执行**（Attempt 不变）、状态翻成 succeeded、下游继续、理由记入 `HumanContext` |
| `TestPassAfterReworkLimitReached` | 返工预算耗尽后的失败节点也能被 Pass 放行，下游继续 |
| `TestPassRejectsAgentNode` / `TestPassRejectsActiveRun` | Pass 只允许作用于 **script** 类型节点；运行中（waiting）的 run 拒绝 Pass（`still active`） |
| `TestFinishSucceededDeletesPersistentSandboxImmediately` | run 成功：**立即删除**持久沙箱目录，并记录 `WorkspaceCleanedAt` |
| `TestFinishFailedKeepsPersistentSandbox` | run 失败：**保留**沙箱现场（供排查/续跑） |

### 7. 门禁策略与命令改写（node_outcome.go / gate_bind.go）

"门禁（VerificationGate）"是节点完成后的客观校验（command / manual），其失败策略 `OnFailure` 有四种：`fail`（直接失败）、`reject`（打回上游）、`human`（转人工）、`loop`（让 agent 自纠）。

| 测试 | 验证的行为 |
| --- | --- |
| `TestGateOnFailureIsConfiguredNotInferred` | 门禁自己的 `onFailure` **显式配置优先**于节点默认；空值继承默认；非法值回退；只有 `loop` 门禁触发自纠（`shouldSelfCorrect`）；**重试策略的精细判定**（`shouldRetryFailedAttempt`）：verification 失败不消耗额外 attempt（交给 onFailure 处理）、协议错误（executor 无终态结果）可以重试、max-turns 与 cwd-mount 126 错误**不**自动重试、`allowRejectOnFailure` 对 max-turns 不自动打回 |
| `TestAutomaticGatesAndArtifactsCompleteBeforeManualApproval` | 节点进入人工门禁等待时：**产物已冻结**、**自动门禁已跑完**（用 telemetry 的 Sequence 断言 `artifact.contract.validated` 先于 `process.started`）——人工审批看到的是完整现场 |
| `TestArtifactContractIsValidatedBeforeAutomaticGate` | 产物契约校验**先于**自动门禁执行：必需产物缺失时节点直接失败，门禁命令根本不跑（marker 文件不存在） |
| `TestVerificationGateRunsMultiLineCommandsAsOneScript` | 回归防护（带长注释）：web UI 把门禁脚本按 `\n` 切成 Commands 数组，引擎必须**拼回一个脚本**整体执行（否则 `if...fi` 拆行会报 shell 语法错误） |
| `TestBindGrepToArtifacts` | 门禁命令防呆：裸 `grep`（无文件名）自动绑定节点的报告文件（否则 grep 读空 stdin 恒失败）；已带文件名或管道后的 grep 不动 |
| `TestVerdictGrepIgnoresMentionAndMatchesConclusionLine` | verdict grep 自动锚定行首（`^[[:space:]]*NEED_HUMAN`）：报告**解释文字里提到** `NEED_HUMAN = true` 不误判，只有真正的结论行才触发（用真实 `sh -c` 执行验证正、反两例） |
| `TestBindGitDiffQuietExcludesDeliverables` | "工作区干净"门禁（`git diff --quiet`）自动排除 SOP 交付物（`:(exclude)fix-plan.md` 等）：报告类产物不算代码脏污；已有显式 exclude 或无关命令不动 |

### 8. Prompt 渲染（prompt.go）

| 测试 | 验证的行为 |
| --- | --- |
| `TestRenderPromptIncludesInputUpstreamAndFeedback` | 占位符替换：`{{input}}`（需求输入）、`{{feedback}}`（打回反馈）、`{{upstream}}`（上游输出汇总，带 `[plan]` 段落头）、`{{node.<id>.output}}`（指定节点输出） |
| `TestRenderPromptAppendsIssueIdentityFromStore` | 从 store 补充 Issue 身份块（"需求身份（平台权威，禁止忽略）"、外部 ID），**不重复追加**（输入已含身份块时只出现一次）；旧 run 的 prompt 也能拿到最新 TAPD 身份 |
| `TestGenericRequirementPlaybookIncludesIssueInput` | 通用模板（generic backend SOP）的 requirement 节点 prompt 必须包含 Issue 正文（多行内容完整透传） |
| `TestRenderPromptSubstitutesRejectToAndSubject` | `{{rejectTo}}`（打回目标）、`{{subject}}`（主题："本次 Issue"/"本次需求"，按工作流 ID 前缀区分） |
| `TestCompileTaskPromptFillsDeliverablesFromNodeContracts` / `TestRolePromptCompilesTaskbook` | **节点任务书**编译：`# 节点任务书` 结构化输出执行角色、任务说明（占位符已替换）、仓库上下文（含工作分支说明）、交付物契约（`change-report.json`）、门禁（"单测门禁必须通过"）、重试策略（"仅修复失败项"）、人工反馈；**没有 Prompt 的角色不生成空任务书** |
| `TestBuildLoopRetroDoesNotBlameMaxTurnsOnMissingResult` | loop 自纠失败的复盘报告不再误怪 `--max-turns`，而是给出协议诊断（`type:result`）——防止误导用户调错参数 |
| `TestExistingMRBlurbDoesNotReusePreviousSOP` | 新 SOP 的 MR 提示**不绑定**上一次（失败的）run 留下的 MR 链接，避免把新工作塞进旧 MR |

### 9. 人因上下文（human_context.go）

人工的每一句话（打回理由、放行说明、补充信息）都要进入 agent 的视野。

| 测试 | 验证的行为 |
| --- | --- |
| `TestRecordHumanContextPersistsForRetryAndPrompt` | `Retry` 携带的人工上下文四处持久化：run 级 `HumanContext`、节点 `Feedback`、`human-context` artifact、渲染进下次 prompt（"人工补充上下文"段落）、并写入工作区 `human-context.md` 文件 |
| `TestApproveWithHumanContextReachesDownstream` | `Approve` 携带的人工上下文同样落盘为 `human-context.md`，**下游节点**的命令能直接读到（`grep -q TestFoo human-context.md`） |

### 10. 执行器与沙箱资源解析（node_execute.go / run_environment.go）

| 测试 | 验证的行为 |
| --- | --- |
| `TestResolveNodeExecutorPrefersAgentModel` | executor 选择优先级：agent 定义上的 `ExecutorID/Model/Effort` 覆盖节点声明；**legacy executor**（自定义 binary/args）安全映射到内置 CLI（`codex`）；未知 executor 报 `not found` |
| `TestResolveSandboxResourcesRequiresDockerfileForDocker` | docker driver 的 profile 没有 DockerfileID 直接报错；dockerfile / environment（变量含 `${PREFIX}`、PATH 追加、安装脚本）从目录正确解析 |
| `TestDockerImageBuildNotice` | 沙箱镜像构建的用户提示：镜像标签（空快照回退"沙箱镜像"）、`dockerImageNeedsBuild`（无快照/未知 tag 视为首次构建）、中文耗时格式化（"12 秒"/"2 分 15 秒"）、提示要进实时日志 |

### 11. 遥测、用量与日志（observability.go / run_events.go）

| 测试 | 验证的行为 |
| --- | --- |
| `TestApplyUsageAccumulatesIndependentSessions` | token 用量**按 session 去重累计**（同一 session 的多次快照取差量、不同 session 相加）：run 级与节点级一致；`billedTokens = input + output` |
| `TestApplyUsagePropagatesCostStatus` | 成本识别状态（CostStatus）传播：适配器显式上报 0 且 `reported` 不被当成"未识别"；状态跟随最近一次快照；无数值的 status-only 快照也更新状态 |
| `TestShouldRecordLogSkipsModelGeneration` | 遥测 → worker 日志的过滤规则：模型生成（model.request）不进日志；工具**成功**完成是心跳噪音；工具**失败**保留；tool start 保留 |
| `TestOverlayLatestNodeBindingsRefreshesArtifactContracts` / `TestOverlayLatestNodeBindingsReadsGenericTemplate` | Retry 回放时用**目录里最新**的节点绑定（产物契约路径、RejectTo）覆盖旧快照——重跑也要按最新规则交付；包括 generic 模板的读取路径 |

## 四、贯穿所有测试的设计不变量

把这些测试放在一起看，可以提炼出 engine 包反复强化的几条"宪法级"约束 —— 理解它们比记住单个测试更重要：

1. **快照隔离**：run 一旦启动就冻结在 `WorkflowSnapshot` 上，工作流后续编辑、上游资产变更都不影响进行中的 run（Retry 时仅按最新绑定覆盖指定节点的产物契约/RejectTo）。
2. **产物不可变且版本化**：每次 attempt 的产物独立冻结；repository-patch 是**文件名清单**而非全量 diff；prompt 引用产物时绝不内联正文 —— 一切为了控制下游 token 成本。
3. **安全边界**：token 绝不落盘（origin URL / 凭据文件 / patch / MCP list 输出 / 资产包）；symlink 防工作区逃逸；资产、沙箱、别名解析严格按 project/user 作用域隔离，legacy 无 scope 数据单独兼容。
4. **人机协作语义精确**：`fail / reject / human / loop / pass` 每种失败路径都有确定的行为与可审计事件（`gate.rejected`、`gate.terminal`、`gate.submit.missing`、`agent.session.dropped`），人工的每句话（feedback/humanContext）持久化并注入后续 prompt 与工作区文件。
5. **失败保留现场，成功立即回收**：失败 run 的沙箱保留排查；成功 run 立即清理并记录 `WorkspaceCleanedAt`。
6. **对真实世界的防御**：git 分支的同名冲突/单分支 clone legacy/损坏 clone、UI 按 `\n` 切分多行脚本、grep 缺文件名、报告里引用结论字符串等"现实会踩的坑"都有专项回归测试。
7. **面向中文用户的可读性**：错误与提示大量使用中文文案（"返工次数已用尽"、"沙箱镜像"、"标准输出：无"），且测试直接断言这些文案。

## 五、如何运行这些测试

```bash
# 全量（engine 包全部测试，含其他 _test.go 文件）
go test ./internal/engine

# 只跑某个主题（-run 支持正则）
go test ./internal/engine -run 'TestResolveAssets' -v          # 资产解析
go test ./internal/engine -run 'TestPrepareRepository' -v      # git 工作区
go test ./internal/engine -run 'TestCollectRepositoryPatch|TestExcludeFromRepositoryPatch' -v
go test ./internal/engine -run 'TestSubmitRework|TestHumanGate|TestPass' -v

# 长跑场景可放宽超时
go test ./internal/engine -run 'TestRetry|TestCancel' -v -timeout 300s
```

注意事项：

- **本仓库的 engine 测试只能在 Linux/macOS（或 WSL/容器）下运行**：`internal/runtime` 与 `internal/preview` 依赖 Unix 独有 syscall（`syscall.Stat_t`、`syscall.Kill`、`Setpgid`、`syscall.Flock`），在 Windows 上直接 `go test` 会构建失败（`build failed`）；
- 需要 `git` 可执行文件在 PATH 中（prepareRepository / 补丁类测试搭真实仓库）；
- `TestScriptNodeCanCallProjectMCP` 等依赖 `TestMain` 的 re-exec 机制，不能单独用 `go test -run TestMain` 之类方式理解；
- 测试几乎全部 `t.Parallel()`，且 `waitFor` 上限 30 秒（注释说明并行测试共享机器）—— CI 慢机上的偶发超时通常不是回归。

---

*本文基于 `internal/engine/engine.go`（struct 定义）与 `internal/engine/engine_test.go`（约 4400 行）静态梳理而成；engine 包另有约 50 个专题测试文件（runner 传输、run 租约、崩溃恢复等）未覆盖，可按第一节的对照表继续扩展阅读。*





