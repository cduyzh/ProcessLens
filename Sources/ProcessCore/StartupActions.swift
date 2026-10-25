import Darwin
import Foundation

/// 必须由明确的用户确认触发。仅改变后续启动资格，绝不 bootout / bootstrap / kill 服务。
public actor StartupActions {
    private let environment: StartupEnvironment
    private let runner: any StartupCommandRunning
    private var transactionInProgress = false
    public init() { environment = .live; runner = StartupSystemCommands() }
    init(environment: StartupEnvironment, runner: any StartupCommandRunning) {
        self.environment = environment; self.runner = runner
    }

    public func disable(_ item: StartupItem) async throws -> StartupActionReport {
        try Task.checkCancellation()
        guard !transactionInProgress else { throw StartupError.refused("已有启动项事务进行中。") }
        transactionInProgress = true
        defer { transactionInProgress = false }
        let environment = environment, runner = runner
        // 一旦开始改变持久状态，补偿必须能够完成，不被 UI Task.cancel 中断。
        return try await Task.detached(priority: .userInitiated) {
            try Self.withLock(environment) { try Self.disableTransaction(item, environment, runner) }
        }.value
    }

    public func restore(_ backup: StartupBackup) async throws -> StartupActionReport {
        try Task.checkCancellation()
        guard !transactionInProgress else { throw StartupError.refused("已有启动项事务进行中。") }
        transactionInProgress = true
        defer { transactionInProgress = false }
        let environment = environment, runner = runner
        return try await Task.detached(priority: .userInitiated) {
            try Self.withLock(environment) { try Self.restoreTransaction(backup, environment, runner) }
        }.value
    }

    private static func withLock<T>(_ environment: StartupEnvironment, _ body: () throws -> T) throws -> T {
        try StartupFiles.userDirectory(environment.backupRoot, environment: environment, create: true)
        let path = environment.backupRoot.appendingPathComponent(".transaction.lock").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw StartupError.refused("无法获得受控备份锁。") }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == environment.uid, info.st_nlink == 1, info.st_mode & 0o022 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw StartupError.refused("备份锁不安全或其他启动项事务正在执行。")
        }
        return try body()
    }

    private static func disableTransaction(_ item: StartupItem, _ environment: StartupEnvironment,
                                           _ runner: any StartupCommandRunning) throws -> StartupActionReport {
        guard item.source == .userLaunchAgent, item.canDisable,
              let source = item.plistURL, let expected = item.fileSnapshot,
              StartupFiles.validLabel(item.label), !item.label.hasPrefix("com.apple.") else {
            throw StartupError.refused(item.managementReason)
        }
        try StartupFiles.sourceURL(source, environment: environment)
        let (data, current) = try StartupFiles.read(source)
        try StartupFiles.validateUserFile(current, environment: environment)
        guard expected == current, try StartupFiles.dictionary(data)["Label"] as? String == item.label else {
            throw StartupError.refused("配置内容或文件身份已变化，请重新扫描后确认。")
        }
        let counts = try StartupFiles.duplicateLabels(environment)
        guard counts[item.label] == 1 else { throw StartupError.refused("同一登录域存在重复 Label，禁止停用。") }
        let states = try StartupLaunchctl.read(runner, domain: "gui/\(environment.uid)")
        let plistDisabled = try StartupFiles.dictionary(data)["Disabled"] as? Bool ?? false
        guard !(states[item.label] ?? plistDisabled) else { throw StartupError.refused("该项目原本已停用，不重复修改。") }
        try StartupLaunchctl.validateLoadedService(label: item.label, originalURL: source,
                                                   environment: environment, runner: runner)

        let directory = environment.backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw StartupError.transactionFailed("无法建立独立备份目录。") }
        let destination = StartupBackupStore.plistURL(directory)
        var manifest = StartupBackupManifest(id: directory.lastPathComponent, label: item.label, name: item.name,
                                             originalPath: source.path, createdAt: Date(), sha256: current.sha256,
                                             owner: environment.uid, originalMode: current.mode,
                                             priorOverride: states[item.label], phase: "prepared")
        try StartupFiles.writeManifest(manifest, at: StartupBackupStore.manifestURL(directory))
        var attemptedDisable = false
        var moved = false
        do {
            attemptedDisable = true
            try StartupLaunchctl.set(true, label: item.label, environment: environment, runner: runner)
            let (_, rechecked) = try StartupFiles.read(source)
            guard rechecked == current else { throw StartupError.refused("停用期间配置被其他软件修改，暂停移动。") }
            try StartupFiles.moveExclusive(source, destination)
            moved = true
            let (_, backedUp) = try StartupFiles.read(destination)
            guard backedUp == current else { throw StartupError.refused("移动后备份身份不匹配。") }
            manifest.phase = "disabled"
            try StartupFiles.writeManifest(manifest, at: StartupBackupStore.manifestURL(directory))
            let backup = StartupBackupStore.item(manifest, directory: directory, environment: environment,
                                                 statesAvailable: true,
                                                 duplicates: try? StartupFiles.duplicateLabels(environment), runner: runner)
            return StartupActionReport(label: item.label,
                                       message: "已禁止后续启动并保存可恢复备份；当前进程未停止。恢复时将显式执行 launchctl enable。",
                                       backup: backup, restored: false)
        } catch {
            var compensation: [String] = []
            var fileRecovered = !moved
            var stateRecovered = !attemptedDisable
            if moved {
                do {
                    let (_, identity) = try StartupFiles.read(destination)
                    guard identity.sha256 == current.sha256, identity.owner == environment.uid else {
                        throw StartupError.refused("备份被修改，保留现场。")
                    }
                    try StartupFiles.moveExclusive(destination, source)
                    fileRecovered = true
                } catch { compensation.append("文件回滚未完成：\(error.localizedDescription)") }
            }
            if attemptedDisable {
                do {
                    try StartupLaunchctl.validateLoadedService(label: item.label, originalURL: source,
                                                               environment: environment, runner: runner)
                    try StartupLaunchctl.set(false, label: item.label, environment: environment, runner: runner)
                    stateRecovered = true
                    if states[item.label] == nil { compensation.append("原无 override，已恢复为等效的显式启用；launchctl 不支持删除单项 override。") }
                } catch { compensation.append("启动资格回滚未确认：\(error.localizedDescription)") }
            }
            if fileRecovered && stateRecovered {
                manifest.phase = "restored"
                try? StartupFiles.writeManifest(manifest, at: StartupBackupStore.manifestURL(directory))
            }
            throw StartupError.transactionFailed("停用未完成：\(error.localizedDescription) \(compensation.joined(separator: " ")) 事务记录保留在 \(directory.path)")
        }
    }

    private static func restoreTransaction(_ backup: StartupBackup, _ environment: StartupEnvironment,
                                           _ runner: any StartupCommandRunning) throws -> StartupActionReport {
        guard backup.canRestore else { throw StartupError.refused(backup.restoreRestriction ?? "该备份不可恢复。") }
        let directory = environment.backupRoot.appendingPathComponent(backup.id, isDirectory: true)
        var manifest = try StartupBackupStore.readManifest(directory, environment: environment)
        guard manifest == backup.manifest, manifest.phase != "restored",
              backup.backupURL == StartupBackupStore.plistURL(directory),
              backup.originalURL.path == manifest.originalPath else { throw StartupError.refused("备份记录已变化，请重新扫描。") }
        let counts = try StartupFiles.duplicateLabels(environment)
        let states = try StartupLaunchctl.read(runner, domain: "gui/\(environment.uid)")
        let current = StartupBackupStore.item(manifest, directory: directory, environment: environment,
                                              statesAvailable: true, duplicates: counts, runner: runner)
        guard current.canRestore else { throw StartupError.refused(current.restoreRestriction ?? "备份不可恢复。") }
        try StartupLaunchctl.validateLoadedService(label: manifest.label, originalURL: backup.originalURL,
                                                   environment: environment, runner: runner)
        if current.recoveryOnly {
            // 原 plist 完整保留时只补偿启动资格，不覆盖/移动用户文件。
            do {
                _ = try StartupBackupStore.validateContents(backup.originalURL, manifest: manifest,
                                                            environment: environment)
                try StartupLaunchctl.set(false, label: manifest.label, environment: environment, runner: runner)
                manifest.phase = "restored"
                try StartupFiles.writeManifest(manifest, at: StartupBackupStore.manifestURL(directory))
                return StartupActionReport(label: manifest.label,
                                           message: "配置仍在原路径；已恢复为显式允许后续启动，未启动或停止当前进程。",
                                           backup: nil, restored: true)
            } catch {
                throw StartupError.transactionFailed("原位恢复未完整确认，配置和事务记录已保留，可重新扫描重试：\(error.localizedDescription)")
            }
        }
        let source = StartupBackupStore.plistURL(directory)
        let destination = URL(fileURLWithPath: manifest.originalPath)
        let originalIdentity = try StartupBackupStore.validateContents(source, manifest: manifest,
                                                                        environment: environment)
        var moved = false
        var attemptedEnable = false
        do {
            try StartupFiles.moveExclusive(source, destination)
            moved = true
            let (_, restored) = try StartupFiles.read(destination)
            guard restored == originalIdentity else { throw StartupError.refused("恢复后的文件身份不匹配。") }
            attemptedEnable = true
            try StartupLaunchctl.set(false, label: manifest.label, environment: environment, runner: runner)
            manifest.phase = "restored"
            try StartupFiles.writeManifest(manifest, at: StartupBackupStore.manifestURL(directory))
            return StartupActionReport(label: manifest.label,
                                       message: "已恢复原 plist 并显式允许后续启动；未立即启动或停止任何进程。",
                                       backup: nil, restored: true)
        } catch {
            var compensation: [String] = []
            if attemptedEnable {
                do {
                    try StartupLaunchctl.validateLoadedService(label: manifest.label, originalURL: backup.originalURL,
                                                               environment: environment, runner: runner)
                    try StartupLaunchctl.set(states[manifest.label] ?? false, label: manifest.label,
                                             environment: environment, runner: runner)
                } catch { compensation.append("启动资格回滚未确认：\(error.localizedDescription)") }
            }
            if moved {
                do {
                    let (_, identity) = try StartupFiles.read(destination)
                    guard identity == originalIdentity else { throw StartupError.refused("恢复文件又被修改，保留现场。") }
                    try StartupFiles.moveExclusive(destination, source)
                } catch { compensation.append("文件回滚未完成：\(error.localizedDescription)") }
            }
            throw StartupError.transactionFailed("恢复未完成：\(error.localizedDescription) \(compensation.joined(separator: " ")) 备份和事务记录已保留，请重新扫描。")
        }
    }
}
