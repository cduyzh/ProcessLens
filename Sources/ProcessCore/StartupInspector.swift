import Darwin
import Foundation

public actor StartupInspector {
    private let environment: StartupEnvironment
    private let runner: any StartupCommandRunning
    public init() { environment = .live; runner = StartupSystemCommands() }
    init(environment: StartupEnvironment, runner: any StartupCommandRunning) {
        self.environment = environment; self.runner = runner
    }

    public func scan() throws -> StartupScanResult {
        try Task.checkCancellation()
        var issues: [String] = []
        let gui: [String: Bool]?
        do { gui = try StartupLaunchctl.read(runner, domain: "gui/\(environment.uid)") }
        catch { gui = nil; issues.append("用户 launchctl 状态不可用：\(error.localizedDescription)") }
        let system: [String: Bool]?
        do { system = try StartupLaunchctl.read(runner, domain: "system") }
        catch { system = nil; issues.append("系统后台服务状态不可用：\(error.localizedDescription)") }
        let duplicates: [String: Int]?
        do { duplicates = try StartupFiles.duplicateLabels(environment) }
        catch { duplicates = nil; issues.append("无法完整核对同域重复 Label，暂停本地停用：\(error.localizedDescription)") }
        var items: [StartupItem] = []
        for (directory, source) in environment.sources {
            try Task.checkCancellation()
            guard StartupFiles.exists(directory) else { continue }
            do {
                let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for file in entries where file.pathExtension.lowercased() == "plist" {
                    items.append(plistItem(file, source: source, states: source == .administratorLaunchDaemon ? system : gui,
                                           duplicates: duplicates, environment: environment))
                }
            } catch { issues.append("\(source.displayName) 扫描失败：\(error.localizedDescription)") }
        }
        var btmAvailable = false
        do {
            let result = try runner.run("/usr/bin/sfltool", ["dumpbtm"])
            guard result.status == 0 else { throw StartupError.commandFailed("sfltool 退出码 \(result.status)") }
            let modern = try StartupBTM.parse(result.output, uid: environment.uid,
                                             existingPlists: Set(items.compactMap { $0.plistURL?.path }))
            items += modern
            btmAvailable = true
        } catch { issues.append("现代登录/后台项目不可读取，不能据此判断没有启动项：\(error.localizedDescription)") }
        let backups = StartupBackupStore.scan(environment: environment, statesAvailable: gui != nil,
                                               duplicates: duplicates, runner: runner, issues: &issues)
        try Task.checkCancellation()
        return StartupScanResult(items: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                                 backups: backups, issues: issues, btmAvailable: btmAvailable,
                                 launchctlStatusAvailable: gui != nil, scannedAt: Date())
    }

    private func plistItem(_ url: URL, source: StartupSource, states: [String: Bool]?,
                           duplicates: [String: Int]?, environment: StartupEnvironment) -> StartupItem {
        do {
            let (data, snapshot) = try StartupFiles.read(url)
            let dictionary = try StartupFiles.dictionary(data)
            let label = dictionary["Label"] as? String
            let executable = dictionary["Program"] as? String ?? (dictionary["ProgramArguments"] as? [String])?.first
            let app = StartupFiles.applicationURL(executable)
            let runAtLoad = dictionary["RunAtLoad"] as? Bool
            let keepAlive = (dictionary["KeepAlive"] as? Bool)
                ?? ((dictionary["KeepAlive"] as? [String: Any]).map { !$0.isEmpty })
            let state: StartupState
            if let states, let label {
                state = (states[label] ?? (dictionary["Disabled"] as? Bool ?? false)) ? .disabled : .enabled
            } else { state = .unknown }
            let kind: StartupKind = source == .administratorLaunchDaemon ? .backgroundDaemon
                : (runAtLoad == true || keepAlive == true ? .loginAgent : .onDemandAgent)
            var restriction: String?
            if source != .userLaunchAgent { restriction = "管理员安装的项目只读；请通过系统设置或原软件管理，不会请求提权。" }
            else if label == nil { restriction = "plist 没有合法 Label；不会拿文件名冒充服务标识。" }
            else if !StartupFiles.validLabel(label!) || label!.hasPrefix("com.apple.") { restriction = "系统或不安全的服务标识受到保护。" }
            else if states == nil { restriction = "无法核实当前停用状态，请稍后重新扫描。" }
            else if state != .enabled { restriction = "该项目已停用或状态未知，不重复修改。" }
            else if duplicates == nil || (duplicates?[label!] ?? 0) != 1 { restriction = "Label 重复或无法完整核对同一登录域，禁止修改。" }
            else {
                do {
                    try StartupFiles.sourceURL(url, environment: environment)
                    try StartupFiles.validateUserFile(snapshot, environment: environment)
                    try StartupLaunchctl.validateLoadedService(label: label!, originalURL: url,
                                                               environment: environment, runner: runner)
                } catch { restriction = error.localizedDescription }
            }
            let triggers = ["StartInterval", "StartCalendarInterval", "WatchPaths", "QueueDirectories", "MachServices", "Sockets"]
                .filter { dictionary[$0] != nil }.joined(separator: "、")
            let keepAliveDescription = dictionary["KeepAlive"] is [String: Any] ? "条件字典" : (keepAlive.map { $0 ? "是" : "否" } ?? "未声明")
            let details = "RunAtLoad：\(runAtLoad.map { $0 ? "是" : "否" } ?? "未声明")；KeepAlive：\(keepAliveDescription)。"
                + (triggers.isEmpty ? "" : "触发条件：\(triggers)。")
                + "允许后续启动不代表登录即启动，也不代表当前运行中。"
            let name = app?.deletingPathExtension().lastPathComponent
                ?? executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? label ?? url.lastPathComponent
            return StartupItem(id: "plist:" + url.path, label: label ?? "（未声明 Label）", name: name,
                               source: source, kind: kind, state: state, runAtLoad: runAtLoad, keepAlive: keepAlive,
                               plistURL: url, applicationURL: app, executablePath: executable,
                               canDisable: restriction == nil,
                               managementReason: restriction ?? "备份 plist 并禁止后续启动；当前进程继续运行。",
                               details: details, fileSnapshot: snapshot)
        } catch {
            return StartupItem(id: "plist:" + url.path, label: "（无法读取 Label）", name: url.lastPathComponent,
                               source: source, kind: .unknown, state: .unknown, runAtLoad: nil, keepAlive: nil,
                               plistURL: url, applicationURL: nil, executablePath: nil,
                               canDisable: false, managementReason: error.localizedDescription,
                               details: "文件保留，只读扫描未能确认配置。", fileSnapshot: nil)
        }
    }
}

