# MenuSearch · 菜单搜索

**中文** | [English](README_EN.md)

在任意 App 里按一个快捷键，列出**这个 App 菜单栏和各级子菜单里的全部命令**；输入就过滤，↑↓ 选择，回车执行，Esc 关闭。用途和 Raycast 的 Search Menu Items 相同，但它是一个独立的原生 macOS App：不需要 Raycast、Karabiner 或 skhd，开源，MIT 许可。

[产品主页与演示](https://app-mac-menusearch.tianli.cyou/) · [下载最新版](https://github.com/zengtianli/MenuSearch/releases/latest) · [报告问题](https://github.com/zengtianli/MenuSearch/issues)

<img src="site/assets/panel.png" width="720" alt="MenuSearch 面板：列出当前 App 的全部菜单命令，带完整路径和快捷键">

<img src="site/assets/panel-search-dark.png" width="720" alt="输入 tab 后的过滤结果，深色外观">

以上是应用自己在后台渲染的真实界面，列表里是固定的演示菜单数据，不是某台电脑上的真实菜单。

## 下载与安装

需要 **Apple Silicon（M1 或更新）与 macOS 14 或更新版本**。没有 Intel 构建；界面为中文。

1. 在 [Releases](https://github.com/zengtianli/MenuSearch/releases/latest) 下载 `MenuSearch-<版本>-arm64.dmg`。
2. 打开 DMG，把 `MenuSearch.app` 拖到 `Applications`。
3. 在「应用程序」里打开 MenuSearch，照下面「第一次使用」授权并录一个快捷键。

也可以下载 ZIP，解压后把应用拖进「应用程序」。发行包用 Developer ID 签名、开启 hardened runtime，并经过 Apple 公证；每个版本的 SHA-256 在 Release 附带的 `SHA256SUMS` 和 `release.json` 里。

想在终端里用同一套功能，加一条命令链接（可选）：

```sh
mkdir -p ~/.local/bin && ln -s /Applications/MenuSearch.app/Contents/MacOS/MenuSearch ~/.local/bin/menusearch
```

更新：在设置窗口点「检查更新」，或运行 `menusearch update --install`。新版下载后先核对校验值、签名和公证，再替换旧版；配置和快捷键保留，上一版留在 `~/Library/Application Support/TianliApps/UpgradeBackups/`。

卸载：退出 MenuSearch，删除 `/Applications/MenuSearch.app`、`~/.local/bin/menusearch` 和 `~/Library/Application Support/cyou.tianli.menusearch/`。

## 第一次使用

1. 打开 `/Applications/MenuSearch.app`，出现设置窗口。
2. 在「权限」里点「打开系统设置…」，在「隐私与安全性 › 辅助功能」中打开 MenuSearch。读取和执行别的 App 的菜单需要这项权限；MenuSearch 不会替你授权。
3. 在「快捷键」里点按钮，按下想用的组合键（至少带 ⌘、⌃ 或 ⌥；Esc 取消）。默认不注册任何快捷键，也不会占用你已有的键。
4. 关掉设置窗口。之后在任意 App 里按这个组合键即可。

再次打开 MenuSearch（或运行 `menusearch settings`、在面板里按 ⌘,）回到设置窗口。

## 两种呼出方式

| 方式 | 谁管快捷键 | 进程 |
| --- | --- | --- |
| 内置快捷键（默认） | MenuSearch 自己向系统注册你录制的那一个组合键 | 保持运行，是一个看得见的普通 App：在程序坞、⌘Tab 应用切换器和菜单栏里都有它。关掉设置窗口和面板都不会退出，退出它才结束 |
| 外部呼出 | skhd、Karabiner 或别的启动器运行 `menusearch show` | 不常驻；面板关闭后进程结束，不注册任何快捷键，也不进程序坞 |

保持运行时可以这样找到它和退出它：⌘Tab 切过去（没有窗口时会打开设置），点程序坞图标，或点菜单栏图标——里面是「搜索当前 App 的菜单」「设置…」「退出」。退出用 ⌘Q、程序坞右键、菜单栏图标、设置窗口里的按钮或 `menusearch quit` 都行；退出后快捷键不再响应，直到再次打开。

两种方式互斥，在设置窗口或用 `menusearch config set mode builtin|external` 切换。切换时先停掉旧的快捷键来源再启用新的；新的启用不了（比如组合键被别的 App 占用）就退回原来的方式，已保存的设置不变。

外部呼出时，把这一条命令绑到你的键位工具上即可，MenuSearch 不会去改那些工具的配置：

```sh
/Applications/MenuSearch.app/Contents/MacOS/MenuSearch show    # 或 ~/.local/bin/menusearch show
```

录制快捷键时会检查三件事：macOS 自己已启用的系统快捷键（拒绝）、系统拒绝注册（拒绝，原来的键保持不变）、以及 skhd 配置和 `~/.config/mackit/keys.d` 里别的工具声明的同一个组合键（只读检查，给出提示）。

## 面板

| 按键 | 作用 |
| --- | --- |
| 输入 | 过滤。按空格分词，支持不连续字符（`exp pdf`），也匹配菜单路径（`view developer`） |
| ↑ ↓ | 选择；焦点留在输入框 |
| ↩ | 执行选中的命令。中文输入法正在组词时，回车仍用于确认候选 |
| Esc，或点到别处 | 关闭 |
| ⌘R | 重新读取菜单 |
| ⌘, | 打开设置 |

不输入时列出全部命令。每条显示完整菜单路径、快捷键、勾选和不可用状态；不可用的命令不会被执行。每次呼出都重新读取，菜单内容不缓存、不落盘。读取超时或某些菜单没有响应时，面板会明确标出「结果不完整」。

执行前会再核对一遍：目标 App 仍在最前、菜单项仍属于它、标题没变、当前可用；任何一条不成立就不执行，并提示刷新。

## 命令行

命令和 App 是同一个可执行文件，共用设置和后台实例。按上面「下载与安装」加一条链接后就能直接用 `menusearch`（从源码安装时 `scripts/install.sh` 会替你加）。

| 命令 | 作用 |
| --- | --- |
| `menusearch status [--json]` | 版本、呼出方式、快捷键、权限、后台实例状态、最近一次呼出的耗时。只读 |
| `menusearch show` | 对当前 App 呼出面板；面板已显示时关闭 |
| `menusearch scan [--pid PID] [--query 词] [--json]` | 读取菜单命令，只读；`--query` 用面板同一套匹配 |
| `menusearch execute --pid PID --path-json '["View","Show Path Bar"]' [--json]` | 执行完整路径唯一匹配的命令；目标 App 须在最前 |
| `menusearch settings` | 打开设置窗口 |
| `menusearch config get｜set mode｜set hotkey｜set login｜export｜import｜path` | 查看和修改配置，导出、导入 |
| `menusearch config set icloud on\|off` | 用 iCloud 记住配置，同设置窗口里的开关 |
| `menusearch update [--install] [--json]` | 查询 GitHub 上的最新正式版，只在运行这条命令时联网；`--install` 由 App 下载并验证发行包后升级，配置保留，升级后的启动不弹窗口 |
| `menusearch quit` | 退出后台实例 |
| `menusearch help`、`version` | 说明、版本 |

退出码：`0` 成功；`1` 没有完成（没有权限、菜单不完整、目标不在最前、实例无响应等）；`2` 用法错误。未知命令是用法错误，不会打开面板。加 `--json` 时标准输出只有一个 JSON 对象。

`scan` 和 `execute` 在命令行进程里读取菜单，用的是**调用它的终端或工具**的辅助功能权限；`show` 交给 MenuSearch.app 自己读取，用的是 App 的权限。`status` 分别报告这两者。

## 配置、同步与更新

设置存在 `~/Library/Application Support/cyou.tianli.menusearch/settings.json`，只有呼出方式和快捷键两项。设置窗口可以导出、导入，也可以打开「使用 iCloud 记住配置」（沿用系统 Apple ID 的 iCloud Drive，默认关闭）。辅助功能权限、登录项、运行状态和菜单内容都不在其中。损坏的设置文件不会被悄悄覆盖：先按默认设置运行并说明原因，下次保存时原文件另存备份。

「检查更新」向 GitHub 查询这个仓库的最新正式版，只在你点它（或运行 `menusearch update`）时执行，不在后台轮询，启动时也不检查。

会随 macOS 变化的少数值（哪些顶层菜单属于系统、读取时限）放在随包的 `tuning.json`；在支持目录放一个同名文件可以逐项覆盖，不需要重新安装。

## 隐私与联网

- 菜单内容只在本机读取，用完即弃，不写文件、不上传。App 记录的只有最近一次呼出的条数和耗时。
- 唯一的联网是检查更新：你点「检查更新」或运行 `menusearch update` 时，向 GitHub 请求这个仓库的最新发行信息；选择升级时再从 GitHub 下载安装包。不自动检查，请求里不带任何菜单内容或设备信息。除此之外 App 不发起网络连接，运行中的实例不持有任何网络套接字（验收里有这一项）。
- 可选的「使用 iCloud 记住配置」读写的是 iCloud Drive 在本机的目录，由系统负责同步；默认关闭。
- 快捷键是向系统注册的一个具体组合键，不监听键盘、不记录按键，也不合成输入。
- 没有账号，没有统计。

<!-- lightweight:start -->
## 资源占用

| 安装后占用 | 空闲内存 | 空闲 CPU | 冷启动到首屏就绪 |
|---|---|---|---|
| **2.1 MB** | **17.8 MB** | **0%** | **422 ms** |

原生 AppKit，无 WebView、无脚本运行时、无第三方库；快捷键是向系统注册的一个组合键，没有事件监听和轮询；菜单每次呼出现读、用完即弃，不建索引；外部呼出方式面板关闭后进程即结束。

<sub>v0.2.0 (6) · Mac16,12 / Apple M4 / macOS 27.2 · 内置快捷键方式常驻、面板未显示时采样；按下快捷键到完整结果的耗时由 App 记录在 menusearch status 的 last_show。 · 2026-10-07。数字来自所列设备实测，版本更新后重新测量。内存口径为 phys_footprint；CPU 为 60 秒采样窗内 CPU 时间 ÷ 墙钟；大小按十进制 MB。原始数据见 [perf/lightweight.json](perf/lightweight.json)。</sub>
<!-- lightweight:end -->

上面这组数字由实测文件自动写入。另外两项：在 1000 条命令里边打字边过滤，P95 约 14–33 ms（后台渲染，含列表重载与布局，随机器负载变化）；读取一个 App 的菜单，Finder 201 条约 40–76 ms、微信 92 条约 28–43 ms、Chrome 750 条约 149–206 ms、Safari 577 条约 307–536 ms（随它当时的状态变化）。外部呼出方式下面板关闭后没有本 App 的进程。「按下快捷键到面板出现完整结果」每次都记在 `menusearch status` 的 `last_show` 里。

## 验证到哪一层

| 层 | 状态 |
| --- | --- |
| 逻辑测试、后台自检（生产面板、设置窗口、方式与快捷键事务、控制通道、配置迁移） | 每次构建都跑，失败就不产出 App；关键保护做过反向验证（改坏后自检失败） |
| 固定验收 functionality / recovery / privacy / native_ui | 通过（隔离目录，不上屏）：`python3 scripts/accept/run.py <项>` |
| 签名、公证、发行包回读 | 每个发行版由 `scripts/release.py` 核对：ZIP 与 DMG 里的 App 都过 Gatekeeper，可执行文件与构建记录一致 |
| 应用内升级 | 在作者的 Mac 上真实执行过：配置与快捷键保留，升级后不弹窗口、不抢前台 |
| 真实菜单读取 | Safari、Finder、微信、Chrome 的 10 条查询全部命中（命令行只读读取） |
| 真实桌面使用 | 作者日常在用。没有逐项的上屏验收记录和截图；页面与本说明里的截图是后台渲染的演示数据 |

已知限制：只支持 Apple Silicon；界面只有中文；个别 App 的菜单要等它响应才读得全，读不全时面板会标「结果不完整」；菜单栏图标在刘海旁边放不下时系统不显示它，这时仍可从程序坞和 ⌘Tab 找到它。

## 从源码构建

需要 Apple Silicon Mac 和 Xcode 或 Command Line Tools，没有第三方依赖。

```sh
bash build.sh                 # 逻辑测试 → 构建并签名 → 后台自检；任何一步失败都不会替换 build/MenuSearch.app
bash build.sh --test-only     # 只跑逻辑测试
python3 scripts/accept/run.py functionality   # 另有 recovery、privacy、native_ui
bash scripts/install.sh [--restart]            # 装到 /Applications 并链接命令，旧版移到废纸篓
```

签名身份取环境变量 `CODESIGN_IDENTITY`，否则取 `local/signing-identity` 的第一行，否则 ad-hoc。ad-hoc 构建可以用，但每次重新构建后 macOS 都会要求重新授予辅助功能权限，应用内升级也只接受与当前安装同一开发者签名的包；固定的签名身份可以保留权限。

用 `scripts/install.sh` 装的版本回滚：上一版在 `~/.Trash/menusearch-<版本>-<时间>/MenuSearch.app`，移回 `/Applications` 即可；设置不受影响。

## 反馈

问题和建议请提到 [Issues](https://github.com/zengtianli/MenuSearch/issues)。说明 macOS 版本、是哪个 App 的菜单，以及 `menusearch status` 的输出（里面没有菜单内容）会很有帮助。

## 来源与许可

MIT，见 [LICENSE](LICENSE)。菜单读取、过滤、面板交互和执行保护从 [MacKit](https://github.com/zengtianli/mackit) 的菜单搜索原型迁出（同一作者，MIT）。行为参考了 [Raycast 的公开说明](https://manual.raycast.com/navigation)，没有复制 Raycast 或任何第三方扩展的代码。设置与更新窗口使用作者各 App 共用的源文件（`Sources/AppLifecycle*.swift`、`AppConfiguration.swift`、`LaneSignal.swift`），随本仓库以同一许可提供。
