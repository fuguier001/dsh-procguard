#!/bin/bash
# dsh-web-preflight.sh — dsh web 启动前依赖链校验
# 背景：2026-09-12 07:10 boot 即崩 —— link: 插件 dsh-imgview 的 peer 依赖
# @deepseek-ai/dsh-tools 符号链接断链（dsh 全局升级/重装后高发），导致整个插件树加载失败。
# 本脚本在启动前验证：插件目录存在、两个 peer 包可解析、profile 侧软链存在。
# 用法：直接运行；退出码 0=健康，1=断链（调用方应拒启并明示原因）。
# 测试失败路径可用 DSH_PREFLIGHT_PLUGIN_DIR 指向一个复制的坏目录。

PLUGIN_DIR="${DSH_PREFLIGHT_PLUGIN_DIR:-$HOME/Documents/DSCli/dsh-imgview}"
PROFILE_LINK="$HOME/.dsh/profiles/web/node_modules/dsh-imgview"

fail() { echo "[preflight] ✗ $1"; exit 1; }

[ -d "$PLUGIN_DIR" ] || fail "插件目录不存在: $PLUGIN_DIR"

for pkg in "@deepseek-ai/dsh-tools" "@deepseek-ai/cordis"; do
  node -e '
    const { createRequire } = require("module");
    const r = createRequire(process.argv[1] + "/lib/index.js");
    try { r.resolve(process.argv[2]); } catch (e) { process.exit(1); }
  ' "$PLUGIN_DIR" "$pkg" \
    || fail "无法从 $PLUGIN_DIR 解析 $pkg —— node_modules 符号链接可能已断（dsh 升级/重装后高发），修复：在该插件的 node_modules/@deepseek-ai/ 下重建指向全局 dsh 内对应包的链接"
done

[ -e "$PROFILE_LINK" ] || fail "profile 软链缺失: $PROFILE_LINK"

# 静态看护管家 dsh-procguard（vendor 于 profile 内部，永不悬空；失联=profile 损坏）
PROC_PKG="$HOME/.dsh/profiles/web/node_modules/dsh-procguard"
[ -e "$PROC_PKG" ] || fail "dsh-procguard 装载点缺失: $PROC_PKG"
node -e 'import(process.argv[1] + "/lib/index.js").then(() => process.exit(0)).catch(() => process.exit(1))' "$PROC_PKG" \
  || fail "dsh-procguard 导入失败（vendor 内容损坏，boot 会在插件树连坐——先修再启）"

echo "[preflight] ✓ 插件依赖链健康（imgview 两个 peer 包可解析、profile 软链在位、procguard vendor 可导入）"
