# 硬件信息伪装 —— 技术归档（功能已从 ProxyLauncher 移除）

> 归档日期：2026-11-08。状态：**功能已删除**，本文件只作技术记录。
> 删除原因见第 5 节。抖音画质问题的真正解法见
> [NOTES-抖音4K画质.md](NOTES-抖音4K画质.md) 与
> [NOTES-抖音高画质模式.md](NOTES-抖音高画质模式.md)。

## 1. 这个功能是做什么的

让目标应用以为自己是另一台 Mac：启动时往进程里注入一个 dylib，在进程内拦截
`sysctl` / `sysctlbyname` / IOKit 的读接口，把机型、芯片、核数、内存、GPU
型号和 GPU 核心数改成预设值；另外还提供命令替身和本地调试端口两条补充通路。

实现分三块：

| 通路 | 作用 | 覆盖的读取方式 |
|---|---|---|
| **dylib 注入** | 在进程内拦截系统调用 | `sysctlbyname`、`sysctl(mib)`、IOKit 的 `model` / `compatible` / GPU 代次字符串 |
| **命令行替身** | 替换 PATH 里的命令 | `system_profiler`、`sysctl`、`ioreg`（这三个是 Apple 平台二进制，带 `__RESTRICT` 段，dylib 注入不进去） |
| **本地调试端口** | 改网页里的 JS 环境 | Electron 渲染进程里的 `navigator.hardwareConcurrency` / `navigator.deviceMemory` |

## 2. dylib 注入（`Sources/hwspoof.c`，已删除）

### 2.1 dyld interpose 的规矩

`DYLD_INSERT_LIBRARIES` **不会**自动抢占符号，必须在 `__DATA,__interpose` 段里
显式写「替换谁 / 替换成谁」，而且：

- **interpose 段必须是一个数组**。写成单个 struct 变量时链接器不生成绑定重定位，
  段里是 0，dyld 静默忽略 —— 表现就是「dylib 加载了但函数没被换掉」。
- interpose 生效后 `dlsym(RTLD_NEXT)` 会拿到**自己**，调用即无限递归。
  要透传原始函数只能用普通数据指针存地址。
- macOS **没有 `__sysctlbyname` 这个系统调用**（SDK 头文件里那个 274 其实是
  `sem_post`）。透传要 `sysctlnametomib()` + `syscall(SYS_sysctl, ...)`。

### 2.2 拦截的读取点（必须整套一起改，否则等于自曝）

只改「核心数」不改「性能核/能效核的拆分」，报上去的资料是自相矛盾的
（"我有 14 个核，但一个性能核都没有"），比不改更容易被当成假设备。

| 读法 | 键 |
|---|---|
| sysctl | `hw.model` / `hw.targettype` / `machdep.cpu.brand_string` / `machdep.cpu.vendor` |
| sysctl | `hw.ncpu` / `hw.logicalcpu` / `hw.logicalcpu_max` / `hw.physicalcpu_max` / `hw.activecpu` / `hw.packages` |
| sysctl | `hw.nperflevels`（固定 2）/ `hw.perflevel0.logicalcpu`（E 核）/ `hw.perflevel1.logicalcpu`（P 核） |
| sysctl | `hw.memsize` |
| sysctl(mib) | `CTL_HW` 的 `HW_MODEL` / `HW_MACHINE` / `HW_NCPU` / `HW_AVAILCPU` / `HW_TARGET` / `HW_PRODUCT` / `HW_MEMSIZE` |
| ioreg | 平台节点的 `"model"`（CFData）/ `"compatible"`（板级 ID，CFData） |
| ioreg | 每个 CPU 节点的 `"cluster-type"`（P / E 标记），还要按目标核数增减节点 |
| ioreg | GPU 节点的 `"model"`（CFString，芯片名） |
| ioreg | GPU 代次字符串：`MetalPluginName` / `MetalPluginClassName` / `MetalStatisticsName` / `IOClass` / `CFBundleIdentifier` / `CFBundleIdentifierKernel` / `IOPersonalityPublisher` |
| system_profiler | `SPHardwareDataType`：`Model Name` / `Model Identifier` / `Chip` / `Total Number of Cores` / `Memory` / `Serial` / `UUID` |
| system_profiler | `SPDisplaysDataType`：`_name` / `sppci_model` / `sppci_cores`（GPU 型号与核心数） |

