#!/usr/bin/env node
// 自检：不依赖外部网络，验证包结构完整、安装器可探测、生成物合规。
// 用于 CI 与发布前检查。任何一项失败即以非零码退出。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");

let failed = 0;
const ok = (m) => console.log(`  ok   ${m}`);
const bad = (m) => { console.log(`  FAIL ${m}`); failed++; };

function check(desc, fn) {
  try { fn(); ok(desc); } catch (e) { bad(`${desc} — ${e.message}`); }
}

console.log("\n包结构");

check("plugin/khc_cli.pm 存在", () => {
  const p = path.join(ROOT, "plugin", "khc_cli.pm");
  if (!fs.existsSync(p)) throw new Error("缺失");
  if (fs.statSync(p).size < 50_000) throw new Error("体积异常，可能被截断");
});

check("lib/ 下三个脚本齐全", () => {
  for (const f of ["cli.mjs", "detect.mjs", "install.mjs"]) {
    if (!fs.existsSync(path.join(ROOT, "lib", f))) throw new Error(`缺少 lib/${f}`);
  }
});

check("package.json 可解析且字段完整", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8"));
  for (const k of ["name", "version", "bin", "files", "license"]) {
    if (!(k in pkg)) throw new Error(`缺少字段 ${k}`);
  }
  if (!pkg.bin.khc) throw new Error("bin 里没有 khc 入口");
});

check("README 中英双版存在", () => {
  for (const f of ["README.md", "README.zh-CN.md"]) {
    if (!fs.existsSync(path.join(ROOT, f))) throw new Error(`缺少 ${f}`);
  }
});

console.log("\n驱动器插件");

check("khc_cli.pm 无硬编码机器路径", () => {
  const src = fs.readFileSync(path.join(ROOT, "plugin", "khc_cli.pm"), "utf8");
  // 允许出现在注释里的历史说明，但不允许出现在代码行
  const badLines = src.split(/\r?\n/).filter((l, i) => {
    const code = l.replace(/#.*$/, "");
    return /['"]D:[\/\\](khc_auto|khcoder3)/i.test(code);
  });
  if (badLines.length) {
    throw new Error(`${badLines.length} 行仍含硬编码路径，首行: ${badLines[0].trim().slice(0, 80)}`);
  }
});

check("khc_cli.pm 支持 KHC_WORKDIR 环境变量", () => {
  const src = fs.readFileSync(path.join(ROOT, "plugin", "khc_cli.pm"), "utf8");
  if (!src.includes("KHC_WORKDIR")) throw new Error("未找到 KHC_WORKDIR");
});

check("安装器生成器内嵌的 khc.cmd 模板为纯 ASCII", () => {
  const src = fs.readFileSync(path.join(ROOT, "lib", "install.mjs"), "utf8");
  // 找到 cmdContent 数组里的字符串字面量，检查有无非 ASCII
  const start = src.indexOf("const cmdContent");
  const end = src.indexOf("].join(", start);
  if (start < 0 || end < 0) throw new Error("未找到 cmdContent");
  const block = src.slice(start, end);
  // 只检查双引号内的内容
  const literals = [...block.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]);
  const offenders = literals.filter((s) => /[^\x00-\x7F]/.test(s));
  if (offenders.length) {
    throw new Error(`${offenders.length} 个字面量含非 ASCII: ${offenders[0].slice(0, 40)}`);
  }
});

console.log("\n探测");

check("detect.mjs 输出合法 JSON", () => {
  const r = spawnSync(process.execPath, [path.join(ROOT, "lib", "detect.mjs")], {
    encoding: "utf8", windowsHide: true, timeout: 120_000,
  });
  let info;
  try { info = JSON.parse(r.stdout); } catch {
    throw new Error("输出不是 JSON");
  }
  if (typeof info.found !== "boolean") throw new Error("缺少 found 字段");
});

check("cli.mjs help 可执行", () => {
  const r = spawnSync(process.execPath, [path.join(ROOT, "lib", "cli.mjs"), "help"], {
    encoding: "utf8", windowsHide: true, timeout: 60_000,
  });
  if (r.status !== 0) throw new Error(`退出码 ${r.status}`);
  if (!r.stdout.includes("khc")) throw new Error("输出异常");
});

console.log("");
if (failed) {
  console.log(`失败 ${failed} 项\n`);
  process.exit(1);
}
console.log("全部通过\n");
