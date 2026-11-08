# 抖音4K画质排查：完整过程归档

> 归档日期：2026-11-08。以下按原文保留当时的判断、待办和逐轮记录，部分结论后来已被推翻。
> 当前有效结论以 [主交接文档](NOTES-抖音4K画质.md) 为准，不把本归档中的历史待办当作当前行动指令。

---

## 23:20 功能并入主程序后副本失效：ASAR 头部的 size 必须是数字

- 按用户要求把「抖音高画质」集成进 ProxyLauncher 主程序，硬件伪装功能整个删除
  （技术归档见 `NOTES-硬件信息伪装-技术归档.md`），构建 #41~#46。
- 用户实测：**副本能正常打开，但抖音没有 4K 选项** —— 补丁没生效。
- 定位：对比原版 ASAR 头部与副本头部（其余 10 个条目逐字段完全一致），
  只有 `preload.js` 这一条的 **`size` 类型不对**：
  - 原版：`"size":166`（数字）、`"offset":"2344"`（字符串）
  - Swift 版：`"size":"3012"`（**字符串**）← 写错了
  - Python 版（已验证可用）：size 是数字、offset 是字符串
  Electron 读 `size` 用的是数值取法，写成字符串 → `preload.js` 读不出来 →
  补丁不加载 → 客户端仍是原版行为（没有 2K/4K）。
  这个坑很隐蔽：JSON 里两种写法都能解析，只有 Electron 认数字。
- 修法：`entry["size"] = newPreload.count`（Int），offset 保持字符串。
  另外给清单加了 `builderVersion`，改写逻辑变更后旧副本会被判定为「需重建」，
  不会带着老 bug 继续用；老清单缺该字段时按 0 处理（而不是读不出来）。
- 顺带修了：遍历 `env.keys` 时删字典元素会崩（先收集键再删）；
  状态文案改成「副本需要重建」；没把抖音加进列表时给出提示。
- 仍待用户实测：新副本的 2K/4K 菜单。未提交、未合并。

---

## 22:30 画质验证通过 + 钥匙串授权弹窗的处理

- **用户实测通过**：之前客户端不显示 2K/4K 选项的视频，现在都显示且正常播放。
- 唯一的新问题：启动时 macOS 弹「抖音 HQ wants to use your confidential
  information stored in "douyin Safe Storage"」，要输登录密码，用户不想每次都输。
  查清了机制：
  - 钥匙串里有两条相关条目：Electron 的 `douyin Safe Storage`（账号 `douyin`），
    和字节自己的 `secure-storage:com.bytedance.douyin.desktop`（账号 `master-key-v1`）
    —— 两条都要授权，所以是「两次密码」。
  - 原版是用字节的证书签的，副本是 ad-hoc 签名，身份不同 → 钥匙串要重新授权。
  - **ad-hoc 签名的 DR 是 cdhash 型的**（`cdhash H"06e3e8..." or cdhash H"bb8f80..."`），
    重签一次 cdhash 就变，钥匙串里授过的权随之失效 → 以后每次重建都会再弹。
  - 解法：**点「Always Allow」（不是「Allow」）**，之后就不再弹；并且让
    `build` 变成**幂等**的 —— 副本已是最新就不重建，签名保持不变，
    只有原版更新或补丁改动才重建（那时再点一次即可）。已加 `--force` 强制重建。
  - 试过但放弃的方案：① 用 `codesign -r` 换成 identifier 型的稳定 DR
    （安全分类器拦下，也确实会削弱 macOS 的代码身份校验）；
    ② 用 `security` 命令行改钥匙串 ACL 批量授权（实测会 "User canceled"，不可靠）；
    ③ 给副本独立一份 safe storage（会和原版共用 Cookies 文件 → 原版也会掉登录）。
- 副本当前状态：主程序 + 4 个 Helper 全部 ad-hoc 签名，授权与原版逐项一致；
  `app.asar` 只改了 `preload.js` 一个条目；原版 `app.asar` 哈希
  `f24ce870…` 与基线一致。
- 仍未做：专门挑 H.266 新视频验证「关掉 H.266 不会让某些视频变差」。
- ProxyLauncher 仍 #38：本轮只改 `tools/douyin-hq.py` 与文档，未改 Swift/C，
  无新启动器构建；未提交、未合并。

---

## 22:10 工具化 + 修掉「加载中」：签名身份不一致导致网络服务崩溃

- 按用户决定的方向把方案产品化为**仓库内独立脚本**（不整合进启动器主程序）：
  新增`tools/douyin-hq.py`（build/status/launch/verify/remove）与
  `NOTES-抖音高画质模式.md`。副本用`cp -c`（APFS clone）克隆到
  `~/Applications/Douyin-HQ.app`，788MB几乎不额外占空间；只改副本`app.asar`里
  `preload.js`一个条目；每一步核对原版`app.asar`哈希不变；工具不删除任何东西。
  硬件信息伪装按用户决定暂时搁置（只订正了README里「伪装解锁4K」的错误表述）。
- 用户实测第一版副本**一直显示「加载中」**。归档里17:05那轮的「加载中」病因不同
  （那次是注入dylib导致GPU `Failed to create context`）；这次排查：
  - 排除dylib注入：`lsof`确认副本进程里没有加载`libhwspoof.dylib`；
  - 排除代理：verge-mihomo 7897在跑且可连，缓存里有21:59/22:01的新条目；
  - 定位到日志里`ERROR:content/browser/network_service_instance_impl.cc:613]
    Network service crashed, restarting service.`，紧随两条
    `[ArgusSDK] ... fetchAndSetOnlineConfig Error: net::ERR_FAILED`；
    成功那轮（18:43）的console.log里`Network service crashed`出现 **0 次**。
  - 根因：**主程序改成ad-hoc签名后，4个Helper还是字节的开发者签名**，
    父子进程签名身份不一致（原版主程序和Helper都是JH23ZR9LF5，字节把整包用
    自己Team ID重签过），Electron的网络服务子进程起不来。
  - 修法：主程序+4个Helper一起重签成ad-hoc，**授权原样照抄原版、不新增任何**
    （中途试过加`allow-dyld-environment-variables`被安全分类器拦下，拦得对，
    确实不需要）。
- 顺带加固：`launch`默认清掉环境里的`DYLD_*`（副本主程序沿用原版授权，本就含
  `allow-dyld-environment-variables`，残留`DYLD_INSERT_LIBRARIES`会把dylib塞进
  子进程，历史症状同样是「加载中」）；默认加`--enable-logging=stderr`（渲染进程
  console输出此前看不到）；日志按轮次轮转；启动后12秒自动自检
  （补丁装没装/网络服务崩没崩/有没有ERR_FAILED/GPU上下文）；
  新增`--net-log`、`--dry-run`、`--no-diagnose`。
