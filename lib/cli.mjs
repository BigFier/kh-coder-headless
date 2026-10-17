#!/usr/bin/env node
// dsh-kh-coder 命令行入口
//
// 一个薄包装：把常用动作变成子命令，内部调用 install.mjs / detect.mjs 或
// 已安装的 khc.cmd。不重复实现分析逻辑——分析全部由 KH Coder 本体完成。
//
//   khc-doctor     环境诊断
//   khc-setup      安装驱动器到本机 KH Coder
//   khc-run <...>  透传给 khc.cmd

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = path.resolve(HERE, "..");

const C = {
  reset: "\x1b[0m", bold: "\x1b[1m", dim: "\x1b[2m",
  red: "\x1b[31m", green: "\x1b[32m", yellow: "\x1b[33m", cyan: "\x1b[36m",
};

function detect() {
  const r = spawnSync(process.execPath, [path.join(HERE, "detect.mjs")], {
    encoding: "utf8", windowsHide: true,
  });
  try { return JSON.parse(r.stdout); } catch { return { found: false, all: [] }; }
}

const cmd = process.argv[2] || "help";
const rest = process.argv.slice(3);

function passThrough(script, args) {
  const r = spawnSync(process.execPath, [path.join(HERE, script), ...args], {
    stdio: "inherit", windowsHide: true,
  });
  process.exit(r.status ?? 1);
}

switch (cmd) {
  // ---------------------------------------------------------------- help
  case "help":
  case "-h":
  case "--help":
    console.log(`
${C.bold}khc${C.reset} — KH Coder 无界面驱动器

${C.bold}用法${C.reset}
  khc doctor              诊断环境（KH Coder 是否可找到、插件是否就位）
  khc setup               安装/更新驱动器到本机 KH Coder
  khc setup --dry-run     只显示将要做什么，不写盘
  khc setup --khc-home DIR  手动指定 KH Coder 路径
  khc run <命令> [参数]   透传给 khc.cmd

${C.bold}示例${C.reset}
  khc setup
  khc run morpho   corpus.txt
  khc run freq     corpus.txt  out/freq.csv
  khc run netgraph corpus.txt  out/net.png --min 150
  khc run conc     corpus.txt  防衛  out/kwic.csv

${C.bold}17 个命令${C.reset}
  probe  db  morpho  words  freq  netgraph  cls  mds  corresp
  conc   mkoutvar  crosstab  bayes  som  topic  codcorresp  dbtables
`);
    break;

  // -------------------------------------------------------------- doctor
  case "doctor": {
    const info = detect();

    console.log(`\n${C.cyan}${C.bold}KH Coder 无界面驱动器 — 环境诊断${C.reset}\n`);

    // 运行时
    console.log(`${C.bold}运行时${C.reset}`);
    console.log(`  Node        ${process.version}  (${process.platform}/${process.arch})`);

    if (!info.found) {
      console.log(`\n${C.bold}KH Coder${C.reset}  ${C.red}未找到${C.reset}`);
      console.log(`\n${C.dim}请从 https://khcoder.net/dl3.html 安装 Windows 版，然后重跑 khc setup${C.reset}\n`);
      process.exit(1);
    }

    console.log(`\n${C.bold}KH Coder${C.reset}  找到 ${info.count} 处`);
    for (const h of info.all) {
      const tag = h === info.best ? `${C.green}← 将使用${C.reset}` : "";
      console.log(`  ${h.dir}  ${C.dim}(${h.source}, exe ${(h.exeBytes / 1048576).toFixed(1)} MB)${C.reset} ${tag}`);
    }

    const best = info.best;
    console.log(`\n${C.bold}结构检查${C.reset}`);
    for (const [k, label] of [
      ["hasPluginEn", "plugin_en/"], ["hasDep", "dep/"], ["hasConfig", "config/"],
    ]) {
      console.log(`  ${best[k] ? `${C.green}✓${C.reset}` : `${C.red}✗${C.reset}`} ${label}`);
    }

    // 驱动器插件
    const pm = path.join(best.dir, "plugin_en", "khc_cli.pm");
    const launcher = path.join(best.dir, "khc.cmd");
    const workdir = path.join(best.dir, "khc_work");
    const log = path.join(workdir, "khc_cli.log");

    console.log(`\n${C.bold}驱动器${C.reset}`);
    if (fs.existsSync(pm)) {
      const sz = (fs.statSync(pm).size / 1024).toFixed(0);
      console.log(`  ${C.green}✓${C.reset} plugin_en/khc_cli.pm  ${C.dim}(${sz} KB)${C.reset}`);
    } else {
      console.log(`  ${C.red}✗${C.reset} plugin_en/khc_cli.pm  ${C.dim}未安装，请运行 khc setup${C.reset}`);
    }
    console.log(`  ${fs.existsSync(launcher) ? `${C.green}✓${C.reset}` : `${C.red}✗${C.reset}`} khc.cmd`);
    console.log(`  ${fs.existsSync(workdir) ? `${C.green}✓${C.reset}` : `${C.dim}·${C.reset}`} khc_work/`);

    if (fs.existsSync(log)) {
      const tail = fs.readFileSync(log, "utf8").trim().split(/\r?\n/).slice(-3);
      console.log(`\n${C.bold}最近日志${C.reset}`);
      for (const l of tail) console.log(`  ${C.dim}${l}${C.reset}`);
    }

    console.log("");
    break;
  }

  // --------------------------------------------------------------- setup
  case "setup":
    passThrough("install.mjs", rest);
    break;

  // ----------------------------------------------------------------- run
  case "run": {
    const info = detect();
    if (!info.found) {
      console.error(`${C.red}${C.reset} 未找到 KH Coder，请先运行 khc setup`);
      process.exit(1);
    }
    const launcher = path.join(info.best.dir, "khc.cmd");
    if (!fs.existsSync(launcher)) {
      console.error(`${C.red}${C.reset} 未找到 khc.cmd，请先运行 khc setup`);
      process.exit(1);
    }
    if (!rest.length) {
      console.error(`${C.red}${C.reset} 需要指定命令，例如: khc run probe`);
      process.exit(1);
    }
    const r = spawnSync(launcher, rest, { stdio: "inherit", windowsHide: true });
    process.exit(r.status ?? 1);
  }

  default:
    console.error(`${C.red}${C.reset} 未知子命令: ${cmd}\n  运行 khc help 查看用法`);
    process.exit(1);
}
