#!/bin/bash
# restart-dsh-web.command — 双击即可重启 dsh web
# v2 (2026-09-12)：优先委托 launchd agent com.fuguier001.dsh-web（唯一属主，防双实例）；
# agent 未加载时走手动路径（含 preflight 校验 + NODE_OPTIONS 堆开关，与 keepalive 一致）。
# 逻辑：找到旧实例 → 委托/停止 → 重启 → 等待就绪 → 报告结果

PORT=3080
DSH_BIN=/Users/fuigui/.npm-global/bin/dsh
LOG="$HOME/.dsh/web-restart.log"
FLAG="$HOME/.dsh/heapsnapshot-flag.enabled"
AGENT="com.fuguier001.dsh-web"
UID_=$(id -u)

echo "==> 重启 dsh web（端口 $PORT）"

if launchctl print "gui/$UID_/$AGENT" >/dev/null 2>&1; then
  # ── 路径 A：launchd 托管（日常） ──
  echo "==> 委托 launchd agent $AGENT 重启"
  launchctl kickstart -k "gui/$UID_/$AGENT"
else
  # ── 路径 B：手动兜底（agent 被卸载时） ──
  OLD=$(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null)
  if [ -n "$OLD" ]; then
    echo "==> 停止旧进程: $OLD"
    kill $OLD 2>/dev/null
    pkill -f "dsh web" 2>/dev/null
    for i in $(seq 1 20); do
      lsof -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || break
      sleep 0.5
    done
    lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null
    sleep 1
  else
    echo "==> 当前没有运行中的 dsh web，直接启动"
  fi

  if ! "$HOME/.dsh/dsh-web-preflight.sh"; then
    echo "==> ❌ preflight 失败（依赖链断），已拒启。修复后再双击。"
    exit 1
  fi

  echo "==> 启动新进程（日志: $LOG）"
  echo "=== restart at $(date) ===" >> "$LOG"
  cd "$HOME"
  export NODE_OPTIONS="--max-old-space-size=8192 --heapsnapshot-signal=SIGUSR2"
  nohup "$DSH_BIN" web >> "$LOG" 2>&1 &
  echo $! > "$FLAG"
fi

# ── 等端口就绪（最多 60 秒；launchd 路径经 keepalive 待命窗口，可能更慢） ──
for i in $(seq 1 60); do
  sleep 1
  if lsof -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    NEW=$(lsof -tiTCP:$PORT -sTCP:LISTEN)
    echo "==> ✅ 重启成功（pid $NEW），请在浏览器刷新 http://127.0.0.1:$PORT"
    echo "=== up at $(date) pid=$NEW ===" >> "$LOG"
    exit 0
  fi
done

echo "==> ❌ 60 秒内未监听 $PORT，最近日志："
tail -15 "$LOG"
exit 1
