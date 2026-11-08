# 抖音 PC 客户端 2K / 4K 画质排查：实验结论与交接

> 更新：2026-11-08。ProxyLauncher 最近构建为 **#38**。
> 状态：**固定样本已在临时测试副本恢复 2K / 4K 菜单，日志确认实际 2K 硬解播放。**
> 原版 `/Applications/douyin.app` 未修改；尚未产品化，未提交、未合并。

## 1. 当前结论

已验证样本的客户端限制来自 **H.266 优先与混流策略**，不是核数不足，也不是服务器没下发高码流：

1. 客户端收到的响应含 2K / 4K H.265 码流。
2. 播放器优先选择 H.266；该视频的 H.266 码流最高只有 720P。
3. 混流阶段只补入 H.265 的 1080P，没有补回 2K / 4K。
4. 仅让 `MediaSource.isTypeSupported` 对 `bvc2` 返回 `false` 后，播放器改走 H.265，
   同视频菜单恢复 2K / 4K。

**效果来自停用 H.266 优先路径，与硬件信息伪装无关。** 成功实验使用真实 8 核，未注入硬件伪装 dylib。
不能将单个样本结论推广成“所有视频都能获得 4K”，也不能把“菜单可选”当作已验证实际播放 4K。

## 2. 固定样本与对照结果

### 2.1 最终验证样本

- 视频 ID：`7690151208207584531`
- 标题：`喵言喵语～喵吃月饼 #小姐姐 #中秋节 #旗袍`
- 网页定位：`https://www.douyin.com/jingxuan?modal_id=7690151208207584531`
- 客户端：抖音 **8.8.0**，日志 UA 显示 Electron **39.5.1** 定制版 / Chromium **142.0.7444.48**。

| 项目 | Chrome 网页 | 原版客户端 | 打补丁的测试副本 |
|---|---|---|---|
| 数据来源 | 服务端首屏内嵌 `app.videoDetail` | 搜索流接口的实际响应 | 同视频播放日志及菜单实测 |
| 收到码流数 | 21 | 27 | 未单独核对总数 |
| 服务端 2K / 4K | 均有，H.265，MP4 / DASH | 均有，H.265，MP4 / DASH | 最终可用列表均保留 |
| 最终菜单 | 有 2K / 4K | 用户确认最高 1080P | 用户确认有 2K / 4K |
| 实际尺寸证据 | 主 video 元素 3840×2160，采样时暂停 | 播放上报 1920×1080 | 播放上报 2560×1440、`is_hw=1` |
| 硬件核数 | 8 | 8 | 8 |

网页和客户端的数据入口不同，**不能用 21 条与 27 条的数量差异来归因**。
判断客户端本地过滤的依据，是客户端自己的响应、过滤前后列表与播放上报。

### 2.2 其他样本及其边界

| 视频 | 结果 | 能说明什么 |
|---|---|---|
| `7705283457831701794`，创哥的 AI 实验室，Codex 那条 | Chrome 响应含 2K / 4K；开启图形加速后网页出现 4K | 网页的 HEVC 能力影响菜单；用户明确指出客户端原本就能选 4K，不能归功于伪装 |
| `7705248118586439163`，RabbittuX，「我把 Purrge APP 做出来啦」 | 已捕获详情响应 21 流、最高 1920×1080；切换 `quick_player` / `video_page` 后码流属性不变；用户确认开启 Chrome 加速后仍最高 1080P | 当前响应未下发高码流，不能据此断言服务器绝无 4K，也不能声称开启加速让所有视频新增 4K |

早期两条详情响应存在入口、版本、`support_dash` 等差异。补采后入口、版本、DASH 与其余已比对
非时效性查询参数得到对齐，但 API 子域仍有 `www` / `www-hj` 差异，未称为完全同条件。

### 2.3 创哥与月饼：已有记录复查

用户要求直接对比已有记录后，已检查原版和补丁两轮的NetLog分片快照及最终合并文件。
月饼有完整 `video_play_quality` / `bitrate_info_record`；创哥在这些记录中仅命中旁路事件，
未恢复其播放过滤链。保留的创哥客户端推荐响应仍可作编码档位比较：