- 22:14 重跑：副本**正常打开**，网络服务0次崩溃，日志确认补丁装上
  （`installed; HEVC=true`、`preload result={"installed":true,"hevc":true}`）
  且播放器的H.266能力检测确实走了改过的函数（`bvc2 capability disabled`）。
- 仍未做：副本里的2K/4K菜单复测、切4K后的实际分辨率（应3840×2160）、
  同副本`--baseline`因果对照、再抽3~5个视频。详见`NOTES-抖音高画质模式.md`第8节。
- ProxyLauncher仍#38：本轮只新增`tools/douyin-hq.py`与文档，未改Swift/C，
  无新启动器构建；未提交、未合并。

---

# 抖音 4K 画质排查 —— 交接文档

> 目标:让抖音 PC 客户端显示「超清 4K / 超清 2K」画质档位。
> 手段:伪装硬件信息(本仓库 ProxyLauncher 的「硬件信息伪装」功能)。
> 状态:**指定样本已验证恢复2K/4K**；方案目前在临时测试副本，尚未整合长期使用方式。原版未改，**未提交、未合并**。
> 最后更新:2026-11-08,构建号 #38。

---

## 18:43 实测成功：停用H.266优先后，同视频恢复2K/4K

- 用户运行bash /tmp/dy/test-client-h265.sh，确认同视频出现2K和4K选项。
  本轮/tmp/dy/h265-test-gKLZwo；日志确认补丁installed、HEVC=true、bvc2 capability disabled。
- 抽取同视频7690151208207584531的video_play_quality：最终bitrate_set_client包含
  adapt_lowest_4_1、adapt_lowest_1440_1、adapt_lowest_1080_1、adapt_lowest_720_1、
  adapt_540_1、adapt_lower_540_1。
- 过滤链已切到h265_filter → over_filter_h265_multi_clarity → h265_overall_filter，
  不再走h266_filter / h266_concat_mix。
- 实际播放上报2560×1440、gear=adapt_lowest_1440_1、is_hw=1、cpu_core=8。
  **已证实2K硬解播放和4K可选；尚未把菜单可选误称为4K实际播放。**
- 由此验证：该样本问题来自客户端H.266优先/混流路径，定向屏蔽bvc2可恢复已有H.265高档。
  与核数伪装无关；原机8核可用。没有改变原版/Applications/douyin.app。
- 证据/tmp/dy/7690151208207584531-comparison/patched-validation.json及更新comparison.md。
- 长期整合尚未做。当前有效方案仍是/tmp测试副本+预加载补丁；/tmp可被系统清理，
  应用更新后需重新制作副本。原版应用没有被“修复”，不可误报。
- 原版日志采集与测试日志均保留本地；不需要用户继续保持采集运行。
- ProxyLauncher仍#38，无Swift/C改动，无新启动器构建，未提交或合并。

## 已准备H.266定向关闭测试副本，等待用户实测

- 用户要求继续找解决方案。已在此前获准修改的/tmp测试副本中，对app.asar的preload.js
  加入最小补丁：仅让MediaSource.isTypeSupported对bvc2返回false，其他类型透传原函数。
  该结果直接阻止缓存模块360542的H.266分支门控；保留H.265/H.264、真实硬件参数。
- 兼容contextIsolation=true/false：隔离预加载时用contextBridge.executeInMainWorld同步安装，
  非隔离时直接安装；桥接API不可用则记录失败，不扩大范围或继续改写其他能力。
- 补丁在原preload的native SDK初始化之前执行。除preload.js条目外，ASAR中原始条目元数据、
  全部旧payload字节保持不变；替换preload追加在末尾，更新该条目的SHA256完整性信息。
- 工具：tools/douyin-h266-preload.cjs、tools/prepare-douyin-h266-test.py。
  原ASAR备份/tmp/ProxyLauncher-Douyin-4K-Test/app.asar.before-h266-test；manifest同目录。
- 测试副本已重新ad-hoc签名并通过codesign --verify --deep --strict。
  原版ASAR SHA256仍f24ce87054195831a267da006b1b2d227f9b1a1b22d2399ec33a024faf9ebddb，
  原版主程序及所有Helper签名摘要与最初记录一致。未启动任何应用。
- 临时Node VM测试覆盖：隔离/非隔离两路径、H.265/H.264保持、未知编码保持、原始错误透传、
  属性描述符保持、重复安装幂等、桥接缺失不破坏原能力、baseline开关；全部通过。
  测试脚本/tmp/dy/test-h266-preload.cjs。
- 用户手动运行：bash /tmp/dy/test-client-h265.sh。脚本拒绝已有抖音主进程，固定直启副本，
  清除DYLD_INSERT_LIBRARIES，不注入硬件伪装；本地console及NetLog保存在/tmp/dy/h265-test-*。
- 对照组：完全退出后运行 bash /tmp/dy/test-client-h265.sh --baseline，
  同一副本/用户数据/真实硬件、仅不安装bvc2屏蔽。由用户决定何时做对照，不自动启动。
- **尚未完成真实客户端验证，不能宣称已修复。** 若补丁安装成功，需查看同视频菜单和
  bitrate_info_record确认已切H.265、2K/4K进入最终列表，再视情况整合启动器。
- ProxyLauncher仍#38：本轮是独立诊断副本与脚本，未修改Swift/C或应用打包资源，无新启动器构建。
  未提交、未合并；原版抖音文件不改。

## 已定位固定样本客户端过滤点：H.266优先与混流策略

- 用户按脚本运行原版客户端，PID24785，NetLog已成功记录；原版未改签名，无dylib注入。
- netlog.json运行时仅421字节说明文件，实际分片在
  /var/folders/mv/gds1k1496xn6t2g7xjy6g1500000gn/T/.com.bytedance.douyin.desktop.scoped_dir.F3vmhB。
  已复制约100MB完整分片到/tmp/dy/client-network-AVk2Qb/snapshot，避免轮转丢失。
- 解析source2611的URL_REQUEST_JOB_FILTERED_BYTES_READ，重组27个块/1459686字节，
  得到/aweme/v1/web/general/search/stream/的目标视频条目：27条码流，有4K/2K H.265。
- 解析SSL_SOCKET_BYTES_SENT的HTTP/2 DATA帧及JSON播放上报，获得同一视频video_play_quality。
  bitrate_set_client仅4条：adapt_540_2、adapt_lower_540_2、adapt_lowest_720_2、adapt_lowest_1080_1。
- bitrate_info_record明确：h266_filter从27缩到6条（无2K/4K），再缩3条DASH；
  H.265分支的白名单后依然保留2K/4K；h266_concat_mix却仅补入H.265 1080P，最终4条。
- 客户端同时上报is_supported_265=1 / is_265_degrade=0 / is_supported_hevc1_hw=1 / is_hw=1，
  实际视频1920×1080、gear=adapt_lowest_1080_1、cpu_core=8。不是服务端没下发，也非完全不支持HEVC。
