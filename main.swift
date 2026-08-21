// 微信多开助手 WeChatMultiOpener
// 一键为 macOS 微信创建可多开的副本（ditto + 改 Bundle ID + ad-hoc 重签名）
// 原理：在 ~/Applications 创建微信副本并赋予新的 Bundle ID，macOS 视其为独立应用
//
// v1.1 新增：
//   - 环境预检查：启动时自动体检（系统版本/系统工具/微信/磁盘/目录权限），缺啥给啥修复引导
//   - 一键清理：彻底移除本软件创建的副本 App、副本数据容器与自身残留文件
//   - --selftest 命令行自检模式，方便自动化验证
// v1.2 新增：
//   - 微信更新检测 + 一键重建全部过期副本：按原 Bundle ID 重建，尽量保留副本容器
//   - 切回窗口时自动刷新版本状态，用户更新微信后回来即可看到重建提示
// v1.3 新增：
//   - 开机自检：可注册为登录项，开机启动后若发现副本过期即发系统通知提醒
//   - 界面改为 Tab 布局（多开 / 体检 / 清理卸载 / 日志），单页不再冗长
//
// 仅供学习交流使用

import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - 常量

enum Const {
    static let originalBundleID = "com.tencent.xinWeChat"
    static let appBundleID = "com.lei.wechat-multi-opener"
}

// MARK: - 环境体检

enum CheckStatus { case ok, warn, fail }

enum FixKind {
    case createCopiesDir      // 一键创建 ~/Applications
    case installCLT           // 唤起 xcode-select --install 安装弹窗
    case openWeChatDownload   // 打开微信官方下载页
    case openStorageSettings  // 打开储存空间管理
}

struct CheckItem: Identifiable {
    let id: String
    let title: String
    let required: Bool      // true=关键项（缺了没法用）；false=信息项（安抚/提示用）
    let status: CheckStatus
    let detail: String
    let fixTitle: String?
    let fixKind: FixKind?
}

// MARK: - 清理

enum CleanupKind: String {
    case copyApp = "微信副本"
    case dataContainer = "副本数据"
    case appSelf = "应用自身文件"
}

struct CleanupItem: Identifiable {
    let url: URL
    let kind: CleanupKind
    let sizeBytes: Int64
    var id: String { url.absoluteString }
    var name: String { url.lastPathComponent }
}

// MARK: - 工具函数

func formatBytes(_ b: Int64) -> String {
    let f = Double(b)
    if f >= 1e9 { return String(format: "%.2f GB", f / 1e9) }
    if f >= 1e6 { return String(format: "%.1f MB", f / 1e6) }
    if f >= 1e3 { return String(format: "%.0f KB", f / 1e3) }
    return "\(b) B"
}

// MARK: - 副本信息

struct CopyInfo: Identifiable {
    let url: URL
    let bundleID: String
    let version: String
    var id: String { url.absoluteString }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

// MARK: - 数据模型

final class MultiOpenModel: ObservableObject {

    // 基础状态
    @Published var wechatURL: URL?
    @Published var wechatVersion: String = ""
    @Published var copies: [CopyInfo] = []
    @Published var busy = false
    @Published var autoOpen = true
    @Published var logLines: [String] = []

    // 环境体检
    @Published var checkItems: [CheckItem] = []
    @Published var checking = false

    // 一键清理
    @Published var cleanupItems: [CleanupItem] = []
    @Published var cleanupScanning = false
    @Published var cleaning = false
    @Published var cleanupReport: String?

    // 创建副本的错误提示（弹窗）
    @Published var createError: String?

    // 一键重建过期副本
    @Published var rebuilding = false
    @Published var rebuildStatus: String? = nil
    @Published var rebuildError: String? = nil

    // 开机自检（登录项 + 更新通知）
    @Published var loginItemEnabled = false
    private var postedUpdateNotification = false

    private let fm = FileManager.default

    var copiesDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    var totalCleanupSizeText: String {
        formatBytes(cleanupItems.map { $0.sizeBytes }.reduce(0, +))
    }

    /// 版本落后于原版微信的副本（需要重建）
    var outdatedCopies: [CopyInfo] {
        guard wechatVersion != "?" && !wechatVersion.isEmpty else { return [] }
        return copies.filter { $0.version != "?" && $0.version != wechatVersion }
    }

    init() {
        refresh()
        runEnvironmentChecks()
        scanCleanupItems()
        // 自检模式（--selftest）下不碰通知与登录项，避免副作用
        if !CommandLine.arguments.contains("--selftest") {
            refreshLoginItemStatus()
            maybePostUpdateNotification()
        }
    }

    // MARK: 日志

