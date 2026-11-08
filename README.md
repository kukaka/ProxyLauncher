# 代理启动器（ProxyLauncher）

> 本项目已链接认可 [LINUX DO](https://linux.do) 社区。

一个 macOS 原生小工具：设置好代理地址后，把应用添加进列表，从这里启动的应用会自动注入
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` 环境变量，让 Antigravity、Claude
等应用的后台进程（如 language_server）直接走 Clash 本地端口，**无需开启 TUN 模式**。

原理：应用启动前注入标准代理环境变量，只影响被启动的应用，不修改系统全局代理。

## 下载安装

从 [Releases](https://github.com/ZhjGo/ProxyLauncher/releases) 下载最新的
`ProxyLauncher-x.x.zip`，解压后把 `ProxyLauncher.app` 拖进「应用程序」文件夹
（显示名称是「代理启动器」）。当前源码构建 Apple Silicon（arm64）版本，
需要 macOS 13 或更高。

**首次打开**：本应用没有 Apple 开发者签名，直接双击会提示"无法验证开发者"。
解决方法（任选其一）：

- 打开「系统设置 → 隐私与安全性」，在底部找到被拦截的提示，点「仍要打开」；
- 或在终端执行：`xattr -cr /Applications/ProxyLauncher.app`，之后正常双击即可。

不想用现成包的话，克隆仓库跑 `./build.sh` 自己构建（只需 Xcode 命令行工具）。

## 使用

1. 先打开 Clash Verge 等代理软件（默认混合端口 7890）。
2. 双击 `dist/ProxyLauncher.app` 打开。顶部绿点表示代理端口已连通。
3. 点「添加应用」或**直接把 App 拖进窗口**添加（可多选）。
4. 点某个应用的「启动」即可带代理启动。若该应用已在运行，会提示「退出并重新启动」
   （环境变量只在启动那一刻生效）；若代理端口不通，会先提醒。
5. 建议把 `ProxyLauncher.app` 拖进「应用程序」文件夹，方便从启动台打开。

### 每个应用的启动设置

点击应用行的滑杆图标，或右键选择「启动设置…」，可分别设置：

- **注入代理环境变量**：默认开启，设置大小写两组 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY`。
- **Chromium 代理参数**：默认关闭，开启后附加 `--proxy-server=http://地址:端口`，用于支持该参数的 Electron / Chromium 应用。其它应用请保持关闭。

ChatGPT 的设置页提供「使用 ChatGPT 建议设置」，同时开启以上两项；不会自动替应用开启。
预览中的代理地址随主界面设置变化，列表会为启用参数的应用显示「Chromium 代理」标签。
这些设置同时用于主窗口、菜单栏、「全部启动」、复制终端命令以及新生成的独立启动器。

保存后需退出并重新启动目标应用才能生效；已有独立启动器需要重新生成。
仅修改主界面的代理地址时，独立启动器仍会读取共享配置，无需重新生成。
复制的终端命令直接运行目标应用的可执行文件，执行前也应先退出已运行的应用。
这些选项不会修改系统代理，也不保证接管不支持相应设置的网络组件。

## 功能

- **独立启动器生成**：应用行悬停的 ⬇ 图标（或右键菜单）可生成 `XXX（代理）.app`，
  用原应用图标，放进 Dock / 启动台后**双击即带代理启动**，不用先开本工具。
  启动器从 `~/Library/Application Support/ProxyLauncher/proxy.env` 读取代理地址，
  在主界面改了设置后所有启动器自动同步，无需重新生成。
  启动器是原生可执行文件（不是脚本），并已 ad-hoc 签名，
  在 Apple Silicon 上双击不会再提示「需要安装 Rosetta」。
- **测出口**：经代理查询出口 IP、国家/城市和运营商，快速判断节点地区是否符合要求
  （如「当前地区不支持」类报错）。依次尝试 ipwho.is / api.ip.sb / ip-api.com，
  单个接口限流会自动换下一个。
- **自动探测端口**：扫描 7890 / 7897 / 7891 / 1080 / 2080 / 8889 / 8118 / 10808 / 10809，
  找到可连通的端口自动填入。启动时端口连不通会自动探测；运行中每 6 秒复查，
  发现断开（如代理软件换了端口）也会自动重新探测切换。当前设置的端口优先，
  能用就不会被改掉。
- **菜单栏常驻**：勾选后菜单栏出现 ✈️ 图标，关掉窗口不退出、从 Dock 隐藏，
  随时从菜单栏一键启动任意应用。
- **全部启动**：一键带代理启动列表里所有未运行的应用。
- **抖音高画质**：可选让抖音客户端显示并播放 2K / 4K 档位。详见下方「抖音高画质」。
- 右键应用行：带代理启动、生成启动器、复制等效终端命令、在访达中显示、移除。
- 所有设置自动保存；只影响由本工具（或生成的启动器）启动的应用，不修改系统全局代理。

## 抖音高画质（2K / 4K 档位）

抖音 PC 客户端会**优先播放 H.266 码流**，而它拿到的 H.266 最高只有 720P，
于是 2K / 4K 档位在客户端被藏了起来 —— 服务端其实早就把 4K 的 H.265 码流发下来了。

主窗口底部的「抖音高画质」区域：

- 勾选「启动抖音时使用高画质副本」→ 之后从本工具启动抖音会改用副本。
- 「制作 / 更新副本」→ 在 `~/Library/Application Support/ProxyLauncher/apps/Douyin-HQ.app`
  生成一份打了补丁的副本（APFS 克隆，几乎不额外占磁盘），**原版应用不会被修改**。
- 「删除副本」→ 删掉副本，同样不碰原版。

原理：补丁让网页里的 `MediaSource.isTypeSupported("...bvc2...")` 返回 false，
客户端就会改走 H.265 分支，用上服务端早就下发好的 4K 码流。
**跟硬件信息没有关系**（真实 8 核同样能出 4K）。

注意事项：

- 副本与原版的应用标识相同，**不能同时运行**，启动副本前请先退出原版抖音。
- 首次运行副本时 macOS 会弹一次钥匙串授权，点「Always Allow」即可，之后不再弹。
- 抖音更新后副本会落后，界面会提示「制作 / 更新副本」。
- 副本是 ad-hoc 签名，从此不再播放 H.266 码流（目前 H.266 最高只有 720P，所以是净收益）。

完整调查过程与证据见 [NOTES-抖音4K画质.md](docs/NOTES-抖音4K画质.md)，
使用说明见 [NOTES-抖音高画质模式.md](docs/NOTES-抖音高画质模式.md)。

## 重新构建

```bash
./build.sh        # 产物在 dist/ProxyLauncher.app，另生成带版本号的 arm64 ZIP 安装包
```

只需要 `swiftc`（Xcode Command Line Tools 即可），不需要完整 Xcode。

个别机器上 Command Line Tools 与它附带的 macOS SDK 版本对不上，编译会报
`this SDK is not supported by the compiler`（或 `redefinition of module 'SwiftBridging'`）。
`build.sh` 会自动探测这种情况，并在 `~/Library/Caches/proxylauncher-toolchain`
生成一份"影子工具链"绕过去，不改系统文件、也不需要管理员权限。
彻底解决请安装完整 Xcode——Xcode 的 SDK 自带二进制模块，不会出现该报错。

## 文件说明

- `Sources/main.swift` — 主应用代码（SwiftUI）
- `Sources/LauncherStub.swift` — 独立启动器的原生可执行文件（生成启动器时复制进去）
- `Sources/DouyinHighQuality.swift` — 抖音高画质：克隆副本、改写 `app.asar`、重签名
- `Sources/douyin-hq-preload.js` — 注入副本 `app.asar` 的画质补丁源码
- `Info.plist` — 应用包信息
- `make-icon.swift` — 构建时生成图标
- `build.sh` — 编译 + 打包 + ad-hoc 签名
- `tools/prepare-toolchain.sh` — 探测工具链与 SDK 是否匹配，必要时准备影子工具链

## 注意

- 目标应用更新后路径不变，启动器继续可用；若应用被移动/改名，需重新生成启动器。
- 代理环境变量只对「从本工具或启动器启动」的进程生效，从 Dock 直接打开不走代理。
- 主程序和生成的独立启动器都只针对 Apple Silicon（arm64）；拷到 Intel Mac 上无法运行。
- 早期版本生成的启动器内部是 shell 脚本，在 Apple Silicon 上双击会提示「需要安装 Rosetta」，
  用新版本重新生成即可。
