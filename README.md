# dsh-procguard

DSH（DeepSeek Harness）**进程看护管家**：一个跑在 dsh web 进程里的 Cordis 插件，把自己的看护层安装进操作系统——launchd（macOS）/ systemd（Linux，骨架）保活、启动前依赖链校验、内存哨兵、断链自愈。进程死了有人拉起，链断了有人修，泄漏了有现场。

## 它解决什么问题

2026-09-12 的一次完整事故复盘（同一台机器，一夜两崩）：

| 事故 | 根因 | 本包对应的层 |
|---|---|---|
| 凌晨 ~05:24 宿主崩溃 | V8 堆 59 小时缓慢泄漏至 4GB 上限 OOM，**死后 2 小时无人拉起** | launchd/systemd 保活 + mem-watch 哨兵（超 2.5GB 自动抓堆快照留证） |
| 早上 07:10 重启即崩 | link: 插件 peer 依赖符号链接断链，插件树连坐，boot 失败 | preflight 启动闸（拒启+明示原因）+ 管家每 5 分钟断链自愈 |

## 四层防御架构

```
第 1 层  OS 保命     launchd agent（KeepAlive）：崩溃 ≤30s 自动拉起，开机自启
第 2 层  启动闸      preflight：boot 前校验依赖链，断链拒启并明示原因（不再裸崩留堆栈）
第 3 层  内存哨兵    mem-watch：每 5 分钟采样 RSS，超阈值 kill -USR2 抓堆快照（12h 限一次）
第 4 层  管家(本包)  procguard 插件：每 5 分钟对账 8 项资产，agent 掉册自动重装、断链自动重建
```

关键设计：**插件不负责"救自己的命"（OS 层负责），插件负责"把 OS 层维持在正确状态"**。插件死了前三层还在；前三层出问题，下次插件上岗时修好。OS 看护层是本包的交付物，卸载插件不回收。

本插件**零外部 import**（不依赖 `@deepseek-ai/*` 任何包，仅 ctx 注入的 `timer`/`shell`/`fs`），失败面从构造上收窄：坏也只坏自己，不连坐插件树——对照 2026-09-12 imgview 的 peer import 断链连坐事故。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| macOS | ✅ 全链路实测 | 断链→自愈、boot 安全（3099 端口双轮测试）、live 热加载均验证 |
| Linux | 🟡 骨架未实测 | systemd user 单元同构逻辑已写；assets 脚本仍为 mac 方言（`lsof` 等），真机验证前请勿依赖 |
| Windows | ❌ 不支持（桩已删） | 无 POSIX 信号（SIGUSR2 快照路径不存在）、无验证手段。**不做看起来像实现了的假实现** |

## 安装

### 第一步：部署 OS 看护层（只需一次）

```bash
git clone https://github.com/fuguier001/dsh-procguard.git
cd dsh-procguard/assets && bash install-os-layer.sh
```

部署 4 个脚本、2 个 launchd agent、桌面重启入口，全部幂等可重跑。

### 第二步：安装插件（web profile）

```bash
cd ~/.dsh/profiles/web
pnpm add github:fuguier001/dsh-procguard
```

### 第三步：挂进组合

把本仓库根目录 [`cordis.patch.yml`](./cordis.patch.yml) 里的行并进 `~/.dsh/profiles/web/cordis.patch.yml`，重启 dsh web（或等 `patchReload: live` 热加载）。

### 验证

```bash
tail -f ~/.dsh/web-restart.log        # 应出现 "[procguard] 管家上岗" 与每 5 分钟的 "对账完成"
cat ~/.dsh/procguard-status.json      # 8 项资产对账结果
```

## 升级 / 卸载

```bash
cd ~/.dsh/profiles/web && pnpm update github:fuguier001/dsh-procguard   # 升级
launchctl bootout gui/$(id -u)/com.fuguier001.dsh-web                   # 停用保活层（一般不需要）
```

## 已知边界

- 管家的对账资产清单（路径、agent 名）当前按作者机器写死（`~/Documents/DSCli/dsh-imgview` 等）；换机器需改 `lib/index.js` 顶部 `assets` 常量。
- 堆快照依赖启动参数 `--heapsnapshot-signal=SIGUSR2`（keepalive 脚本已内置）；手动 `dsh web` 启动的实例没有该开关，哨兵只记警情不动进程。
- 插件沙箱按实例 cwd 授权文件写入：keepalive 保证 `cd $HOME`，故 `~/.dsh/procguard-status.json` 正常落盘；若从其他目录裸启 dsh web，状态写盘会被拒（已优雅降级：只记日志，审计与自愈不受影响，2026-09-12 3099 端口实测）。
- Linux 的 assets 脚本移植（`lsof`→`ss`、launchctl→systemctl）欢迎 PR——带上你的真机验证记录。

## License

[MIT](./LICENSE)
