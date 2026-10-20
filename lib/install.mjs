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
    // This is the one place where a beginner gets stuck, so it has to be
    // unambiguous: one sentence, one link, one thing to do.
    console.log("");
    bad("这台电脑上还没装 KH Coder");
    console.log(`
${C.bold}这是一个独立的免费软件，本项目只是给它加了个命令行入口，必须先装上。${C.reset}

${C.cyan}${C.bold}下载地址（含提取码，已填好）${C.reset}

  https://pan.baidu.com/s/1K24bPGdrR4YEbkxW1X3GuA?pwd=2cre

${C.bold}怎么装${C.reset}

  1. 打开上面的链接，下载安装包
  2. 双击安装，一路点「下一步」，用默认路径即可
  3. 装完回到这里，重新运行本安装器

${C.dim}装的时候不要改路径，默认路径最省事。
也可以从官网下载：https://khcoder.net/dl3.html
如果你确认已经装了但这里没找到，指定路径：
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
// 5. 跑一遍真实分析（证明真的能用，而不是"装完了"）
// ---------------------------------------------------------------------------
//
// This is what convinces a non-technical user. "Installed successfully" means
// nothing to them; a word count and a generated PNG mean something. So the
// installer runs the bundled example corpus end to end and reports the actual
// numbers it got.

step(5, "用示例语料跑一遍（证明真的能用）");

// Windows will not spawn a .cmd through CreateProcess directly -- Node reports
// EINVAL. Route it through cmd.exe explicitly. (spawnSync's `shell: true` also
// works but would hand the arguments to a shell, and the paths here contain
// spaces and Chinese characters.)
function runLauncher(args, timeout) {
  return spawnSync(process.env.COMSPEC || "cmd.exe", ["/c", LAUNCHER, ...args], {
    encoding: "utf8", windowsHide: true, timeout, shell: false,
  });
}

function readLogTail(marker) {
  const logPath = path.join(khc.dir, "khc_work", "khc_cli.log");
  let text = "";
  try { text = fs.readFileSync(logPath, "utf8"); } catch { return { fresh: "", logPath }; }
  // The log is append-only across runs, so only look at what came after the
  // most recent invocation line. Otherwise a previous run's numbers show up and
  // make the report look absurd.
  const at = text.lastIndexOf(marker);
  return { fresh: at >= 0 ? text.slice(at) : text, logPath };
}

const SAMPLE = path.join(PKG_ROOT, "examples", "quickstart", "corpus.txt");
const SELFTEST_PNG = path.join(khc.dir, "khc_work", "_selftest_network.png");

if (DRY) {
  warn("--dry-run：跳过实测");
} else if (!fs.existsSync(SAMPLE)) {
  warn("包内没有示例语料，跳过实测");
} else {
  // Count words at a few thresholds first — fast, and gives a number to show.
  const rw = runLauncher(["words", SAMPLE, "--lang", "cn", "--at", "3,5,10"], 600000);
  const { fresh: logw } = readLogTail("cmd=words");

  const hits = [...logw.matchAll(/freq >= \s*(\d+)\s*->\s*(\d+) terms/g)];
  if (hits.length) {
    ok(`分词正常：${hits.map((m) => `≥${m[1]} 有 ${m[2]} 个词`).join("，")}`);
  } else if (rw.error) {
    warn(`分词测试没跑起来: ${rw.error.message}`);
  } else {
    warn("分词测试没有输出结果（不影响使用，但请留意）");
  }

  // Then draw a real figure, which is the tangible proof.
  try { fs.unlinkSync(SELFTEST_PNG); } catch {}
  const rf = runLauncher([
    "netgraph", SAMPLE, SELFTEST_PNG,
    "--lang", "cn", "--min", "4", "--hinshi", "Noun,Verb", "--edges", "40",
  ], 600000);

  if (fs.existsSync(SELFTEST_PNG)) {
    const kb = (fs.statSync(SELFTEST_PNG).size / 1024).toFixed(0);
    ok(`出图正常：${kb} KB 的共现网络图`);
    console.log(`${C.dim}      图在这里，可以打开看看：${SELFTEST_PNG}${C.reset}`);
  } else if (rf.error) {
    warn(`出图测试没跑起来: ${rf.error.message}`);
  } else {
    warn("出图测试失败。分词能用的话，这通常是 R 环境的问题，可先不管。");
  }
}

// ---------------------------------------------------------------------------
// 完成
// ---------------------------------------------------------------------------
console.log(`
${C.green}${C.bold}安装完成，可以用了${C.reset}

  KH Coder   ${khc.dir}
  工作目录   ${WORKDIR}
  命令行     ${LAUNCHER}

${C.bold}怎么用${C.reset}

  你不用记命令。直接跟 AI 说你要做什么，例如：

    「用 khc 分析 D:\\我的语料.txt，看看主要话题是什么」

  下面这些是它背后会用到的东西，想自己试也可以：

  "${LAUNCHER}" words   mycorpus.txt --at 5,20,50
  "${LAUNCHER}" freq    mycorpus.txt  out/freq.csv
  "${LAUNCHER}" netgraph mycorpus.txt out/net.png --min 150

${C.bold}17 个命令${C.reset}
  probe  db  morpho  words  freq  netgraph  cls  mds  corresp
  conc   mkoutvar  crosstab  bayes  som  topic  codcorresp  dbtables

${C.dim}运行日志: ${path.join(khc.dir, "khc_work", "khc_cli.log")}${C.reset}
`);