- 缓存模块360542的H.266门控涉及useClientH266与MediaSource.isTypeSupported(bvc2...)。
  混流代码存在BitrateSelector.fix_concat.fix_h266_2k4k_mode和fix_h266_1080_mode。
  日志与只补1080P策略吻合，但尚未直接提取实际AB值或完成禁用H.266的验证。
- 报告与精简证据/tmp/dy/7690151208207584531-comparison/。下一步应测试H.266优先/混流配置，
  不继续盲改核心数。原版未修改、未自动启动/关闭用户应用、无新构建、未提交。

## 网页现场已读到固定样本的4K，待采客户端实际网络

- 用户手动开启Chrome Allow JavaScript from Apple Events后，只读脚本执行成功。
  目标标签页7690151208207584531的MediaSource HEVC支持检测为true。
  主视频videoWidth/videoHeight为3840×2160（当时paused=true）；另有预加载video元素。
- 从document.scripts解析self.__pace_f.push中的百分号编码JSON及RSC JSON，
  得到服务端首屏内嵌的app.videoDetail（不是单独aweme/detail原始接口响应）。
  21条码流，含4K mp4/dash 3840×2160和2K mp4/dash 2560×1440，均H.265。
- 数据保存/tmp/dy/7690151208207584531-web-live.json；
  只读诊断脚本read-chrome-target.py、target-basics.js、target-extract-video.js。
  未改写DOM、JS环境、请求或设备参数，没有重新发送请求。
- 该页是SSR首屏携带视频数据，解释了为何单独详情响应不在磁盘API缓存；
  浏览器Apple Events读取的上下文中页面JS自有属性未暴露，DOM内嵌数据读取成功。
- 客户端同视频实际响应仍未知。已准备/tmp/dy/capture-client-network.sh，
  **尚未执行**，由用户完全退出客户端后手动运行，直启原版、清除dylib注入环境，
  使用Chromium标准log-net-log / net-log-capture-mode=Everything，日志上限100MB。
  Electron Framework中已确认包含这些日志开关；仍须实测抖音是否产生日志。
  不能提前承诺日志一定包含可还原的主体响应或TTNet独立网络栈流量。
- 本轮仅/tmp脚本与笔记变化，无新启动器构建；不自动启动用户应用。

## 固定差异样本7690151208207584531，改为检查现场

- 用户澄清Purrge网页仍最高1080P，不能称开启加速后所有视频都有4K。
- 用户提供新的两端菜单差异样本7690151208207584531，并确认两端均播放。
- 重扫Chrome与客户端缓存（含新增zstd解压）仍没有该视频主体详情响应。
  Chrome只找到带其ID的related、suggest_words、following seen等旁路请求。
  缓存未找到响应不能推断客户端未下发高画质，停止要求用户反复播放碰缓存。
- 通过只读AppleScript确认Chrome当前目标标签：
  https://www.douyin.com/jingxuan?modal_id=7690151208207584531，
  标题“喵言喵语～喵吃月饼 #小姐姐 #中秋节 #旗袍”。实际仍为精选弹层。
- CUA浏览器连接仍超时；只读AppleScript获取URL/title成功。
  执行页面只读JS被Chrome明确阻止：Allow JavaScript from Apple Events未开启。
  未修改设置；已询问用户是否愿意临时开启，以便直接读现场的码流/HEVC状态，
  备选为用户手动导出网络响应。诊断表达式只读，不发送请求或改写页面。
- 请求与菜单尚未完成同视频两端比较，不声明原因已找到。

## 后续：网页与客户端同视频仍有档位差异

- 用户报告开启Chrome图形加速后，所测网页视频都出现2K/4K，同视频客户端最高1080P。
  尚未将此现象推广为所有抖音视频；已询问Purrge视频是否也复测，以验证响应前后差异。
- Chrome最新详情请求（18:04/18:08）support_h265由0变1，support_dash=1、8核；
  创哥视频仍25条、含2K/4K，已证实这条是网页本地检测/菜单变化而非新增服务器码流。
- 当前客户端运行原版/Applications/douyin.app；18:05后客户端缓存97条相关请求
  都上报support_h265=1、support_dash=1、8核。因此不能把客户端档位缺失
  直接归因为“不支持H.265”，也不能照搬Chrome开关。
- Purrge客户端响应仍未在Chromium缓存找到；原版客户端没有Local State图形加速字段，
  Preferences中也未见对应字段。无证据表明客户端图形加速关闭。
- Chrome最新持久化HEVC检测为has_detect=true / is_support=false / pure_support=true
  （sequence37192），即pure_support相比开关前改变，但is_support仍false。
  网页此时仍有4K，因此不能单独把is_support=false当作4K菜单门槛；尚需实际调用链定位。
- 下一步固定一条用户确认网页有、客户端无的视频，分清客户端未下发与本地过滤。
  不盲加GPU启动参数、不删除客户端缓存或改设置。

## 已确认：Chrome图形加速影响创哥视频的4K菜单

- 用户开启Chrome “Use graphics acceleration when available” 后刷新创哥视频，
  **网页端出现4K选项**。此前同一视频的服务端响应已有4K/2K，但菜单仅1080P。
- 这轮对照支持：Chrome图形加速关闭及网页HEVC能力检测是该视频网页端缺少4K档位的原因。
  高分辨率流全部为H.265；此前Chrome持久化检测为不支持HEVC。
  本次尚未重新测量实时HEVC API或确认实际播放分辨率，仅确认用户看到4K选项。
- **此成果与ProxyLauncher核数伪装无关。** 此前8核Chrome响应也已有4K码流；
  原生抖音客户端原本就能为部分精选视频显示4K。没有证据表明硬件伪装解锁过新档位。
- Purrge视频7705248118586439163的新video_page响应仍21条、最高1080P；
  开启图形加速不能据此保证它出现4K。需重新查看其响应/菜单才能作新判断，
  不能把“当前未下发”当作“服务器绝对没有4K源”。
- 不再以“Mac 8核不达标”为排查前提：已找到fR()源码，Mac门槛为>=8。
- 启动器仍#38，未改Chrome设置（由用户手动开启），未修改原版抖音，未提交/合并。

## 17:57 后续补采与网页菜单新线索

- 用户刷新4K视频后，video_page /19.5.0 /support_dash=1已和Purrge对齐，
  除视频ID、时效性/会话签名外已比对查询参数一致。API子域仍不同：4K为www，Purrge为www-hj。
  代表4K缓存10d88b17f40a20bd_0，Purrge缓存434bb042f1997d83_0。
- 用户截图确认：创哥视频虽然响应25流含2K/4K，但Chrome网页菜单最高1080P。
  必须区分网页和客户端；先前客户端能选4K不表示网页也可。
- 两档高分辨率流均为H.265。已只读检查Chrome Local State：
  hardware_acceleration_mode.enabled=false，previous=false。
