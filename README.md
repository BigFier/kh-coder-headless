# dsh-kh-coder

**Run KH Coder headless.** 17 analysis commands, no GUI, no clicking, no dialog boxes — batch-friendly and scriptable.

[中文说明](README.zh-CN.md)

---

## What it is

[KH Coder](https://khcoder.net/) is a widely used quantitative text analysis tool for Japanese and Chinese corpora. It is powerful but GUI-only: every analysis is a sequence of window clicks, and long batch runs are impractical.

This package makes it **headless**. A driver plugin runs *inside* `kh_coder.exe` and calls KH Coder's own analysis functions directly, so results are identical to clicking through the interface — same MeCab parsing, same MySQL storage, same R plotting. It is not a reimplementation.

```
khc freq     corpus.txt  out/freq.csv
khc netgraph corpus.txt  out/net.png --min 150
khc conc     corpus.txt  防衛  out/kwic.csv
```

## What it is NOT

- **Not a redistribution of KH Coder.** KH Coder is ~7.7 GB and GPL-2.0. This package ships only the driver (~100 KB) and an installer. You install KH Coder yourself.
- **Not a replacement for the GUI.** If you want interactive exploration, use KH Coder's interface.
- **Not version-pinned.** The installer detects whatever KH Coder you have installed.

## Requirements

| | |
|---|---|
| OS | Windows (KH Coder's bundled MySQL and R are Windows-only) |
| Node.js | ≥ 18 (only for the installer and CLI wrapper) |
| KH Coder | 3.x, installed — [download](https://khcoder.net/dl3.html) |

## Install

```bash
git clone https://github.com/BigFier/dsh-kh-coder.git
cd dsh-kh-coder
node lib/install.mjs
```

The installer will:

1. **Locate** your KH Coder installation (environment variable → common paths → Windows registry → `PATH`)
2. **Deploy** `khc_cli.pm` into `<KHC>/plugin_en/`, backing up any previous version to `<KHC>/khc_backup/`
3. **Generate** `<KHC>/khc.cmd` — a launcher with your paths baked in
4. **Verify** by running `probe` and checking the log

If detection fails, point it explicitly:

```bash
node lib/install.mjs --khc-home "D:\khcoder3"
```

Other flags: `--dry-run` (show what would happen), `--force` (overwrite without comparing).

### After install

```bash
# Diagnose at any time
node lib/cli.mjs doctor

# Run analyses through the generated launcher
"D:\khcoder3\khc.cmd" probe
"D:\khcoder3\khc.cmd" morpho corpus.txt
```

Or use the wrapper, which finds the launcher for you:

```bash
node lib/cli.mjs run freq corpus.txt out/freq.csv
```

Optionally add `<KHC>` to `PATH` so you can just type `khc`.

## The 17 commands

| Command | What it does | Output |
|---|---|---|
| `probe` | Print runtime environment | text |
| `db` | List registered projects | text |
| `morpho` | Preprocess (morphological analysis) | internal |
| `words` | Word counts at several thresholds — **run this first to pick `--min`** | text |
| `freq` | Word frequency table | CSV (Shift_JIS) |
| `netgraph` | Co-occurrence network | PNG |
| `cls` | Hierarchical clustering | PNG |
| `mds` | Multidimensional scaling | PNG |
| `som` | Self-organizing map | PNG |
| `corresp` | Correspondence analysis (words × groups) | PNG + CSV |
| `topic` | Topic model | 3 CSVs |
| `conc` | KWIC concordance | CSV |
| `mkoutvar` | Build external variables from heading structure | internal |
| `crosstab` | Cross tabulation + chi-square | CSV |
| `codcorresp` | Correspondence analysis with `.cod` rules | PNG |
| `bayes` | Naive Bayes (training only) | model |
| `dbtables` | Show corpus structure (documents / paragraphs / headings) | text |

Common options:

```
--min N        minimum frequency (most important for figures)
--max N        maximum frequency
--min_df N     minimum document frequency
--edges N      max edges (default 60)
--lang jp|zh   corpus language
--engine jieba|mecab    segmenter (zh defaults jieba, jp defaults mecab)
--dict FILE    user dictionary
--csv FILE     export figure coordinates
--cod FILE     coding rules for crosstab
--tani UNIT    counting unit (bun|dan|h1..h5)
--var h1..h5   grouping variable
--topics N     number of topics
```

## Examples

```bash
# 1. See how many words you get at different thresholds
khc words corpus.txt --at 5,20,50,100

# 2. Pick a threshold that yields 100–150 terms for the network
khc netgraph corpus.txt out/net.png --min 150

# 3. Frequency table, then sort by a part of speech
khc freq corpus.txt out/freq.csv

# 4. Which words distinguish these groups?
khc mkoutvar corpus.txt --var h1 --tani dan
khc corresp  corpus.txt out/ca.png --csv out/coords.csv

# 5. KWIC around a term
khc conc corpus.txt 防衛  out/kwic.csv
```

## Things that will bite you

Each of these was found the hard way. They are in the code comments too.

**The `freq` CSV is Shift_JIS, not UTF-8.** Excel opens it fine; if you read it programmatically, decode as CP932.

**Word counts must be normalized.** KH Coder counts raw occurrences. A yearly report that grows 80% in length will show every term "increasing". Divide by total tokens before comparing across documents.

**`cls` crashes on large corpora.** On a 54,526-paragraph Japanese corpus, 63 terms completed but ~170 terms crashed natively (exit `0xC000013A`, no Perl exception in the log). Keep the term count under ~100, or split the corpus by year.

**`cls` output is a very tall image.** 281 terms produced a 480×5655 PNG with unreadable overlapping labels. For figures, prefer `netgraph` or `corresp`.

**`corresp` does not draw word labels by default** — this package fixes it. KH Coder builds two plot objects (`plot_mode="color"` with labels, `"dots"` with labels blanked) and the stock code saves the second one. See `plugin/khc_cli.pm` near `_cmd_corresp`.

**A logo splash window covers your screen.** `kh_coder.pl` shows a 400×122 borderless window and nothing ever destroys it (the destroy call only fires for the Tk fallback path, which Windows never takes). The generated launcher starts `khsplashkill.exe` if present. See "Splash window" below.

**`khc.cmd` must be pure ASCII.** `cmd.exe` reads `.cmd` files in the OEM code page. One non-ASCII byte in a `rem` comment breaks parsing — and the exit code stays 0, so the failure is silent. The installer asserts this.

**Never leave `*.pm.bak` in `plugin_en/`.** KH Coder scans plugins by stripping the last 3 characters, so `khc_cli.pm.bak` is loaded as `use khc_cli.pm` and triggers a plugin-error dialog that blocks forever in a headless run. The installer backs up to `<KHC>/khc_backup/` instead and warns if it finds violations.

## Splash window

`kh_coder.exe` displays a borderless 400×122 logo at screen center on every launch. `main.pm:42` destroys it only on the Tk fallback branch, so on Windows it stays on top of your work until the process exits.

It cannot be suppressed from inside the plugin — the module is loaded by the packaged executable before any plugin runs. The working fix is an external process that closes the window. This package expects `khsplashkill.exe` next to `kh_coder.exe` and starts it if found:

```
<KHC>/khsplashkill.exe --loop 20
```

See [`docs/splash.md`](docs/splash.md) for how to build it and why the obvious approaches fail.

If you do not care about the splash, the launcher works fine without it.

## Using from an AI agent

The point of a headless CLI is that agents can drive it. A typical handoff:

```
Corpus is at ./corpus.txt (Japanese, ~500 KB).
1. Run `khc words corpus.txt --at 5,20,50,100` and choose --min so the term count lands near 120.
2. Run `khc netgraph` with that --min. Save to out/net.png.
3. Read the PNG and describe the communities.
```

The agent needs nothing but the path to `khc.cmd`. No server, no protocol, no token overhead.

## License

The installer, CLI wrapper and documentation are MIT.

**The driver plugin (`plugin/khc_cli.pm`) is distributed under GPL-2.0**, because it links against KH Coder's GPL-2.0 modules at runtime. If you redistribute a modified copy, GPL-2.0 applies to it.

KH Coder itself is not included and is licensed separately by its author.
