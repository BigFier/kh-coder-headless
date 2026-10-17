#!/usr/bin/env node
// 探测本机 KH Coder 安装位置。
//
// 为什么要探测而不是写死路径：
//   本插件分发的只是驱动器（khc_cli.pm）与安装脚本，KH Coder 本体
//   （7.7 GB，GPL-2.0）不随包分发。用户可能装在任意盘符，
//   也可能用的是官方安装器给出的默认位置。
//
// 探测顺序（先精确后模糊）：
//   1. 环境变量 KHC_HOME
//   2. 常见安装路径
//   3. Windows 注册表卸载项
//   4. 用户 PATH 中的 kh_coder.exe
//
// 输出 JSON，便于安装器与其他脚本复用。

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const EXE = process.platform === "win32" ? "kh_coder.exe" : "kh_coder";

// 一个目录算不算 KH Coder 根目录：要有可执行文件 + 至少两个已知子目录
function looksLikeKhCoder(dir) {
  if (!dir) return null;
  try {
    const exe = path.join(dir, EXE);
    if (!fs.existsSync(exe)) return null;
    const st = fs.statSync(exe);
    if (!st.isFile() || st.size < 1024 * 1024) return null;   // 官方 exe 约 14 MB

    const marks = ["kh_lib", "plugin_en", "dep", "config"];
    const found = marks.filter(m => fs.existsSync(path.join(dir, m)));
    if (found.length < 2) return null;

    return {
      dir,
      exe,
      exeBytes: st.size,
      exeMtime: st.mtime.toISOString(),
      marks: found,
      hasPluginEn: fs.existsSync(path.join(dir, "plugin_en")),
      hasDep: fs.existsSync(path.join(dir, "dep")),
      hasConfig: fs.existsSync(path.join(dir, "config")),
    };
  } catch {
    return null;
  }
}

function fromEnv() {
  const v = process.env.KHC_HOME;
  return v ? looksLikeKhCoder(v) : null;
}

function fromCommonPaths() {
  const drives = ["C", "D", "E", "F"];
  const names = ["khcoder3", "khcoder", "KH Coder", "kh_coder", "khcoder2"];
  const out = [];
  for (const d of drives) {
    for (const n of names) {
      for (const base of [`${d}:\\`, `${d}:\\Program Files\\`, `${d}:\\Program Files (x86)\\`]) {
        const hit = looksLikeKhCoder(path.join(base, n));
        if (hit) out.push(hit);
      }
    }
  }
  return out;
}

function fromRegistry() {
  if (process.platform !== "win32") return [];
  const out = [];
  const roots = [
    "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
    "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
    "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
  ];
  for (const root of roots) {
    let keys = [];
    try {
      const r = execFileSync("reg", ["query", root, "/s", "/f", "KH Coder", "/t", "REG_SZ"],
        { encoding: "utf8", windowsHide: true, timeout: 15000 });
      keys = r.split(/\r?\n/);
    } catch { continue; }

    const locs = keys
      .filter(l => /InstallLocation|DisplayIcon|UninstallString/i.test(l))
      .map(l => {
        const m = l.match(/REG_SZ\s+(.+)$/i);
        return m ? m[1].trim().replace(/^"|"$/g, "") : null;
      })
      .filter(Boolean);

    for (const loc of locs) {
      // 可能是目录，也可能是 exe 路径
      const candidates = [
        loc,
        path.dirname(loc),
        path.dirname(path.dirname(loc)),
      ];
      for (const c of candidates) {
        const hit = looksLikeKhCoder(c);
        if (hit) out.push({ ...hit, source: "registry" });
      }
    }
  }
  return out;
}

function fromPath() {
  const out = [];
  const parts = (process.env.PATH || "").split(path.delimiter);
  for (const p of parts) {
    if (!p) continue;
    const exe = path.join(p, EXE);
    if (!fs.existsSync(exe)) continue;
    const hit = looksLikeKhCoder(p);
    if (hit) out.push({ ...hit, source: "PATH" });
  }
  return out;
}

function main() {
  const results = [];
  const seen = new Set();

  const push = (hit, source) => {
    if (!hit) return;
    const key = path.resolve(hit.dir).toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    results.push({ ...hit, source: hit.source || source });
  };

  push(fromEnv(), "env:KHC_HOME");
  for (const h of fromCommonPaths()) push(h, "common-path");
  for (const h of fromRegistry()) push(h, "registry");
  for (const h of fromPath()) push(h, "PATH");

  // 判断哪个最可信：有 dep（说明是完整安装）优先
  results.sort((a, b) => {
    const score = (x) => (x.hasDep ? 2 : 0) + (x.hasPluginEn ? 1 : 0);
    return score(b) - score(a) || b.exeBytes - a.exeBytes;
  });

  const out = {
    platform: process.platform,
    found: results.length > 0,
    count: results.length,
    best: results[0] || null,
    all: results,
  };

  console.log(JSON.stringify(out, null, 2));
  process.exit(out.found ? 0 : 1);
}

main();
