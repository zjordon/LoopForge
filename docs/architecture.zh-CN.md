# 架构

平台沿用上游的 Go module 名 `agentflow`、包边界与 `AGENTFLOW_` 环境变量，以减少后续合并冲突。

| 目录 | 职责 |
| --- | --- |
| `cmd/agentflow` | API、worker 或合一进程 |
| `cmd/agentflow-runner` | 个人与资源池执行机 |
| `cmd/agentflow-mcp`、`cmd/agentflow-gate-mcp` | 公开 MCP 与结构化门禁结果 |
| `internal/engine` | SOP 图、租约、调度、沙箱生命周期与交付。就绪分支在 run 工作区内并行执行；取消后重跑某一分支会恢复被取消的兄弟分支 |
| `internal/repo` | MySQL 持久化，每个业务领域一个 Repo |
| `internal/httpapi` | HTTP/MCP handler，每个业务领域一个 handler |
| `internal/runtime`、`internal/runner` | 执行器协议、凭据、隔离与产物 |
| `internal/tracker` | 远程 Issue/PR 适配器 |
| `web` | 内嵌的上游 Web 界面、偏好设置与公开登录 |
| `migrations` | 显式数据迁移与可选的公开目录 |
| `local` | 本地工作流与宿主集成；用户指南见 `docs/local/` |

公开版在上述基础上增加了账号/密码登录与 GitHub 适配器。它们接入既有的用户、令牌、仓库与交付契约；不存在独立的公开引擎，也没有内存版生产存储。以 `github:` 开头的远程仓库标识用于区分 GitHub 的 owner/repository 名称与旧的跟踪器标识；上游的 `gongfengProjectId` JSON 字段为兼容起见承载该标识。

CLI 的 Classic 与 Portable 工作流资产彼此独立，也与平台角色定义分开。共享行为契约优于复制运行时资产。平台 worker 不需要任何 classic 宿主包。