| 项目 | 创哥 `7705283457831701794` | 月饼 `7690151208207584531` |
|---|---|---|
| 响应入口 | `/aweme/v1/web/tab/feed/` | `/aweme/v1/web/general/search/stream/` |
| 捕获时请求核数 | 14（早期伪装实验） | 8（原版网络采集） |
| 总码流数 | 31 | 27 |
| H.264 | 11条，最高1080P | 9条，最高1080P |
| H.265 | 12条，包含2K/4K | 12条，包含2K/4K |
| H.266 | 8条，最高1080P | 6条，最高720P |
| 原版播放过滤链 | 尚无记录 | 已确认H.266优先、只补1080P |

两条视频都有H.266、且其H.266都没有4K，所以不能仅用“有无H.266”或“H.266最高分辨率”
解释为什么创哥可选4K。源码允许依据分支和混流开关保留H.265高档；创哥当时实际走哪条分支，
仍不能从现有响应推断。两份响应的入口与请求核数也不同，不是严格同条件对照。
精简原始字段没有随仓库提交（里面是抖音的码流数据），需要时按第 8 节的方法重新采集。

## 3. 原版客户端的直接证据

网络采集轮次：`/tmp/dy/client-network-AVk2Qb`，原版主进程 PID `24785`。
客户端搜索流 `/aweme/v1/web/general/search/stream/` 的目标视频条目包含 27 条码流，
其中有 3840×2160 的 4K 和 2560×1440 的 2K，均有 MP4 / DASH。

`video_play_quality.bitrate_info_record` 记录了以下过程：

| 阶段 | 过滤后结果 |
|---|---|
| 原始响应 | 27 条，含 2K / 4K H.265 |
| `h266_filter` | 6 条 H.266，只有 720P / 576P |
| `over_filter_h266_multi_clarity` | 3 条 H.266 DASH |
| H.265 分支的白名单处理 | 仍保留 2K / 4K / 1080P 等档位 |
| `h266_concat_mix` | 只补入 H.265 的 1080P，最终共 4 条 |

原版最终 `bitrate_set_client`：

```text
adapt_540_2
adapt_lower_540_2
adapt_lowest_720_2
adapt_lowest_1080_1
```

同一视频同时上报 `is_supported_265=1`、`is_265_degrade=0`、
`is_supported_hevc1_hw=1`、`is_hw=1`，实际选择 `adapt_lowest_1080_1`，1920×1080。
所以不能把客户端限制简单归因为“不支持 H.265”。

注意：响应字段名 `is_h265` 实际被用作编码枚举；本次源码中 `0` / `1` / `2`
分别对应 H.264 / H.265 / H.266，不能把 `2` 当成普通布尔值。

## 4. 已验证的兼容补丁

### 4.1 作用点

缓存播放器模块 `360542` 的 H.266 分支门控包含：

- 客户端环境；
- 视频存在 `isH265=2` 的码流；
- `MediaSource.isTypeSupported("video/mp4;codecs=bvc2.1.6.L93.B0")`；
- `useClientH266` 实验开关（配置键 `use_h266_client`）。

混流代码还包含 `BitrateSelector.fix_concat.fix_h266_1080_mode` 和
`fix_h266_2k4k_mode`。已定位相关代码，但**尚未直接读取实际 AB 配置值，未验证修改这些配置的方案**。

当前补丁在预加载阶段，仅对 `bvc2` 能力检测返回 `false`，其余类型透传原函数。
保留 H.265 / H.264 能力、真实硬件信息，不修改视频响应或重新签名请求参数。

### 4.2 实现与副本处理

- 补丁源码：[Sources/douyin-hq-preload.js](../Sources/douyin-hq-preload.js)
- 临时测试应用：`/tmp/ProxyLauncher-Douyin-4K-Test/douyin.app`（实验期用；
  正式的改写逻辑已并入主程序）
- **已产品化**：集成在 ProxyLauncher 主程序里
  （[Sources/DouyinHighQuality.swift](../Sources/DouyinHighQuality.swift)：克隆副本 +
  改写 app.asar + 重签 + 启动），说明见
  [NOTES-抖音高画质模式.md](NOTES-抖音高画质模式.md)。
  上面的两个旧工具是实验期用的，只针对 `/tmp` 里的测试副本。

补丁被加在原 `preload.js` 的 native SDK 初始化之前。非隔离上下文直接安装；
隔离上下文用 `contextBridge.executeInMainWorld` 同步安装。桥接 API 不可用时记录失败，
不扩大改写范围。没有向网页新增特权 API。

