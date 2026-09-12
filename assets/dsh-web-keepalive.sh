#!/bin/bash
# dsh-web-keepalive.sh — launchd agent com.fuguier001.dsh-web 的托管体
# 职责：
#   1. 防双实例：端口 3080 已被非托管实例（用户手动 nohup 的）占用时待命不抢；
#   2. 启动前 preflight：依赖链断则等 2 分钟交 launchd 重试，不进入紧密崩溃循环；
#   3. 以 NODE_OPTIONS（堆上限 8G + SIGUSR2 堆快照开关）启动 dsh web --no-open。
# 堆快照标记：exec 前 $$ 写入 heapsnapshot-flag.enabled；exec 不换 pid，
# 故文件内容 == dsh web 进程 pid，mem-watch 哨兵凭此判断能否安全 USR2。

PORT=3080
LOG="$HOME/.dsh/web-restart.log"
STATE="$HOME/.dsh/.keepalive-standdown"
FLAG="$HOME/.dsh/heapsnapshot-flag.enabled"
DSH_BIN="$HOME/.npm-global/bin/dsh"
MAX_OLD_SPACE="${DSH_MAX_OLD_SPACE:-8192}"   # 本机 24GB 物理内存

# launchd 环境极简，主动继承用户 shell 的 PATH / API KEY 等
[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv" 2>/dev/null
[ -x "$DSH_BIN" ] || DSH_BIN="$(command -v dsh)"
[ -n "$DSH_BIN" ] || { echo "=== keepalive: 找不到 dsh 二进制 ($(date)) ===" >> "$LOG"; sleep 120; exit 1; }

# 1) 端口被占用：可能是用户手动实例，待命（限速日志，防刷屏）
if lsof -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  now=$(date +%s); last=$(stat -f %m "$STATE" 2>/dev/null || echo 0)
  if [ $((now - last)) -gt 600 ]; then
    echo "=== keepalive: 端口 $PORT 被非托管实例占用，待命不抢 ($(date)) ===" >> "$LOG"
    touch "$STATE"
  fi
  sleep 120; exit 0
fi
rm -f "$STATE"

# 2) 启动前校验
if ! "$HOME/.dsh/dsh-web-preflight.sh" >> "$LOG" 2>&1; then
  echo "=== keepalive: preflight 失败，2 分钟后由 launchd 重试 ($(date)) ===" >> "$LOG"
  sleep 120; exit 1
fi

# 3) 启动（exec 保持 pid，与 FLAG 文件内容一致）
cd "$HOME"
export NODE_OPTIONS="--max-old-space-size=$MAX_OLD_SPACE --heapsnapshot-signal=SIGUSR2"
echo "=== keepalive 启动 dsh web（NODE_OPTIONS=$NODE_OPTIONS, $(date)）===" >> "$LOG"
echo $$ > "$FLAG"
exec "$DSH_BIN" web --no-open >> "$LOG" 2>&1
