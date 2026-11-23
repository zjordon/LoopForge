# LoopForge 接入 GLM Coding Plan 与 GitHub 操作手册

> 整理自 2026-11-20 晚间的实际部署操作（实例 `http://192.168.5.7:8090`，LoopForge 0.3.8+，管理员账号 admin）。
> 目标：不使用 CodeBuddy，用 **Claude Code 执行器 + GLM Coding Plan** 驱动全部 SOP 节点；接入 GitHub 私有仓库并同步 Issue。
> 所有菜单名称均按当晚上述版本的实际界面记录。

## 目录

1. [配置 GLM 作为模型后端](#1-配置-glm-作为模型后端)
2. [接入 GitHub 并同步 Issue](#2-接入-github-并同步-issue)
3. [故障排查：需求定型失败（CodeBuddy 依赖）](#3-故障排查需求定型失败codebuddy-依赖)
4. [替换 SOP 执行器并重跑需求](#4-替换-sop-执行器并重跑需求)
5. [交付模型：直建 PR vs 集成分支（二选一）](#5-交付模型直建-pr-vs-集成分支二选一)
6. [升级到 0.4.1：从 v0.4.0 或更早版本](#6-升级到-041从-v040-或更早版本)
7. [附录：API 速查与注意事项](#7-附录api-速查与注意事项)

---

## 1. 配置 GLM 作为模型后端

GLM 不在 LoopForge 的十种执行器里，但 GLM Coding Plan 提供兼容 Anthropic 协议的端点，而 **Claude Code 执行器原生支持自定义 API Key + Base URL**，两者正好接上。

### 1.1 准备材料

| 材料 | 取值（国内 Plan） | 取值（国际 Plan） |
|------|-------------------|-------------------|
| API Key | 智谱控制台 → API Keys（Coding Plan 专用） | 同左 |
| Base URL | `https://open.bigmodel.cn/api/anthropic` | `https://api.z.ai/api/anthropic` |

> Base URL 必须是纯 HTTP(S) 地址，**不能带查询参数、账号密码或路径后缀**（平台校验规则在 `internal/httpapi/users.go:68`）。

### 1.2 界面配置步骤

1. 登录 LoopForge → 右上角头像 → **个人配置**（`#/settings`）。
2. 「个人凭证」→ 第 4 个分组 **「模型与执行 · AI 对话与编码 CLI」**（默认折叠，点开）。
3. 找到 **Claude Code** 行 → 点 **「去配置」**。
4. 弹窗（第 2 步 / 共 3 步）填两项：
   - **Claude Code API Key**：GLM API Key；
   - **Base URL**：上表的智谱端点。
5. 点 **「下一步」** 进入第 3 步模型目录：
   - 优先点 **「获取可用模型」** 用表单里的 Key + Base URL 探测远端模型列表；
   - 若端点不返回列表（提示「可以手动添加模型」），逐个**手动添加模型 ID**。本次实际添加的 12 个：`glm-4.5`、`glm-4.5-air`、`glm-4.6`、`glm-4.7`、`glm-5`、`glm-5-turbo`、`glm-5.1`、`glm-5.2`、`glm-5.3`、`glm-5.3-flash`、`glm-5.3-flashx`、`glm-5.3-flashx-legal`。
6. 保存。回到列表页，Claude Code 行应显示 **「已配置」** 并带 Base URL 与自定义模型数。

### 1.3 机制说明（为什么能通）

运行时绑定凭据时（`internal/runtime/command_binding.go:114-123`），平台把配置注入为 `ANTHROPIC_API_KEY` + `ANTHROPIC_BASE_URL` 写进该 run 的**私有 HOME**，同时先清空宿主机上的同名环境变量（`:46`），Claude Code CLI 据此直连智谱的 Anthropic 兼容网关。凭据**按用户隔离**：每个团队成员要在自己的个人配置里填各自的 Key。

### 1.4 仍然固定 CodeBuddy 的边角功能（无 Key 时不可用，但不影响 SOP 跑通）

- 需求抽屉里的「**澄清**」按钮（独立澄清接口，其它 CLI 的模型会被 400 拒绝）；
- Run 页面的「**智能评测**」页签；
- AI 通知摘要 / Bot 回复。

---

## 2. 接入 GitHub 并同步 Issue

Issue 通过「同步」进入平台：tracker 遍历所有 `provider=github` 的已绑定仓库，全量分页拉取（自动跳过 PR），open → `todo` 落入需求列表（`internal/tracker/service.go:302-314`）。**Issue 导入和 PR 状态同步用的是「项目 Owner」的 Git token**——谁的项目谁去授权。

### 2.1 个人 GitHub 授权（Device Flow）

1. **个人配置 → 个人凭证 → 平台集成 → GitHub → 去配置**。
2. 弹窗选「GitHub 授权」页签 → 点 **「连接 GitHub」** → 显示 8 位授权码（如 `A38C-FF5B`）。
3. 新开标签页访问 `https://github.com/login/device`：
   - 已登录则直接选账号（Continue as xxx）；未登录先登录；
   - 在 8 个单字符输入框里填入授权码 → Continue；
   - 确认页核对应用名为 **LoopForge**（仓库权限：公开 + 私有）→ 点 **Authorize**。
4. 回到 LoopForge，轮询成功后弹窗自动变为**仓库选择器**，GitHub 行显示「已配置」。

**⚠️ 已踩过的坑：**

- **授权按钮长时间禁用**：确认页上「Organization access」区块如果一直显示 Loading（组织策略请求在网络不佳时挂起），Authorize 按钮会保持 disabled。这是纯客户端门，可等待、刷新重进，或强制启用按钮后用 `form.requestSubmit(按钮)` 提交（等效真实点击）。本次第三次尝试成功。
- **`form.submit()` 会被当成拒绝**：GitHub 的授权表单靠提交按钮携带 `authorize=1` 参数区分「授权/取消」，漏掉它 GitHub 记为 denied，LoopForge 侧报「授权被拒绝或已过期」。若需脚本辅助，必须用 `requestSubmit(button)`。
- **确认页一次性**：`/login/device/confirmation` 刷新即 404，需要重新走一遍输码流程（授权码本身 15 分钟内有效）。
- Organization 下的 Restricted 标记与 Grant 按钮是可选项，个人仓库授权不需要动它们。

### 2.2 绑定仓库到项目

1. **设置 → 项目配置** → 点开目标项目。
2. **「代码仓库」页签 → ＋ 添加仓库**。
3. 点 **「选择我的 GitHub 仓库」**（推荐：走授权后的选择器，自动带出真实默认分支），搜索并选中仓库；也可直接粘贴 `https://github.com/<owner>/<repo>`。
4. 确认主分支（集成分支可选）→ **保存仓库**（保存即生效，无需点「保存项目设置」）。首个仓库自动设为项目默认仓库。

### 2.3 导入与增量同步 Issue

- **手动一次性导入**：**需求列表 → 更多 → 同步 GitHub**。后台异步执行，完成后需求列表出现带「GitHub」徽标的工作项（本次导入 29 条）。
- **自动同步（可选）**：需求列表 → 更多 → 外部同步 → 勾选「自动同步」（默认间隔 300 秒）。
- **重复同步安全**：本地已做的澄清结论、状态推进、描述修改不会被覆盖（`internal/tracker/github_test.go:64-73` 有专测）；GitHub 侧关闭的 Issue 会同步为已关闭。
- GitHub 是**全量同步**，无单条重拉（逐条重同步只有 TAPd 有）。

---

## 3. 故障排查：需求定型失败（CodeBuddy 依赖）

### 3.1 现象

Run 详情页第一节点「需求定型」失败（通常十几秒内、0 tokens），失败信息：

> 需求责任人未配置 CodeBuddy API Key，请在个人配置中配置

### 3.2 原因

内置 SOP 的角色默认执行器是 **CodeBuddy**（执行器解析优先级：角色 `ExecutorID` → 节点 `ExecutorID` → 默认 `codebuddy`，见 `internal/engine/node_execute.go:189-196`）。凭据绑定阶段硬检查失败（`command_binding.go:90-93`），还没调模型。SOP 模板卡片上的「运行条件：需要 CodeBuddy API Key」即指此事。

### 3.3 结论

「需求定型」等节点都是**普通 Agent 节点**，执行器随角色定义可换——不需要装 CodeBuddy，按下节把角色全部切到 Claude Code/GLM 即可。

---

## 4. 替换 SOP 执行器并重跑需求

### 4.1 复制内置 SOP 到项目

内置 SOP 只读。**设置 → 流程模板 → 「内置」页签** → 目标卡片（如「通用缺陷修复 SOP」）→ **复制到本项目**。弹窗会列出运行依赖（此时仍提示 CodeBuddy 未配置——复制不检查依赖，后面换掉即可）。确认复制后**自动进入流程设计器**，且 6 个角色定义（需求定型/方案设计/开发实现/独立评审/测试验证/交付汇总）随复制进入项目。

> 坑：设计器左侧角色库可能短暂显示「这个项目还没有角色」、画布节点显示「角色不可用」——是复制完成前的旧状态，刷新设计器即恢复。

### 4.2 批量切换 6 个角色的执行器与模型

**设置 → 角色定义（`#/agents`）**，对每个角色重复：

1. 点开角色 → 编辑弹窗。
2. **「运行方式 → CLI」**下拉：`CodeBuddy` → **`Claude Code`**。
3. **「模型」**：下拉默认只列 Claude 官方目录，选最底部 **「手动输入模型 ID…」**，填入 GLM 模型 ID（本次统一用 **`glm-5.3`**；轻量文档节点可考虑 `glm-5.3-flash`）。
4. **保存**（提示「Agent 新版本已保存」）。

### 4.3 发布并切换需求关联

1. 回到设计器（**流程模板 → 本项目 → 打开设计器**），确认节点全部可用、无「角色不可用」→ 点 **「发布版本」**（草稿 → 已发布）。
2. 需求默认仍关联旧的通用 SOP。切换方式二选一：
   - **界面**：需求抽屉里改关联 SOP（若当前版本提供入口）；
   - **API**（本次实际使用，可靠）：浏览器控制台（已登录态）执行
     ```js
     fetch("/api/issues").then(r => r.json()).then(async list => {
       const it = list.find(x => x.title.includes("批次4")); // 按标题定位
       it.workflowId = "sop-mwp0aeff-t688";                   // 新 SOP 的 id
       const r = await fetch("/api/issues", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(it) });
       console.log("PUT", r.status);
     });
     ```
     SOP id 可从 `GET /api/bootstrap` 的 `workflows` 里查（`generic:false` 的是项目副本）。
3. 需求抽屉 → **「整条 SOP 从头触发」**。

### 4.4 验证成功的标志

- 新 run 的第一个节点**持续 running 超过 1–2 分钟**（对比凭据失败时 13 秒内即死）；
- Run 详情页「资源消耗」开始出现 tokens（首次调用前为 0 正常）。

> 首次运行会按需 npm 安装 Claude Code CLI（pinned 版本装入 `$LOOPFORGE_DATA_DIR/cli`，之后对话与 SOP 沙箱共享），第一节点耗时几分钟属正常。镜像内置的 CLI 只有 CodeBuddy/Codex/DeepSeek Harness。

---

## 5. 交付模型：直建 PR vs 集成分支（二选一）

### 5.1 背景：为什么手动跑完的 run 没有推代码、没建 PR

平台有**两条彼此独立**的交付通道，各有自己的开关：

- **平台侧自动集成**（`internal/engine/integrate.go`）——两道门**同时满足**才启动：
  1. run 由**定时调度**触发（`ExecutionContext.ScheduleJobID` 非空，`integrate.go:55`）；手动「从头触发」的 run 直接跳过；
  2. 仓库配置了**集成分支**（`rc.IntegrateBranch` 非空，`integrate.go:84-86`）；留空则 `continue`。
- **Agent 侧交付**（交付节点的角色提示词驱动）——内置「通用缺陷修复 SOP」的交付汇总角色默认规则是
  「仅在用户明确要求且已配置目标 GitHub 仓库及凭据时创建 PR，不得自行合并」。没人明确要求时，agent 只在本地备好分支与 PR 素材，不推远端。

**注意**：SOP run 成功后约 1 分钟工作区即被自动清理，且六个节点的产物快照均为 `.md` 报告、不含代码——若 agent 未推送，产出代码会随工作区一起丢失。先到服务器 `.local/workspaces/` 查工作区是否幸存；已删则只能从「开发实现」节点重跑。

### 5.2 两种交付模型

| 模型 | 配置方式 | 行为 | 适合 |
|------|----------|------|------|
| **A. 直建 PR**（当前采用） | 仓库「集成分支」**留空** + 交付角色提示词要求推送并建 PR | agent 完成后 `git push` 工作分支并创建 PR 到 main，人负责合并 | 手动触发 / 小团队，一条需求一个 PR |
| **B. 集成分支收敛** | 仓库填「集成分支」（如 `agentflow/integration`）+ 定时/自动派发触发 + 交付角色不碰远端 | 平台自动推工作分支、向集成分支建 PR 并自动合并；攒批后由人把集成分支合回 main（默认分支绝不自动合入） | 批量自动交付 |

两模型的开关相互独立，**同时打开会双路交付**（agent 的 work→main PR + 平台的 work→集成分支 PR，同样的改动进 main 两次，重复且易冲突）。选定一个后不要混开。

### 5.3 本部署交付配置的演进（按时间序）

1. **2026-11-21 早（0.3.x 时期的临时方案，已废弃）**：曾把「交付汇总」角色提示词中的
   「仅在用户明确要求且已配置目标 GitHub 仓库及凭据时创建 PR，不得自行合并」
   改为「已配置目标 GitHub 仓库及凭据时，完成后推送工作分支并创建 PR 到主分支 main；不得自行合并」。
   该方案依赖提示词约束，无门禁校验，已被 0.4.0 的「发起 MR」节点取代，提示词已还原为出厂默认。
2. **2026-11-21 晚（0.4.0 正式方案，现行）**：升级 0.4.0 后从内置模板重新复制 SOP（新副本 `sop-mwpuifbf-rzri`，8 节点，已发布）。
   「发起 MR」节点（人工验收 → 发起 MR → 交付汇总）负责提交、推送并创建 MR/PR，写 `mr-body.md`，
   并带两道门禁：`mr-pushed`（命令门禁：工作区无未提交改动、在工作分支上、origin 已推到 HEAD）与
   `mr-opened`（`mr` 模式门禁：引擎到 GitHub/工蜂查证 MR 真实存在且 head 为推送的 tip）。
   门禁不过自动带反馈重试一次，再不过转人工——不再出现「run 成功但代码留在被清理的工作区」。
   「交付汇总」出厂提示词已改为只汇总（按 mr-body.md 记录链接/分支/SHA），不再推送或建 PR。
   7 个角色（含新增「发起 MR」）已全部切 Claude Code + `glm-5.3`；29 条存量需求已批量重指派到新副本；旧副本 `sop-mwp0aeff-t688` 已删除（删除前 diff 确认 v1→v2 无实质差异）。
   仓库仍未配置集成分支，交付保持模型 A 单通道。

> 经验记录：0.4.0 升级后浏览器若长期开着旧页签，模板数据会停留在旧版（复制弹窗显示 7 节点），
> Ctrl-Shift-R 强刷后才显示 8 节点；内置模板升级**不会**同步到已复制的项目副本，需要重新复制。

---

## 6. 升级到 0.4.1：从 v0.4.0 或更早版本

> 本章步骤针对本部署的形态：**原生安装**（`bash scripts/dev.sh` 或 `./devctl.sh start`），平台直接跑在宿主机上，MySQL 是 compose 里的 `mysql` 容器。步骤中的命令都按这个形态写。
> 0.4.1 的官方说明见 `docs/deployment.md` 的「Migrating existing GitHub credentials」一节。

### 6.1 升级前必读：三件必须知道的事

**① 036 迁移必须手工执行，且必须在启动新版本之前。**
0.4.1 改了 Git 凭据的存储模型：从「每用户一个 `user_configs.git_token`」变成「每用户、每主机一条凭据」（新表 `user_git_http_credentials`）。新代码从新表读凭据，所以不回填就会出现「GitHub 显示已配置，但沙箱里取不到 token」。顺序错了（先起新服务再跑迁移）在这段时间内的推送都会失败。

**② 本部署的安装器不会代劳。**
`scripts/dev.sh` 只重放 `migrations/seed/001`、`002` 两个文件（见脚本第 17-18 行），**不调用** `install-schema-extensions.sh`。所以 036、038 在本部署上都要手工执行。Compose 发布镜像安装（`./start.sh`）会自动跑 033/038，但**同样不会自动跑 036**。

**③ 内置模板会被改写，你的项目副本不会。**
038 把内置模板里「发起 MR」角色的认证指令从

> GitHub 仓库优先用已配置的 GitHub MCP，没有时用 curl 调 GitHub API，令牌取 $AGENTFLOW_GIT_TOKEN

改成

> 使用托管平台的 CLI（如 gh、glab）或已配置的 MCP……调用 API 需要令牌时，用 git credential fill 按仓库主机获取

它的 `UPDATE` 只作用于 `generic_templates` 表。本部署的「缺陷修复 SOP」是复制进 `workflows` 表的项目副本（`sop-mwpuifbf-rzri`），**不在改写范围内**，所以「发起 MR」角色会继续带着旧指令运行。旧指令里的 `$AGENTFLOW_GIT_TOKEN` 在 0.4.1 下是否还有效见 6.4 的验证步骤。

### 6.2 备份

```bash
cd /home/jasonzhang/git/z_jordon/LoopForge
# 数据库全量导出（回滚的唯一依靠）
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction loopforge' \
  > .local/loopforge-pre-0.4.1-$(date +%Y%m%d-%H%M%S).sql
ls -lh .local/loopforge-pre-0.4.1-*.sql     # 确认不是空文件
```

`.local/` 已被 Git 忽略，导出文件不会进提交。

### 6.3 升级步骤

```bash
cd /home/jasonzhang/git/z_jordon/LoopForge

# 1. 停平台，MySQL 保持运行
./devctl.sh stop            # 注意：不要加 --mysql

# 2. 取新代码（fork 的 main 已合并上游 v0.4.1）
git pull

# 3. 手工执行 036 —— 必须写全文件名，见下方说明
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u loopforge loopforge' \
  < migrations/036_git_http_credentials.sql

# 4. 确认回填结果（应看到一行，host = github.com）
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u loopforge loopforge -e \
  "SELECT user_id, host, platform, username, created_at FROM user_git_http_credentials;"'

# 5. 手工执行 038（只影响内置模板，可重复执行）
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u loopforge loopforge' \
  < migrations/038_generic_sop_host_credentials.sql

# 6. 重新构建并启动
./devctl.sh start
```

**为什么要写全文件名**：`migrations/` 里有两组撞号的脚本——`036_git_http_credentials.sql` 与 `036_assistant_steer_on_send.sql`，`039_platform_git_ssh_hosts.sql` 与 `039_schedule_execution_legacy_stats.sql`。不要用 `036_*.sql` 这样的通配符批量执行，会跑到不相干的脚本。038 还要求在 033 之后执行；本部署此前没有手工跑过 033（内置模板是随新版本 seed 进来的），如果 038 执行后内置模板没变化，先把 `033_generic_sop_mr_node.sql` 跑一遍再重跑 038。

### 6.4 升级后验证（按顺序）

| # | 验证什么 | 怎么做 | 不通过的迹象 |
|---|---------|--------|-------------|
| 1 | 凭据已回填 | 6.3 第 4 步的查询有 `github.com` 一行 | 表为空 → 回填没发生，见 6.6 |
| 2 | 平台起来了 | `curl -s http://127.0.0.1:8090/api/health` 返回 `{"status":"ok"...}` | 起不来 → 看 `.local/platform.log` |
| 3 | **私有仓库能访问** | 个人配置 → GitHub 一行仍是「已配置」；需求列表 → 更多 → 同步 GitHub，确认能拉到 Issue | 同步报 401/404 → 凭据没迁好，见 6.6 |
| 4 | 端到端交付 | 挑一条需求跑完「发起 MR」，确认 GitHub 上出现 PR | MR 节点报凭据错误 → 见 6.6；报 IP 授权相关 → 见 6.7 |

第 3 项是官方文档点名要求验证的：本部署绑定的 `zjordon/examination-system` 是私有仓库，正好落在受影响范围内。

### 6.5 037：回滚窗口过后再执行

`037_retire_plain_git_token.sql` 会把旧列 `user_configs.git_token` 清空——**仅当**它与新表里的 `github.com` 凭据值完全一致时才清；不一致则两边都保留。它还会删除 036 期间临时加的 `expose_to_workspace` 列。

这一步是**不可逆**的收尾动作，不要和 036 在同一时间做。等 6.4 的四项都通过、并且不再需要回滚到旧版本之后：

```bash
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u loopforge loopforge' \
  < migrations/037_retire_plain_git_token.sql
```

**回滚到 0.4.0 的窗口只存在于执行 037 之前**：旧版本读的是 `user_configs.git_token`，036 只是复制不清空，所以在 037 之前把代码切回旧提交就能回退。

### 6.6 回填为空时怎么查

036 的回填有排除条件，以下情况**不会**被复制：

- 该用户有工蜂 refresh token（`gongfeng_refresh_token` 非空）；
- token 以 `oauth2:` 或 `private:` 开头（受管凭据，由部署适配器自己管理）；
- `git_token` 本身为空。

排查查询（写法上避开了嵌套引号，可直接复制；不输出 token 内容）：

```bash
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u loopforge loopforge -e "SELECT user_id, LENGTH(TRIM(git_token)) AS token_len, LEFT(git_token,8) LIKE CONCAT(CHAR(111,97,117,116,104,50), CHAR(58), CHAR(37)) AS is_oauth2, LEFT(git_token,8) LIKE CONCAT(CHAR(112,114,105,118,97,116,101), CHAR(58), CHAR(37)) AS is_private, LENGTH(TRIM(gongfeng_refresh_token)) AS gongfeng_len FROM user_configs;"'
```

> 上面两个 `LIKE` 里的 `CHAR(...)` 分别拼出 `oauth2:` 和 `private:` 前缀，这样整条命令里不需要出现单引号。

- `token_len = 0`（或 NULL）：这个用户本来就没配 GitHub，正常。
- `is_oauth2 = 1` 或 `is_private = 1`：受管凭据，按设计不回填，由部署适配器继续提供，无需处理。
- `token_len > 0`、两个前缀标记都是 0、`gongfeng_len = 0`，但 `user_git_http_credentials` 里没有这个用户的 `github.com` 行：重跑 036（幂等，已存在的 `github.com` 条目会被保留），仍不行就到个人配置里重新走一遍 GitHub 授权（0.4.1 的代码直接写新表，`internal/httpapi/github_auth.go:315`）。

### 6.7 0.4.1 中与本部署相关的其它变化

| 变化 | 对本部署的影响 |
|------|---------------|
| CodeBuddy 在平台模型功能里变为可选（#1157） | 第 1.4 节列的「仍然固定 CodeBuddy」边角功能可能已放开。升级后如果「澄清」「智能评测」能选 Claude Code，第 1.4 节即过时。**未在本部署上验证** |
| 安装器自动重放 033/038（#1010） | 只对 `./start.sh` / `./start.sh pull` 生效；本部署走 `dev.sh`，仍需手工执行 |
| HTTPS Git 服务器 IP 授权（#1232） | 自建 Git 服务器场景才需要；本部署用 github.com，不需要配置。如果 MR 节点推送失败且报 IP 授权相关错误，查这一项 |
| 新增按主机分发可信 SSH 主机密钥（`039_platform_git_ssh_hosts.sql`） | 本部署不用 Git SSH，不需要执行 |
| SOP 设计器的 AI 编排器重写 | 功能变化，无部署影响 |

### 6.8 升级记录

- 2026-11-23：fork 的 main 已合并上游 v0.4.1（`upstream/main @ 37e0dada`，合并提交 `0ed34e60`），仅 CHANGELOG 冲突。**服务器尚未升级**，本章步骤待执行。

---

## 7. 附录：API 速查与注意事项

### 7.1 当晚用过的 API（均可用浏览器登录态直接 fetch）

| 用途 | 请求 | 说明 |
|------|------|------|
| 查角色执行器/模型 | `GET /api/bootstrap` → `agents[]` | 核对 6 角色 `executorId:"claude"`、`model:"glm-5.3"` |
| 查 SOP 清单 | `GET /api/bootstrap` → `workflows[]` | `generic:true` 为内置模板，`generic:false` 为项目副本 |
| 改需求关联 SOP | `PUT /api/issues`（整对象回传） | 先 `GET /api/issues` 定位，改 `workflowId` 后回写 |
| 查 run 状态 | `GET /api/runs/{id}` | `status`；`nodes` 是 **map** 不是数组，用 `Object.values()` |
| 触发 GitHub 同步 | （界面）需求列表 → 更多 → 同步 GitHub | 等价 `POST /api/sync/now`（后台异步） |

### 7.2 检查清单（新成员接入 GLM + GitHub）

- [ ] 个人配置 → Claude Code：Key + Base URL + 模型目录已保存（显示「已配置」）
- [ ] 个人配置 → GitHub：device flow 授权完成（显示「已配置」）
- [ ] 项目已绑定仓库且为默认（需求列表页头部可见「代码仓库（1）」）
- [ ] SOP 角色的 CLI 全部为 Claude Code、模型为 GLM（角色定义页逐个核对）
- [ ] SOP 已「发布版本」（不再是草稿）
- [ ] 需求的「关联 SOP」指向项目副本（列表「关联 SOP」列核对）
- [ ] 需求列表 → 更多 → 同步 GitHub 已执行，Issue 带 GitHub 徽标进入列表

### 7.3 其它注意事项

- **凭据按人隔离**：没有全局环境变量可替所有人配 Claude Code key；API token 管理（`/api/auth/tokens`）只能用登录 Cookie，不允许 Bearer 自建。
- **聊天路径同理**：AI 工作台 composer 里执行器选 Claude Code、模型选 GLM，Main Bot 对话同样不走 CodeBuddy。
- **其余存量需求**：同步进来的旧需求默认关联通用 SOP，触发前记得切换（或批量 API 改 `workflowId`）。
- 本手册基于 2026-11-20 的 0.3.8+ 界面；菜单文案随版本可能调整，以实际界面与 `docs/api/` 为准。