ASAR 工具只修改测试副本的 `preload.js` 条目，追加替换内容、更新该条目的 SHA256 完整性信息，
保留其他条目元数据和原 payload。原 ASAR 备份在测试目录的 `app.asar.before-h266-test`。
修改后已重签测试副本，并通过 `codesign --verify --deep --strict`。

这次复用了早期硬件注入实验中已重签主程序和 Helper 的测试副本，**不表示纯 JS 兼容补丁本身
需要给所有 Helper 增加 DYLD 授权**；长期方案应从原版重新制作最小改动副本。

### 4.3 验证结果

模拟检查通过：隔离 / 非隔离路径、H.265 / H.264 保持、未知类型保持、原错误透传、
属性描述符保持、重复安装幂等、桥接缺失回退以及 baseline 开关。

用户运行测试副本后，日志确认 `installed; HEVC=true`、`bvc2 capability disabled`。
过滤链切换为：

```text
h265_filter
→ over_filter_h265_multi_clarity
→ h265_overall_filter
```

最终 `bitrate_set_client`：

```text
adapt_lowest_4_1
adapt_lowest_1440_1
adapt_lowest_1080_1
adapt_lowest_720_1
adapt_540_1
adapt_lower_540_1
```

用户确认 2K / 4K 菜单出现；播放日志确认 `adapt_lowest_1440_1`、2560×1440、`is_hw=1`、`cpu_core=8`。
同副本的 `--baseline` 开关已准备并通过模拟检查（可选的对照手段，不影响结论）。

原版 ASAR SHA256 保持为：

```text
f24ce87054195831a267da006b1b2d227f9b1a1b22d2399ec33a024faf9ebddb
```

原版主程序和所有 Helper 的签名摘要与实验前一致。

## 5. 本轮排除或纠正的早期推测

- **Mac 8 核不达标：错误。** 已恢复模块 `38918` 的 `fR()`：`has2K` 为真直接通过，
  否则 Windows 要求 `>8`、Mac / Ohos 要求 `>=8`。本机 8 核已达标。
- **改到 14 核就是解锁原因：无证据。** 早期确实让请求上报 14 核，但未证明解锁过新档位。
  最终有效补丁使用真实 8 核。
- **Chromium 的 deviceMemory 一律封顶 8：不适用于当前 Chrome。** 本机 Chrome 请求实际上报 16，
  Electron 客户端上报 8。
- **Chrome 开关会改变客户端：不成立。** 两者配置独立。Chrome 图形加速关闭时，网页 HEVC
  检测受影响；用户开启后，创哥视频出现 4K。客户端本来就上报 `support_h265=1`。
- **只有客户端没有收到 4K：本次固定样本已排除。** NetLog 明确捕获了客户端响应里的高码流。
- **菜单出现 4K 就表示实际播放 4K：不成立。** 本次区分用户菜单确认、最终列表和实际解码尺寸。
- **GPU、重复类或 `get pc_* failed` 警告就是加载失败原因：未证明。** 一轮完整硬件伪装副本卡住，
  下一轮同时移除多加的代理环境、关闭 IOKit 改写后可打开，不能分辨是哪项变化解决。

## 6. 已讨论的长期方案

建议将其做成独立的「抖音高画质兼容模式」，与硬件信息伪装分开。

### 第一阶段：已验证的兼容路径（**已实现为仓库内独立工具**）

工具：ProxyLauncher 主程序内的「抖音高画质」功能，说明：
[NOTES-抖音高画质模式.md](NOTES-抖音高画质模式.md)。

1. 默认关闭，由用户主动启用 —— 独立脚本，不随启动器自动执行。
2. 从原版制作独立兼容副本，安装最小 `bvc2` 补丁，保留原版。
3. 不改核数、机型、GPU 或请求参数，保留 H.265 / H.264。
4. 提供原版 / 兼容版启动和明确路径，避免误启动同 bundle ID 的原版。
5. 记录补丁安装、HEVC 支持、最终高画质列表与实际播放尺寸。
6. 绑定原版版本、ASAR 哈希、补丁版本；更新后重新制作，不盲用旧补丁。
7. 验收固定同视频：菜单出现 → 切换成功 → 实际分辨率 / 解码状态。