注意 `HW_NCPU_CONF` / `HW_PACKAGES` 在 macOS 上并不存在，要用真实 mib
（`HW_AVAILCPU=25`、`HW_TARGET=26`、`HW_PRODUCT=27`）。

### 2.3 注入位置

dylib **必须**放在 `~/Library/Application Support/` 再注入。Chromium（抖音是
Electron 应用）跑网页的渲染进程在 Seatbelt 沙箱里，策略是 `(deny default)`
起步，只放行应用 bundle、`/usr/lib`、`/System` 和**用户目录**。dylib 放在
`~/Documents` 之类的地方渲染进程读不到，dyld 会直接把它杀掉，页面一片空白。

### 2.4 子进程注入

Chromium 拉子进程时会整理自己的环境变量，`DYLD_INSERT_LIBRARIES` 活不到子进程。
dylib 里因此要拦截 `posix_spawn` / `execve`，主动把 `DYLD_INSERT_LIBRARIES`
和全部 `HWSPOOF_*` 参数塞回子进程的环境（开关 `HWSPOOF_INJECT_CHILDREN=1`）。

### 2.5 硬伤：Electron 的 Helper 注入不进去

| 进程 | 签名 | `allow-dyld-environment-variables` |
|---|---|---|
| 主程序 | hardened runtime | ✅ 有 → 能注入 |
| `抖音 Helper (Renderer)` | hardened runtime | ❌ **没有** |
| `抖音 Helper (GPU)` | hardened runtime | ❌ 没有 |
| `抖音 Helper`(zygote) | hardened runtime | ❌ 没有 |

**dyld 对「硬化运行时 + 缺该授权」的进程直接无视 `DYLD_INSERT_LIBRARIES`。**
所以渲染进程里的 `navigator.hardwareConcurrency` 永远是真值。

日志能证明「注入动作发生了、但进程没加载」：
`spawn child .../抖音 Helper (Renderer).app/... (注入 dylib)` 有记录，
但 `loaded pid=... exe=.../抖音 Helper (Renderer)` 一条都没有。

### 2.6 另一条路：本地调试端口（`Sources/DevToolsOverride.swift`，已删除）

用 Chrome DevTools 协议在页面里改 JS 环境：

- 启动目标应用时带 `--remote-debugging-address=127.0.0.1 --remote-debugging-port=<随机端口>`；
- 用 CDP 连上去，对每个 page target 发 `Page.enable` /
  `Page.addScriptToEvaluateOnNewDocument` / `Runtime.evaluate`，
  注入的脚本只改 `Navigator.prototype` 上的 `hardwareConcurrency` 和 `deviceMemory`；
- 注入成功后每个 target 自动刷新一次（页面启动时就把设备参数算好了）。

安全边界：只监听 `127.0.0.1`、**不加** `--remote-allow-origins`（保留 Chromium
默认的来源校验）、只改两个属性、必须手动勾选开关。

**实测结果：调试端口没有监听**，启动参数到了主程序但服务没起来，具体哪层禁用
没查清（抖音只有一个主可执行文件，没有多级 launcher，所以不是参数丢失）。
所以这条路也没走通。

### 2.7 Swift / Foundation 相关的坑

- `URLSession` 的回调默认投递到**主线程**，主线程被 `Thread.sleep` 占住就永远不回调；
  轮询用的队列不能同时当 delegate 队列（`Thread.sleep` 会把队列占死）。
- SwiftUI `body` 表达式太长会报「unable to type-check this expression in
  reasonable time」，长字符串要抽成单独的计算属性。
- `build.sh` 用 `tools/prepare-toolchain.sh` 准备的**影子工具链**，
  直接 `xcrun swiftc` 会报 SDK/编译器不匹配。编译新文件记得同步改 `build.sh`
  的源文件列表。

## 3. 命令行替身（`Sources/bin/`，已删除）

