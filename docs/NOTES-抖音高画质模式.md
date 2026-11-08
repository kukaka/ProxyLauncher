# 抖音「高画质模式」使用说明

> 更新：2026-11-08。功能已集成进 ProxyLauncher（构建 #46）。
> 实现：`Sources/DouyinHighQuality.swift`，补丁：`Sources/douyin-hq-preload.js`。
> 结论与实验过程见 [NOTES-抖音4K画质.md](NOTES-抖音4K画质.md) 与
> [NOTES-抖音4K画质-实验过程归档.md](NOTES-抖音4K画质-实验过程归档.md)。

## 0. 一句话

抖音 PC 客户端会把 4K / 2K 档位藏起来，**原因不是核数不够，而是它本地判定
「设备支持 H.266」后优先走 H.266 分支**，而 H.266 侧最高只有 720P。
本功能在**隔离副本**里让页面中的 `MediaSource.isTypeSupported('...bvc2...')`
返回 false，客户端就会改走 H.265 分支，同一视频恢复 2K / 4K 菜单。

- 原版 `/Applications/douyin.app` **完全不动**。
- 副本是 ad-hoc 签名；抖音更新后需要重新制作。
- 与「硬件信息伪装」**无关**：真实 8 核同样能出 4K，伪装不参与这件事。

## 1. 怎么用

在 ProxyLauncher 主窗口底部的「抖音高画质」区域：

1. 勾选「**启动抖音时使用高画质副本**」。
2. 点「**制作 / 更新副本**」，等它做完（克隆 + 改写 + 重签名，几秒钟）。
   副本放在 `~/Library/Application Support/ProxyLauncher/apps/Douyin-HQ.app`。
   之后从本工具启动抖音就会用这份副本。
3. 点「**删除副本**」可以清掉它（同样不碰原版）。

状态那一行会显示副本是否最新：抖音更新过之后会提示「原版已更新到 x.y.z」，
点一次「制作 / 更新副本」即可。

**首次运行副本**时 macOS 会弹一次钥匙串授权，点「**Always Allow**」，
输一次登录密码，之后不再弹。

**副本和原版不能同时运行**（应用标识相同）：启动副本前请先完全退出原版抖音，
本工具检测到原版还开着会直接拒绝启动并提示。

## 2. 副本长什么样

- 用 `cp -c` 做 APFS 克隆，**几乎不额外占磁盘空间**（788MB 的应用克隆后
  `df` 看不出变化）。
- 显示名改成「抖音 HQ」，方便在 Dock / 访达里和原版区分。
- 主程序和 4 个 Helper 一起重签成 ad-hoc，**entitlements 一项不动**
  （沿用原版的，逐项校验过一致）。
  只签主程序的话父子进程签名身份不一致，Electron 的网络服务子进程会起不来，
  界面会一直停在「加载中」。
- `app.asar` 里只改了 `preload.js` 这一个条目，其余条目和原始字节都不变。

## 3. 排障用的日志

副本的输出不落在本工具里，需要的话可以自己起一个看：

```bash
~/Library/Application\ Support/ProxyLauncher/apps/Douyin-HQ.app/Contents/MacOS/抖音 \
  --enable-logging=stderr 2>&1 | tee /tmp/douyin-hq.log
grep "ProxyLauncher H266 test" /tmp/douyin-hq.log | tail
```

期望看到 `[ProxyLauncher H266 test] installed; HEVC=true`，
以及播放器做能力检测时打出的 `bvc2 capability disabled`
（**后者才是关键** —— 说明播放器的 H.266 探测真的走了我们改过的函数）。

## 4. 它到底改了什么

补丁只有一处：副本 `app.asar` 里 `preload.js` 的最前面插入一段几十行的 JS
（`Sources/douyin-hq-preload.js`）。它做的事：

1. 把 `MediaSource.isTypeSupported` 包一层；
2. 类型里含 `bvc2`（H.266）时返回 `false`，其余类型原样透传；
3. 不碰 H.265 / H.264 的能力检测，不改请求参数，不改签名参数，不动视频响应。

为什么这个点有效（来自抖音网页端播放器代码）：

- 客户端是否启用 H.266 分支，取决于
  `useClientH266 === On && MediaSource.isTypeSupported("video/mp4;codecs=bvc2.1.6.L93.B0")`；
- 码流列表里 H.266 只有 720P / 576P，混流阶段（`h266_concat_mix`）只把
  H.265 的 1080P 补回去，4K / 2K 在这一步被丢掉；