实现要点：副本用 `cp -c`（APFS clone）克隆到
`~/Library/Application Support/ProxyLauncher/apps/Douyin-HQ.app`，
几乎不额外占磁盘；只改副本 `app.asar` 里 `preload.js` 一个条目；沿用原版
entitlements 做 ad-hoc 重签；每一步都核对原版 `app.asar` 哈希不变。
本工具**不删除任何东西**：旧副本改名留档，由用户自行清理。

**重签的坑（已踩并修掉）**：主程序改成 ad-hoc 签名后，4 个 Helper 必须一起改成
ad-hoc —— 否则父子进程签名身份不一致（原版里主程序和 Helper 都是字节 Team ID
`JH23ZR9LF5`），Electron 的网络服务子进程会起不来，日志里是
`Network service crashed`，界面一直停在「加载中」。只改签名身份，授权一项不动。

**ad-hoc 签名的连带影响**：副本读钥匙串要重新授权（弹窗里点「Always Allow」，
输一次密码即可）。ad-hoc 签名的 designated requirement 是 cdhash 型的，
重签一次授权就失效，所以工具的 `build` 做成幂等的 —— 副本已是最新就不重建。

### 第二阶段：精细混流方案（**结论：本地基本不可行**）

保留 H.266，仅修正或配置混流，让已有 H.265 2K / 4K 补回列表。
源码里确实存在 `BitrateSelector.fix_concat.fix_h266_2k4k_mode` 和
`fix_h266_1080_mode` 两个开关，H.266 分支门控也用到 `useClientH266`。

但进一步扒缓存里的播放器代码后确认：**这三个值全部来自服务端下发的
`abtestData`**（`useClientH266 === UseClientH266.On`），不是本地常量：

```js
g = e => !!(0, n.DT)() && d.video.bitRateList.some(e => 2 === e.isH265)
     && (0, u.Yk)()                      // ← bvc2 能力检测
     && (r?.useClientH266) === o.UseClientH266.On
```

混流分支里的 `fix_h266_2k4k_mode !== 1` 同样取自 abtestData。
所以「只改配置、不改代码」在客户端侧做不到，除非改 abtest 缓存本身
（会被服务端刷新覆盖，且相关请求带签名）。**第一阶段的 bvc2 能力屏蔽
是目前唯一稳定可用的杠杆**，第二阶段仅在将来能稳定注入 abtestData 时再考虑。

### 关于 ASAR 完整性校验

当前抖音（8.8.0 / Electron 39.5.1）的 Electron 熔丝
`EnableEmbeddedAsarIntegrityValidation = 0`（关闭），所以改 `app.asar` 不会被拦。
若后续版本打开这个熔丝，补丁副本会启动即报错，届时需改注入点。

## 7. 证据、工具与复现位置

### 仓库内持久保存

- 本文：当前结论、实验边界与后续设计。
- 精简结构化证据（两端目标视频码流、补丁前后过滤链与播放字段）
  没有随仓库提交；需要时按第 8 节的方法重新采集，或从原始 NetLog 快照里提取。
- [Sources/DouyinHighQuality.swift](../Sources/DouyinHighQuality.swift) + `Sources/douyin-hq-preload.js`
  + [NOTES-抖音高画质模式.md](NOTES-抖音高画质模式.md)：
  「高画质模式」功能（副本 + 补丁 + 启动），已集成进主程序。
- `tools/prepare-douyin-h266-test.py`：实验期用的 ASAR 修改工具（只针对 `/tmp` 测试副本）。
- `tools/extract-douyin-cache.cjs`：Chromium Simple Cache 的 JS 提取工具。
- [完整过程归档](NOTES-抖音4K画质-实验过程归档.md)：保留原始交接和逐轮历史，不作为当前待办。

### 临时目录（可能被系统清理）

| 路径 | 内容 |
|---|---|
| `/tmp/dy/7690151208207584531-comparison/` | 对比报告、网页状态、客户端响应条目、过滤链和补丁验证 |
| `/tmp/dy/client-network-AVk2Qb/snapshot/` | 原版 NetLog 分片快照及解出的目标响应 / 上报 |
| `/tmp/dy/h265-test-gKLZwo/snapshot/` | 成功补丁轮次 NetLog 快照及上报 |
| `/tmp/ProxyLauncher-Douyin-4K-Test/` | 测试副本、原 ASAR 备份、签名授权文件和补丁 manifest |
| `/tmp/dy/test-client-h265.sh` | 启动兼容副本并记录 console / NetLog |
| `/tmp/dy/capture-client-network.sh` | 不注入伪装，启动原版并开启 NetLog |