enum StartupBackupStore {
    static func manifestURL(_ directory: URL) -> URL { directory.appendingPathComponent("record.json") }
    static func plistURL(_ directory: URL) -> URL { directory.appendingPathComponent("item.plist") }

    static func validateContents(_ url: URL, manifest: StartupBackupManifest,
                                  environment: StartupEnvironment) throws -> StartupFileSnapshot {
        let (data, identity) = try StartupFiles.read(url)
        try StartupFiles.validateUserFile(identity, environment: environment)
        guard identity.sha256 == manifest.sha256,
              identity.mode & 0o777 == manifest.originalMode & 0o777,
              try StartupFiles.dictionary(data)["Label"] as? String == manifest.label else {
            throw StartupError.refused("备份内容、权限或 Label 已变化。")
        }
        return identity
    }

    static func readManifest(_ directory: URL, environment: StartupEnvironment) throws -> StartupBackupManifest {
        try StartupFiles.userDirectory(directory, environment: environment, create: false)
        guard directory.deletingLastPathComponent().path == environment.backupRoot.path,
              UUID(uuidString: directory.lastPathComponent) != nil else { throw StartupError.refused("备份目录不合法。") }
        let (data, identity) = try StartupFiles.read(manifestURL(directory))
        try StartupFiles.validateUserFile(identity, environment: environment)
        let manifest = try JSONDecoder().decode(StartupBackupManifest.self, from: data)
        guard manifest.id == directory.lastPathComponent, manifest.owner == environment.uid,
              StartupFiles.validLabel(manifest.label), !manifest.label.hasPrefix("com.apple."),
              manifest.sha256.count == 64, manifest.sha256.allSatisfy({ $0.isHexDigit }),
              ["prepared", "disabled", "restored"].contains(manifest.phase),
              manifest.originalMode & 0o022 == 0 else { throw StartupError.refused("备份记录校验失败。") }
        try StartupFiles.sourceURL(URL(fileURLWithPath: manifest.originalPath), environment: environment)
        return manifest
    }