- 把 `bvc2` 的能力检测改成 `false`，客户端直接走 H.265 分支
  （`h265_filter → over_filter_h265_multi_clarity → h265_overall_filter`），
  最终列表里 `adapt_lowest_4_1`、`adapt_lowest_1440_1` 都在。

补丁在 preload 阶段安装，并兼容 `contextIsolation`：

- 非隔离上下文：直接替换；
- 隔离上下文：用 `contextBridge.executeInMainWorld` 在主世界同步安装
  （播放器跑在主世界）；桥接不可用时只记录失败，不扩大改写范围。

控制台会打印 `[ProxyLauncher H266 test] installed; HEVC=true`，页面上还会留下
`window.__PROXYLAUNCHER_HQ__ = { patched: true, ... }` 便于确认。

## 5. 边界与已知风险

- **原版永远不动。** 每一步都会核对原版 `app.asar` 的 SHA256；不一致就中止。
- **副本与原版不能同时运行。** bundle ID 相同（Electron 单实例锁 + macOS 按
  bundle ID 认应用）。`launch` 会检测到已在运行的抖音进程时**直接拒绝启动**，
  不会替你结束进程。
- **主程序和 4 个 Helper 必须一起重签。** 主程序改成 ad-hoc 签名后，如果 Helper
  还留着字节的开发者签名，父子进程签名身份不一致，Electron 的**网络服务子进程
  会起不来**（日志里是 `Network service crashed`，界面就一直停在「加载中」）。
  原版里主程序和 Helper 都是字节 Team ID `JH23ZR9LF5` 签的（字节把整个包用
  自己 Team ID 重签过），所以原版没这个问题。
  实测：只签主程序 → 网络服务崩溃、一直「加载中」；主程序 + Helper 一起签 →
  网络服务 0 次崩溃、正常打开。`build` 已按后者处理。
  注意这只改**签名身份**，授权一项不动（已逐项校验与原版一致）。
- **环境里残留的 `DYLD_*` 会被清掉。** 主程序沿用原版授权（其中本来就含
  `allow-dyld-environment-variables`），万一 shell 里还留着 `DYLD_INSERT_LIBRARIES`，
  dylib 会被塞进子进程，历史症状同样是「加载中」。`launch` 默认清掉这些变量
  （要伪装硬件时用 `--allow-dyld` 保留）。
- **重签只改身份，不改授权。** 副本里每一项授权都与原版逐项一致
  （已校验），新增任何授权都没有必要。
- **改写 ASAR 时 `size` 必须是数字、`offset` 必须是字符串。** 原版 ASAR 头部就是
  这个约定（`"size":166` 是数字，`"offset":"2344"` 是字符串）。Electron 读 `size`
  用的是数值取法 —— 写成字符串的话 `preload.js` 根本读不出来，补丁不生效，
  表现是「副本能正常打开，但没有 2K/4K」。很容易漏，因为 JSON 里两种写法都能解析。
- **副本制作逻辑有版本号**（`builderVersion`）。改了改写逻辑就 +1，
  旧副本会被判定为「需要重建」，不会带着老 bug 继续用。
- **ad-hoc 签名的副作用：钥匙串会弹一次授权框。** 副本要用原版建的
  Electron safe storage 密钥（钥匙串条目 `douyin Safe Storage` / 账号 `douyin`），
  以及字节自己的 secure storage（`secure-storage:com.bytedance.douyin.desktop` /
  账号 `master-key-v1`）。原版是用字节的证书签的，副本是 ad-hoc 签名，
  身份不同 → macOS 要你授权。
  **弹窗里点「Always Allow」（不是「Allow」）**，输一次登录密码，之后就不再弹。
  点「Allow」的话下次启动还会再问。
  - 为什么重建后又可能再弹：ad-hoc 签名的 designated requirement 是 cdhash 型的
    （`cdhash H"..."`），重签一次 cdhash 就变，之前授的权就失效了。
    所以 `build` 现在是**幂等**的：副本已是最新就不重建，签名保持不变；
    只有原版更新或补丁改动才重建（那时再点一次「Always Allow」即可）。
  - 没有采用「用 identifier 型 DR 换稳定授权」的方案：那会削弱 macOS 的
    代码身份校验（任何声称同一 bundle ID 的签名都能通过），不划算。
  - 用 `security` 命令行改钥匙串 ACL 试过，不可靠（会 "User canceled"），
    走 macOS 自己的授权流程更稳。
