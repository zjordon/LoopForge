#!/usr/bin/env bash
# LoopForge 本机开发栈控制脚本(后台模式)
# 用法: ./devctl.sh {start|stop|restart|status|logs}
#   start            后台启动: 走 scripts/dev.sh 全流程(增量构建), 等健康检查就绪
#   stop [--mysql]   优雅停止平台(SIGTERM drain); --mysql 连 MySQL 容器一起停
#   restart          stop + start
#   status           平台与 MySQL 容器状态
#   logs             跟随平台日志(tail -f)
set -euo pipefail
cd "$(dirname "$0")"

PID_FILE=.local/platform.pid
LOG_FILE=.local/platform.log
HEALTH_URL=http://127.0.0.1:8090/api/health

# 平台 PID: 只认 platform.pid 登记过、且进程确实是本仓库 agentflow 的情况
platform_pid() {
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'agentflow' || return 1
  printf '%s' "$pid"
}

is_running() { platform_pid >/dev/null 2>&1; }

lan_url() { echo "http://$(hostname -I 2>/dev/null | awk '{print $1}'):8090"; }

cmd_status() {
  local pid
  if pid=$(platform_pid); then
    echo "平台: 运行中 (PID $pid)"
    if curl -sf -o /dev/null "$HEALTH_URL"; then
      echo "健康检查: ok  本机: $HEALTH_URL  局域网: $(lan_url)"
    else
      echo "健康检查: 未响应(可能在启动中)"
    fi
  else
    echo "平台: 未运行"
  fi
  docker compose ps --format 'MySQL 容器: {{.Name}} {{.State}} {{.Health}}' 2>/dev/null || \
    echo "MySQL 容器: 未运行"
  return 0
}

cmd_start() {
  if is_running; then
    echo "平台已在运行 (PID $(platform_pid)), 无需启动:"
    cmd_status
    return 0
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/8090") 2>/dev/null; then
    echo "端口 8090 已被其他进程占用(且不是本栈平台), 先排查: ss -tlnp | grep 8090" >&2
    exit 1
  fi
  mkdir -p .local
  rm -f "$PID_FILE"
  # 日志超过 10MB 时轮转一份 .old
  if [[ -f $LOG_FILE ]] && (( $(stat -c%s "$LOG_FILE") > 10485760 )); then
    mv "$LOG_FILE" "$LOG_FILE.old"
  fi
  setsid nohup bash scripts/dev.sh >>"$LOG_FILE" 2>&1 </dev/null &
  local wrapper=$!
  echo "后台启动中 (构建+启动, PID $wrapper, 日志: $LOG_FILE)"
  local i
  for i in $(seq 1 72); do            # 最多等 6 分钟
    sleep 5
    if curl -sf -o /dev/null "$HEALTH_URL"; then
      echo "就绪: $HEALTH_URL  局域网: $(lan_url)"
      return 0
    fi
    if ! kill -0 "$wrapper" 2>/dev/null; then
      echo "启动失败, 最近日志:" >&2
      tail -30 "$LOG_FILE" >&2 || true
      exit 1
    fi
  done
  echo "6 分钟未就绪(可能仍在首次构建/拉镜像), 进度查看: tail -f $LOG_FILE" >&2
  exit 1
}

cmd_stop() {
  local also_mysql=${1:-}
  local pid
  if pid=$(platform_pid); then
    echo "停止平台 (PID $pid, 优雅 drain)..."
    kill -TERM "$pid"
    local i
    for i in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || { echo "平台已停止"; break; }
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "平台仍在退出中(可能在排空在途 run, 最长可达 AGENTFLOW_DRAIN_TIMEOUT);"
      echo "确认无在途 run 后可强制: kill -9 $pid"
      return 1
    fi
    rm -f "$PID_FILE"
  else
    local pids
    pids=$(pgrep -f "$PWD/.local/bin/agentflow -addr" || true)
    if [[ -n $pids ]]; then
      echo "发现未登记的平台进程: $(echo $pids | tr '\n' ' '), 发送 SIGTERM..."
      kill -TERM $pids || true
      rm -f "$PID_FILE"
    else
      echo "平台未运行"
    fi
  fi
  if [[ $also_mysql == "--mysql" ]]; then
    echo "停止 MySQL 容器..."
    docker compose stop mysql >/dev/null 2>&1 || true
  else
    echo "(MySQL 容器保留运行; 连它一起停用: ./devctl.sh stop --mysql)"
  fi
  return 0
}

cmd_logs() {
  if [[ -f $LOG_FILE ]]; then
    tail -n 100 -f "$LOG_FILE"
  else
    echo "暂无日志文件($LOG_FILE); 平台可能从未以本脚本启动"
  fi
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop "${2:-}" ;;
  restart) cmd_stop "${2:-}" || true; cmd_start ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  *) echo "用法: $0 {start|stop [--mysql]|restart|status|logs}" >&2; exit 1 ;;
esac