    static func item(_ manifest: StartupBackupManifest, directory: URL, environment: StartupEnvironment,
                     statesAvailable: Bool, duplicates: [String: Int]?, runner: any StartupCommandRunning) -> StartupBackup {
        var restriction: String?
        let originalURL = URL(fileURLWithPath: manifest.originalPath)
        // prepared: disable 已生效但尚未移动，或补偿失败；disabled: restore 已移动但未完成 enable。
        // 这两种中断都只允许在原位文件内容/Label/所有者/权限完全匹配时补偿启动资格。
        let recoveryOnly = ["prepared", "disabled"].contains(manifest.phase)
            && !StartupFiles.exists(plistURL(directory)) && StartupFiles.exists(originalURL)
        do {
            // 中断于 disable 与 move 之间，或 restore 的 move 与 enable 之间时，原文件仍可定位。
            _ = try validateContents(recoveryOnly ? originalURL : plistURL(directory), manifest: manifest,
                                     environment: environment)
            guard recoveryOnly || !StartupFiles.exists(originalURL) else {
                throw StartupError.refused("原路径已有文件；不会覆盖用户新文件。")
            }
            guard statesAvailable else { throw StartupError.refused("launchctl 状态不可用，暂不能安全恢复。") }
            guard let duplicates, (duplicates[manifest.label] ?? 0) == (recoveryOnly ? 1 : 0) else {
                throw StartupError.refused("已有同 Label 服务或无法完整核对，禁止恢复。")
            }
            try StartupLaunchctl.validateLoadedService(label: manifest.label, originalURL: originalURL,
                                                       environment: environment, runner: runner)
        } catch { restriction = error.localizedDescription }
        return StartupBackup(id: manifest.id, label: manifest.label, name: manifest.name,
                             originalURL: URL(fileURLWithPath: manifest.originalPath), backupURL: plistURL(directory),
                             createdAt: manifest.createdAt, sha256: manifest.sha256,
                             recoveryOnly: recoveryOnly,
                             canRestore: restriction == nil, restoreRestriction: restriction, manifest: manifest)
    }

    static func scan(environment: StartupEnvironment, statesAvailable: Bool,
                     duplicates: [String: Int]?, runner: any StartupCommandRunning, issues: inout [String]) -> [StartupBackup] {
        guard StartupFiles.exists(environment.backupRoot) else { return [] }
        do {
            try StartupFiles.userDirectory(environment.backupRoot, environment: environment, create: false)
            let directories = try FileManager.default.contentsOfDirectory(at: environment.backupRoot, includingPropertiesForKeys: nil)
            var result: [StartupBackup] = []
            for directory in directories where !directory.lastPathComponent.hasPrefix(".") {
                do {
                    let record = try readManifest(directory, environment: environment)
                    if record.phase != "restored" {
                        result.append(item(record, directory: directory, environment: environment,
                                           statesAvailable: statesAvailable, duplicates: duplicates, runner: runner))
                    }
                } catch { issues.append("备份 \(directory.lastPathComponent) 不可安全读取：\(error.localizedDescription)") }
            }
            return result.sorted { $0.createdAt > $1.createdAt }
        } catch { issues.append("恢复记录不可读取：\(error.localizedDescription)"); return [] }
    }
}