- **副本是「关能力」而不是「解锁」。** 关掉 H.266 之后，副本**永远播不了
  H.266**。目前观察到 H.266 侧最高只有 720P，所以是净收益；如果将来抖音把
  H.266 也铺到 2K / 4K，这个补丁会变成净损失（届时需要重新评估）。
- **抖音更新后必须重建。** 服务端下发的网页 JS 是跟客户端版本走的，
  H.266 分支的逻辑变了就得重新验证；`status` 会提示原版已更新。
- **依赖服务端行为。** 服务端本来就把 2K / 4K 的 H.265 码流发下来了，
  本补丁只是让客户端别自己丢掉。服务端不下发的视频，这里也无能为力。
- **改第三方客户端代码并重签，是有法律/ToS 风险的行为。** 本工具只在本机、
  只对用户自己的副本操作，默认不开启，不随 ProxyLauncher 主程序自动执行。

## 6. 复现与取证

- 硬指标：播放上报里的 `bitrate_set_client` 是否含 `adapt_lowest_4_1` /
  `adapt_lowest_1440_1`；以及 `video_play_quality` 里的最终分辨率。
- 抓取客户端网络请求的脚本见 `NOTES-抖音4K画质.md` 第 8 节
  （`/tmp/dy/capture-client-network.sh` 等，属临时目录，可能已被系统清理）。
- 精简结构化证据没有随仓库提交，需要时按 `NOTES-抖音4K画质.md` 第 8 节重新采集。

## 7. 与「硬件信息伪装」的关系

**没有关系。** 之前排查时以为是核数不够，实际源码里高性能判定
（`fR()`）是「Mac 核数 ≥ 8」就通过，而实测的未打补丁轮次里，
H.265 分支的中间列表**本来就保留着 4K / 2K** —— 是最后的 H.266 混流把它们顶掉了。
所以伪装功能对抖音画质没有贡献，`fR()` 那条线可以不再追。

## 8. 已知边界

- **画质已验证**：用户确认「之前客户端不显示 2K / 4K 选项的视频，
  现在都显示且正常播放了」。
- **只验证过一个视频**：`7690151208207584531`。用户这次是横向验证了「多个此前
  没有 2K/4K 的视频现在都有了」，但还没有专门挑抖音刚铺 H.266 的新视频，
  确认「关掉 H.266 不会让某些视频变差」。
- **ASAR 完整性校验熔丝状态**：已确认当前版本
  `EnableEmbeddedAsarIntegrityValidation = 0`（关闭），所以改 `app.asar` 不会被拦。
  抖音若在后续版本打开这个熔丝，本工具会失效（表现为副本启动即报错），
  届时需要改成改 Electron 二进制或换别的注入点。

## 9. 排障：副本一直显示「加载中」

这个症状出现过两次，病因不同，别混：

| 现象 | 日志里的标志 | 病因 | 处理 |
|---|---|---|---|
| 一直「加载中」，GPU 报错 | `Failed to create context` / `ContextResult::kFatalFailure` | 往渲染/GPU 子进程注入了 dylib，IOKit 改写把 GPU 搞崩了 | 别注入；本工具不注入任何 dylib |
| 一直「加载中」，网络请求失败 | `Network service crashed, restarting service` + `net::ERR_FAILED` | 主程序改成 ad-hoc 签名后，Helper 还是开发者签名，**父子签名身份不一致**，网络服务子进程起不来 | 主程序 + 4 个 Helper 一起重签成 ad-hoc（`build` 已处理） |
| 启动时弹「XX wants to use your confidential information stored in "douyin Safe Storage"」 | 日志里看不出来（是 macOS 的对话框） | 副本的签名身份与原版不同，钥匙串要你授权 | 点「**Always Allow**」，输一次密码即可，以后不再弹 |

第二种还有两个同症状的诱因，一起排掉：

- shell 里残留 `DYLD_INSERT_LIBRARIES` → 副本带 `allow-dyld` 授权，dylib 会被
  塞进子进程（`launch` 默认清掉 `DYLD_*`）；
- 抖音更新后副本没重建 → `status` 会提示原版已更新。

定位命令：

```bash
grep -c "Network service crashed" /tmp/douyin-hq.log
grep "ProxyLauncher H266 test" /tmp/douyin-hq.log | tail
```
