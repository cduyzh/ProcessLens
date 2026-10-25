import Foundation

public enum StartupSource: String, CaseIterable, Sendable, Hashable {
    case userLaunchAgent, administratorLaunchAgent, administratorLaunchDaemon, backgroundTaskManagement
    public var displayName: String {
        switch self {
        case .userLaunchAgent: "用户 LaunchAgent"
        case .administratorLaunchAgent: "管理员 LaunchAgent"
        case .administratorLaunchDaemon: "管理员 LaunchDaemon"
        case .backgroundTaskManagement: "系统登录与后台项目"
        }
    }
}

public enum StartupKind: String, CaseIterable, Sendable, Hashable {
    case loginAgent, onDemandAgent, backgroundDaemon, loginItem, backgroundItem, unknown
    public var displayName: String {
        switch self {
        case .loginAgent: "登录或常驻代理"
        case .onDemandAgent: "按需或定时代理"
        case .backgroundDaemon: "系统后台服务"
        case .loginItem: "登录项"
        case .backgroundItem: "后台项目"
        case .unknown: "类型待确认"
        }
    }
}

public enum StartupState: String, CaseIterable, Sendable, Hashable {
    case enabled, disabled, unknown
    public var displayName: String {
        switch self {
        case .enabled: "允许后续启动"
        case .disabled: "已停用"
        case .unknown: "状态未知"
        }
    }
}

public struct StartupItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let name: String
    public let source: StartupSource
    public let kind: StartupKind
    public let state: StartupState
    public let runAtLoad: Bool?
    public let keepAlive: Bool?
    public let plistURL: URL?
    public let applicationURL: URL?
    public let executablePath: String?
    public let canDisable: Bool
    public let managementReason: String
    public let details: String
    let fileSnapshot: StartupFileSnapshot?
}

public struct StartupBackup: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let name: String
    public let originalURL: URL
    public let backupURL: URL
    public let createdAt: Date
    public let sha256: String
    public let recoveryOnly: Bool
    public let canRestore: Bool
    public let restoreRestriction: String?
    let manifest: StartupBackupManifest
}

public struct StartupScanResult: Sendable {
    public let items: [StartupItem]
    public let backups: [StartupBackup]
    public let issues: [String]
    public let btmAvailable: Bool
    public let launchctlStatusAvailable: Bool
    public let scannedAt: Date
}

public struct StartupActionReport: Sendable {
    public let label: String
    public let message: String
    public let backup: StartupBackup?
    public let restored: Bool
}

public enum StartupError: LocalizedError, Sendable {
    case refused(String)
    case commandFailed(String)
    case transactionFailed(String)
    public var errorDescription: String? {
        switch self {
        case let .refused(message), let .commandFailed(message), let .transactionFailed(message): message
        }
    }
}

struct StartupFileSnapshot: Hashable, Sendable {
    let owner: UInt32
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let sha256: String
}

struct StartupBackupManifest: Codable, Hashable, Sendable {
    let id: String
    let label: String
    let name: String
    let originalPath: String
    let createdAt: Date
    let sha256: String
    let owner: UInt32
    let originalMode: UInt16
    let priorOverride: Bool?
    var phase: String
}

struct StartupEnvironment: Sendable {
    let home: URL
    let uid: UInt32
    let administratorAgents: URL
    let administratorDaemons: URL
    let systemAgents: URL
    var userAgents: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
    var backupRoot: URL { home.appendingPathComponent("Library/Application Support/cduyzhProcessTool/StartupBackups", isDirectory: true) }
    var sources: [(URL, StartupSource)] {
        [(userAgents, .userLaunchAgent), (administratorAgents, .administratorLaunchAgent),
         (administratorDaemons, .administratorLaunchDaemon)]
    }
    static var live: Self {
        Self(home: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath(),
             uid: getuid(), administratorAgents: URL(fileURLWithPath: "/Library/LaunchAgents"),
             administratorDaemons: URL(fileURLWithPath: "/Library/LaunchDaemons"),
             systemAgents: URL(fileURLWithPath: "/System/Library/LaunchAgents"))
    }
}
