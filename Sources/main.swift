import SwiftUI
import AppKit
import Network
import ImageIO
import UniformTypeIdentifiers

// MARK: - 数据模型

struct ManagedApp: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var path: String
    var injectProxyEnvironment = true
    var chromiumProxyEnabled = false

    init(path: String) { self.path = path }

    private enum CodingKeys: String, CodingKey {
        case id, path, injectProxyEnvironment, chromiumProxyEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        injectProxyEnvironment = try values.decodeIfPresent(Bool.self, forKey: .injectProxyEnvironment) ?? true
        chromiumProxyEnabled = try values.decodeIfPresent(Bool.self, forKey: .chromiumProxyEnabled) ?? false
    }

    func launchArguments(proxyURL: String) -> [String] {
        chromiumProxyEnabled ? ["--proxy-server=\(proxyURL)"] : []
    }

    var name: String {
        FileManager.default.displayName(atPath: path)
            .replacingOccurrences(of: ".app", with: "")
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

// MARK: - 全局状态

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var host: String { didSet { save(); checkPort() } }
    @Published var port: String { didSet { save(); checkPort() } }
    @Published var noProxy: String { didSet { save() } }
    @Published var apps: [ManagedApp] { didSet { save() } }
    @Published var menuBarEnabled: Bool { didSet { save() } }

    /// nil = 检测中, true/false = 端口是否可连
    @Published var portReachable: Bool? = nil
    @Published var runningPaths: Set<String> = []
    @Published var toast: String? = nil
    @Published var exitChecking = false
    @Published var exitInfo: String? = nil
    @Published var scanning = false
    @Published var launchSettingsSuggestion: ManagedApp?

    private let defaults = UserDefaults.standard

    private init() {
        host = defaults.string(forKey: "host") ?? "127.0.0.1"
        port = defaults.string(forKey: "port") ?? "7890"
        noProxy = defaults.string(forKey: "noProxy") ?? "localhost,127.0.0.1,::1"
        menuBarEnabled = defaults.bool(forKey: "menuBar")
        if let data = defaults.data(forKey: "apps"),
           let list = try? JSONDecoder().decode([ManagedApp].self, from: data) {
            apps = list
        } else {
            apps = []
        }
        writeEnvFile()
        checkPort()
        refreshRunning()
        // 每 2 秒刷新运行状态；每 6 秒复查端口，断开时自动探测切换
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.periodicTick()
        }
        // 启动 1.5 秒后仍连不通就自动探测一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.portReachable != true else { return }
            self.autoDetectPort(silent: true)
        }
    }

    private var tick = 0

    private func periodicTick() {
        refreshRunning()
        tick += 1
        if tick % 3 == 0 {
            checkPort()
            if portReachable == false { maybeAutoDetect() }
        }
    }

    private func save() {
        defaults.set(host, forKey: "host")
        defaults.set(port, forKey: "port")
        defaults.set(noProxy, forKey: "noProxy")
        defaults.set(menuBarEnabled, forKey: "menuBar")
        if let data = try? JSONEncoder().encode(apps) {
            defaults.set(data, forKey: "apps")
        }
        writeEnvFile()
    }

    var proxyURL: String { "http://\(host):\(port)" }

    var proxyEnvironment: [String: String] {
        let url = proxyURL
        return [
            "HTTP_PROXY": url, "HTTPS_PROXY": url, "ALL_PROXY": url, "NO_PROXY": noProxy,
            "http_proxy": url, "https_proxy": url, "all_proxy": url, "no_proxy": noProxy,
        ]
    }

    // MARK: 共享配置（独立启动器读取此文件，改设置后自动同步）

    private var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyLauncher")
    }

    private func writeEnvFile() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let content = "PROXY_URL=\(q(proxyURL))\nNO_PROXY_VALUE=\(q(noProxy))\n"
        try? content.write(to: supportDir.appendingPathComponent("proxy.env"),
                           atomically: true, encoding: .utf8)
    }

    // MARK: 端口检测

    private var probe: NWConnection?
    private var probeCompleted = false

    func checkPort() {
        probe?.cancel()
        guard let p = UInt16(port.trimmingCharacters(in: .whitespaces)),
              let nwPort = NWEndpoint.Port(rawValue: p), !host.isEmpty else {
            portReachable = false
            return
        }
        // 复查时保留上一次的结果显示，避免小圆点每 6 秒闪一次橙色
        probeCompleted = false
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        probe = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            DispatchQueue.main.async {
                guard let self, self.probe === conn else { return }
                switch state {
                case .ready:
                    self.probeCompleted = true
                    self.portReachable = true
                    conn?.cancel()
                case .failed, .waiting:
                    self.probeCompleted = true
                    self.portReachable = false
                    conn?.cancel()
                default: break
                }
            }
        }
        conn.start(queue: .global())
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak conn] in
            guard let self, self.probe === conn, !self.probeCompleted else { return }
            self.probeCompleted = true
            self.portReachable = false
            conn?.cancel()
        }
    }

    private var lastAutoScan = Date.distantPast

    /// 端口断开时的自动探测，加冷却时间避免反复扫描
    private func maybeAutoDetect() {
        guard Date().timeIntervalSince(lastAutoScan) > 20 else { return }
        autoDetectPort(silent: true)
    }

    /// 扫描常用代理端口，找到第一个可连通的自动填入。
    /// 当前设置的端口排在最前，它能用就不会被改掉
    func autoDetectPort(silent: Bool = false) {
        guard !scanning else { return }
        scanning = true
        lastAutoScan = Date()
        if !silent { showToast("正在探测常用端口…") }
        var candidates: [UInt16] = [7890, 7897, 7891, 1080, 2080, 8889, 8118, 10808, 10809]
        if let current = UInt16(port.trimmingCharacters(in: .whitespaces)) {
            candidates.removeAll { $0 == current }
            candidates.insert(current, at: 0)
        }
        let queue = DispatchQueue(label: "port-scan")
        let group = DispatchGroup()
        var openPorts: [UInt16] = []
        var finished = Set<UInt16>()
        var conns: [UInt16: NWConnection] = [:]
        let hostName = host
        for p in candidates {
            group.enter()
            let conn = NWConnection(host: NWEndpoint.Host(hostName),
                                    port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
            conns[p] = conn
            conn.stateUpdateHandler = { st in
                guard !finished.contains(p) else { return }
                switch st {
                case .ready:
                    finished.insert(p)
                    openPorts.append(p)
                    conn.cancel()
                    group.leave()
                case .failed, .waiting:
                    finished.insert(p)
                    conn.cancel()
                    group.leave()
                default: break
                }
            }
            conn.start(queue: queue)
        }
        queue.asyncAfter(deadline: .now() + 2) {
            for p in candidates where !finished.contains(p) {
                finished.insert(p)
                conns[p]?.cancel()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.scanning = false
            guard let best = candidates.first(where: { openPorts.contains($0) }) else {
                if !silent {
                    self.showToast("未在常用端口发现代理，请确认代理软件已启动")
                }
                return
            }
            if String(best) == self.port {
                self.checkPort()
                if !silent { self.showToast("当前端口 \(best) 就可用") }
            } else {
                self.port = String(best)  // didSet 会自动保存并复查
                self.showToast(silent ? "已自动切换到代理端口 \(best)" : "发现代理端口 \(best)")
            }
        }
    }

    // MARK: 出口 IP 检测

    /// 依次尝试多个 IP 查询接口，被限流或失败就自动换下一个
    private static let exitEndpoints = [
        "https://ipwho.is/",
        "https://api.ip.sb/geoip",
        "http://ip-api.com/json",
    ]

    func checkExitIP() {
        guard let p = Int(port.trimmingCharacters(in: .whitespaces)) else {
            showToast("端口无效")
            return
        }
        exitChecking = true
        exitInfo = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 12
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": p,
            "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": p,
        ]
        tryExitEndpoint(session: URLSession(configuration: cfg), index: 0, lastError: nil)
    }

    private func tryExitEndpoint(session: URLSession, index: Int, lastError: String?) {
        guard index < Self.exitEndpoints.count else {
            DispatchQueue.main.async {
                self.exitChecking = false
                self.exitInfo = "检测失败：\(lastError ?? "所有接口都无响应")"
            }
            return
        }
        let url = URL(string: Self.exitEndpoints[index])!
        session.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let parsed = Self.parseExitInfo(obj) {
                DispatchQueue.main.async {
                    self.exitChecking = false
                    self.exitInfo = parsed
                }
                return
            } else if let code = (response as? HTTPURLResponse)?.statusCode {
                failure = "\(url.host ?? "") 返回 HTTP \(code)"
            } else {
                failure = "响应无法解析"
            }
            self.tryExitEndpoint(session: session, index: index + 1,
                                 lastError: failure ?? lastError)
        }.resume()
    }

    private static func parseExitInfo(_ obj: [String: Any]) -> String? {
        if let success = obj["success"] as? Bool, !success { return nil }        // ipwho.is
        if let status = obj["status"] as? String, status != "success" { return nil }  // ip-api
        guard let ip = (obj["ip"] as? String) ?? (obj["query"] as? String) else { return nil }
        var parts: [String] = []
        let cc = (obj["country_code"] as? String) ?? (obj["countryCode"] as? String)
        if let cc {
            let flag = cc.uppercased().unicodeScalars
                .compactMap { Unicode.Scalar(127397 + $0.value) }
                .map(String.init).joined()
            let name = Locale.current.localizedString(forRegionCode: cc)
                ?? (obj["country"] as? String) ?? cc
            var region = "\(flag) \(name)"
            if let city = obj["city"] as? String, !city.isEmpty {
                region += " \(city)"
            }
            parts.append(region)
        }
        parts.append(ip)
        let org = (obj["isp"] as? String)
            ?? (obj["org"] as? String)
            ?? (obj["organization"] as? String)
            ?? ((obj["connection"] as? [String: Any])?["isp"] as? String)
        if let org, !org.isEmpty { parts.append(org) }
        return parts.joined(separator: " · ")
    }

    // MARK: 运行状态

    func refreshRunning() {
        let paths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        // 无变化就不发布，避免每 2 秒白白重绘一次界面
        if paths != runningPaths { runningPaths = paths }
    }

    func isRunning(_ app: ManagedApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.path }
    }

    // MARK: 添加 / 启动

    func add(path: String) {
        guard path.hasSuffix(".app"),
              path != Bundle.main.bundlePath,
              !apps.contains(where: { $0.path == path }) else { return }
        let app = ManagedApp(path: path)
        apps.append(app)
        if URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased() == "chatgpt" {
            DispatchQueue.main.async { self.launchSettingsSuggestion = app }
        }
    }

    func addApps() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择要走代理的应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(path: url.path) }
    }

    func launch(_ app: ManagedApp) {
        if portReachable == false {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "代理端口未连通"
            alert.informativeText = "\(proxyURL) 目前连不上，请先打开 Clash 等代理软件。仍要带代理环境变量启动吗？"
            alert.addButton(withTitle: "仍要启动")
            alert.addButton(withTitle: "取消")
            let choice = alert.runModal()
            checkPort()
            guard choice == .alertFirstButtonReturn else { return }
        }
        if let running = isRunning(app) {
            confirmRelaunch(app, running: running)
            return
        }
        doLaunch(app)
    }

    func launchAll() {
        let targets = apps.filter { $0.exists && isRunning($0) == nil }
        if targets.isEmpty {
            showToast("列表里的应用都在运行中")
            return
        }
        for app in targets { doLaunch(app) }
        showToast("已带代理启动 \(targets.count) 个应用")
    }

    private func confirmRelaunch(_ app: ManagedApp, running: NSRunningApplication) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(app.name) 已在运行"
        alert.informativeText = "代理环境变量只在启动时生效。需要先退出该应用，再带代理重新启动。"
        alert.addButton(withTitle: "退出并重新启动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        running.terminate()
        waitAndRelaunch(app, running: running, attempts: 0)
    }

    private func waitAndRelaunch(_ app: ManagedApp, running: NSRunningApplication, attempts: Int) {
        if running.isTerminated {
            doLaunch(app)
            return
        }
        if attempts > 40 {  // 10 秒还没退出（可能有未保存内容的弹窗）
            showToast("等待 \(app.name) 退出超时，请手动退出后再点启动")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitAndRelaunch(app, running: running, attempts: attempts + 1)
        }
    }

    private func doLaunch(_ app: ManagedApp) {
        guard app.exists else {
            showToast("找不到 \(app.path)，应用可能已被移动或删除")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        var env = ProcessInfo.processInfo.environment
        if app.injectProxyEnvironment {
            proxyEnvironment.forEach { env[$0] = $1 }
        }
        config.environment = env
        config.arguments = app.launchArguments(proxyURL: proxyURL)
        config.createsNewApplicationInstance = false
        let name = app.name
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path),
                                           configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.showToast("启动 \(name) 失败：\(error.localizedDescription)")
                } else {
                    self?.showToast("已带代理启动 \(name)")
                    self?.refreshRunning()
                }
            }
        }
    }

    func copyTerminalCommand(_ app: ManagedApp) {
        guard let executable = Bundle(path: app.path)?.executableURL?.path else {
            showToast("读取应用启动信息失败")
            return
        }
        var parts: [String] = []
        if app.injectProxyEnvironment {
            parts = ["env"] + proxyEnvironment.keys.sorted().map {
                shellQuote("\($0)=\(proxyEnvironment[$0]!)")
            }
        }
        parts += [shellQuote(executable)] + app.launchArguments(proxyURL: proxyURL).map(shellQuote)
        let cmd = parts.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        showToast("终端命令已复制")
    }

    // MARK: 生成独立启动器

    func generateLauncher(for app: ManagedApp) {
        guard let bundle = Bundle(path: app.path),
              let execName = bundle.infoDictionary?["CFBundleExecutable"] as? String else {
            showToast("读取 \(app.name) 的启动信息失败")
            return
        }
        let execPath = app.path + "/Contents/MacOS/" + execName

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "保存启动器"
        panel.message = "双击生成的启动器即可带代理打开 \(app.name)，建议保存到「应用程序」"
        panel.nameFieldStringValue = "\(app.name)（代理）"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "app" { url.appendPathExtension("app") }

        do {
            try buildLauncherBundle(at: url, app: app, execPath: execPath)
            showToast("已生成 \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showToast("生成失败：\(error.localizedDescription)")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func buildLauncherBundle(at url: URL, app: ManagedApp, execPath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        let contents = url.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let displayName = url.deletingPathExtension().lastPathComponent
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleName</key>
        \t<string>\(displayName)</string>
        \t<key>CFBundleDisplayName</key>
        \t<string>\(displayName)</string>
        \t<key>CFBundleExecutable</key>
        \t<string>launcher</string>
        \t<key>CFBundleIdentifier</key>
        \t<string>dev.hua.proxylauncher.gen.\(UUID().uuidString.lowercased())</string>
        \t<key>CFBundleVersion</key>
        \t<string>1.0</string>
        \t<key>CFBundlePackageType</key>
        \t<string>APPL</string>
        \t<key>CFBundleIconFile</key>
        \t<string>AppIcon</string>
        \t<key>NSHighResolutionCapable</key>
        \t<true/>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"),
                        atomically: true, encoding: .utf8)

        let script = """
        #!/bin/bash
        # 由「代理启动器」生成
        # 代理地址从共享配置读取，在「代理启动器」里改设置后此启动器自动同步
        ENV_FILE="$HOME/Library/Application Support/ProxyLauncher/proxy.env"
        [ -f "$ENV_FILE" ] && . "$ENV_FILE"
        PROXY_URL="${PROXY_URL:-http://127.0.0.1:7890}"
        NO_PROXY_VALUE="${NO_PROXY_VALUE:-localhost,127.0.0.1,::1}"
        \(app.injectProxyEnvironment ? """
        export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
        export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
        export NO_PROXY="$NO_PROXY_VALUE" no_proxy="$NO_PROXY_VALUE"
        """ : "# 未启用代理环境变量注入")
        TARGET=\(shellQuote(execPath))
        if [ ! -x "$TARGET" ]; then
          osascript -e 'display alert "找不到目标应用" message "请确认应用位置，并重新生成启动器。"' >/dev/null 2>&1
          exit 1
        fi
        exec "$TARGET"\(app.chromiumProxyEnabled ? " \"--proxy-server=$PROXY_URL\"" : "")
        """
        let scriptURL = macos.appendingPathComponent("launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        writeIcon(of: app.path, to: resources.appendingPathComponent("AppIcon.icns"))
    }

    /// 把目标应用的图标复制/渲染成启动器的 icns
    private func writeIcon(of targetApp: String, to dest: URL) {
        let fm = FileManager.default
        if let iconFile = Bundle(path: targetApp)?
            .object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            var name = iconFile
            if !name.hasSuffix(".icns") { name += ".icns" }
            let src = targetApp + "/Contents/Resources/" + name
            if fm.fileExists(atPath: src) {
                try? fm.copyItem(atPath: src, toPath: dest.path)
                if fm.fileExists(atPath: dest.path) { return }
            }
        }
        // 应用图标在 Assets.car 里时（无独立 icns 文件），从系统取图标渲染
        let icon = NSWorkspace.shared.icon(forFile: targetApp)
        let sizes = [16, 32, 128, 256, 512]
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL,
                                                      UTType.icns.identifier as CFString,
                                                      sizes.count, nil) else { return }
        for s in sizes {
            if let cg = render(icon, size: s) {
                CGImageDestinationAddImage(d, cg, nil)
            }
        }
        CGImageDestinationFinalize(d)
    }

    private func render(_ image: NSImage, size: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Toast

    private var toastWork: DispatchWorkItem?

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            proxySection
            Divider()
            appListSection
            Divider()
            bottomBar
        }
        .frame(minWidth: 500, minHeight: 560)
        .overlay(alignment: .bottom) { toastView }
        .overlay { dropOverlay }
        .sheet(item: $state.launchSettingsSuggestion) { app in
            AppLaunchSettings(state: state, app: app)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // 代理设置区

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("代理设置", systemImage: "network")
                    .font(.headline)
                Spacer()
                portStatus
            }
            HStack(spacing: 8) {
                Text("地址")
                    .foregroundColor(.secondary)
                TextField("127.0.0.1", text: $state.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text("端口")
                    .foregroundColor(.secondary)
                TextField("7890", text: $state.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Button {
                    state.checkPort()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新检测代理端口")
                Button {
                    state.autoDetectPort()
                } label: {
                    Label("自动探测", systemImage: "wand.and.rays")
                }
                .disabled(state.scanning)
                .help("扫描 7890 / 7897 / 1080 等常用端口，自动找到本机代理。启动时和端口断开时也会自动探测")
            }
            HStack(spacing: 8) {
                Text("排除")
                    .foregroundColor(.secondary)
                TextField("localhost,127.0.0.1,::1", text: $state.noProxy)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button {
                    state.checkExitIP()
                } label: {
                    Label("测出口", systemImage: "globe.asia.australia")
                }
                .disabled(state.exitChecking)
                .help("经代理访问 ipinfo.io，查看出口 IP 和地区，确认节点是否符合要求")
                if state.exitChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                if let info = state.exitInfo {
                    Text(info)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            Text("启动时注入 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY = \(state.proxyURL)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
    }

    private var portStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.portReachable == true ? Color.green
                      : state.portReachable == false ? Color.red : Color.orange)
                .frame(width: 8, height: 8)
            Text(state.portReachable == true ? "代理端口可用"
                 : state.portReachable == false ? "端口未连通（请先打开 Clash 等代理软件）"
                 : "检测中…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // 应用列表区

    private var appListSection: some View {
        Group {
            if state.apps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "plus.app")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("还没有添加应用")
                        .foregroundColor(.secondary)
                    Text("点击「添加应用」，或直接把 App 拖进这个窗口\n从这里启动的应用会自动带上代理")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(Color.secondary.opacity(0.8))
                    Button("添加应用") { state.addApps() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.apps) { app in
                            AppRow(state: state, app: app)
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                state.addApps()
            } label: {
                Label("添加应用", systemImage: "plus")
            }
            Button {
                state.launchAll()
            } label: {
                Label("全部启动", systemImage: "play.fill")
            }
            .disabled(state.apps.isEmpty)
            .help("带代理启动列表里所有未运行的应用")
            Spacer()
            Toggle("菜单栏常驻", isOn: $state.menuBarEnabled)
                .toggleStyle(.checkbox)
                .help("在菜单栏显示图标，关掉窗口后仍可从菜单栏一键启动")
        }
        .padding(12)
    }

    // 拖拽

    private var dropOverlay: some View {
        Group {
            if dropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .padding(8)
                    Label("松开以添加应用", systemImage: "plus.app.fill")
                        .font(.title3)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let u = url, u.pathExtension == "app" {
                    DispatchQueue.main.async { state.add(path: u.path) }
                }
            }
        }
        return found
    }

    private var toastView: some View {
        Group {
            if let toast = state.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 52)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.toast)
    }
}

// MARK: - 应用行

struct AppRow: View {
    @ObservedObject var state: AppState
    let app: ManagedApp
    @State private var hovering = false
    @State private var showingSettings = false

    private var running: Bool { state.runningPaths.contains(app.path) }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .fontWeight(.medium)
                    if app.chromiumProxyEnabled {
                        Text("Chromium 代理")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundColor(.accentColor)
                    }
                    if running {
                        Text("运行中")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundColor(.green)
                    }
                    if !app.exists {
                        Text("未找到")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundColor(.red)
                    }
                }
                Text(app.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("启动设置")
            if hovering {
                Button {
                    state.generateLauncher(for: app)
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("生成独立启动器：双击即带代理启动，可放进 Dock / 启动台")
                Button {
                    state.apps.removeAll { $0.id == app.id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("从列表移除（不会删除应用本身）")
            }
            Button {
                state.launch(app)
            } label: {
                Label(running ? "重启走代理" : "启动", systemImage: "paperplane.fill")
                    .frame(minWidth: 76)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.exists)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sheet(isPresented: $showingSettings) {
            AppLaunchSettings(state: state, app: app)
        }
        .contextMenu {
            Button("启动设置…") { showingSettings = true }
            Divider()
            Button("带代理启动") { state.launch(app) }
            Button("生成独立启动器…") { state.generateLauncher(for: app) }
            Button("复制终端启动命令") { state.copyTerminalCommand(app) }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Divider()
            Button("从列表移除") {
                state.apps.removeAll { $0.id == app.id }
            }
        }
    }
}

struct AppLaunchSettings: View {
    @ObservedObject var state: AppState
    let app: ManagedApp
    @Environment(\.dismiss) private var dismiss
    @State private var injectEnvironment: Bool
    @State private var chromiumProxy: Bool

    init(state: AppState, app: ManagedApp) {
        self.state = state
        self.app = app
        _injectEnvironment = State(initialValue: app.injectProxyEnvironment)
        _chromiumProxy = State(initialValue: app.chromiumProxyEnabled)
    }

    private var isChatGPT: Bool {
        URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.lowercased() == "chatgpt"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("启动设置").font(.title2.bold())
                    Text(app.name).foregroundColor(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("注入代理环境变量", isOn: $injectEnvironment)
                Text("为支持 HTTP_PROXY、HTTPS_PROXY 等变量的应用及后台组件设置代理。")
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Chromium 代理参数", isOn: $chromiumProxy)
                Text("适用于支持此参数的 Electron / Chromium 应用；其它应用请保持关闭。")
                    .font(.caption).foregroundColor(.secondary)
            }
            if isChatGPT {
                Label("ChatGPT 建议同时启用这两项，以改善账号信息等页面的加载。", systemImage: "lightbulb")
                    .font(.callout).foregroundColor(.secondary)
                if !chromiumProxy || !injectEnvironment {
                    Button("使用 ChatGPT 建议设置") {
                        injectEnvironment = true
                        chromiumProxy = true
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("当前启动预览").font(.subheadline.bold())
                Text("代理地址：\(state.proxyURL)")
                if injectEnvironment {
                    Text("HTTP_PROXY / HTTPS_PROXY / ALL_PROXY（含小写）\nNO_PROXY = \(state.noProxy)")
                }
                if chromiumProxy {
                    Text("--proxy-server=\(state.proxyURL)").font(.system(.callout, design: .monospaced))
                }
                if !injectEnvironment && !chromiumProxy {
                    Text("按默认方式启动，不额外设置代理。")
                }
            }
            .font(.caption)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text("保存后，下次启动或重启应用时生效。已生成的独立启动器需要重新生成；仅修改代理地址无需重新生成。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let index = state.apps.firstIndex(where: { $0.id == app.id }) {
                        var updated = state.apps[index]
                        updated.injectProxyEnvironment = injectEnvironment
                        updated.chromiumProxyEnabled = chromiumProxy
                        state.apps[index] = updated
                        state.showToast("启动设置已保存，下次启动时生效")
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

// MARK: - 菜单栏

struct MenuBarContent: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.portReachable == true
             ? "代理 \(state.proxyURL) ✓"
             : "代理端口未连通")
        Divider()
        if state.apps.isEmpty {
            Text("先在主窗口添加应用")
        } else {
            ForEach(state.apps) { app in
                Button("启动 \(app.name)") { state.launch(app) }
                    .disabled(!app.exists)
            }
        }
        Divider()
        Button("打开主窗口") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出") { NSApp.terminate(nil) }
    }
}

// MARK: - 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻模式下，关掉最后一个窗口就从 Dock 隐藏，只留菜单栏图标
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let closing = note.object as? NSWindow
            DispatchQueue.main.async {
                guard AppState.shared.menuBarEnabled else { return }
                let stillVisible = NSApp.windows.contains {
                    $0 !== closing && $0.isVisible
                        && $0.styleMask.contains(.titled) && !($0 is NSPanel)
                }
                if !stillVisible {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppState.shared.menuBarEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }
}

@main
struct ProxyLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("代理启动器", id: "main") {
            ContentView(state: state)
        }
        .windowResizability(.contentMinSize)

        // isInserted 绑定会被系统在每次场景刷新时回写；@Published 对相同值的写入
        // 也会触发刷新，直接用 $state.menuBarEnabled 会形成无限重绘循环，
        // 这里必须做值去重
        MenuBarExtra("代理启动器", systemImage: "paperplane.circle.fill",
                     isInserted: Binding(
                        get: { state.menuBarEnabled },
                        set: { newValue in
                            if state.menuBarEnabled != newValue {
                                state.menuBarEnabled = newValue
                            }
                        }
                     )) {
            MenuBarContent(state: state)
        }
    }
}
