# kh-coder-headless

**Run KH Coder from the command line — or hand it to an AI agent.**

[中文说明](README.md) · The default README is in Chinese.

---

KH Coder is one of the best tools for corpus research, but it only has a GUI. Three things get in the way:

- **You don't know which button to press.** Seventeen analysis functions, dozens of controls. Following a tutorial works once; the next corpus leaves you lost again.
- **It's tedious.** One analysis is a dozen clicks. Change a parameter and it's a dozen more.
- **It doesn't batch.** Twenty documents, or ten years of one document, means twenty or ten manual runs.

This package turns all 17 functions into commands. Then you can script them — or **let an AI agent drive them**. The agent picks the parameters, reads the output, and explains the result.

```
khc words   corpus.txt --at 20,50,100
khc netgraph corpus.txt out/net.png --min 150
khc conc     corpus.txt 领导 out/kwic.csv
```

## How it works

A driver plugin runs *inside* `kh_coder.exe` and calls KH Coder's own analysis functions — same MeCab parsing, same MySQL, same R plotting. Output is byte-for-byte what you would get clicking through the interface.

## Requirements

- Windows (KH Coder's bundled MySQL and R are Windows-only)
- Node.js ≥ 18 (installer and CLI wrapper only)
- KH Coder 3.x installed — [download](https://khcoder.net/dl3.html)

## Install

```bash
git clone https://github.com/BigFier/kh-coder-headless.git
cd kh-coder-headless
node lib/install.mjs
```

KH Coder itself is not bundled: it is ~7.7 GB and GPL-2.0. The installer finds your existing installation (environment variable → common paths → registry → `PATH`), deploys the driver into `plugin_en/`, generates a launcher, and verifies with `probe`.

If detection fails:

```bash
node lib/install.mjs --khc-home "D:\khcoder3"
```

Check the environment any time:

```bash
node lib/cli.mjs doctor
```

## The 17 commands

`words` · `freq` · `netgraph` · `conc` · `corresp` · `cls` · `mds` · `som` · `topic` · `morpho` · `mkoutvar` · `crosstab` · `codcorresp` · `bayes` · `dbtables` · `db` · `probe`

Common options:

```
--min N        minimum term frequency (the one that matters most for figures)
--max N        maximum term frequency
--min_df N     minimum document frequency
--edges N      max edges, default 60
--lang jp|zh   corpus language
--dict FILE    user dictionary
--csv FILE     export figure coordinates
--tani UNIT    counting unit: bun / dan / h1..h5
--topics N     number of topics
```

## Handing it to an agent

Give this to any agent that can run shell commands:

```
Corpus is at ./corpus.txt (Chinese, ~400k characters). I want to know the main topics.

khc is at <your KH Coder install dir>\khc.cmd (run `node lib/cli.mjs doctor` to print the exact path).

1. Run khc words corpus.txt --at 20,50,100 to see the term distribution.
2. Pick a --min that lands the term count near 120.
3. Run khc netgraph with that --min, save to out/net.png.
4. Open the image and tell me, in plain language, which topic clusters you see.
```

No protocol, no server, no token overhead — the agent just runs commands and reads files.

## Things that will bite you

**Normalize your counts.** KH Coder counts raw occurrences. A report that grows 80% each year will make every term look like it is rising. Divide by total tokens before comparing across documents.

**`freq` output is Shift_JIS, not UTF-8.** Excel opens it fine; decode as CP932 if you read it programmatically.

**`cls` crashes on large corpora.** On a 54,526-paragraph Japanese corpus, 63 terms completed; ~170 terms crashed natively (exit `0xC000013A`, no Perl exception logged). Keep the term count under ~100 or split by year.

**`cls` output is extremely tall.** 281 terms produced a 480×5655 PNG with unreadable labels. Prefer `netgraph` or `corresp` for figures.

**`corresp` doesn't draw word labels by default** — fixed here. KH Coder builds two plot objects (one labelled, one with labels blanked) and the stock code saves the wrong one.

**A logo splash covers the screen on every launch.** A 400×122 borderless window parked at screen centre that is never destroyed (the destroy call only fires on the Tk fallback path, which Windows never takes). The launcher starts `khsplashkill.exe` if present. See [docs/splash.md](docs/splash.md).

**`khc.cmd` must be pure ASCII.** `cmd.exe` reads `.cmd` in the OEM code page; a single non-ASCII byte in a `rem` comment breaks parsing — and the exit code stays 0, so the failure is silent.

**Never leave `*.pm.bak` in `plugin_en/`.** KH Coder strips the last 3 characters when scanning plugins, so `khc_cli.pm.bak` loads as `use khc_cli.pm` and raises a plugin-error dialog that blocks forever in an unattended run.

## License

Installer, CLI wrapper and docs: MIT.

`plugin/khc_cli.pm`: **GPL-2.0**, because it links KH Coder's GPL-2.0 modules at runtime. Full text in `plugin/COPYING-GPL-2.0.txt`.

KH Coder itself is not included and is licensed separately by its author.
