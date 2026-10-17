#!/usr/bin/env node
// KH Coder 无界面驱动器 —— 安装器
//
// 做的事：
//   1. 探测本机 KH Coder（不随包分发本体，7.7 GB 且 GPL-2.0）
//   2. 部署 khc_cli.pm 到 <KHC>/plugin_en/
//   3. 在 <KHC>/ 生成 khc.cmd（路径参数化，纯 ASCII）
//   4. 跑一次 probe 验证
//
// 设计原则：可重复执行（幂等）。已有同名文件先备份为 .bak.<时间戳>，
// 备份放在 <KHC>/khc_backup/ 而不是 plugin_en/ —— KH Coder 扫描插件时
// 会把 plugin_en 下任何「去掉末 3 字符仍以 .pm 结尾」的文件当成插件加载，
// khc_cli.pm.bak 会被误读成 use khc_cli.pm，导致弹窗死锁。

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = path.resolve(HERE, "..");

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };

const DRY = has("--dry-run");
const FORCE = has("--force");
const KHC_ARG = opt("--khc-home", null);

const C = {
  reset: "\x1b[0m", bold: "\x1b[1m", dim: "\x1b[2m",
  red: "\x1b[31m", green: "\x1b[32m", yellow: "\x1b[33m", cyan: "\x1b[36m",
};
const ok = (m) => console.log(`${C.green}  ✓${C.reset} ${m}`);
const warn = (m) => console.log(`${C.yellow}  !${C.reset} ${m}`);
const bad = (m) => console.log(`${C.red}  ✗${C.reset} ${m}`);
const step = (n, m) => console.log(`\n${C.cyan}${C.bold}[${n}]${C.reset} ${m}`);

