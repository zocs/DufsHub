# Changelog / 更新日志

> 所有版本均可在 [GitHub Releases](https://github.com/zocs/fileinfra/releases) 下载。
> All versions available at [GitHub Releases](https://github.com/zocs/fileinfra/releases).

## [v0.5.0](https://github.com/zocs/fileinfra/releases/tag/v0.5.0) (2026-08-15)

**中文：**
- 📛 **项目更名：`DufsHub` → `FileInfra`**。应用名、包名、桌面入口、安装器、启动图同步更新。
- ⚠️ applicationId 由 `cc.merr.dufshub` 变更为 `cc.merr.fileinfra`——breaking change：老版本无法覆盖升级，请卸载旧版后安装新版。
- ✨ 权限预设「允许上传」现默认附带文件夹下载；开关「允许归档下载」更名为「允许文件夹下载」；使用帮助、组网提示与设置页描述文案更新。
- ⬆️ dufs 核心升至 v0.46.0-fix2：文件夹打包下载引擎换用 async-deflate-zip v0.2.0，并纳入 `--path-prefix` 前缀边界匹配、macOS liblzma 链接等上游修复。

**English:**
- 📛 **Project renamed: `DufsHub` → `FileInfra`**. App name, package ids, desktop entries, installer, and splash updated across all platforms.
- ⚠️ applicationId changed from `cc.merr.dufshub` to `cc.merr.fileinfra` — breaking: existing installs cannot upgrade in place; uninstall the old version, then install fresh.
- ✨ The "Allow upload" permission preset now includes folder download; the toggle formerly labeled "Allow Archive Download" is now "Allow Folder Download"; help, networking-tip, and settings copy revised.
- ⬆️ dufs core bumped to v0.46.0-fix2: folder archive downloads now use async-deflate-zip v0.2.0, and upstream fixes for `--path-prefix` boundary matching and macOS liblzma linking are included.

## [v0.4.4](https://github.com/zocs/fileinfra/releases/tag/v0.4.4) (2026-08-04)

**中文：**
- 🐛 桌面端：修复关闭窗口（点右上角 X、Alt+F4 或托盘「退出」）后要等约 30 秒才真正关闭的问题，现在瞬间关闭。

**English:**
- 🐛 Desktop: fixed the app hanging ~30s before actually closing after you click the window's X (or Alt+F4, or tray Quit) — it now closes instantly.

---

## [v0.4.3](https://github.com/zocs/fileinfra/releases/tag/v0.4.3) (2026-07-31)

**中文：**
- ⚡ 大幅减少传输过程中的界面卡顿：活动日志改为批量刷新，二维码不再随统计数字变化反复重绘。
- ⚡ 桌面端：停止服务不再卡住界面（服务在后台收尾）。
- 🐛 桌面端：修复高负载下下载可能被提前截断/重置的问题（Windows 上尤为明显）。
- 🐛 修改权限前的「重启服务」确认框，现在只在最近 15 秒内有传输活动时弹出。
- ⬆️ 内核 dufs 升级到 v0.46.0：带来上游多项修复与改进（认证逻辑修正、HTTP Range 修复、符号链接安全加固、HEAD 请求提速、可自定义 404 页面等）。

**English:**
- ⚡ Much smoother UI during transfers: activity-log updates are now batched, and the QR code no longer re-renders on every stats tick.
- ⚡ Desktop: stopping the server no longer freezes the UI (shutdown finishes in the background).
- 🐛 Desktop: fixed downloads possibly being cut short / reset under heavy load (most visible on Windows).
- 🐛 The "restart server" confirmation before permission changes now only appears if there was transfer activity in the last 15 seconds.
- ⬆️ Upgraded the dufs core to v0.46.0: brings many upstream fixes and improvements (auth-logic fixes, HTTP Range fix, symlink hardening, faster HEAD requests, customizable 404 page, and more).

---

## [v0.4.2](https://github.com/zocs/fileinfra/releases/tag/v0.4.2) (2026-06-12)

**中文：**
- 🔒 增强账号密码安全：修复密码在特定情况下可能被记录到系统日志，并限制了会导致登录认证出错的特殊字符。
- 🐛 提升运行稳定性，避免个别请求出错导致应用 / 服务整体崩溃。
- 🐛 Android 通知栏文案现在跟随应用内的语言设置。
- 🐛 桌面端：通过系统方式（如 Alt+F4）关闭窗口时，现在也会遵循「关闭行为」设置。
- 🐛 桌面端：修复每次启动残留临时文件的问题。

**English:**
- 🔒 Hardened account/password security: fixed the password possibly being written to system logs, and restricted special characters that could break login.
- 🐛 Improved stability so a single failing request no longer crashes the whole app / server.
- 🐛 The Android notification text now follows the in-app language setting.
- 🐛 Desktop: closing the window via the system (e.g. Alt+F4) now also respects your "close action" setting.
- 🐛 Desktop: fixed leftover temporary files accumulating on each launch.

---

## [v0.4.1](https://github.com/zocs/fileinfra/releases/tag/v0.4.1) (2026-05-27)

**中文：**
- ✨ 启动/停止按钮内的 loading 指示器换成自定义三点跳动动画：Material 的 `CircularProgressIndicator` 每帧重绘整个 `Canvas.drawArc`，在 120Hz debug build 上肉眼可见卡顿；新组件只平移 `Offset`+`Opacity`，任何刷新率都顺滑。
- 💅 Splash 文字字号从 48 缩到 24（letterSpacing 4→2），让 Flutter splash 与 native bitmap splash（186×24px @ mdpi）起手视觉一致，消除 Flutter 接管 native 窗口时「突然变大」的跳帧。

**English:**
- ✨ Replaced the start/stop button's loading indicator with a custom three-dot bouncer: Material's `CircularProgressIndicator` redraws a full `Canvas.drawArc` every frame and visibly stutters at 120Hz in debug builds; the new widget only translates `Offset`+`Opacity`, so it stays smooth at any refresh rate.
- 💅 Shrank splash text from fontSize 48 to 24 (letterSpacing 4→2) so the Flutter splash starts visually identical to the native bitmap splash (186×24px @ mdpi), removing the "pop bigger" frame when Flutter takes over from the native window.

---

## [v0.4.0](https://github.com/zocs/fileinfra/releases/tag/v0.4.0) (2026-05-27)

**中文：**
- 🏷️ **项目改名：`inout` → `DufsHub`**（applicationId 由 `cc.merr.inout` 改为 `cc.merr.dufshub`）。这是 breaking change——老版本无法直接 OTA 升级，需要卸载老版本后安装新版本。
- 🔒 修复 Dart 侧 `--auth user:pass@/:rw` 仍会打到 logcat（v0.3.4 只修了 Kotlin 侧，Dart 侧的 `_log(args.join(...))` 仍泄漏）(C1)
- 🐛 修复 Android 14+ (API 34) 启动 foreground service 时缺少 `FOREGROUND_SERVICE_TYPE_DATA_SYNC` 参数导致的 `MissingForegroundServiceTypeException` (C2)
- 🐛 修复 macOS bundle id 仍是 Flutter 模板占位 `com.inout.inoutFlutter` (C3)
- 🐛 修复 Linux APPLICATION_ID 仍是 Flutter 模板占位 `com.inout.inout` (C4)
- 🔒 修复 release build keystore 缺失时静默 fallback 到 debug 签名——现在 fail-fast，避免发出 debug-signed APK 到 release 通道导致用户无法 OTA 升级 (C5)

**English:**
- 🏷️ **Project renamed: `inout` → `DufsHub`** (applicationId changed from `cc.merr.inout` to `cc.merr.dufshub`). This is a breaking change — existing installs cannot OTA-upgrade; users must uninstall the old version and install the new one.
- 🔒 Fixed Dart side still logging `--auth user:pass@/:rw` to logcat (v0.3.4 only fixed the Kotlin side; Dart's `_log(args.join(...))` still leaked) (C1)
- 🐛 Fixed Android 14+ (API 34) `MissingForegroundServiceTypeException` crash on service start; now passes `FOREGROUND_SERVICE_TYPE_DATA_SYNC` (C2)
- 🐛 Fixed macOS bundle id stuck on Flutter template placeholder `com.inout.inoutFlutter` (C3)
- 🐛 Fixed Linux APPLICATION_ID stuck on Flutter template placeholder `com.inout.inout` (C4)
- 🔒 Fixed release build silently falling back to the debug keystore when `KEYSTORE_FILE` is missing — now fail-fast, preventing debug-signed APKs from reaching the release channel (C5)

---

## [v0.3.4](https://github.com/zocs/inout/releases/tag/v0.3.4) (2026-05-02)

**中文：**
- 🔒 修复 Android 端 dufs 启动日志把 `--auth user:pass@/:rw` 直接打到 logcat（任何 adb client 或同 user 应用都能读取用户密码）
- 🐛 修复应用内"关于"页版本号显示与 `pubspec.yaml` 不一致——改为 runtime 从 `package_info_plus` 读，发版不再需要手动同步 `lib/app.dart::appVersion`
- 🐛 修复 secure_storage 凭据迁移逻辑：之前每次 load 都会用 SharedPreferences 里的 legacy auth 覆写 secure_storage 里更新过的凭据（用户改密码后下次启动密码被改回去）
- 🐛 修复端口冲突自动 +1 后，用户配置的原始端口被持久化覆盖：现在用户偏好端口和实际运行端口分开记录，下次启动仍尝试原端口
- 🐛 修复 Android 启动服务的 race：之前 Dart 端固定等 500ms 就查询服务状态，但 Kotlin 的 socket probe 最多需要 5s 才完成，导致服务实际跑起来但 UI 报"启动失败"。现改为最多轮询 6s
- ✨ 切换语言立即生效，无需重启 app（之前必须重启才能看到 UI 文案变化）
- 🏗️ NSIS Windows 安装包改为从 CI 命令行注入版本号（`/DAPP_VERSION=...`），下次发版不会再因为忘改 .nsi 内的硬编码版本号而上传失败

**English:**
- 🔒 Fixed Android dufs startup log writing the `--auth user:pass@/:rw` argument verbatim to logcat (any adb client or same-uid app could read user credentials)
- 🐛 Fixed in-app About page version drifting from `pubspec.yaml` — now read at runtime from `package_info_plus`, so releases no longer require manual sync of `lib/app.dart::appVersion`
- 🐛 Fixed secure_storage credential migration: previous load() would re-write the legacy SharedPreferences auth into secure_storage every run, overwriting any newer credential the user had set (effectively reverting password changes on next launch)
- 🐛 Fixed port-conflict auto-bump persisting the bumped port over the user's preferred port: user preference and actual-runtime port are now tracked separately
- 🐛 Fixed an Android start race: Dart used to wait a fixed 500ms before checking service status, but the Kotlin socket probe takes up to 5s — UI would falsely report "start failed" while the service actually came up. Now polls up to 6s
- ✨ Language switch in Settings now takes effect immediately (previously required app restart)
- 🏗️ NSIS Windows installer now reads APP_VERSION from the CI command line (`/DAPP_VERSION=...`) instead of a hardcoded `.nsi` constant — no more silent missing setup.exe when the .nsi version isn't manually bumped

---

## [v0.3.3](https://github.com/zocs/inout/releases/tag/v0.3.3) (2026-05-01)

**中文：**
- 🐛 修复 Android < 15 设备点击启动后立即报"服务启动失败：dufs did not start listening on port 5000"——NDK r28 默认 16KB 页对齐让旧设备 dynamic linker bind() 异常 + 服务主线程上 `Socket.connect()` 被 `NetworkOnMainThreadException` 静默吞掉，两个 bug 叠加把已经在 listen 的 dufs 误报为启动失败
- 🐛 修复 AppImage 升级后偶发使用旧版本 libdufs 的提取冲突（提取路径加 mtime+pid 唯一化）
- ✨ 端口冲突自动恢复：5000 被占时先尝试接管同 user 的残留 dufs/inout 进程；接管不了则自动切到 5001+，UI SnackBar 提示
- ✨ Auth 凭据从 SharedPreferences 迁移到平台 keychain（flutter_secure_storage）
- ✨ 传输日志条目支持点击复制完整路径
- 🏗️ 新增 Docker 化本地构建支持（Linux x64 + Android arm64），与 CI 行为对齐
- 🏗️ CI 加入 libdufs.so 4KB 页对齐 hard guard、Gradle cache、独立 `flutter analyze` job
- 🏗️ Flutter 升级到 3.41.5；编译器升级到 NDK r28，但强制 4KB 页对齐保留对 Android 7.0+ 的全部兼容

**English：**
- 🐛 Fixed Android < 15 devices reporting "service failed to start: dufs did not start listening on port 5000" right after tapping Start. Two stacked bugs: NDK r28 changed default LOAD-segment alignment to 16KB which the dynamic linker on older Android mishandles, and the new socket-connect probe silently swallowed `NetworkOnMainThreadException` because it ran on the foreground service's main thread — leaving an actually-listening dufs reported as failed
- 🐛 Fixed AppImage upgrade occasionally reusing a stale extracted libdufs binary (extraction path now embeds mtime+pid)
- ✨ Auto port-conflict recovery: when :5000 is busy, app first tries to reclaim a leftover dufs/inout process owned by the same user; otherwise bumps to :5001+ and surfaces a SnackBar notice
- ✨ Auth credentials moved from SharedPreferences to the platform keychain (flutter_secure_storage)
- ✨ Tap a transfer-log entry to copy its full path to the clipboard
- 🏗️ Added Dockerized local builds for Linux x64 and Android arm64 (`scripts/docker_build_*.sh`) mirroring CI behavior
- 🏗️ CI gained a hard libdufs.so 4KB page-alignment guard, Gradle cache, and a standalone `flutter analyze` job
- 🏗️ Flutter bumped to 3.41.5; toolchain bumped to NDK r28 but forced back to 4KB page alignment so support down to Android 7.0+ is preserved

---

## [v0.3.2](https://github.com/zocs/inout/releases/tag/v0.3.2) (2026-04-27)

**中文：**
- 🐛 修复桌面端单文件分享在路径包含空格/中文/特殊字符时的 FFI 启动失败
- 🐛 修复 Android 单文件分享后切换预置目录仍按单文件模式校验导致的 `File not found`
- 🐛 修复 Android/桌面端单文件分享 working directory 处理错误
- ✨ 启动/停止服务新增过渡态进度条与忙碌文案，降低等待卡顿感知
- ✨ 退出前若需停止服务，关闭确认流程也复用同一套过渡反馈

**English：**
- 🐛 Fixed desktop single-file sharing startup failures when paths contain spaces, CJK text, or special characters
- 🐛 Fixed Android preset directories still being validated as single-file paths after previous file sharing, causing `File not found`
- 🐛 Fixed working-directory handling for single-file sharing on Android and desktop
- ✨ Added transition progress feedback for server start/stop to reduce perceived stutter
- ✨ Reused the same transition feedback when exiting while a running server must be stopped first

---

## [v0.3.1](https://github.com/zocs/inout/releases/tag/v0.3.1) (2026-04-20)

**中文：**
- 🐛 修复 Android 8/9 等 API 30 以下设备因 DT_RELR packed relocations 导致的 dufs 启动崩溃
- 🐛 修复应用内版本号显示与 `pubspec.yaml` 不一致
- 🐛 修复传输日志统计无法累计文件大小的问题
- 🏗️ 传输日志改为增量读取，避免长时间运行后反复整文件扫描
- ✨ 新增显式“选择分享文件”入口，不再只依赖桌面拖放触发单文件分享

**English：**
- 🐛 Fixed dufs startup crash on Android API < 30 caused by DT_RELR packed relocations
- 🐛 Fixed in-app version display drifting from `pubspec.yaml`
- 🐛 Fixed transfer log stats not accumulating file sizes
- 🏗️ Switched transfer log reading to incremental reads to avoid full-file rescans over long sessions
- ✨ Added an explicit "select share file" entry instead of relying only on desktop drag-and-drop

---

## [v0.3.0](https://github.com/zocs/inout/releases/tag/v0.3.0) (2026-03-31)

**中文：**
- ✨ 隐藏系统文件：自动隐藏 .git、.DS_Store、Thumbs.db、.env 等系统文件（默认开启）
- ✨ 渲染首页：目录有 index.html 时自动渲染，方便简易测试网页
- 🐛 修复 Linux/macOS 构建脚本版本号提取错误（0.2.929 → 0.2.9）
- 🏗️ CI 排除 iOS 从 release 发布（仅编译测试）

**English：**
- ✨ Hide system files: auto-hide .git, .DS_Store, Thumbs.db, .env etc. (on by default)
- ✨ Render index: auto-render index.html if present in directory for quick web testing
- 🐛 Fixed Linux/macOS build script version extraction bug (0.2.929 → 0.2.9)
- 🏗️ CI excludes iOS from release (compile-only)

---

## [v0.2.8](https://github.com/zocs/inout/releases/tag/v0.2.8) (2026-03-28)

**中文：**
- ✨ Android 正式签名发布，CI 构建统一使用 release keystore，覆盖安装不再需要先卸载旧版
- ✨ F-Droid 上架材料已提交审核（Fastlane metadata、GitLab MR）
- 🐛 修复多平台版本号不一致的问题（安装包文件名和 app 内显示版本对不上）
- 🏗️ CI 全平台版本号统一从 pubspec.yaml 读取

**English：**
- ✨ Android release signing — CI builds use a unified release keystore, no need to uninstall before updating
- ✨ F-Droid submission prepared (Fastlane metadata, GitLab MR)
- 🐛 Fixed version number inconsistency across platforms (package filename vs in-app display)
- 🏗️ CI reads version from pubspec.yaml across all platforms

---

## [v0.2.7](https://github.com/zocs/inout/releases/tag/v0.2.7) (2026-03-27)

**中文：**
- 🐛 修复 Windows NSIS 安装包路径含空格时引号处理错误
- 🐛 修复 Android FFI 重复调用导致的并发崩溃
- 🐛 修复 F-Droid 构建版本号检测
- 🐛 修复版本号同步问题

**English：**
- 🐛 Fixed NSIS installer quoting error when path contains spaces
- 🐛 Fixed Android FFI concurrent crash from re-entry
- 🐛 Fixed F-Droid build version detection
- 🐛 Fixed version number sync issues

---

## [v0.2.6](https://github.com/zocs/inout/releases/tag/v0.2.6) (2026-03-27)

### 🔧 架构重构 / Refactor: dufs FFI

**中文：**

dufs 文件服务从"作为子进程运行"改为"编译成共享库通过 FFI 加载"。解决了三个实际问题：Windows 杀毒软件误报、Linux AppImage 网络隔离、以及子进程残留。

**English：**

dufs is now compiled as a shared library (.so/.dll/.dylib) and loaded via Dart FFI instead of running as a child process. This fixes antivirus false positives on Windows, network isolation in AppImage (FUSE sandbox), and orphaned processes.

### ✨ 新功能 / Features (since v0.2.3)

**中文：**
- **传输记录** — 实时查看文件下载/上传日志
- **源码编译 dufs** — 全平台从源码编译，兼容 F-Droid 要求
- **Android 原生 Service** — dufs 跑在原生 Android Service 里，Activity 被回收后服务不中断（小米 6 等 4GB 内存设备实测修复）
- **返回键确认** — 服务运行中按返回键会弹窗确认，避免误关
- **多地址显示** — 列出所有网卡的 IP 地址和网卡名称

**English：**
- **Transfer log** — real-time download/upload history viewer
- **Source-compiled dufs** — all platforms build from source, F-Droid compatible
- **Android Native Service** — dufs runs in a native Service, survives Activity destruction (fixes low-memory devices like Mi 6)
- **Back key confirmation** — prompts before exiting while server is running
- **Multi-address display** — shows all network interfaces with names

### 🐛 修复 / Fixes

**中文：**
- Windows 杀毒软件不再误报（dufs 从 .exe 改为 .dll）
- AppImage 内文件服务无法访问的问题
- 部分 Linux 发行版打包时的权限报错
- Android API 级别调整以兼容旧设备

**English：**
- Windows antivirus no longer flags dufs (changed from .exe to .dll)
- Fixed dufs unreachable inside AppImage
- Fixed CMAKE_INSTALL_PREFIX permission error on some distros
- Adjusted Android target API for older device compatibility

---

## [v0.2.3](https://github.com/zocs/inout/releases/tag/v0.2.3) (2026-03-25)

**中文：**
- ✨ Android 文件服务改用原生 Kotlin Service 管理，低内存设备不再假死
- ✨ 新增传输记录功能，查看文件传输历史
- ✨ 返回键双重确认：服务运行中按返回会弹窗询问
- ✨ 地址列表始终显示所有网卡地址
- 🐛 修复低内存设备上 dufs 进程丢失的问题
- 🐛 修复端口冲突检测

**English：**
- ✨ Android dufs process now managed by native Kotlin Service, fixes low-memory device crashes
- ✨ Transfer log — view file transfer history
- ✨ Back key confirmation when server is running
- ✨ Address list always shows all network interfaces
- 🐛 Fixed dufs process orphaning on low-memory devices
- 🐛 Fixed port conflict detection

---

## [v0.2.2](https://github.com/zocs/inout/releases/tag/v0.2.2) (2026-03-20)

**中文：**
- 🐛 修复 Linux AppImage 内找不到 dufs 的问题
- 🐛 修复 Windows CI 构建的编码问题

**English：**
- 🐛 Fixed dufs binary not found in Linux AppImage
- 🐛 Fixed UTF-8 encoding issue in Windows CI builds

---

## [v0.2.1](https://github.com/zocs/inout/releases/tag/v0.2.1) (2026-03-18)

**中文：**
- ✨ 全新铅笔手绘风格图标（应用图标 + 系统托盘图标）

**English：**
- ✨ New hand-drawn pencil sketch icon (app + system tray)

---

## [v0.2.0](https://github.com/zocs/inout/releases/tag/v0.2.0) (2026-03-15)

**中文：**
- ✨ 桌面端拖放共享——直接拖文件/文件夹到窗口设置共享目录
- ✨ 系统托盘——最小化到托盘，右键菜单操作
- ✨ 关闭行为可选——最小化到托盘还是直接退出
- ✨ 多网卡地址列表——显示所有网络接口 IP
- ✨ 修复 Android 8 存储权限问题
- ✨ 启动动画——像素风 inout + 原生到 Flutter 无缝过渡
- ✨ 启动时自动清理残留的 dufs 孤儿进程

**English：**
- ✨ Desktop drag & drop — drag files/folders to set share path
- ✨ System tray — minimize to tray with right-click menu
- ✨ Close behavior choice — minimize to tray or exit
- ✨ Multi-address list — shows all network interface IPs
- ✨ Fixed Android 8 storage permission
- ✨ Animated splash — pixel-art inout with smooth Flutter transition
- ✨ Auto-cleanup of orphaned dufs processes on startup

---

## [v0.1.0](https://github.com/zocs/inout/releases/tag/v0.1.0) (2026-03-01)

🎉 首个版本 / Initial Release

**中文：**
- 文件夹和单文件分享
- 权限预设（只读 / 可上传 / 完整控制）
- 密码认证、CORS 开关
- 二维码生成
- 三语支持（简中 / 繁中 / English）
- Material 3 主题 + 6 种配色
- Android + Windows + Linux 安装包

**English：**
- Directory & single-file sharing
- Permission presets (readonly / upload / full)
- Password auth, CORS toggle
- QR code generation
- Multilingual (Simplified Chinese / Traditional Chinese / English)
- Material 3 theming with 6 color schemes
- Android + Windows + Linux packages
