import Foundation
import CryptoKit

/// 抖音「高画质模式」：让抖音 PC 客户端显示并播放 2K / 4K 档位。
///
/// ## 为什么需要它
///
/// 抖音服务端下发的码流里，2K / 4K 都是 H.265。但客户端本地判定「设备支持
/// H.266」后会优先走 H.266 分支，而这个视频的 H.266 码流最高只有 720P；
/// 混流阶段（`h266_concat_mix`）又只把 H.265 的 1080P 补回去 —— 4K / 2K
/// 就在这一步被丢掉了。
///
/// 两边对「支持 H.266」的认知不一致是关键：
///
///   * 点播请求里客户端**从不声明**自己支持 H.266（扫了 16 万条请求 URL，
///     只有 `support_h265=1`，没有任何 266 / vvc / bvc 相关的参数）；
///   * 直播请求里反而有 —— CDN 参数 `biz_vcodec` 的取值是
///     `bytevc1`（字节自己的 VVC 品牌名）886 次、`h265` 484 次。
///
/// 于是服务端按「你只支持 H.265」来配点播的 ladder：H.265 一路到 4K，
/// H.266 那条只给到 720P（0.3 Mbps）。客户端却按「本机能解 VVC」去选那条
/// 分支，结果用 720P 换掉了 4K。
///
/// ## 怎么办
///
/// 让页面里的 `MediaSource.isTypeSupported("...bvc2...")` 返回 false，
/// 客户端就会改走 H.265 分支，用上服务端早就下发好的 4K 码流。
/// 这跟硬件信息伪装没有关系 —— 实测真实 8 核同样能出 4K。
///
/// ## 实现方式
///
/// 在原版的**隔离副本**里，给 `app.asar` 的 `preload.js` 前置一段补丁
/// （`Sources/douyin-hq-preload.js`），再重签名。原版应用全程不动。
/// 完整调查过程见 `NOTES-抖音4K画质.md`，使用说明见 `NOTES-抖音高画质模式.md`。
enum DouyinHQ {

    // MARK: - 常量