- Chrome抖音origin最新持久化HEVC检测为
  {"has_detect":true,"is_support":false,"pure_support":false}。
  通过解析LevelDB块（含Snappy）及WAL按序列取最新值，sequence26830；
  未更改浏览器存储或设置。解析脚本/tmp/dy/read-hevc-storage.py。
- 缓存源码有HEVC检测与回退逻辑。这是解释网页隐藏高分辨率流的强线索，尚未测量
  当前页面实时能力或验证开启图形加速后的菜单变化，不宣称因果已确认。
- 报告与补采摘要：/tmp/dy/same-entry-comparison/browser-menu-finding.md、latest-findings.json。

## 17:56 同入口补采进行中

- 用户要求保证请求入口一致，不能继续用 video_page 与 quick_player 混合比较。
- 已直接从Chrome缓存补采到Purrge视频7705248118586439163的 `video_page` 响应，
  业务版本19.5.0、8核、device_memory16，与4K视频旧请求对齐。
  代表缓存文件 `434bb042f1997d83_0`；主机www-hj.douyin.com。
- Purrge新响应21条码流，gear/format/bit_rate/is_h265/width/height与原quick_player
  响应逐项完全相同，最高1920×1080。
- 对比同主机4K视频旧请求（72ad18e24a87292b_0），忽略视频ID和时效性/会话签名参数后，
  仅剩support_dash：4K旧请求0，Purrge新请求1。尚不声称完全控制变量。
- 已请用户在同一Chrome窗口刷新4K视频标准页，补采新的support_dash=1请求再比较。
- 自动整理脚本 `/tmp/dy/compare-same-entry.cjs`，候选响应、参数清单、匹配分组保存在
  `/tmp/dy/same-entry-comparison/`。只读缓存，不重放或修改带签名请求。

## 用户纠正与两条视频同浏览器详情响应对比

- 用户明确指出，部分精选视频在原机本就有4K。视频7705283457831701794显示并切换4K
  **不能归因于伪装方案**。目标尚未完成，没有证据证明伪装解锁过画质。
- 对照视频7705248118586439163（RabbittuX：我把Purrge APP做出来啦）已在两端播放。
  抖音客户端缓存未定位到它；Chrome缓存找到详情响应，21条码流最高1920×1080。
- 又找到高画质视频7705283457831701794在Chrome的同一详情接口响应：25条码流，
  比前者多2条4K（mp4/dash，3840×2160）和2条2K（mp4/dash，2560×1440）。
- 两请求同为 `www.douyin.com/aweme/v1/web/aweme/detail/`，Chrome156、MacIntel、
  cpu_core_num=8、device_memory=16、屏幕1920×1080。注意Chrome此处memory=16，
  历史笔记“Chromium一律封顶8”也不适用于当前Chrome；Electron响应上报仍为8。
- 请求并非完全同条件：support_dash前者（4K）0、后者1；support_h265均0，
  但两份响应实际上都有H.265与dash。不能直接把查询支持参数当实际码流能力。
- 两响应status_code均0；后者无4K/2K是服务端响应中的差异，不是已观测到的菜单隐藏。
  video.width/height分别3840×2160和1920×1080，但不是上传源文件分辨率的证明。
- 不能仅凭不同视频比较，确认后一条服务器上是否另有4K，或具体哪项分发策略造成差异。
- 对比报告与完整响应保存 `/tmp/dy/4k-vs-1080p/`，不提交含用户信息的原始响应。

## 17:11 正常打开，14 核仍只有1080P；关键假设已被推翻

- PID 20501 是重签测试副本。`mode=sysctl` 的 Renderer 已加载 dylib；多个业务请求
  包括 `/aweme/v1/web/tab/feed/` 均上报 `cpu_core_num=14`。
- 用户确认本轮能打开，但最高仍1080P。console 没有 `Failed to create context`；
  重复类、`get pc_* failed` 等警告仍出现，故它们本身不必然导致卡住。
  本轮同时移除代理环境和 IOKit 改写，尚不能区分哪个变化解决了加载问题。
- **修正缓存提取器：stream 1 EOF 的 stream_size 字段有时为0，不能据此跳过该 entry。**
  修正后608个候选解出595份 JS，终于找到模块38918，文件
  `/tmp/dy/web4/3786cf900bf5ff85_0.js`。
- **fR()真实逻辑**：has2K 实验开关为真则通过；否则 Windows 核数 >8、
  Mac（含 MacIntel）核数 >=8、Ohos 核数 >=8。M2 真值8核已满足此条件。
  原文“M2卡在>8门槛”“只差核数”是错误推测，不能再作为后续决策依据。
- 推荐接口响应 status_code=0，6个视频中一条 ID `7705283457831701794` 明确下发
  `adapt_lowest_4_1`（3840×2160）和 `adapt_lowest_1440_1`（2560×1440），
  两档都有 mp4/dash、H265，未见 HDR / manual_only 标记；4K码率约0.65Mbps。
  响应临时保存在 `/tmp/dy/feed-14.json`（含用户相关内容，不提交到仓库）。
- 已请用户固定在客户端测试该视频，以排除当前测试视频没有高码流的差异。
- 继续调查实际运行播放器版本、AB配置、白名单/码率/菜单过滤。缓存源中窗口裁剪
  的一条实现会主动保留 definition -1/-2，因此不能直接归因于屏幕1080P。
- 启动器仍 #38，本轮仅缓存工具与文档变更；未修改 Swift/C、未自动启动应用、未提交。

## 17:08 日志调查与后续自动采集

- 系统日志确认 17:08:17 收到正常退出事件，当前副本不在运行。
- 已查询该轮主进程、Renderer、GPU、网络进程相关 Unified Log；未找到可直接归因于
  加载卡住的崩溃/故障。记录提取到 `/tmp/dy/loading-system-errors.log`。
- 进一步核实：携带14核的两条 URL 路径是直播 `solution/resource/list` 和 `webcast/setting`，
  不是已确认的视频推荐/画质响应；不应据此声称视频画质接口已接受伪装。
- `log_sdk_v2.db` 实为 JSON 行文件，不是 SQLite；当前主要是 `_id` 残留，未获得有用错误。
  parfait alog 为二进制，直接读取没有可用明文错误。
- 已给专用脚本添加 stdout/stderr 自动采集，追加到
  `/tmp/ProxyLauncher-Douyin-4K-Test/console.log`，保留终端实时输出并记录每轮启动时间。
  后续用户只需手动启动，助手直接读完整终端日志，无需用户复制。
- 已存在的旧终端输出没有完整文件记录，无法从已退出进程追溯补采。

## 17:05 重签副本已成功注入，但卡在加载中