    private func stamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date())
    }

    func appendLog(_ text: String) {
        logLines.append("[\(stamp())] \(text)")
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    // MARK: 探测

    private func plistValue(_ key: String, of appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = fm.contents(atPath: plist.path),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return dict[key] as? String
    }

    private func bundleID(of appURL: URL) -> String? {
        plistValue("CFBundleIdentifier", of: appURL)
    }

    private func version(of appURL: URL) -> String {
        plistValue("CFBundleShortVersionString", of: appURL) ?? "?"
    }

    private func isManagedCopyBundleID(_ id: String) -> Bool {
        guard id.hasPrefix(Const.originalBundleID), id != Const.originalBundleID else { return false }
        let suffix = id.dropFirst(Const.originalBundleID.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }

    func detectWeChat() -> URL? {
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/WeChat.app"),
            URL(fileURLWithPath: "/Applications/微信.app"),
            home.appendingPathComponent("Applications/WeChat.app"),
            home.appendingPathComponent("Applications/微信.app"),
        ]
        for c in candidates where fm.fileExists(atPath: c.path) {
            if bundleID(of: c) == Const.originalBundleID { return c }
        }
        // 同名应用不一定是官方微信，未验证 Bundle ID 时不要拿它做复制源。
        return nil
    }

    func refresh() {
        if let u = detectWeChat() {
            wechatURL = u
            wechatVersion = version(of: u)
            appendLog("✅ 检测到微信：\(u.path)（v\(wechatVersion)）")
        } else {
            wechatURL = nil
            appendLog("⚠️ 未自动找到微信，请点击「手动选择」指定 WeChat.app")
        }
        scanCopies()
    }

    /// 同步扫描副本列表（不触发 UI 刷新）
    func findCopies() -> [CopyInfo] {
        var result: [CopyInfo] = []
        let apps = (try? fm.contentsOfDirectory(at: copiesDir, includingPropertiesForKeys: nil)) ?? []
        for app in apps where app.pathExtension == "app" && !app.lastPathComponent.hasPrefix(".") {
            if let id = bundleID(of: app),
               isManagedCopyBundleID(id) {
                result.append(CopyInfo(url: app, bundleID: id, version: version(of: app)))
            }
        }
        return result.sorted { $0.bundleID < $1.bundleID }
    }

    func scanCopies() {
        copies = findCopies()
    }

    // MARK: 环境体检

    /// 体检核心（同步计算，可被自检模式复用）
    func computeChecks() -> [CheckItem] {
        var items: [CheckItem] = []

        // 1. macOS 版本
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osOK = os.majorVersion >= 13
        items.append(CheckItem(id: "os", title: "macOS 系统版本", required: true,
                               status: osOK ? .ok : .warn,
                               detail: "当前 macOS \(os.majorVersion).\(os.minorVersion)（建议 13.0 及以上）",
                               fixTitle: nil, fixKind: nil))

        // 2. 系统必备工具（全部系统自带，小白无需安装任何东西）
        let tools = ["ditto", "plutil", "codesign", "open"].map { "/usr/bin/\($0)" }
        let missing = tools.filter { !fm.isExecutableFile(atPath: $0) }
        if missing.isEmpty {
            items.append(CheckItem(id: "tools", title: "系统工具完整性", required: true, status: .ok,
                                   detail: "ditto / plutil / codesign / open 全部就绪（系统自带，无需额外安装）",
                                   fixTitle: nil, fixKind: nil))
        } else {
            let names = missing.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            items.append(CheckItem(id: "tools", title: "系统工具完整性", required: true, status: .fail,
                                   detail: "缺少系统命令：\(names)。极少见，通常是系统组件被误删",
                                   fixTitle: "安装命令行工具", fixKind: .installCLT))
        }

        // 3. 微信主程序
        if let wc = detectWeChat() {
            items.append(CheckItem(id: "wechat", title: "微信主程序", required: true, status: .ok,
                                   detail: "\(wc.path)（v\(version(of: wc))）",
                                   fixTitle: nil, fixKind: nil))
        } else {
            items.append(CheckItem(id: "wechat", title: "微信主程序", required: true, status: .fail,
                                   detail: "未找到微信。请先安装官方 Mac 版微信",
                                   fixTitle: "打开微信官网下载", fixKind: .openWeChatDownload))
        }

        // 4. 磁盘空间（每个副本约 1.2 GB）
        if let free = freeDiskBytes() {
            let enough = free > 2_000_000_000
            items.append(CheckItem(id: "disk", title: "可用磁盘空间", required: true,
                                   status: enough ? .ok : .warn,
                                   detail: String(format: "剩余 %@（每个副本约需 1.2 GB）", formatBytes(free)),
                                   fixTitle: enough ? nil : "打开储存空间管理",
                                   fixKind: enough ? nil : .openStorageSettings))
        }

        // 5. 副本目录
        let dirOK = fm.fileExists(atPath: copiesDir.path)
        items.append(CheckItem(id: "copiesdir", title: "副本目录（~/Applications）", required: true,
                               status: dirOK ? .ok : .warn,
                               detail: dirOK ? "已就绪" : "目录不存在（创建副本时会自动创建，也可现在手动创建）",
                               fixTitle: dirOK ? nil : "立即创建",
                               fixKind: dirOK ? nil : .createCopiesDir))

        // 6. 开发环境（信息项：安抚小白 / 告知开发者）
        let clt = cltInstalled()
        items.append(CheckItem(id: "clt", title: "开发环境（可选）", required: false, status: .ok,
                               detail: clt
                                   ? "已检测到 Xcode 命令行工具（开发者模式）"
                                   : "未安装任何开发工具 —— 本软件不依赖开发环境，可以放心使用",
                               fixTitle: nil, fixKind: nil))

        return items
    }

    func runEnvironmentChecks() {
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let items = self.computeChecks()
            DispatchQueue.main.async {
                self.checkItems = items
                self.checking = false
                let fails = items.filter { $0.status == .fail }.count
                let warns = items.filter { $0.status == .warn }.count
                if fails == 0 && warns == 0 {
                    self.appendLog("🔍 环境体检：全部通过，可放心使用")
                } else if fails > 0 {
                    self.appendLog("⚠️ 环境体检：\(fails) 项异常、\(warns) 项提醒，请按提示修复")
                } else {
                    self.appendLog("🔍 环境体检：\(warns) 项提醒，不影响核心功能")
                }
            }
        }
    }

    private func freeDiskBytes() -> Int64? {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let cap = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(cap)
    }

    private func cltInstalled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }

    /// 执行体检项的修复动作
    func applyFix(_ kind: FixKind) {
        switch kind {
        case .createCopiesDir:
            do {
                try fm.createDirectory(at: copiesDir, withIntermediateDirectories: true)
                appendLog("✅ 已创建副本目录：\(copiesDir.path)")
            } catch {
                appendLog("❌ 创建目录失败：\(error.localizedDescription)")
            }
            runEnvironmentChecks()

        case .installCLT:
            appendLog("⬇️ 正在唤起系统「命令行工具」安装弹窗，请在弹窗中点击「安装」，完成后回来点「重新检测」")
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                p.arguments = ["--install"]
                try? p.run()
                p.waitUntilExit()
            }

        case .openWeChatDownload:
            if let url = URL(string: "https://mac.weixin.qq.com/") {
                NSWorkspace.shared.open(url)
                appendLog("🌐 已打开微信官方下载页，安装完成后回来点「重新检测」")
            }

        case .openStorageSettings:
            var ok = false
            if let u = URL(string: "x-apple.systempreferences:com.apple.preferences.storage") {
                ok = NSWorkspace.shared.open(u)
            }
            if !ok {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
            appendLog("📁 已打开储存空间管理，建议清理出至少 2 GB 可用空间")
        }
    }

    // MARK: 开机自检与更新通知

    /// 本软件是否位于稳定位置（登录项依赖路径，workspace/下载文件夹里可能失效）
    var appLocationStable: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func refreshLoginItemStatus() {
        loginItemEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
                appendLog("✅ 已开启「开机自动检查微信更新」")
            } else {
                try SMAppService.mainApp.unregister()
                appendLog("已关闭开机自动检查")
            }
        } catch {
            appendLog("❌ 开机自检设置失败：\(error.localizedDescription)（建议把本软件移到「应用程序」文件夹后重试）")
        }
        refreshLoginItemStatus()
    }

    /// 启动时检查一次：副本过期则发系统通知（每次运行只发一次，切回窗口刷新不重复发）
    func maybePostUpdateNotification() {
        guard !postedUpdateNotification else { return }
        let outdated = outdatedCopies
        guard !outdated.isEmpty, wechatVersion != "?" else { return }
        postedUpdateNotification = true
        let version = wechatVersion
        let count = outdated.count

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "微信已更新到 v\(version)"
            content.body = "检测到 \(count) 个多开副本版本落后。打开「微信多开助手」按原 Bundle ID 重建，完成后请检查各副本登录状态。"
            content.sound = .default
            let req = UNNotificationRequest(identifier: "wechat-update-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
            center.add(req)
        }
    }

    // MARK: 命令执行

    @discardableResult
    private func runCmd(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw NSError(domain: "cmd", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(path) 退出码 \(p.terminationStatus)：\(out.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return out
    }

    // MARK: 创建副本

    private func nextIndex() -> Int {
        var maxIndex = 1
        for c in copies {
            let digits = c.bundleID.dropFirst(Const.originalBundleID.count)
            if let n = Int(digits), n > maxIndex { maxIndex = n }
        }
        return maxIndex + 1
    }

    func createCopy() {
        guard let source = wechatURL, !busy else { return }
        guard bundleID(of: source) == Const.originalBundleID else {
            createError = "当前选择的应用不是官方微信（Bundle ID 不匹配），请重新选择 WeChat.app。"
            appendLog("❌ 创建中止：微信 Bundle ID 不匹配")
            return
        }

        // ---- 关键操作前的环境校验（给小白明确的指引，而不是让他们看报错）----
        for t in ["/usr/bin/ditto", "/usr/bin/plutil", "/usr/bin/codesign"] {
            if !fm.isExecutableFile(atPath: t) {
                createError = "缺少系统命令 \((t as NSString).lastPathComponent)。请在上方「环境体检」中点击「安装命令行工具」完成修复后再试。"
                appendLog("❌ 创建中止：缺少系统命令 \((t as NSString).lastPathComponent)")
                return
            }
        }
        if let free = freeDiskBytes(), free < 1_500_000_000 {
            createError = "磁盘空间不足（剩余 \(formatBytes(free))），创建一个微信副本约需 1.2 GB。请先清理磁盘空间后重试。"
            appendLog("❌ 创建中止：磁盘空间不足（剩余 \(formatBytes(free))）")
            return
        }

        busy = true
        let n = nextIndex()
        let stem = source.deletingPathExtension().lastPathComponent
        let dest = copiesDir.appendingPathComponent("\(stem)\(n).app")
        let newID = "\(Const.originalBundleID)\(n)"
        appendLog("🚧 开始创建副本 \(dest.lastPathComponent)，约需 10~30 秒，请稍候…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.fm.createDirectory(at: self.copiesDir, withIntermediateDirectories: true)
                try self.runCmd("/usr/bin/ditto", [source.path, dest.path])
                try self.runCmd("/usr/bin/plutil", ["-replace", "CFBundleIdentifier", "-string", newID,
                                                    dest.appendingPathComponent("Contents/Info.plist").path])
                try self.runCmd("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", dest.path])
                DispatchQueue.main.async {
                    self.appendLog("✅ 副本创建成功：\(dest.lastPathComponent)（\(newID)）")
                    self.scanCopies()
                    self.scanCleanupItems()
                    self.busy = false
                    if self.autoOpen { self.openApp(at: dest) }
                }
            } catch {
                // ditto 成功但后续改 plist / 重签名失败时，清掉刚生成的半成品。
                if self.fm.fileExists(atPath: dest.path) {
                    try? self.fm.removeItem(at: dest)
                }
                DispatchQueue.main.async {
                    self.appendLog("❌ 创建失败：\(error.localizedDescription)")
                    self.createError = "创建副本失败：\(error.localizedDescription)"
                    self.scanCopies()
                    self.scanCleanupItems()
                    self.busy = false
                }
            }
        }
    }

    func openApp(at url: URL) {
        DispatchQueue.global().async { [weak self] in
            do {
                try self?.runCmd("/usr/bin/open", ["-n", url.path])
                DispatchQueue.main.async {
                    self?.appendLog("▶️ 已启动：\(url.deletingPathExtension().lastPathComponent)")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.appendLog("❌ 启动失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func deleteCopy(_ info: CopyInfo) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID) {
            app.terminate()
        }
        var resultingURL: NSURL? = nil
        do {
            try fm.trashItem(at: info.url, resultingItemURL: &resultingURL)
            appendLog("🗑 已移到废纸篓：\(info.name)")
        } catch {
            appendLog("❌ 删除失败：\(error.localizedDescription)")
        }
        scanCopies()
        scanCleanupItems()
    }

    func chooseWeChatManually() {
        let panel = NSOpenPanel()
        panel.title = "选择微信 App"
        panel.message = "请选择「应用程序」文件夹中的 WeChat.app（或 微信.app）"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            guard bundleID(of: url) == Const.originalBundleID else {
                createError = "请选择官方微信应用（WeChat.app 或 微信.app）。当前选择的应用不是微信。"
                appendLog("❌ 手动选择失败：Bundle ID 不匹配（\(url.lastPathComponent)）")
                return
            }
            wechatURL = url
            wechatVersion = version(of: url)
            appendLog("✅ 已手动选择微信：\(url.path)（v\(wechatVersion)）")
        }
    }

    // MARK: 一键重建过期副本

    /// 检测到微信更新后，把所有版本落后的副本按原 Bundle ID 重建
    /// Bundle ID 保持不变，系统通常会复用对应容器；最终登录状态仍取决于微信版本与签名策略。
    func rebuildAllCopies() {
        guard !rebuilding, !busy else { return }
        let outdated = outdatedCopies
        guard !outdated.isEmpty else { return }

        // 前置校验：磁盘空间（每个副本约 1.2 GB）
        if let free = freeDiskBytes(), free < Int64(1_500_000_000) * Int64(max(outdated.count, 1)) {
            let need = formatBytes(Int64(1_200_000_000) * Int64(outdated.count))
            rebuildError = "磁盘空间不足（剩余 \(formatBytes(free))），重建 \(outdated.count) 个副本约需 \(need)。请先清理磁盘空间后重试。"
            appendLog("❌ 重建中止：磁盘空间不足（剩余 \(formatBytes(free))）")
            return
        }

        rebuilding = true
        rebuildStatus = "准备重建…"
        appendLog("🔄 开始重建 \(outdated.count) 个过期副本（按原 Bundle ID 保留容器）…")

        // 主线程：请求退出正在运行的过期副本
        var quitCount = 0
        for c in outdated {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID) {
                app.terminate()
                quitCount += 1
            }
        }
        if quitCount > 0 {
            appendLog("👋 已请求退出 \(quitCount) 个正在运行的副本，等待其关闭…")
        }

        guard let source = wechatURL ?? detectWeChat(), bundleID(of: source) == Const.originalBundleID else {
            rebuilding = false
            rebuildStatus = nil
            appendLog("❌ 重建中止：未找到微信主程序")
            return
        }
        let srcVersion = version(of: source)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if quitCount > 0 { Thread.sleep(forTimeInterval: 3.0) }

            var ok = 0
            var failNames: [String] = []
            for (idx, c) in outdated.enumerated() {
                DispatchQueue.main.async {
                    self.rebuildStatus = "正在重建 \(idx + 1)/\(outdated.count)：\(c.name)…"
                    self.appendLog("🚧 重建 \(c.name)：删除旧版 → 复制 v\(srcVersion) → 重签名…")
                }
                do {
                    // 1. 先在同一目录生成并签名临时副本，避免中途失败时留下空路径。
                    let staging = c.url.deletingLastPathComponent()
                        .appendingPathComponent(".\(c.name)-rebuild-\(UUID().uuidString).app")
                    defer { try? self.fm.removeItem(at: staging) }
                    try self.runCmd("/usr/bin/ditto", [source.path, staging.path])
                    // 2. 恢复原 Bundle ID（数据容器按原 ID 保留）
                    try self.runCmd("/usr/bin/plutil", ["-replace", "CFBundleIdentifier", "-string", c.bundleID,
                                                        staging.appendingPathComponent("Contents/Info.plist").path])
                    // 3. 重签名临时副本，并确认 Bundle ID 没被工具链改坏。
                    try self.runCmd("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", staging.path])
                    guard self.bundleID(of: staging) == c.bundleID else {
                        throw NSError(domain: "rebuild", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "临时副本 Bundle ID 校验失败"])
                    }
                    // 4. 原子替换：旧副本先改名保留，换入成功后再移到废纸篓。
                    let backup = c.url.deletingLastPathComponent()
                        .appendingPathComponent(".\(c.name)-backup-\(UUID().uuidString).app")
                    if self.fm.fileExists(atPath: c.url.path) {
                        try self.fm.moveItem(at: c.url, to: backup)
                    }
                    do {
                        try self.fm.moveItem(at: staging, to: c.url)
                    } catch {
                        if self.fm.fileExists(atPath: backup.path) {
                            try? self.fm.moveItem(at: backup, to: c.url)
                        }
                        throw error
                    }
                    if self.fm.fileExists(atPath: backup.path) {
                        var trashed: NSURL?
                        try? self.fm.trashItem(at: backup, resultingItemURL: &trashed)
                    }
                    ok += 1
                    DispatchQueue.main.async {
                        self.appendLog("✅ 已重建：\(c.name) → v\(srcVersion)（\(c.bundleID)）")
                    }
                } catch {
                    failNames.append(c.name)
                    DispatchQueue.main.async {
                        self.appendLog("❌ 重建失败：\(c.name)——\(error.localizedDescription)")
                    }
                }
            }

            DispatchQueue.main.async {
                self.rebuildStatus = nil
                self.rebuilding = false
                var report = "🔄 重建完成：成功 \(ok) 个"
                if !failNames.isEmpty {
                    report += "，失败 \(failNames.count) 个（\(failNames.joined(separator: "、"))）"
                }
                self.appendLog(report)
                self.refresh()
                self.scanCleanupItems()
            }
        }
    }

    /// 静默刷新版本与副本状态（窗口重新激活时调用，不打日志）
    func rescan() {
        if let u = detectWeChat() {
            wechatURL = u
            wechatVersion = version(of: u)
        }
        scanCopies()
        maybePostUpdateNotification()
    }

    // MARK: 一键清理

    /// 清理扫描核心（同步计算，可被自检模式复用）
    func computeCleanupItems() -> [CleanupItem] {
        var items: [CleanupItem] = []
        let home = fm.homeDirectoryForCurrentUser
        let copyList = findCopies()

        // 1. 副本 App 本体
        for c in copyList {
            items.append(CleanupItem(url: c.url, kind: .copyApp, sizeBytes: directorySize(c.url)))
        }

        // 2. 副本产生的数据容器
        //    微信是沙盒应用：每个副本的数据在 ~/Library/Containers/<副本BundleID>
        //    匹配规则严格限定「等于副本 BundleID」或「副本 BundleID 的扩展/组容器」，
        //    绝不会碰原版微信的 com.tencent.xinWeChat 及 5A4RE8SF68.com.tencent.xinWeChat
        let libDirs = [
            home.appendingPathComponent("Library/Containers"),
            home.appendingPathComponent("Library/Group Containers"),
        ]
        for c in copyList {
            let bid = c.bundleID
            for dir in libDirs {
                let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for e in entries {
                    let n = e.lastPathComponent
                    if n == bid || n.hasPrefix(bid + ".") || n.hasSuffix("." + bid) {
                        items.append(CleanupItem(url: e, kind: .dataContainer, sizeBytes: directorySize(e)))
                    }
                }
            }
        }

        // 3. 本软件自身的残留文件（防御性扫描：当前版本其实不写配置，但卸载要彻底）
        let selfPaths = [
            "Library/Preferences/\(Const.appBundleID).plist",
            "Library/Caches/\(Const.appBundleID)",
            "Library/Application Support/WeChatMultiOpener",
            "Library/Application Support/微信多开助手",
            "Library/Saved Application State/\(Const.appBundleID).savedState",
        ]
        for p in selfPaths {
            let u = home.appendingPathComponent(p)
            if fm.fileExists(atPath: u.path) {
                items.append(CleanupItem(url: u, kind: .appSelf, sizeBytes: directorySize(u)))
            }
        }

        return items
    }

    func scanCleanupItems() {
        cleanupScanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let items = self.computeCleanupItems()
            DispatchQueue.main.async {
                self.cleanupItems = items
                self.cleanupScanning = false
            }
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let f as URL in en {
            if let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 执行一键清理：退出运行中的副本 → 副本与数据移到废纸篓 → 清除自身残留 → 汇报
    func performCleanup() {
        guard !cleaning, !cleanupItems.isEmpty else { return }
        cleaning = true
        cleanupReport = nil

        // 第一步：主线程上请求退出正在运行的副本微信
        var quitCount = 0
        for item in cleanupItems where item.kind == .copyApp {
            if let bid = bundleID(of: item.url) {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                    app.terminate()
                    quitCount += 1
                }
            }
        }
        if quitCount > 0 {
            appendLog("👋 已请求退出 \(quitCount) 个正在运行的副本微信，等待其关闭…")
        }
        appendLog("🧹 开始一键清理（\(cleanupItems.count) 项，约 \(totalCleanupSizeText)）…")

        let snapshot = cleanupItems
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if quitCount > 0 { Thread.sleep(forTimeInterval: 3.0) }

            var freed: Int64 = 0
            var ok = 0
            var failNames: [String] = []
            for item in snapshot {
                do {
                    if item.kind == .appSelf {
                        // 应用自身残留：直接删除（体积小，且废纸篓里没意义）
                        try self.fm.removeItem(at: item.url)
                    } else {
                        // 副本与副本数据：移到废纸篓，可反悔
                        var res: NSURL? = nil
                        try self.fm.trashItem(at: item.url, resultingItemURL: &res)
                    }
                    freed += item.sizeBytes
                    ok += 1
                } catch {
                    failNames.append(item.name)
                }
            }

            // 清掉本软件的 UserDefaults 域
            UserDefaults.standard.removePersistentDomain(forName: Const.appBundleID)

            var report = "已清理 \(ok) 项，释放 \(formatBytes(freed))"
            if !failNames.isEmpty {
                report += "；\(failNames.count) 项失败（\(failNames.joined(separator: "、"))，可能仍在运行，退出后重试）"
            }

            DispatchQueue.main.async {
                self.cleanupReport = report
                self.appendLog("🧹 \(report)")
                self.cleaning = false
                self.scanCopies()
                self.scanCleanupItems()
                self.runEnvironmentChecks()
            }
        }
    }
}

