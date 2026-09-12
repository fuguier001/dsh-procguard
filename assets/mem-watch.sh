#!/bin/bash
# mem-watch.sh — dsh web 内存哨兵（launchd 托管，跨宿主重启/跨开机存活）
# 职责：每 5 分钟记录端口 3080 监听进程的 RSS 到 ~/.dsh/mem-watch.log；
#       RSS 超阈值（默认 2.5GB）时，若该 pid 确认启用了堆快照开关
#       （heapsnapshot-flag.enabled 内容 == pid，由 keepalive 写入），
#       自动 kill -USR2 抓堆快照（12 小时内最多一次）；否则只记警情。
# 快照文件落在 dsh web 的 cwd（$HOME）：~/Heap.<日期>.<时间>.<pid>.*.heapsnapshot
# （实测 Node 24.15 文件名模式，2026-09-12 验证通过）
# 用法：由 launchd agent com.fuguier001.dsh-mem-watch 托管（开机自启、死亡自动重启）；
#       也可手动 nohup 调用。停止请用：launchctl bootout gui/$(id -u)/com.fuguier001.dsh-mem-watch
#       （直接 kill 会被 KeepAlive 立即拉起）
# 自限：连续运行 180 天后退出——launchd 会自动重启续期。（2026-09-12 实测教训：
#       nohup 起的哨兵会随 dsh web 宿主一起死，必须 launchd 化才能存活。）

PORT=3080
LOG="$HOME/.dsh/mem-watch.log"
FLAG="$HOME/.dsh/heapsnapshot-flag.enabled"
LAST_SNAP="$HOME/.dsh/.mem-watch-lastsnap"
PIDFILE="$HOME/.dsh/mem-watch.pid"
THRESH_KB="${MEM_WATCH_THRESH_KB:-2621440}"   # 2.5GB；2026-09-12 事故在 ~4GB 崩

case "${1:-start}" in
  stop)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill "$(cat "$PIDFILE")" 2>/dev/null
      echo "$(date '+%F %T') mem-watch stopped" >> "$LOG"
    fi
    rm -f "$PIDFILE"; exit 0 ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "running pid=$(cat "$PIDFILE")"; else echo "not running"; fi
    exit 0 ;;
esac

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "already running pid=$(cat "$PIDFILE")"; exit 0
fi
echo $$ > "$PIDFILE"
echo "$(date '+%F %T') mem-watch start pid=$$ threshold=${THRESH_KB}KB interval=300s" >> "$LOG"

# 180 天 × 288 次/天
for i in $(seq 1 51840); do
  pid="$(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | head -1)"
  if [ -n "$pid" ]; then
    rss="$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')"
    if [ -n "$rss" ]; then
      echo "$(date '+%F %T') pid=$pid rss=${rss}KB ($((rss/1024))MB)" >> "$LOG"
      if [ "$rss" -gt "$THRESH_KB" ]; then
        flagged="$(cat "$FLAG" 2>/dev/null)"
        now=$(date +%s); last="$(cat "$LAST_SNAP" 2>/dev/null || echo 0)"
        if [ "$pid" = "$flagged" ] && [ $((now - last)) -gt 43200 ]; then
          echo "$(date '+%F %T') ⚠️ RSS=${rss}KB 超阈值 → 抓堆快照 kill -USR2 $pid（快照将落在 $HOME/Heap.*.heapsnapshot）" >> "$LOG"
          if kill -USR2 "$pid" 2>/dev/null; then echo "$now" > "$LAST_SNAP"; fi
        else
          echo "$(date '+%F %T') ⚠️ RSS=${rss}KB 超阈值（pid 未启用快照开关，或 12h 内已抓过；只记警情不动进程）" >> "$LOG"
        fi
      fi
    fi
  fi
  sleep 300
done
echo "$(date '+%F %T') mem-watch 运行满 180 天自动退出" >> "$LOG"
rm -f "$PIDFILE"
