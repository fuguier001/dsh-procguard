// dsh-procguard — DSH 进程看护管家
// 零外部 import（不依赖 @deepseek-ai/* 任何包），依赖仅 ctx 注入的 timer/shell/fs；
// 失败面从构造上收窄：坏也只坏自己，不连坐插件树。
//
// 平台支持矩阵：
//   macOS  —— 全链路实测（2026-09-12：断链→自愈、boot 安全、live 热加载均验证）
//   Linux  —— systemd 骨架（同构逻辑，未实测；欢迎真机验证后提 PR）
//   其他   —— 安全待命：识别到不支持的平台即退出，不审计、不安装、不报错
//   Windows —— 明确不支持（曾经留桩，已删：无验证手段不做假实现，见 README）
//
// 职责（macOS/Linux，每 5 分钟 + 启动首检）：
//   1. 看护层资产对账：4 脚本文件 / 2 守护 agent / 2 imgview 依赖链接；
//   2. agent 掉册自动 bootstrap 重装；imgview 断链自动 ln -sfn 重建（自愈）；
//   3. 状态落盘 ~/.dsh/procguard-status.json，日志 [procguard] 进宿主 stdout。
// 注意：OS 看护层（脚本/plist/agent）由 assets/install-os-layer.sh 部署，是交付物，
//       插件卸载不回收；定时器随插件生命周期自动清理。

const name = "procguard";
// shell/fs 声明为硬依赖：boot 早期服务未注册时插件等待而非失效（2026-09-12 3099 端口实测教训）
const inject = ["timer", "shell", "fs"];

