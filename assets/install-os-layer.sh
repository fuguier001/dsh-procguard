#!/bin/bash
# install-os-layer.sh — 部署 dsh-procguard 的 OS 看护层（第 1~3 层），幂等可重跑
# 交付物：
#   ~/.dsh/dsh-web-keepalive.sh      launchd 托管启动体（防双实例 + preflight 闸 + NODE_OPTIONS 堆开关）
#   ~/.dsh/dsh-web-preflight.sh      boot 前依赖链校验（断链拒启明示原因）
#   ~/.dsh/mem-watch.sh              内存哨兵（5 分钟采样，超 2.5GB 自动抓堆快照）
#   ~/Desktop/restart-dsh-web.command 双击重启入口（launchd 在管则委托 kickstart）
#   ~/Library/LaunchAgents/com.fuguier001.dsh-web.plist        KeepAlive 保活
#   ~/Library/LaunchAgents/com.fuguier001.dsh-mem-watch.plist  哨兵保活
# 仅支持 macOS（Linux 骨架在插件内，脚本移植欢迎 PR；Windows 不支持）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DSH_HOME="${HOME}/.dsh"
AGENTS="${HOME}/Library/LaunchAgents"
UID_="$(id -u)"

echo "==> 部署 OS 看护层到 ${DSH_HOME}（幂等，重复执行安全）"

install -m 755 "$HERE/dsh-web-keepalive.sh"   "$DSH_HOME/dsh-web-keepalive.sh"
install -m 755 "$HERE/dsh-web-preflight.sh"   "$DSH_HOME/dsh-web-preflight.sh"
install -m 755 "$HERE/mem-watch.sh"           "$DSH_HOME/mem-watch.sh"
install -m 755 "$HERE/restart-dsh-web.command" "$HOME/Desktop/restart-dsh-web.command"
install -m 644 "$HERE/com.fuguier001.dsh-web.plist"      "$AGENTS/com.fuguier001.dsh-web.plist"
install -m 644 "$HERE/com.fuguier001.dsh-mem-watch.plist" "$AGENTS/com.fuguier001.dsh-mem-watch.plist"

echo "==> 装载 launchd agents（已装载则跳过）"
for a in com.fuguier001.dsh-web com.fuguier001.dsh-mem-watch; do
  if launchctl print "gui/${UID_}/${a}" >/dev/null 2>&1; then
    echo "    ${a}: 已在册"
  else
    launchctl bootstrap "gui/${UID_}" "$AGENTS/${a}.plist"
    echo "    ${a}: 已装载"
  fi
done

echo "==> 校验"
"$DSH_HOME/dsh-web-preflight.sh" || true   # 断链不阻塞安装（管家上岗后会自动修复 imgview 链接）
echo "==> 完成。若 dsh web 正在运行且非 launchd 托管，双击 ~/Desktop/restart-dsh-web.command 完成交接"