    static let bundleIdentifier = "com.bytedance.douyin.desktop"
    static let originalURL = URL(fileURLWithPath: "/Applications/douyin.app")
    static let copyDisplayName = "抖音 HQ"
    /// 补丁要插在 preload.js 的最前面（preload 早于页面脚本执行）
    static let asarRelativePath = "Contents/Resources/app.asar"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyLauncher")
    }
    /// 副本放在应用自己的支持目录里，不往「应用程序」里塞东西
    static var copyURL: URL {
        supportDirectory.appendingPathComponent("apps/Douyin-HQ.app")
    }
    static var manifestURL: URL {
        supportDirectory.appendingPathComponent("douyin-hq-manifest.json")
    }

    // MARK: - 状态

    enum Status: Equatable {
        /// 找不到原版抖音
        case originalMissing
        /// 还没做过副本
        case notBuilt
        /// 副本与原版、补丁都一致
        case upToDate(version: String)
        /// 原版更新了或补丁改了，副本需要重建
        case outdated(version: String, copyVersion: String)
        /// 副本在，但内容对不上（被手工改过）
        case damaged(String)

        var text: String {
            switch self {
            case .originalMissing: return "找不到原版抖音（/Applications/douyin.app）"
            case .notBuilt: return "尚未制作副本"
            case .upToDate(let version): return "副本已是最新（抖音 \(version)）"
            case .outdated(let version, let copyVersion):
                return "副本需要重建（当前抖音 \(version)，副本是 \(copyVersion)）"
            case .damaged(let reason): return "副本异常：\(reason)"
            }
        }

        /// 副本能不能直接拿来启动
        var isUsable: Bool {
            switch self {
            case .upToDate, .outdated: return true
            default: return false
            }
        }
    }

    struct Manifest: Codable {
        var createdAt: String
        var originalPath: String
        var originalVersion: String
        var originalAsarSHA256: String
        var copyPath: String
        var patchedAsarSHA256: String
        var shimSHA256: String
        /// 副本制作逻辑的版本。改动了改写逻辑就 +1，
        /// 旧副本会被判定为「需重建」，不会带着老 bug 继续用。
        var builderVersion: Int

        init(createdAt: String, originalPath: String, originalVersion: String,
             originalAsarSHA256: String, copyPath: String, patchedAsarSHA256: String,
             shimSHA256: String, builderVersion: Int) {
            self.createdAt = createdAt
            self.originalPath = originalPath
            self.originalVersion = originalVersion
            self.originalAsarSHA256 = originalAsarSHA256
            self.copyPath = copyPath
            self.patchedAsarSHA256 = patchedAsarSHA256
            self.shimSHA256 = shimSHA256
            self.builderVersion = builderVersion
        }

        private enum CodingKeys: String, CodingKey {
            case createdAt, originalPath, originalVersion, originalAsarSHA256
            case copyPath, patchedAsarSHA256, shimSHA256, builderVersion
        }

        /// 老清单里没有 builderVersion，按 0 处理 —— 会被判定为「需重建」，
        /// 而不是读不出来变成「清单缺失」。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            createdAt = try c.decode(String.self, forKey: .createdAt)
            originalPath = try c.decode(String.self, forKey: .originalPath)
            originalVersion = try c.decode(String.self, forKey: .originalVersion)
            originalAsarSHA256 = try c.decode(String.self, forKey: .originalAsarSHA256)
            copyPath = try c.decode(String.self, forKey: .copyPath)
            patchedAsarSHA256 = try c.decode(String.self, forKey: .patchedAsarSHA256)
            shimSHA256 = try c.decode(String.self, forKey: .shimSHA256)
            builderVersion = try c.decodeIfPresent(Int.self, forKey: .builderVersion) ?? 0
        }
    }

    /// 当前制作逻辑的版本
    static let currentBuilderVersion = 2

    enum HQError: LocalizedError {
        case originalMissing
        case shimMissing
        case asarBroken(String)
        case commandFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .originalMissing: return "找不到原版抖音（/Applications/douyin.app）"
            case .shimMissing: return "应用里缺少补丁文件 douyin-hq-preload.js，请重新安装本应用"
            case .asarBroken(let reason): return "app.asar 解析失败：\(reason)"
            case .commandFailed(let cmd, let message):
                return "命令执行失败：\(cmd)\n\(message)"
            }
        }
    }

    // MARK: - 识别

    /// 这个路径是不是抖音
    static func isDouyin(at path: String) -> Bool {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let identifier = info["CFBundleIdentifier"] as? String {
            return identifier == bundleIdentifier
        }
        // 读不到 Info.plist 就退回按名字判断
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        return name == "douyin" || name == "抖音"
    }

    // MARK: - 状态查询

    static var status: Status {
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return .originalMissing
        }
        let copyExists = FileManager.default.fileExists(atPath: copyURL.path)
        guard copyExists else { return .notBuilt }
        guard let manifest = loadManifest() else { return .damaged("清单缺失") }
        let version = versionString(of: originalURL)
        let copyVersion = versionString(of: copyURL)
        do {
            let originalHash = try sha256(of: originalURL.appendingPathComponent(asarRelativePath))
            let copyHash = try sha256(of: copyURL.appendingPathComponent(asarRelativePath))
            let shimHash = try sha256(of: shimURL())
            if copyHash != manifest.patchedAsarSHA256 {
                return .damaged("副本内容与清单不符")
            }
            if shimHash != manifest.shimSHA256 {
                return .outdated(version: version, copyVersion: copyVersion)
            }
            if manifest.builderVersion != currentBuilderVersion {
                return .outdated(version: version, copyVersion: copyVersion)
            }
            if originalHash != manifest.originalAsarSHA256 {
                return .outdated(version: version, copyVersion: copyVersion)
            }
            return .upToDate(version: version)
        } catch {
            return .damaged(error.localizedDescription)
        }
    }

    static func loadManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - 制作副本

    /// 从原版做一个打了补丁的副本。
    ///
    /// 全程不修改原版：每一步都会核对原版 `app.asar` 的哈希。
    /// 也不会删除任何东西 —— 旧副本改名留档，由用户自己决定什么时候清。
    static func build(progress: ((String) -> Void)? = nil) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: originalURL.path) else { throw HQError.originalMissing }
        let shim = try shimData()
        let originalAsar = originalURL.appendingPathComponent(asarRelativePath)
        let originalHash = try sha256(of: originalAsar)
        let originalVersion = versionString(of: originalURL)

        try fm.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1) 克隆（cp -c 是 APFS 克隆：几乎不额外占空间，也很快）
        progress?("正在克隆抖音…")
        let stamp = timestamp()
        let staging = copyURL.deletingLastPathComponent()
            .appendingPathComponent("Douyin-HQ.app.new-\(stamp)")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        if !runOK("/bin/cp", ["-Rc", originalURL.path, staging.path]) {
            try? fm.removeItem(at: staging)
            try run("/bin/cp", ["-R", originalURL.path, staging.path])
        }
        defer { try? fm.removeItem(at: staging) }

        // 2) 注入补丁
        progress?("正在注入画质补丁…")
        try patchAsar(at: staging.appendingPathComponent(asarRelativePath), shim: shim)

        // 3) 改显示名，方便在 Dock / 访达里和原版区分
        progress?("正在设置副本显示名…")
        _ = try? run("/usr/bin/plutil", [
            "-replace", "CFBundleDisplayName", "-string", copyDisplayName,
            staging.appendingPathComponent("Contents/Info.plist").path,
        ])

        // 4) 重签名
        //    主程序和 4 个 Helper 必须一起签成 ad-hoc：只签主程序的话，
        //    父子进程签名身份不一致，Electron 的网络服务子进程会起不来
        //    （日志里是 "Network service crashed"，界面一直停在「加载中」）。
        //    只改签名身份，entitlements 一项不动（沿用原版的）。
        progress?("正在签名…")
        let frameworks = staging.appendingPathComponent("Contents/Frameworks")
        let helpers = (try? fm.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        for helper in helpers {
            let origin = originalURL.appendingPathComponent("Contents/Frameworks")
                .appendingPathComponent(helper.lastPathComponent)
            try sign(helper, entitlements: entitlements(of: origin))
        }
        try sign(staging, entitlements: entitlements(of: originalURL))

        // 5) 原版必须没被动过
        let originalHashAfter = try sha256(of: originalAsar)
        guard originalHashAfter == originalHash else {
            throw HQError.commandFailed("校验原版", "原版 app.asar 发生变化，已中止")
        }

        // 6) 就位：旧的改名留档，不删除
        if fm.fileExists(atPath: copyURL.path) {
            let backup = copyURL.deletingLastPathComponent()
                .appendingPathComponent("Douyin-HQ.app.old-\(stamp)")
            try fm.moveItem(at: copyURL, to: backup)
        }
        try fm.moveItem(at: staging, to: copyURL)

        // 7) 清单
        let manifest = Manifest(
            createdAt: timestamp(),
            originalPath: originalURL.path,
            originalVersion: originalVersion,
            originalAsarSHA256: originalHash,
            copyPath: copyURL.path,
            patchedAsarSHA256: try sha256(of: copyURL.appendingPathComponent(asarRelativePath)),
            shimSHA256: try sha256(of: shimURL()),
            builderVersion: currentBuilderVersion
        )
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        progress?("完成")
    }

    /// 删除副本（不动原版）
    static func removeCopy() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: copyURL.path) {
            try fm.removeItem(at: copyURL)
        }
        try? fm.removeItem(at: manifestURL)
    }

    // MARK: - ASAR

    /// 给 app.asar 里的 preload.js 前置补丁。
    ///
    /// 只动 preload.js 这一个条目：其余条目的元数据和原始 payload 字节保持不变，
    /// 新的 preload 追加在 payload 末尾（原字节留在原地、不再被引用）。
    static func patchAsar(at asarURL: URL, shim: Data) throws {
        let data = try Data(contentsOf: asarURL)
        let (header, payload) = try unpackAsar(data)

        guard var files = header["files"] as? [String: Any],
              var entry = files["preload.js"] as? [String: Any],
              let offset = intValue(entry["offset"]),
              let size = intValue(entry["size"]),
              offset >= 0, size >= 0, offset + size <= payload.count else {
            throw HQError.asarBroken("找不到 preload.js 条目")
        }
        let originalPreload = payload.subdata(in: offset..<(offset + size))
        if originalPreload.range(of: shim) != nil { return }   // 已经打过补丁

        let newPreload = shim + Data("\n".utf8) + originalPreload
        // 注意类型：原版 ASAR 里 size 是数字、offset 是字符串，Electron 读 size
        // 用的是数值取法 —— 写成字符串的话 preload.js 根本读不出来，
        // 补丁不生效（表现就是「副本能开，但没有 2K/4K」）。
        entry["offset"] = String(payload.count)
        entry["size"] = newPreload.count
        entry["integrity"] = integrity(of: newPreload)
        files["preload.js"] = entry
        var newHeader = header
        newHeader["files"] = files

        let newPayload = payload + newPreload
        let rebuilt = try packAsar(header: newHeader, payload: newPayload)

        // 自检：新包能解开、preload 内容正确、旧字节没被动过
        let (checkHeader, checkPayload) = try unpackAsar(rebuilt)
        guard let checkFiles = checkHeader["files"] as? [String: Any],
              let checkEntry = checkFiles["preload.js"] as? [String: Any],
              let checkOffset = intValue(checkEntry["offset"]),
              let checkSize = intValue(checkEntry["size"]),
              checkPayload.subdata(in: checkOffset..<(checkOffset + checkSize)) == newPreload,
              checkPayload.prefix(payload.count) == payload else {
            throw HQError.asarBroken("重打包后自检不通过")
        }

        try rebuilt.write(to: asarURL, options: .atomic)
    }

    static func unpackAsar(_ data: Data) throws -> (header: [String: Any], payload: Data) {
        guard data.count >= 16 else { throw HQError.asarBroken("文件太短") }
        func u32(_ offset: Int) -> UInt32 {
            let b = data.subdata(in: offset..<(offset + 4))
            return UInt32(b[b.startIndex]) | UInt32(b[b.startIndex + 1]) << 8
                 | UInt32(b[b.startIndex + 2]) << 16 | UInt32(b[b.startIndex + 3]) << 24
        }
        guard u32(0) == 4 else { throw HQError.asarBroken("不是 ASAR 格式") }
        let headerSize = Int(u32(4))
        let jsonSize = Int(u32(12))
        guard 16 + jsonSize <= 8 + headerSize, 8 + headerSize <= data.count else {
            throw HQError.asarBroken("头部长度对不上")
        }
        let json = data.subdata(in: 16..<(16 + jsonSize))
        guard let header = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw HQError.asarBroken("头部 JSON 解析失败")
        }
        return (header, data.subdata(in: (8 + headerSize)..<data.count))
    }

    static func packAsar(header: [String: Any], payload: Data) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: header, options: [])
        func u32(_ value: Int) -> Data {
            var d = Data()
            let v = UInt32(value)
            d.append(UInt8(v & 0xff))
            d.append(UInt8((v >> 8) & 0xff))
            d.append(UInt8((v >> 16) & 0xff))
            d.append(UInt8((v >> 24) & 0xff))
            return d
        }
        var stringData = u32(json.count)
        stringData.append(json)
        while stringData.count % 4 != 0 { stringData.append(0) }
        var headerPickle = u32(stringData.count)
        headerPickle.append(stringData)
        var result = u32(4)
        result.append(u32(headerPickle.count))
        result.append(headerPickle)
        result.append(payload)
        return result
    }

    /// ASAR 的完整性信息：整块哈希 + 按 4MB 分块的哈希
    static func integrity(of data: Data) -> [String: Any] {
        let blockSize = 4 * 1024 * 1024
        var blocks: [String] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: blockSize, limitedBy: data.endIndex) ?? data.endIndex
            blocks.append(sha256Hex(Data(data[index..<end])))
            index = end
        }
        return [
            "algorithm": "SHA256",
            "hash": sha256Hex(data),
            "blockSize": blockSize,
            "blocks": blocks,
        ]
    }

    static func intValue(_ any: Any?) -> Int? {
        if let s = any as? String { return Int(s) }
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: - 签名

    static func entitlements(of bundle: URL) -> [String: Any]? {
        guard let result = try? run("/usr/bin/codesign", ["-d", "--entitlements", ":-", bundle.path]),
              let data = result.out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              !plist.isEmpty else { return nil }
        return plist
    }

    static func sign(_ bundle: URL, entitlements: [String: Any]?) throws {
        var arguments = ["--force", "--sign", "-"]
        if let entitlements {
            let file = supportDirectory.appendingPathComponent("douyin-hq-entitlements.plist")
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            try data.write(to: file, options: .atomic)
            arguments += ["--entitlements", file.path]
        }
        arguments += ["--options", "runtime", bundle.path]
        try run("/usr/bin/codesign", arguments)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
    }

    // MARK: - 杂项

    static func shimURL() -> URL {
        Bundle.main.url(forResource: "douyin-hq-preload", withExtension: "js")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    static func shimData() throws -> Data {
        let url = shimURL()
        guard FileManager.default.fileExists(atPath: url.path) else { throw HQError.shimMissing }
        return try Data(contentsOf: url)
    }

    static func versionString(of bundle: URL) -> String {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "?"
        }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 执行外部命令

    struct CommandResult {
        var code: Int32 = 0
        var out: String = ""
        var err: String = ""
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // 必须先读完再等退出，否则管道写满会死锁
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = CommandResult(
            code: process.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? ""
        )
        if result.code != 0 {
            throw HQError.commandFailed(
                ([launchPath] + arguments).joined(separator: " "),
                (result.err + result.out).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    static func runOK(_ launchPath: String, _ arguments: [String]) -> Bool {
        (try? run(launchPath, arguments)) != nil
    }
}