当前临时启动方式：完全退出所有抖音主进程后，用户手动执行：

```bash
bash /tmp/dy/test-client-h265.sh
# 同副本基线模式（已准备，未由用户实跑）：
bash /tmp/dy/test-client-h265.sh --baseline
```

ASAR 工具依赖已存在的测试副本；它不是完整安装器，不会自动制作副本、重签或启动应用。
不要直接用于原版安装目录。

## 8. 采集方法和已踩过的坑

- 固定同一视频；分别记录响应内容、客户端最终列表、菜单、实际播放尺寸。
- `/video/` 地址可能实际跳回精选弹层，要检查实际页面和请求参数，不以输入地址推断入口。
- 磁盘缓存缺记录不等于无高码流；视频数据可能在 SSR 内嵌状态、流式响应或内存里。
- Simple Cache 的 stream 1 长度字段可能为 0；按末尾 stream 0 footer 定位 body。
  响应可能用 Brotli / gzip / zlib / zstd，提取器必须处理对应格式。
- 网页现场可只读解析 `document.scripts` 中 `self.__pace_f.push` 的百分号编码 JSON / RSC JSON。
  这不是独立详情接口的原始响应，要标明来源。
- Chrome Apple Events 读取需用户开启 `View → Developer → Allow JavaScript from Apple Events`；
  本轮由用户开启，未替用户关闭，后续不用时可手动关闭。CUA 连接工具多次超时。
- NetLog 使用 `--log-net-log`、`--net-log-capture-mode=Everything`、100MB 上限。
  运行中的目标文件可能只是说明文本，实际分片在说明中指向的 scoped_dir；先保存快照，避免轮转。
- 客户端 `URL_REQUEST_JOB_FILTERED_BYTES_READ` 可恢复响应体；搜索流需重组分块。
  `SSL_SOCKET_BYTES_SENT` 的 HTTP/2 DATA 帧可重组 JSON 上报，其 `params` 可能再次 JSON 编码。
- 沙箱内 macOS Security 可能读不到完整 entitlements，甚至误报未改的原版签名无效。
  本轮签名授权读取和最终验证在沙箱外完成，保留原有 JIT 等授权。
- 不以旧持久化 HEVC 单个布尔值代替现场检测；本轮曾出现 `is_support=false`、
  `pure_support=true` 但网页仍可显示 4K 的组合。

## 9. 硬件伪装 / CDP 路线现状

这些属于早期排查成果，**已被证明与本问题无关，相关代码已从 ProxyLauncher 删除**
（技术细节见 [NOTES-硬件信息伪装-技术归档.md](NOTES-硬件信息伪装-技术归档.md)）：

- 原版主程序可注入，Helper 的 hardened runtime 授权阻止 DYLD 注入；重签副本后 Renderer 可注入，
  请求核数曾成功改为 14，但**没有解锁过任何画质档位**。
- 关键否证：未打补丁的那一轮里，H.265 分支的中间列表**本来就保留着 4K / 2K**
  （`over_filter_h265_whitelist` 的 after 里含 `adapt_lowest_4_1`、`adapt_lowest_1440_1`），
  是最后一步 `h266_concat_mix` 把它们顶掉的。高性能判定 `fR()` 的门槛是
  Mac 核数 ≥ 8，本机 8 核已过线。**所以画质瓶颈 100% 在 H.266 分支，与核数/机型无关。**
- CDP 那条路（`--remote-debugging-port` 改网页里的 JS 环境）：实测启动参数到达主程序，
  但调试端口未监听，具体哪层禁用没查清。
  （若将来查通了，可以用同样的方式在运行时屏蔽 bvc2，那样连副本都不用。）
- ProxyLauncher 最近一次完整构建为 #46（本轮把高画质功能并入主程序、
  删除硬件伪装功能）。

## 10. 工作约定

- 不提交、不合并，等待用户明确要求。
- 不自动启动或退出用户应用；功能测试由用户手动进行。
- 不修改原版抖音；目前授权与实验均限隔离测试副本。
- 更新启动器代码或打包资源时运行 `./build.sh` 并报告构建号；文档整理不需要重建应用。
- 不把历史假设、菜单选项、播放上报混为同一级证据，不把指定样本结果推广到所有视频。