async function apply(ctx) {
  const shell = ctx.get("shell");
  const fs = ctx.get("fs");
  const log = (m) => console.log("[procguard]", m);
  if (shell === undefined || fs === undefined) {
    log("缺少 shell/fs 服务，管家退出（OS 看护层不受影响）");
    return;
  }

  const sh = async (cmd) => {
    try {
      const spec = shell.resolve({ command: cmd });
      const r = await shell.run(spec);
      return {
        ok: r.exitCode === 0,
        out: ((r.stdout && r.stdout.text) || "").trim(),
        err: ((r.stderr && r.stderr.text) || "").trim(),
      };
    } catch (e) {
      return { ok: false, out: "", err: String(e) };
    }
  };

  // ── HOME 与平台（fs.resolve 不展开 ~，必须绝对路径）──
  const home = ((await sh("echo $HOME")).out.split("\n")[0]) || "/Users/fuigui";
  const uname = (await sh("uname -s")).out;
  if (uname !== "Darwin" && uname !== "Linux") {
    log("平台不支持（uname='" + uname + "'），管家安全待命退出——本包支持 macOS（实测）与 Linux（骨架未实测），不支持 Windows，详见 README");
    return;
  }
  const platform = uname === "Darwin" ? "macOS" : "Linux";
  const uid = (await sh("id -u")).out;
  log("管家上岗 平台=" + platform + " HOME=" + home);

  const assets = {
    files: [
      home + "/.dsh/dsh-web-keepalive.sh",
      home + "/.dsh/dsh-web-preflight.sh",
      home + "/.dsh/mem-watch.sh",
      home + "/Desktop/restart-dsh-web.command",
    ],
    agents: ["com.fuguier001.dsh-web", "com.fuguier001.dsh-mem-watch"],
    links: [
      { path: home + "/Documents/DSCli/dsh-imgview/node_modules/@deepseek-ai/dsh-tools", pkg: "dsh-tools" },
      { path: home + "/Documents/DSCli/dsh-imgview/node_modules/@deepseek-ai/cordis", pkg: "cordis" },
    ],
  };

  const q = (s) => "'" + s + "'";

  async function repairLink(link) {
    const groot = (await sh("npm root -g")).out;
    if (!groot) {
      log("✗ 无法确定 npm 全局根，放弃修复 " + link.pkg);
      return false;
    }
    const target = groot + "/@deepseek-ai/dsh/node_modules/@deepseek-ai/" + link.pkg;
    const t = await sh("test -d " + q(target) + " && echo YES");
    if (t.out !== "YES") {
      log("✗ 全局安装内找不到 " + target + "，放弃修复");
      return false;
    }
    await sh("mkdir -p " + q(link.path.slice(0, link.path.lastIndexOf("/"))));
    const ln = await sh("ln -sfn " + q(target) + " " + q(link.path));
    if (ln.ok) {
      log("🔧 已自动修复断链: " + link.pkg + " -> " + target);
      return true;
    }
    log("✗ 修复失败 " + link.pkg + ": " + ln.err);
    return false;
  }

  async function ensureLinux() {
    const hasSystemd = (
      await sh("systemctl --user is-system-running >/dev/null 2>&1 || test -d /run/systemd/users && echo YES")
    ).out;
    if (hasSystemd !== "YES") {
      log("Linux: 无 systemd --user，本层留桩不安装");
      return { systemd: "unavailable" };
    }
    const unitDir = home + "/.config/systemd/user";
    await sh("mkdir -p " + q(unitDir));
    const unit =
      "[Unit]\nDescription=DSH web keepalive (installed by dsh-procguard)\n[Service]\nExecStart=" +
      home +
      "/.dsh/dsh-web-keepalive.sh\nRestart=always\nRestartSec=30\n[Install]\nWantedBy=default.target\n";
    try {
      const t = await fs.resolve(unitDir + "/dsh-web-keepalive.service");
      await fs.writeText(t, unit);
    } catch (e) {
      log("Linux: 写 unit 失败 " + String(e));
    }
    await sh("systemctl --user daemon-reload && systemctl --user enable --now dsh-web-keepalive.service");
    log("Linux: systemd 单元已安装（assets 脚本为 mac 方言，boot 兼容性待适配——未实测）");
    return { systemd: "enabled" };
  }

  async function audit() {
    try {
      const report = { time: new Date().toISOString(), platform, findings: [], repaired: [], broken: [] };
      for (const f of assets.files) {
        const r = await sh("test -f " + q(f) + " && echo YES");
        report.findings.push({ file: f, ok: r.out === "YES" });
        if (r.out !== "YES") report.broken.push("文件缺失: " + f);
      }
      for (const a of assets.agents) {
        const r = await sh("launchctl print gui/" + uid + "/" + a + " >/dev/null 2>&1 && echo YES");
        let ok = r.out === "YES";
        if (!ok && platform === "macOS") {
          const plist = home + "/Library/LaunchAgents/" + a + ".plist";
          const ex = await sh("test -f " + q(plist) + " && echo YES");
          if (ex.out === "YES") {
            await sh("launchctl bootstrap gui/" + uid + " " + q(plist));
            const again = await sh("launchctl print gui/" + uid + "/" + a + " >/dev/null 2>&1 && echo YES");
            ok = again.out === "YES";
            if (ok) {
              log("🔧 已重新装载 agent: " + a);
              report.repaired.push("重新装载 " + a);
            }
          }
        }
        report.findings.push({ agent: a, ok });
        if (!ok) report.broken.push("agent 不在册: " + a);
      }
      for (const link of assets.links) {
        const r = await sh("test -e " + q(link.path) + " && echo YES");
        let ok = r.out === "YES";
        if (!ok) {
          const fixed = await repairLink(link);
          ok = fixed;
          if (fixed) report.repaired.push("修复链接 " + link.pkg);
        }
        report.findings.push({ link: link.pkg, ok });
        if (!ok) report.broken.push("断链: " + link.pkg);
      }
      if (platform === "Linux") report.linux = await ensureLinux();
      const sent = await sh(
        "test -f " + q(home + "/.dsh/mem-watch.pid") + " && kill -0 $(cat " + q(home + "/.dsh/mem-watch.pid") + ") 2>/dev/null && echo ALIVE"
      );
      report.sentinel = sent.out === "ALIVE" ? "alive" : "dead(launchd会接管)";
      try {
        const st = await fs.resolve(home + "/.dsh/procguard-status.json");
        await fs.writeText(st, JSON.stringify(report, null, 2));
      } catch (e) {
        log("状态写盘失败: " + String(e));
      }
      const bad = report.broken.length;
      log(
        "对账完成: " + report.findings.length + " 项，修复 " + report.repaired.length + " 项，仍坏 " + bad + " 项" +
          (bad ? " → " + report.broken.join("; ") : "") + "；哨兵=" + report.sentinel
      );
      return report;
    } catch (e) {
      log("对账异常（吞掉不抛，保 boot）: " + String(e));
      return { error: String(e) };
    }
  }

  await audit();
  const disposer = ctx.interval(() => {
    audit();
  }, 5 * 60 * 1000);
  ctx.effect(() => disposer(), "procguard-audit-interval");
}

export { apply, inject, name };