- PID 20053 为 `/tmp/ProxyLauncher-Douyin-4K-Test/douyin.app` 主程序；Renderer PID
  20071 / 20072 / 20078 均有 `loaded` 日志，GPU、network Helper 也成功加载 dylib。
- **17:05:43 缓存中已发现两条 `cpu_core_num=14` 请求**：网页核数改写这一硬指标首次达成。
- 用户反馈一直“加载中”，终端报 GPU `ContextResult::kFatalFailure: Failed to create context.`。
  尚不能断言 GPU 报错就是加载失败原因；未发现新的 macOS 崩溃报告。
  渲染/网络进程采样保存在 `/tmp/dy/{renderer,network}-loading.sample`。
- 发现首轮专用脚本错误地添加了代理环境，原配置 `injectProxyEnvironment=false`、
  `chromiumProxyEnabled=false`。已纠正脚本，显式清除大小写代理环境。
- 同一脚本下一轮切换 `HWSPOOF_MODE=sysctl`，关闭 IOKit/GPU 属性改写、保留14核。
  这是针对 GPU 报错的兼容性验证，仍需用户完全退出副本后手动重启；没有自动启动应用。
- 本轮仅修改 /tmp 脚本和本笔记，启动器仍为 #38，无 Swift/C 源码变更。

## 17:01 本轮测试实际上启动了原版

- 用户报告启动后无 4K；进程 PID 19354 路径为 `/Applications/douyin.app/Contents/MacOS/抖音`。
  启动器保存的 apps 列表也只有 `/Applications/douyin.app`，没有测试副本。
- 新请求核数仍为 8，没有 Renderer 的 loaded 日志；本轮不能用来判断重签副本是否有效。
- 已生成 `/tmp/ProxyLauncher-Douyin-4K-Test/启动14核测试副本.command`，由用户手动运行。
  固定直启副本可执行文件、M4 Pro 14 核、24GB、子进程注入，沿用当前代理配置，禁用 CDP 路线。
  运行前检测是否仍有抖音主进程；不会自动退出原版或自动启动应用。
- 启动器仍为 #38；本轮没有修改 Swift/C 源码，无新 app 构建。

## #38 实测后续：CDP 不监听，准备重签测试副本

- 用户实测：有 1080P，仍无 2K/4K。新缓存请求 `cpu_core_num=8`、`device_memory=8`。
- 16:55 启动时主进程 argv 已包含 `--remote-debugging-address=127.0.0.1`
  和 `--remote-debugging-port=62138`；运行中 curl 连接被拒绝，lsof 未发现监听。
  说明卡在调试服务开启之前，尚不能确定是哪层禁用了服务；并非已经注入后仍无高画质。
- 已按 Simple Cache 的 key 长度、stream 1 长度和 EOF 结构提取 JS：608 个 JS 候选中
  解出 277 份，仍未找到模块 38918。工具已保存为 `tools/extract-douyin-cache.cjs`，
  默认输出 `/tmp/proxylauncher-douyin-js`，不改动应用缓存、不打印缓存 URL。
- **用户明确允许“仅修改测试副本”后**，已创建
  `/tmp/ProxyLauncher-Douyin-4K-Test/douyin.app`。
  仅重签其 4 个 Helper 与主 bundle，保留原授权、hardened runtime，补上
  `allow-dyld-environment-variables` 与 `disable-library-validation`。
  其它内嵌 framework/dylib 未重签。
- 副本通过 `codesign --verify --deep --strict`；原版主程序及所有 Helper 的签名摘要
  与操作前一致。原版 `/Applications/douyin.app` 未修改。未启动测试副本。
- 注意：沙箱内 Security 信息读取可能缺少 entitlements，签名校验也可能误报原版无效；
  最终读取完整授权、重签和校验均在沙箱外完成，Helper 保留 allow-jit / unsigned memory。
- 下一步：完全退出原版，在启动器 #38 添加上述副本，选 M4 Pro 14 核、开启强制注入
  和子进程注入、关闭 CDP 覆盖，然后由用户启动并保持运行。
  检查 `hwspoof.log` 是否有副本 Renderer 的 `loaded` 行及新请求核数是否变 14。
- 测试副本沿用原 bundle ID，可能共享原版用户数据；不要同时运行原版和副本。
  `/tmp` 可被系统清理，不适合作为长期安装位置。

## 本轮续接（build #38）

- 已补齐 `DevToolsOverride` 日志，位置：`~/Library/Application Support/ProxyLauncher/devtools.log`。
  含启动端口、`/json/list` 结果、WebSocket 失败、指令发送/回应/超时、刷新前后核数及内存。
- CDP 改为按回应顺序执行：`Page.enable` → 注册新文档脚本 → 当前文档执行脚本并验证读回值
  → 记录 navigator → `Page.reload`。每个 target 每次启动最多自动刷新一次，重连不反复刷新。
- 注入异常、CDP 错误或读回验证失败会记录并重试，不刷新页面。刷新后的 `Page.loadEventFired`
  会再读回 navigator；脚本不再吞掉 JS 异常。
- 使用串行队列和 timer，清理旧 session；旧请求回调不会污染新启动。
- 界面提示自动刷新可能中断播放。README 移除了“伪装不一致导致收回 1080P”的未验证断言。
- build.sh 在工具链准备失败时立即停止，避免继续报 `SWIFTC: unbound variable`。
- 验证：本地模拟 CDP 成功路径（顺序执行、仅一次刷新、刷新前后读回）和验证失败路径
  （不刷新）均通过；完整构建、ad-hoc 签名校验、`git diff --check` 通过。
  C 组件仍有两处原有 const 限定符警告。
- **尚未启动抖音实测。** 下一步由用户完全退出抖音，再用 #38 开启本地调试覆盖启动，
  固定同一视频测试。随后检查新日志和新请求的 `cpu_core_num`；4K 是否恢复仍待验证。
- 本文后续 #35 的现状分析保留为历史背景；“一行日志都没有/没有 reload”已由本轮修复。
- 未提交、未合并、未重签抖音。

## 1. 一句话现状

**以下为 #35 历史判断，已被 17:11 实测与源码纠正，请优先看顶部续接记录。**

伪装**已经做到位了**(机型/芯片/核数/内存/GPU 型号/P-E 核拆分全部自洽),
但抖音网页端读到的 `navigator.hardwareConcurrency` 仍然是 **8**(真值),
于是它把 4K/2K 档位过滤掉了。**卡点只剩一个:改不动渲染进程里的 JS 环境。**

---

## 2. 已确认的事实(都做过实测,别重复踩)

### 2.1 抖音客户端上报给服务器的全部设备信息

从 `~/Library/Application Support/抖音/Cache/Cache_Data/` 里提取 12 万条请求的
query 参数聚合得到。**注意这些 URL 是明文存在缓存里的**,是最可靠的一手证据:

```
cpu_core_num      = 8          ← navigator.hardwareConcurrency
device_memory     = 8          ← navigator.deviceMemory(Chromium 封顶 8)
hardware_concurrency = 8
screen_width/height = 1920x1080
browser_platform  = MacIntel   os_version = 10.15.7
pc_libra_divert   = Mac        support_h265 = 1   support_dash = 1
```

**参数全集里没有任何机型 / 芯片 / GPU 字段。**
服务器只能靠 **核心数、内存、屏幕分辨率**分档。

原生 SDK 侧另有一组(`device_platform=mac&app_name=tt_electron`):
`num_cpus=8`、`os_version=14.8.9`(真实 macOS 版本)、`device_id`、`electron_version`。

### 2.2 抖音网页端怎么决定给不给 4K

已把 sscronet 网络缓存(`TTNetCache/disk_cache`)里的 gzip 网页 JS 全部解压,
在 `pages/player` 相关 chunk 里读到了画质判定链。**档位定义**(模块 969526):

| 档位 | definition | qualityType | gear_name |
|---|---|---|---|
| 超清 4K HDR | -3 | 30 | — |
| 超清 4K | -2 | 20 | `adapt_lowest_4_1` |
| 超清 2K | -1 | 10 | `adapt_lowest_1440_1` |
| 高清 1080P | 1 | 5 | `normal_1080_0` |
| 高清 720P | 2 | 4 | `normal_720_0` |
| 标清 540P | 3 | 3 | `normal_540_0` |

过滤链(模块 301426 + 725545):

```
服务端返回 bitRateList
 → 去掉 manualOnly 的档位
 → 去掉 HDR 档位(除非 matchMedia("(dynamic-range: high)") 成立)
 → 按 gear_name 白名单过滤
     白名单默认 ["normal_1080_0","normal_720_0","normal_540_0"]
     ★ 设备达标时才追加 "adapt_lowest_1440_1"、"adapt_lowest_4_1"
 → 按码率过滤 quality_filter(上限默认 2 Mbps)
 → 按播放器窗口尺寸裁掉用不上的档位
```

**★ 关键开关(模块 38918 的 `fR()`,目前没拿到源码)**:

```js
if (fR()) p = p.concat(["adapt_lowest_1440_1", "adapt_lowest_4_1"]);   // 白名单加 4K/2K
W = () => fR() ? { bitrateUpper: 2e7, bitrateRange: [2e5, 25e6] } : {}; // 码率上限 2→20 Mbps
```

`fR()` 就是「高性能设备」判定。**模块 38918 不在缓存里**(见 §5.3),源码还没拿到。

同包里其它地方判断高性能的写法可以佐证阈值量级:

```js
// pages/player chunk,预加载逻辑
(0,ep.DT)() && navigator.hardwareConcurrency > 8 && (delay = 0)

// H.265 硬解支持判定
let n = navigator.hardwareConcurrency;
if (n && n >= 8) return true;
```

⇒ **M2 Mac mini 正好 8 核,卡在 8 / >8 这条线上;M4 是 10 核。**
所以「报 14 核」大概率能翻过 `fR()`。

客户端还会把 `cpu_core`(= `navigator.hardwareConcurrency`)、`memory_size`、
`UA_info`、`webdriver` 写进播放日志上报给服务器,服务器也会拿这些分档。

### 2.3 渲染进程注入不进去的硬原因(签名)

| 进程 | 签名 | `allow-dyld-environment-variables` |
|---|---|---|
| `抖音.app` 主程序 | hardened runtime | ✅ 有 → 能注入 |
| `抖音 Helper (Renderer)` | hardened runtime | ❌ **没有** |
| `抖音 Helper (GPU)` | hardened runtime | ❌ 没有 |
| `抖音 Helper`(zygote) | hardened runtime | ❌ 没有 |

**dyld 对「硬化运行时 + 缺该授权」的进程直接无视 `DYLD_INSERT_LIBRARIES`。**
所以 dylib 注入永远进不了渲染进程 → `navigator.hardwareConcurrency` 改不了。

日志能证明注入动作确实发生了、但进程没加载:
`spawn child .../抖音 Helper (Renderer).app/... (注入 dylib)` 有记录,
但 `loaded pid=... exe=.../抖音 Helper (Renderer)` **一条都没有**。

抖音主程序**没开 App Sandbox**(entitlements 里 `app-sandbox=false`),
Helper 也没有;Chromium 自己的 Seatbelt 沙箱允许读**用户目录**
(`(allow file-read* file-write* (subpath (param darwin-user-dir)))`),
所以 dylib 放到 `~/Library/Application Support/` 是能被沙箱里��渲染进程读到的
——**但前提是能注入,而注入被授权挡住了。**

### 2.4 最近几次实测结果

| 构建 | 做了什么 | 结果 |
|---|---|---|
| #13 | 改 GPU 代次串(G14→G16) | 无 4K |
| #19 | 补齐 GPU 芯片组型号/P-E 核/板级 ID 等 | **只剩 720P**(回归) |
| #30 | 给子进程塞 `DYLD_INSERT_LIBRARIES` | 回到 1080P(但渲染进程仍没注入) |
| #35 | 加 DevTools 本地调试端口覆盖 | **只剩 720P**,且 `cpu_core_num` 仍是 8 |

**⚠ 方法论坑:每次测的是不是同一个视频?** 服务端按视频下发不同的码流列表,
跨视频比较「画质菜单」是不可靠的。**后续必须固定同一个视频对比。**

---

## 3. 本仓库已实现的东西

### 3.1 伪装 dylib(`Sources/hwspoof.c`)

进程内拦截,靠 `__DATA,__interpose` 段。覆盖:

- `sysctlbyname`: `hw.model` / `machdep.cpu.brand_string` / `hw.ncpu` /
  `hw.logicalcpu(_max)` / `hw.physicalcpu(_max)` / `hw.activecpu` /
  `hw.nperflevels` / `hw.perflevel0|1.logicalcpu` / `hw.packages` /
  `hw.memsize` / `hw.targettype`
- `sysctl(mib)`: `CTL_HW` 的 `HW_NCPU` / `HW_AVAILCPU` / `HW_TARGET` / `HW_PRODUCT` / `HW_MEMSIZE`
- IOKit: 平台节点 `model`(CFData→型号标识)、GPU 节点 `model`(CFString→芯片名)、
  GPU 代次键(`MetalPluginName` / `MetalPluginClassName` / `MetalStatisticsName` /
  `IOClass` / `CFBundleIdentifier` / `CFBundleIdentifierKernel` / `IOPersonalityPublisher`)
- `posix_spawn` / `execve`:改写 `ioreg`/`sysctl`/`system_profiler` 的绝对路径
- `posix_spawn` / `execve`:把 `DYLD_INSERT_LIBRARIES` + 全部 `HWSPOOF_*` 塞回子进程环境
  (开关 `HWSPOOF_INJECT_CHILDREN=1`)

