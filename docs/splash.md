# 启动画面：问题与解法

## 现象

`kh_coder.exe` 每次启动都会在屏幕正中显示一个 **400×122 的无边框窗口**，内容是 KH Coder 的 logo。它没有标题栏、不能最小化、不能拖动，而且**不会自己消失**——会一直盖在用户正在做的事上面，直到进程退出。

实测时间线（1920×1080 屏幕）：

```
0.5 s   400×122 窗口出现，位置 (760, 479) —— 正好是屏幕正中
2.9 s   主窗口出现，logo 仍在
 ...    logo 一直在，直到 kh_coder.exe 退出
```

## 根因

`kh_coder.pl` 第 109–116 行：

```perl
if (eval 'require Win32::GUI::SplashScreen'){
    require Tk::Splash;
    Win32::GUI::SplashScreen::Show(
        -file => Tk->findINC('kh_logo.bmp'),
        -mintime => 3,
    );
}
```

它设了 `-mintime => 3`（至少显示 3 秒），但负责销毁它的代码在 `main.pm` 第 42 行：

```perl
$::splash->Destroy if $::splash;
```

关键在于 **`$::splash` 只在 Tk::Splash 分支里被赋值**（见 `kh_coder.pl` 里被注释掉的那几行）。Windows 走的是 `Win32::GUI::SplashScreen` 分支，从不给 `$::splash` 赋值，所以 `if $::splash` 恒为假，**没有任何代码销毁这个窗口**。

## 试过但无效的办法

以下四条都实际试过，记录在此以免重复投入。

### 1. 插件内用 `%INC` 占位，阻止模块加载

思路：在插件的 `BEGIN` 块里写 `$INC{'Win32/GUI/SplashScreen.pm'} = __FILE__`，让 `require` 认为模块已加载，从而跳过执行。

**失败原因**：PDK 打包的可执行文件在**任何插件加载之前**就已经处理了这个模块。加了日志确认 `BEGIN` 块确实执行了（`ARGV=-khc|probe` 打印成功），但拦不住——那时候 logo 早就画出来了。

### 2. 把 `kh_logo.bmp` 换成 1×1 的空图

思路：`Tk->findINC('kh_logo.bmp')` 会遍历 `@INC`，而 `kh_coder.pl:35` 有 `push @INC, '.'`，所以放在 exe 同目录的替换图应该优先生效。

**失败原因**：PDK 解压目录里的副本优先级更高。换掉之后 logo 照常显示。

### 3. 在插件里用 `Win32::EnumWindows` 找窗口并关掉

思路：找到那个无标题、400×122 的窗口，`PostMessage(WM_CLOSE)`。

**失败原因**：这个 PDK 打包的 `Win32` 模块是**精简版**。用 `Win32->can()` 逐个实测：

```
EnumWindows                 no
IsWindowVisible             no
GetWindowRect               no
GetWindowText               no
PostMessage                 no
GetWindowThreadProcessId    no
```

`require Win32` 能成功，但上面这些函数**一个都没有**。所以进程内根本没法找窗口。

### 4. PowerShell 守护脚本

思路：起一个 PowerShell 进程轮询关窗。

**失败原因**：`powershell.exe` 冷启动实测 **1064 ms**，加上脚本解析约 1.5–2 秒。而 logo 只活约 3 秒、0.5 秒就出现——赶不上。

### 5. 只发 `WM_CLOSE`

思路：定位到窗口后直接发关闭消息。

**失败原因**：窗口能准确定位（日志里能看到 `closed 400x122 at 760,479`），但 `PostMessage(WM_CLOSE)` 发过去之后它**纹丝不动**。该窗口由 `Win32::GUI` 创建，没有走标准窗口过程，不响应关闭消息。

## 有效解法

一个**外部原生进程**，编译成 exe 以缩短冷启动时间。

### 为什么是原生 exe

| 方案 | 冷启动 |
|---|---|
| `powershell.exe` 加载脚本 | 1064 ms + 解析 |
| 编译后的 .NET exe | **208 ms** |

logo 在 0.5 秒出现，只活约 3 秒。208 ms 赶得上，1064 ms 赶不上。

### 关窗三连

```
ShowWindow(h, SW_HIDE)      // 先让它从屏幕上消失 —— 这才是用户要的
DestroyWindow(h)            // 尝试真正销毁
PostMessage(h, WM_CLOSE)    // 兜底
```

顺序很重要：`SW_HIDE` 在前，因为即使后面两步失败，用户的屏幕也已经干净了。

### 识别条件

```
可见  ∧  无标题  ∧  400×122（容许 6 px DPI 误差）  ∧  所属进程是 kh_coder.exe
```

最后一条是必须的。只按尺寸匹配会误伤——实测本机就开着 5 个无标题窗口（资源管理器的子窗口），虽然尺寸不匹配，但只要哪天出现一个恰好 400×122 的无标题窗口就会被误关。

进程名通过 `Process.GetProcessById(pid).ProcessName` 取，带 `Dictionary` 缓存避免每帧重复查询。

### 源码

`docs/khsplashkill.cs` 是完整源码。编译：

```bash
csc /nologo /target:exe /optimize+ /out:khsplashkill.exe khsplashkill.cs
```

`csc.exe` 在 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\` 下（Windows 自带，无需装 SDK）。

把 `khsplashkill.exe` 放到 `kh_coder.exe` 同目录，启动器会自动拉起：

```cmd
start "kh-splash-guard" /min "%SPLASH_EXE%" --loop 20
```

`--loop 20` 表示轮询 20 秒后自行退出，每 80 ms 扫一次。

## 两个命令级的坑

**`start /b` 会让 `khc.cmd` 永不返回。** `/b` 启动的进程附着当前控制台，cmd 会等它。用 `start "title" /min`（给个标题、最小化），实测 0.1 秒就返回。

**`WScript.Shell.Run()` 也会阻塞。** 试过用 COM 对象做完全脱离，同样卡住。最后还是 `start "title" /min` 最可靠。

## 反向验证

确认不会误伤其它程序的做法：造一个精确 400×122 的无标题 WinForms 窗口，跑关窗器：

```
exe 输出：（空 —— 没有命中任何窗口）
诱饵进程存活: True
```

关窗器没有碰它。这个验证在加进程过滤之后做过，是判断"安全"的依据。