// MARK: - 通知代理（App 在前台时也显示横幅）

final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 界面

/// 统一四个 Tab 的内容容器，避免系统默认 GroupBox 产生过重的边框和内边距。
struct AssistantGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            configuration.content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: MultiOpenModel
    @State private var pendingDelete: CopyInfo?
    @State private var showCleanupConfirm = false
    @State private var showRebuildConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                mainTab
                    .tabItem { Label(mainTabLabel, systemImage: "square.stack.3d.up") }
                envTab
                    .tabItem { Label(envTabLabel, systemImage: "stethoscope") }
                cleanupTab
                    .tabItem { Label("清理卸载", systemImage: "trash.circle") }
                logTab
                    .tabItem { Label("日志", systemImage: "terminal") }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 760, minHeight: 640)
        .groupBoxStyle(AssistantGroupBoxStyle())
        // 删除单个副本的确认
        .confirmationDialog(
            "确定删除副本「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                if let info = pendingDelete { model.deleteCopy(info) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("副本会被移到废纸篓，不影响原版微信和已登录账号。")
        }
        // 创建失败/前置校验未通过的提示
        .alert("暂时无法创建副本", isPresented: Binding(
            get: { model.createError != nil },
            set: { if !$0 { model.createError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.createError ?? "")
        }
        // 一键清理确认
        .alert("确认一键清理？", isPresented: $showCleanupConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清理", role: .destructive) { model.performCleanup() }
        } message: {
            Text("将把 \(model.cleanupItems.count) 项（约 \(model.totalCleanupSizeText)）移到废纸篓或删除，包括微信副本与副本产生的登录数据。原版微信与聊天记录完全不受影响。正在运行的副本会先自动退出。")
        }
        // 一键重建确认
        .alert("一键重建过期副本？", isPresented: $showRebuildConfirm) {
            Button("取消", role: .cancel) {}
            Button("开始重建") { model.rebuildAllCopies() }
        } message: {
            Text("将重建 \(model.outdatedCopies.count) 个版本落后的副本：自动退出运行中的副本 → 生成并签名新版程序 → 按原路径替换。副本 Bundle ID 保持不变，完成后请检查登录状态；每个约需 10~30 秒。")
        }
        // 重建前置校验未通过
        .alert("暂时无法重建", isPresented: Binding(
            get: { model.rebuildError != nil },
            set: { if !$0 { model.rebuildError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.rebuildError ?? "")
        }
        // 切回本软件时静默刷新版本状态（用户更新微信后回来即可看到重建提示）
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.rescan()
        }
    }

    // MARK: Tab 内容

    private var mainTabLabel: String {
        model.outdatedCopies.isEmpty ? "多开" : "多开 ⚠️"
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.4"
    }

    private var envTabLabel: String {
        model.checkItems.contains { $0.status == .fail } ? "体检 ⚠️" : "体检"
    }

    /// Tab 1：多开（日常主流程）
    private var mainTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                mainSummary
                wechatCard
                copiesCard
                createCard
                Text("仅供学习交流使用。微信多开可能违反《微信个人帐号使用规范》，账号风险请自行评估；请勿用于商业用途。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Tab 2：体检（环境检查 + 自动检查设置）
    private var envTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                envCard
                autoCheckCard
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Tab 3：清理卸载
    private var cleanupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cleanupCard
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Tab 4：日志
    private var logTab: some View {
        logCard
            .padding(.vertical, 14)
    }

    /// 主流程摘要：用户打开应用后先看到是否可用、已有多少副本和是否需要重建。
    private var mainSummary: some View {
        HStack(spacing: 0) {
            summaryMetric(
                title: "原版微信",
                value: model.wechatVersion.isEmpty ? "检测中" : "v\(model.wechatVersion)",
                icon: "checkmark.seal",
                tint: model.wechatURL == nil ? .orange : .green
            )
            Divider().frame(height: 30)
            summaryMetric(title: "已创建副本", value: "\(model.copies.count) 个", icon: "square.stack.3d.up", tint: .blue)
            Divider().frame(height: 30)
            summaryMetric(
                title: "当前状态",
                value: readinessText,
                icon: readinessIcon,
                tint: readinessTint
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isReady: Bool {
        model.wechatURL != nil &&
        !model.checkItems.contains { $0.required && $0.status == .fail } &&
        !model.checkItems.contains { $0.id == "wechat" && $0.status == .warn }
    }

    private var readinessText: String {
        if model.wechatURL == nil { return "未找到微信" }
        if model.checking || model.checkItems.isEmpty { return "检查中" }
        if !isReady { return "需要检查" }
        if !model.outdatedCopies.isEmpty { return "需要重建" }
        if model.checkItems.contains(where: { $0.status == .warn }) { return "需要留意" }
        return "可以使用"
    }

    private var readinessIcon: String {
        readinessText == "可以使用" ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var readinessTint: Color {
        readinessText == "可以使用" ? .green : .orange
    }

    private func summaryMetric(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 142, alignment: .leading)
    }

    /// 自动检查（体检 Tab 内）：开机自启 + 更新通知
    private var autoCheckCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLoginItem($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开机自动检查微信更新").font(.subheadline.weight(.medium))
                        Text("开启后每次开机自动运行本软件，检测到微信更新导致副本过期时，会发送系统通知提醒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.appLocationStable {
                    Label("建议先把「微信多开助手」移动到「应用程序」文件夹，避免路径变动导致开机自启失效", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("首次开启后如弹出通知授权窗口请点「允许」；之后可随时在 系统设置 → 通知 中管理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("自动检查", systemImage: "bell.badge")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.teal)
                    .frame(width: 44, height: 44)
                Text("2×")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("微信多开助手").font(.title2.bold())
                Text("管理副本、检查环境与更新状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("v\(appVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("macOS 13+")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: 环境体检卡

    private var envCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if model.checkItems.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在体检…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(model.checkItems) { item in
                        checkRow(item)
                    }
                }
                HStack(spacing: 8) {
                    if model.checking {
                        ProgressView().controlSize(.small)
                        Text("检测中…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.runEnvironmentChecks()
                    } label: {
                        Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        } label: {
            Label("环境体检", systemImage: "stethoscope")
        }
    }

    private func checkRow(_ item: CheckItem) -> some View {
        HStack(spacing: 10) {
            switch item.status {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warn:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).font(.subheadline.weight(.medium))
                    if !item.required {
                        Text("可选")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let fix = item.fixTitle, let kind = item.fixKind {
                Button(fix) { model.applyFix(kind) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: 微信主程序卡

    private var wechatCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("原版微信").font(.headline)
                    if let u = model.wechatURL {
                        Text("\(u.path) · v\(model.wechatVersion)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("状态正常，可以创建副本")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("未检测到「应用程序」文件夹中的微信")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let u = model.wechatURL {
                    Button("打开原版") { model.openApp(at: u) }
                }
                Button("手动选择") { model.chooseWeChatManually() }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新检测")
            }
            .padding(.vertical, 4)
        } label: {
            Label("微信主程序", systemImage: "checkmark.seal")
        }
    }

    // MARK: 副本列表卡

    private var copiesCard: some View {
        GroupBox {
            if model.copies.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    Text("还没有副本。点击下方按钮创建第一个，即可同时登录第二个微信。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    if !model.outdatedCopies.isEmpty {
                        rebuildBanner
                    }
                    ForEach(model.copies) { info in
                        copyRow(info)
                        if info.id != model.copies.last?.id { Divider() }
                    }
                }
            }
        } label: {
            Label("已创建的副本（\(model.copies.count) 个）", systemImage: "square.stack.3d.up")
        }
    }

    /// 微信更新后的重建横幅
    private var rebuildBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("微信已更新到 v\(model.wechatVersion)，\(model.outdatedCopies.count) 个副本版本落后")
                    .font(.subheadline.weight(.medium))
                Text("按原 Bundle ID 重建并保留容器路径，完成后请检查各副本登录状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.rebuilding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.rebuildStatus ?? "重建中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    showRebuildConfirm = true
                } label: {
                    Label("一键重建", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .padding(.bottom, 8)
    }

    private func copyRow(_ info: CopyInfo) -> some View {
        HStack(spacing: 10) {
            Circle().fill(.green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.body.weight(.medium))
                Text(info.bundleID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.wechatVersion != info.version && model.wechatVersion != "?" && info.version != "?" {
                    Label("微信已更新到 v\(model.wechatVersion)，此副本为 v\(info.version)，建议删除后重建", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("打开") { model.openApp(at: info.url) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(role: .destructive) {
                pendingDelete = info
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("移到废纸篓")
        }
        .padding(.vertical, 8)
    }

    // MARK: 新建多开卡

    private var createCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $model.autoOpen) {
                    Text("创建完成后自动打开新副本").font(.subheadline)
                }
                if model.busy {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在复制并签名（约 1.2GB，请勿关闭本窗口）…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.createCopy()
                } label: {
                    Label(model.busy ? "创建中…" : "创建新的微信副本", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || model.rebuilding || model.wechatURL == nil)
                Text("副本创建在 ~/Applications，使用独立 Bundle ID，可同时启动不同实例。首次使用请分别确认登录状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("新建多开", systemImage: "wand.and.stars")
        }
    }

    // MARK: 一键清理卡

    private var cleanupCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.cleaning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在清理，请稍候…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let report = model.cleanupReport {
                    Label(report, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                if model.cleanupScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在扫描本软件创建的文件…").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if model.cleanupItems.isEmpty && !model.cleaning {
                    Label("未发现本软件创建的文件，系统很干净", systemImage: "sparkles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.cleanupItems) { item in
                            cleanupRow(item)
                            if item.id != model.cleanupItems.last?.id { Divider() }
                        }
                    }
                    HStack {
                        Text("合计 \(model.cleanupItems.count) 项，约 \(model.totalCleanupSizeText)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button(role: .destructive) {
                            showCleanupConfirm = true
                        } label: {
                            Label("一键清理", systemImage: "trash.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.cleaning)
                    }
                }
                Text("清理范围仅限本软件创建的微信副本及副本产生的数据，原版微信、聊天记录完全不受影响。如需彻底卸载本软件，清理后再把「微信多开助手」拖入废纸篓即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Label("一键清理 / 卸载", systemImage: "trash.circle")
        }
    }

    private func cleanupRow(_ item: CleanupItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .copyApp ? "square.stack.3d.up" : (item.kind == .dataContainer ? "internaldrive" : "doc"))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(item.kind.rawValue)：\(item.name)")
                    .font(.subheadline.weight(.medium))
                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(formatBytes(item.sizeBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: 日志卡

    private var logCard: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: model.logLines.count) { _ in
                    if let last = model.logLines.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        } label: {
            Label("操作日志", systemImage: "terminal")
        }
    }
}

// MARK: - 入口

@main
struct WeChatMultiOpenerApp: App {
    @StateObject private var model = MultiOpenModel()

    init() {
        // 通知代理：保证 App 在前台时横幅也能显示
        UNUserNotificationCenter.current().delegate = NotificationCenterDelegate.shared

        if CommandLine.arguments.contains("--selftest") {
            Self.selfTest()
        }
        if CommandLine.arguments.contains("--login-test") {
            Self.loginItemTest()
        }
    }

    var body: some Scene {
        WindowGroup("微信多开助手") {
            ContentView(model: model)
        }
    }

    /// 命令行测试登录项注册：./WeChatMultiOpener --login-test
    static func loginItemTest() -> Never {
        let statusNames: [SMAppService.Status: String] = [
            .notRegistered: "notRegistered",
            .enabled: "enabled",
            .requiresApproval: "requiresApproval",
            .notFound: "notFound",
        ]
        do {
            try SMAppService.mainApp.register()
            let s1 = SMAppService.mainApp.status
            print("登录项注册：成功（status=\(statusNames[s1] ?? "\(s1.rawValue)")）")
            try SMAppService.mainApp.unregister()
            let s2 = SMAppService.mainApp.status
            print("登录项注销：成功（status=\(statusNames[s2] ?? "\(s2.rawValue)")）")
            print("==== 登录项测试通过 ====")
        } catch {
            print("登录项测试失败：\(error)")
        }
        exit(0)
    }

    /// 命令行自检：./WeChatMultiOpener --selftest
    /// 跑完环境体检和清理扫描，打印结果后退出，方便自动化验证
    static func selfTest() -> Never {
        let m = MultiOpenModel()
        print("==== 环境体检 ====")
        for it in m.computeChecks() {
            let s = it.status == .ok ? "OK  " : (it.status == .warn ? "WARN" : "FAIL")
            print("[\(s)] \(it.title) —— \(it.detail)")
        }
        print("==== 已创建副本 ====")
        let copies = m.findCopies()
        if copies.isEmpty { print("（无）") }
        for c in copies { print("- \(c.name)（\(c.bundleID)）v\(c.version)") }
        print("==== 过期副本检测 ====")
        let outdated = copies.filter { $0.version != m.wechatVersion && $0.version != "?" && m.wechatVersion != "?" }
        if outdated.isEmpty {
            print("全部副本均为最新版本 v\(m.wechatVersion)")
        } else {
            for c in outdated { print("- \(c.name)：v\(c.version) → 需重建到 v\(m.wechatVersion)") }
        }
        print("==== 一键清理扫描 ====")
        let items = m.computeCleanupItems()
        if items.isEmpty { print("（无）") }
        for i in items { print("- [\(i.kind.rawValue)] \(i.url.path)（\(formatBytes(i.sizeBytes))）") }
        print("==== 自检完成 ====")
        exit(0)
    }
}