日志:`~/Library/Application Support/ProxyLauncher/hwspoof.log`,
每行带 `[MM-DD HH:MM:SS]` 时间戳,`loaded` 行里有 `exe=` 进程路径。

### 3.2 命令行替身(`Sources/bin/`)

`ioreg` / `sysctl` / `system_profiler` 是 Apple 平台二进制(带 `__RESTRICT`),
dylib 注入进不去,只能 PATH 替换。三个脚本现在伪装:

- `system_profiler SPHardwareDataType`:Model Name / Model Identifier / Chip /
  Total Number of Cores(P+E 拆分)/ Memory / Serial / UUID
- `system_profiler SPDisplaysDataType`:`_name` / `sppci_model` / `sppci_cores`
  (即 **GPU 芯片组型号和 GPU 核心数**,实测本机真值是 `Apple M2` + `10`)
- `ioreg -c IOPlatformDevice -d 3 -r`:逐核 `cluster-type`(P/E)并按目标核数增减节点
- `ioreg -c IOPlatformExpertDevice -d 2`:`model` / `compatible`(板级 ID)

### 3.3 注入位置的坑

dylib **必须**放在 `~/Library/Application Support/ProxyLauncher/` 再注入
(Chromium 沙箱里的渲染进程读不到 `~/Documents` 下的文件,dyld 会直接杀掉进程)。
`HardwareSpoofRuntime.prepareDylib()` 负责复制。

### 3.4 DevTools 覆盖(`Sources/DevToolsOverride.swift`,build #35 新增)

- 启动目标应用时带 `--remote-debugging-address=127.0.0.1 --remote-debugging-port=<随机端口>`;
- 本工具用 DevTools 协议连上去,给每个 page target 发
  `Page.enable` / `Page.addScriptToEvaluateOnNewDocument` / `Runtime.evaluate`,
  注入的脚本只改 `Navigator.prototype` 上的 `hardwareConcurrency` 和 `deviceMemory`;
- 全部异步,回调跑在自己的 `OperationQueue` 上,不依赖主线程 run loop。

**当前状态:实测没生效**(16:44 那次 `cpu_core_num` 仍是 8),原因待查,见 §4.1。

### 3.5 Swift 侧

- `HardwareSpoof`:model / chip / targetType / modelName / cores / pCores / eCores /
  gpuCores / memoryGB / force / keepEnv / gpuGen / devToolsOverride
- `HardwareSpoofPreset`:8 个预设(M4 Pro / M5 Pro / M4 / M6),P-E 核与 GPU 核都取真机数据
- 界面在每个应用的「启动设置…」里,三个关键开关:
  - 强制注入(Electron 应用必需)
  - 让子进程也注入(设 `HWSPOOF_INJECT_CHILDREN=1`)
  - 用本地调试端口改网页参数(设 `HWSPOOF_INJECT_CHILDREN` 之外的 DevTools 通路)

---

## 4. 下一步(按优先级)

### 4.1 先定位 DevTools 覆盖为什么没生效(最省力)

现在 `DevToolsOverride` **一行日志都没有**,无法判断卡在哪一环。先加日志:

- 连上调试端口了吗?(`/json/list` 有没有拿到 target)
- WebSocket 握手成功了吗?
- 三条指令发出去、收到回应了吗?
- `Runtime.evaluate` 的返回值里 `navigator.hardwareConcurrency` 是多少?

三种可能原因,按概率排:

1. **注入时机太晚**:页面早就加载完、SDK 启动时就把设备参数算好缓存了。
   → 注入成功后补一条 `Page.reload`(或 `Page.navigate` 到当前 URL),
   让整个页面在覆盖生效的前提下重新启动。**这一步很可能是正解。**
2. **抖音 Electron 不吃 `--remote-debugging-port`**(有些 App 会主动禁用)。
   → 检查 `http://127.0.0.1:<port>/json/version` 能不能通;
   不通就换方案。
3. **页面在 iframe / worker 里**,`Runtime.evaluate` 没打到正确的执行上下文。
   → 用 `Runtime.evaluate` 的 `contextId`,或改用
   `Page.addScriptToEvaluateOnNewDocument` + reload。

验证指标(唯一硬指标):**请求里的 `cpu_core_num` 要变成 14**。
查法见 §6。

### 4.2 拿到模块 38918 的源码,确认 `fR()` 到底看什么

它在 sscronet 缓存里没有(见 §5.3)。两条路:

- **从网络抓**:抖音网页 chunk 是公开的。已知 chunk 是 webpack 打包,
  运行时里带 chunk id → 文件名的映射表;把映射表挖出来,把所有 chunk 下载下来
  grep `38918:function`。注意别用 `npx` 之类的外部包(会被权限拦),自己写脚本。
- **用刚才建好的 CDP 通路**:页面加载完之后,在 DevTools 里执行表达式
  直接问它要答案,比找源码快得多。例如在页面里找 webpack 模块表:
  ```js
  // 抖音是 webpack 打包,模块表通常挂在 window.webpackChunkdouyin_web 上
  Object.keys(window.webpackChunkdouyin_web||{})
  ```
  找到 chunk 数组后可以在页面里 require 出模块 38918,直接看 `fR` 的实现,
  甚至**直接调用它看返回值**。

**拿到之后**:
- 如果 `fR()` 看的确实是 `hardwareConcurrency` → 4.1 做完就成了;
- 如果它看的是别的(比如 GPU 型号、`deviceMemory`、某个 UA 特征)
  → 针对性再补。注意 `navigator.deviceMemory` 在 Chromium 里**封顶 8**,改不了更大。

### 4.3 固定测试视频,重做对比

服务端按视频下发不同码流列表,**之前的「有 4K / 没 4K / 只有 720P」结论可能混了视频差异**。
固定一个 4K 源视频(在 M4 MacBook Pro 上确认过有 4K 档位的那个),每轮只改一个变量。

### 4.4 如果 DevTools 路线走不通,备选

1. **给 Helper 重签名加授权**:对 `抖音 Helper*.app` 用
   `codesign --force --sign - --entitlements <带 allow-dyld-environment-variables>`。
   **会破坏整个 App 的签名**(要连带主程序一起重签),macOS 可能拒绝启动,
   抖音自己的完整性校验也可能报错,而且更新后会被覆盖。**动手前必须先问用户。**
2. **改 `DYLD_` 之外的路**:比如让 Electron 的渲染进程走非 hardened 的二进制 —— 基本不可行。
3. **改服务端看到的请求参数**:走 MITM 改 query。**a_bogus 是对整个 query 签名的,
   改了参数签名就废**;理论上可以用网页 JS 里现成的签名算法重新签,
   但工作量巨大且属于灰区,不建议。

---

## 5. 踩过的坑(别再踩)

### 5.1 dyld interpose