`ioreg` / `sysctl` / `system_profiler` 是 Apple 平台二进制（带 `__RESTRICT` 段），
dylib 注入进不去，只能靠 PATH 替换 —— 也就是把替身脚本放到 `PATH` 最前面，
并在 dylib 里靠 `HWSPOOF_BIN_DIR` 把 `/usr/sbin/ioreg` 这类绝对路径改写掉。

写这些脚本时踩过的坑：

- **`exec cmd | awk` 在管道里只替换子 shell**，主 shell 会继续往下跑 →
  `system_profiler` 被执行两次、输出夹了一份没改过的原始 XML。
  **不要在管道里用 `exec`。**
- plist XML 的键和值分两行，改写要记住「上一个 key」；键后面不是 `<string>`
  时必须清状态，否则后面随便哪个 `<string>` 都会被误改。
- `ioreg` 的 CPU 节点有 20 多行属性，按「跳过一行」处理会漏 → 要按节点块处理。
- 给 CPU 节点改 `"cluster-type"` 时曾因为块跳过有 bug，结果变成 6P+8E 而不是 10P+4E。

## 4. 结论：它对抖音画质没有任何贡献

最终定位到的瓶颈**不在硬件信息**：

- 抖音网页端的高性能判定 `fR()`（模块 38918）：`has2K` 实验开关为真直接通过，
  否则 Windows 要求核数 `>8`、Mac / Ohos 要求核数 `>=8`。**本机 8 核已达标。**
- 未打补丁的那一轮实测里，H.265 分支的中间列表**本来就保留着 4K / 2K**
  （`over_filter_h265_whitelist` 的结果里有 `adapt_lowest_4_1`、`adapt_lowest_1440_1`），
  是最后一步 `h266_concat_mix` 把它们顶掉的。
- 把请求里的核数从 8 改成 14 之后，画质档位**没有**解锁过任何新选项。

所以伪装这条线对画质是无效的，而它的代价不小：约 700 行 C + 三个替身脚本 +
一个 CDP 客户端、一堆 dyld/沙箱/签名的坑，还会在 Electron 应用上引起
「加载中」「GPU 上下文创建失败」之类的副作用。

## 5. 为什么删除

1. **对目标功能无贡献**（见第 4 节）。
2. **代码量大且脆弱**：dyld interpose、Chromium 沙箱、硬化运行时三处限制叠在一起，
   换一台机器、换一个抖音版本都可能失效，排查成本很高。
3. **有副作用**：注入 dylib 会让 Electron 应用的 GPU 进程崩（`Failed to create
   context`），界面停在「加载中」；历史上为此排查了整整一轮。
4. 保留下来会让人以为「画质靠伪装解锁」，与事实相反。

## 6. 如果将来要复活

需要重新实现的部分（按工作量从小到大）：

1. **命令替身**：三个脚本，纯 awk，无系统依赖，最安全。
2. **dylib 注入**：注意第 2 节的 interpose 规则、注入位置、子进程注入。
3. **CDP 覆盖**：先查清「调试端口为什么不监听」，这条路成功后最干净
   —— 不碰目标应用，只改网页里的 JS 环境。

另外，Apple Silicon 上第三方 App 普遍开了硬化运行时 + 库验证，
`DYLD_INSERT_LIBRARIES` 对它们基本无效，所以这条路的天花板很低。

## 7. 相关文件（已删除，仅列出名字便于考古）

| 原文件 | 作用 |
|---|---|
| `Sources/hwspoof.c` | 伪装 dylib：sysctl / IOKit / spawn / exec 拦截 |
| `Sources/bin/ioreg` | ioreg 替身：型号、兼容 ID、逐核 cluster-type |
| `Sources/bin/sysctl` | sysctl 替身：机型、核数、内存等 |
| `Sources/bin/system_profiler` | system_profiler 替身：机型、芯片、核数、GPU |
| `Sources/DevToolsOverride.swift` | DevTools 协议客户端，改网页里的 JS 环境 |

配套记录：抖音 4K 画质的完整调查过程在
[NOTES-抖音4K画质.md](NOTES-抖音4K画质.md) 和
[NOTES-抖音4K画质-实验过程归档.md](NOTES-抖音4K画质-实验过程归档.md)。