function die(msg, hint) {
  bad(msg);
  if (hint) console.log(`\n${C.dim}${hint}${C.reset}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// 1. 探测
// ---------------------------------------------------------------------------
step(1, "探测 KH Coder 安装");

let khc = null;
if (KHC_ARG) {
  const exe = path.join(KHC_ARG, "kh_coder.exe");
  if (fs.existsSync(exe)) {
    khc = { dir: KHC_ARG, exe, source: "--khc-home" };
  } else {
    die(`--khc-home 指定的目录里没有 kh_coder.exe：${KHC_ARG}`);
  }
} else {
  const r = spawnSync(process.execPath, [path.join(HERE, "detect.mjs")], {
    encoding: "utf8", windowsHide: true,
  });
  let info = null;
  try { info = JSON.parse(r.stdout); } catch { /* ignore */ }
  if (info && info.found) {
    khc = info.best;
  }
  if (!khc) {
    console.log("");
    bad("未找到 KH Coder");
    console.log(`
${C.bold}请先安装 KH Coder${C.reset}

  KH Coder 本体不在本包内（约 7.7 GB，GPL-2.0 许可），需自行安装：

    下载：https://khcoder.net/dl3.html
    选择：Windows 版安装包（含 MySQL 与 R 的一体包）

  安装完成后重新运行本脚本即可。

${C.dim}如果你已经装好但没被探测到，指定路径：
    node ${path.relative(process.cwd(), path.join(HERE, "install.mjs"))} --khc-home "D:\\khcoder3"${C.reset}
`);
    process.exit(1);
  }
}

ok(`找到 KH Coder: ${C.bold}${khc.dir}${C.reset}`);
console.log(`${C.dim}      来源: ${khc.source || khc.src || "未知"}${C.reset}`);
if (khc.marks) console.log(`${C.dim}      结构: ${khc.marks.join(", ")}${C.reset}`);

if (!khc.hasPluginEn && !fs.existsSync(path.join(khc.dir, "plugin_en"))) {
  die("该目录缺少 plugin_en/，可能不是完整的 KH Coder 安装");
}

// ---------------------------------------------------------------------------
// 2. 部署插件
// ---------------------------------------------------------------------------
step(2, "部署驱动器插件");

const SRC_PM = path.join(PKG_ROOT, "plugin", "khc_cli.pm");
if (!fs.existsSync(SRC_PM)) die(`包内缺少 plugin/khc_cli.pm：${SRC_PM}`);

const KHC_PLUGIN_DIR = path.join(khc.dir, "plugin_en");
const DST_PM = path.join(KHC_PLUGIN_DIR, "khc_cli.pm");
const BACKUP_DIR = path.join(khc.dir, "khc_backup");

fs.mkdirSync(KHC_PLUGIN_DIR, { recursive: true });

if (fs.existsSync(DST_PM) && !FORCE) {
  const same = fs.statSync(DST_PM).size === fs.statSync(SRC_PM).size &&
    fs.readFileSync(DST_PM).equals(fs.readFileSync(SRC_PM));
  if (same) {
    ok("khc_cli.pm 已是最新，跳过");
  } else {
    fs.mkdirSync(BACKUP_DIR, { recursive: true });
    const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
    const bak = path.join(BACKUP_DIR, `khc_cli.pm.${stamp}`);
    fs.copyFileSync(DST_PM, bak);
    ok(`已备份旧版 -> ${path.relative(khc.dir, bak)}`);
    if (!DRY) fs.copyFileSync(SRC_PM, DST_PM);
    ok("已更新 khc_cli.pm");
  }
} else {
  if (!DRY) fs.copyFileSync(SRC_PM, DST_PM);
  ok(`已安装 khc_cli.pm (${(fs.statSync(SRC_PM).size / 1024).toFixed(0)} KB)`);
}

// 卫生检查：plugin_en 下不能有「去掉末 3 字符仍以 .pm 结尾」的文件
const dirty = fs.readdirSync(KHC_PLUGIN_DIR).filter((n) => {
  const s = n.slice(0, Math.max(0, n.length - 3));
  return s.endsWith(".pm");
});
if (dirty.length) {
  warn(`plugin_en/ 下有会导致弹窗的文件: ${dirty.join(", ")}`);
  console.log(`${C.dim}      这些文件会被 KH Coder 当成插件加载。请手动移走。${C.reset}`);
} else {
  ok("plugin_en/ 目录卫生检查通过");
}

// ---------------------------------------------------------------------------
// 3. 生成启动器
// ---------------------------------------------------------------------------
step(3, "生成命令行入口 khc.cmd");

const LAUNCHER = path.join(khc.dir, "khc.cmd");
const WORKDIR = path.join(khc.dir, "khc_work").replace(/\//g, "\\");

// 纯 ASCII：cmd.exe 按 OEM 码页读 .cmd，任何非 ASCII 字节都会破坏解析。
const cmdContent = [
  "@echo off",
  "rem ===================================================================",
  "rem  KH Coder headless CLI launcher",
  "rem  Generated by dsh-kh-coder installer. Safe to regenerate.",
  "rem",
  "rem  IMPORTANT: this file must stay pure ASCII. cmd.exe reads .cmd in the",
  "rem  OEM code page; any non-ASCII byte breaks rem parsing and the script",
  "rem  silently stops working (exit code stays 0, which hides the failure).",
  "rem ===================================================================",
  "setlocal",
  "",
  `set "KHC_ROOT=${khc.dir.replace(/\//g, "\\")}"`,
  `set "KHC_EXE=%KHC_ROOT%\\kh_coder.exe"`,
  `set "KHC_WORKDIR=${WORKDIR}"`,
  "",
  'if not exist "%KHC_EXE%" (',
  "  echo KH Coder executable not found: %KHC_EXE%",
  "  echo Re-run the installer to regenerate this launcher.",
  "  exit /b 1",
  ")",
  'if not exist "%KHC_WORKDIR%" mkdir "%KHC_WORKDIR%" >nul 2>&1',
  "",
  "rem Close the KH Coder logo splash.",
  "rem kh_coder.pl shows a 400x122 borderless window before any analysis runs and",
  "rem nothing ever destroys it (main.pm only destroys the Tk::Splash variant, and",
  "rem on Windows that handle is never assigned). It would cover the user's screen",
  "rem for the whole run. A separate process closes it; it must start BEFORE",
  "rem kh_coder.exe so it is already polling when the window appears at ~0.5 s.",
  'set "SPLASH_EXE=%KHC_ROOT%\\khsplashkill.exe"',
  'if exist "%SPLASH_EXE%" (',
  '  start "kh-splash-guard" /min "%SPLASH_EXE%" --loop 20 >nul 2>&1',
  ")",
  "",
  'pushd "%KHC_ROOT%"',
  '"%KHC_EXE%" -khc %*',
  "set \"RC=%ERRORLEVEL%\"",
  "popd",
  "",
  "exit /b %RC%",
  "",
].join("\r\n");

if (!DRY) {
  fs.writeFileSync(LAUNCHER, cmdContent, "ascii");
}
ok(`已生成 ${path.relative(process.cwd(), LAUNCHER) || LAUNCHER}`);

// 自检：确认写出的确实是纯 ASCII
if (!DRY) {
  const raw = fs.readFileSync(LAUNCHER);
  const nonAscii = raw.filter((b) => b > 0x7f).length;
  if (nonAscii > 0) {
    bad(`生成的 khc.cmd 含 ${nonAscii} 个非 ASCII 字节，会导致脚本失效`);
  } else {
    ok("khc.cmd 纯 ASCII 校验通过");
  }
}

// ---------------------------------------------------------------------------
// 4. 验证
// ---------------------------------------------------------------------------
step(4, "运行 probe 验证");

if (DRY) {
  warn("--dry-run：跳过验证");
} else {
  const r = spawnSync(LAUNCHER, ["probe"], {
    encoding: "utf8", windowsHide: true, timeout: 180000,
    shell: false,
  });

  const logPath = path.join(khc.dir, "khc_work", "khc_cli.log");
  let logged = "";
  try { logged = fs.readFileSync(logPath, "utf8"); } catch { /* ignore */ }

  if (logged.includes("invoked cmd=probe")) {
    ok("probe 已执行（插件加载成功）");
    if (logged.includes("rc=1")) {
      console.log(`${C.dim}      probe 返回 rc=1 属正常（无分析任务时的退出码）${C.reset}`);
    }
  } else if (r.error) {
    bad(`probe 启动失败: ${r.error.message}`);
  } else {
    bad(`probe 未产生日志。退出码 ${r.status}`);
    console.log(`${C.dim}      日志路径: ${logPath}${C.reset}`);
    if (r.stderr) console.log(`${C.dim}      stderr: ${r.stderr.slice(0, 500)}${C.reset}`);
  }
}

// ---------------------------------------------------------------------------
// 完成
// ---------------------------------------------------------------------------
console.log(`
${C.green}${C.bold}安装完成${C.reset}

  KH Coder   ${khc.dir}
  工作目录   ${WORKDIR}
  命令行     ${LAUNCHER}

${C.bold}开始使用${C.reset}

  "${LAUNCHER}" probe
  "${LAUNCHER}" morpho  mycorpus.txt
  "${LAUNCHER}" freq    mycorpus.txt  out/freq.csv
  "${LAUNCHER}" netgraph mycorpus.txt out/net.png --min 150

${C.bold}17 个命令${C.reset}
  probe  db  morpho  words  freq  netgraph  cls  mds  corresp
  conc   mkoutvar  crosstab  bayes  som  topic  codcorresp  dbtables

${C.dim}完整参数与调参方法见 docs/commands.md
运行日志: ${path.join(khc.dir, "khc_work", "khc_cli.log")}${C.reset}
`);