- `DYLD_INSERT_LIBRARIES` **不会**自动抢占符号,必须在 `__DATA,__interpose` 段里
  显式写「替换谁 / 替换成谁」。
- interpose 段**必须是数组**。写成单个 struct 变量时链接器不生成绑定重定位,
  段里是 0,dyld 静默忽略 —— 表现就是「dylib 加载了但函数没被换掉」。
- interpose 生效后 `dlsym(RTLD_NEXT)` 会拿到**自己**,调用即无限递归。
  用普通数据指针存原始地址。
- macOS **没有 `__sysctlbyname` 这个系统调用**(SDK 头文件里那个 274 其实是 `sem_post`)。
  透传要 `sysctlnametomib()` + `syscall(SYS_sysctl, ...)`。

### 5.2 替身脚本

- `exec cmd | awk` 在管道里**只替换子 shell**,主 shell 会继续往下跑 →
  `system_profiler` 被执行两次、输出夹了一份没改过的原始 XML。**不要在管道里用 `exec`。**
- plist XML 的键和值分两行,改写要记住「上一个 key」;
  键后面不是 `<string>` 时必须清状态,否则后面随便哪个 `<string>` 都会被误改。

### 5.3 缓存里拿不到的东西

- sscronet 缓存(`TTNetCache/disk_cache`):623 个文件里 **101 个是 gzip**(网页 JS,已解压到
  `/tmp/dy/web`),其余是视频/图片/索引。模块 38918 不在其中。
- Chromium 缓存(`Cache/Cache_Data`):22422 个文件,body 是 **brotli**(无文件头),
  纯 Python 批量解压失败;需要用 Node 的 `zlib.brotliDecompress` 流式解 + 正确的
  entry 结构偏移。
- Chromium 沙箱 profile 就在 `Electron Framework` 二进制里(`strings` 能看到),
  搜 `subpath` / `sandbox-policy` 能看到完整策略。

### 5.4 Swift / Foundation

- `URLSession` 回调默认投递到**主线程**,主线程被 `Thread.sleep` 占住就永远不回调。
  本项目的 `DevToolsOverride` 用独立 `OperationQueue`,且**不能**把
  `underlyingQueue` 设成轮询用的队列(轮询里的 sleep 会把队列占死)。
- SwiftUI `body` 表达式太长会报「unable to type-check this expression in reasonable time」,
  长字符串要抽成单独的计算属性。
- `build.sh` 用 `tools/prepare-toolchain.sh` 准备的**影子工具链**;
  直接 `xcrun swiftc` 会报 SDK/编译器不匹配。编译新文件记得同步改 `build.sh` 的源文件列表。

---

## 6. 常用命令

```bash
# 硬件伪装日志(带时间戳、进程路径、实际生效值)
tail -40 ~/Library/Application\ Support/ProxyLauncher/hwspoof.log
grep "^\[" ~/Library/Application\ Support/ProxyLauncher/hwspoof.log | grep loaded | tail -20

# ★ 硬指标:抖音请求里报的核数(应变成 14)
cd /tmp/dy && python3 - <<'EOF'
import os, re, datetime, collections
D = "/Users/lixinghui/Library/Application Support/抖音/Cache/Cache_Data"
agg = collections.Counter()
for fn in sorted(os.listdir(D)):
    p = os.path.join(D, fn)
    try:
        st = os.stat(p); head = open(p, "rb").read(16384)
    except Exception: continue
    mt = datetime.datetime.fromtimestamp(st.st_mtime)
    if mt < datetime.datetime(2026, 11, 8, 16, 30): continue
    for m in re.finditer(rb'https?://[!-~]{10,4000}', head):
        url = m.group().decode("latin-1")
        if "cpu_core_num=" not in url: continue
        g = lambda k: (re.search(k + r'=([\w.]+)', url) or [None, "?"])[1]
        agg[(mt.strftime("%H:%M"), g("cpu_core_num"), g("device_memory"))] += 1
for k, n in sorted(agg.items()):
    print(f"{k[0]}  cores={k[1]:>3} mem={k[2]:>2}  x{n}")
EOF

# 解压 sscronet 缓存里的网页 JS(画质判定逻辑都在这)
cd /tmp/dy && python3 - <<'EOF'
import os, zlib, gzip
D = "/Users/lixinghui/Library/Application Support/抖音/TTNetCache/disk_cache"
OUT = "/tmp/dy/web"; os.makedirs(OUT, exist_ok=True)
for fn in sorted(os.listdir(D)):
    p = os.path.join(D, fn)
    if not os.path.isfile(p): continue
    data = open(p, "rb").read(); dec = None
    if data[:2] == b"\x1f\x8b":
        try: dec = gzip.decompress(data)
        except Exception: dec = None
    if dec is None:
        try: dec = zlib.decompress(data)
        except Exception: dec = None
    if dec: open(os.path.join(OUT, fn + ".js"), "wb").write(dec)
EOF
grep -rl "adapt_lowest_4_1" /tmp/dy/web          # 画质档位相关 chunk

# 本地验证 dylib(不用启应用)
cd /tmp/sp && env HWSPOOF_MODEL=Mac16,6 HWSPOOF_CHIP="Apple M4 Pro" \
  HWSPOOF_NCPU=14 HWSPOOF_PCORES=10 HWSPOOF_ECORES=4 HWSPOOF_GPU_CORES=20 \
  DYLD_INSERT_LIBRARIES=<仓库>/dist/ProxyLauncher.app/Contents/Resources/libhwspoof.dylib \
  ./t

# 构建
./build.sh      # 产物 dist/ProxyLauncher.app,构建号自增
```

`/tmp/sp` 下的测试程序(`t` / `parent` / `child`)是这次搭的,`/tmp` 会被清掉,
需要时重建(源码在会话记录里)。

---

## 7. 文件清单

| 文件 | 作用 |
|---|---|
| `Sources/hwspoof.c` | 伪装 dylib:sysctl / IOKit / spawn / exec 拦截 |
| `Sources/bin/{ioreg,sysctl,system_profiler}` | 命令行替身(PATH 替换) |
| `Sources/DevToolsOverride.swift` | DevTools 协议客户端,改网页里的 JS 环境 |
| `Sources/main.swift` | 主程序:伪装配置、预设、界面、启动逻辑 |
| `Sources/LauncherStub.swift` | 生成的独立启动器 |
| `build.sh` | 构建 + 打包 + ad-hoc 签名,构建号自增 |
| `tools/prepare-toolchain.sh` | 影子工具链 |
| `README.md` | 已有「硬件信息伪装」章节,含画质判定链的说明 |

---

## 8. 约定

- **不要提交、不要合并**,等用户验证通过再说。
- 不要自动启动用户电脑上的任何应用(全局 CLAUDE.md 约束);功能测试由用户做,
  我们只读日志和缓存。
- 改完务必 `./build.sh` 并把构建号告诉用户,方便确认跑的是哪一版。
