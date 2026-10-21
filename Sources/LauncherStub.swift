import Foundation

// 独立启动器的原生可执行文件。
//
// 「代理启动器」生成 XXX（代理）.app 时，把本程序复制为
// Contents/MacOS/launcher，并在 Info.plist 里写入：
//   PLTargetPath      目标应用的可执行文件路径
//   PLInjectEnv       是否注入代理环境变量
//   PLChromiumProxy   是否附加 --proxy-server 参数
// 代理地址在运行时从共享配置读取，改设置后无需重新生成启动器。
//
// 这里必须用原生可执行文件：如果 Contents/MacOS 里放的是 shell 脚本，
// Apple Silicon 上的 Launch Services 无法判断 bundle 的架构，会提示
// 「需要安装 Rosetta」才能打开。

@main
struct LauncherStub {

    static func main() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let target = info["PLTargetPath"] as? String, !target.isEmpty else {
            alert("启动器配置损坏", "找不到目标应用路径，请重新生成启动器。")
            exit(1)
        }
        let injectEnv = info["PLInjectEnv"] as? Bool ?? true
        let chromiumProxy = info["PLChromiumProxy"] as? Bool ?? false

        let env = readEnvFile()
        let proxyURL = env["PROXY_URL"] ?? "http://127.0.0.1:7890"
        let noProxy = env["NO_PROXY_VALUE"] ?? "localhost,127.0.0.1,::1"

        if injectEnv {
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                setenv(key, proxyURL, 1)
            }
            setenv("NO_PROXY", noProxy, 1)
            setenv("no_proxy", noProxy, 1)
        }

        guard FileManager.default.isExecutableFile(atPath: target) else {
            alert("找不到目标应用", "请确认应用位置，并重新生成启动器。")
            exit(1)
        }

        var arguments = [target]
        if chromiumProxy { arguments.append("--proxy-server=\(proxyURL)") }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        _ = target.withCString { execv($0, argv) }
        let reason = String(cString: strerror(errno))
        for pointer in argv { free(pointer) }
        alert("启动失败", "无法启动 \(target)：\(reason)")
        exit(1)
    }

    // MARK: - 共享配置

    /// 读取 ~/Library/Application Support/ProxyLauncher/proxy.env
    /// 内容形如 PROXY_URL='http://127.0.0.1:7890'
    private static func readEnvFile() -> [String: String] {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/ProxyLauncher/proxy.env")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equal]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("'") && value.hasSuffix("'")) ||
               (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    // MARK: - 提示

    private static func alert(_ title: String, _ message: String) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display alert \(quoted(title)) message \(quoted(message))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
