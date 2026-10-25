import Darwin
import Foundation

/// 一次采样中的进程。CPU 百分比以单个逻辑核心为 100%，多线程进程可以超过 100%。
public struct ProcessRecord: Identifiable, Sendable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let user: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    /// -1 表示当前权限无法读取线程数。
    public let threadCount: Int
    public let state: String
    public let elapsed: String
    public let executablePath: String
    public let isApplication: Bool
    public let bundleIdentifier: String?

    // 不公开构造身份信息。只有采集到的记录可以用于发送信号。
    let identity: ProcessIdentity?

    public init(
        pid: Int32,
        parentPID: Int32,
        name: String,
        user: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        threadCount: Int,
        state: String,
        elapsed: String,
        executablePath: String,
        isApplication: Bool,
        bundleIdentifier: String? = nil
    ) {
        self.init(
            pid: pid, parentPID: parentPID, name: name, user: user,
            cpuPercent: cpuPercent, memoryBytes: memoryBytes, threadCount: threadCount,
            state: state, elapsed: elapsed, executablePath: executablePath,
            isApplication: isApplication, bundleIdentifier: bundleIdentifier,
            identity: nil
        )
    }

    init(
        pid: Int32, parentPID: Int32, name: String, user: String,
        cpuPercent: Double, memoryBytes: UInt64, threadCount: Int,
        state: String, elapsed: String, executablePath: String,
        isApplication: Bool, bundleIdentifier: String?, identity: ProcessIdentity?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.user = user
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.state = state
        self.elapsed = elapsed
        self.executablePath = executablePath
        self.isApplication = isApplication
        self.bundleIdentifier = bundleIdentifier
        self.identity = identity
    }
}

struct ProcessIdentity: Sendable, Hashable {
    let ownerUID: UInt32
    let realUID: UInt32
    let flags: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

public struct SystemSnapshot: Sendable {
    public let processes: [ProcessRecord]
    public let cpuPercent: Double
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let memoryPressure: String
    public let diskUsedBytes: UInt64
    public let diskTotalBytes: UInt64
    public let networkBytesPerSecond: Double
    public let networkUploadPerSecond: Double
    public let networkDownloadPerSecond: Double
    public let collectedAt: Date

    public init(
        processes: [ProcessRecord], cpuPercent: Double, memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64, memoryPressure: String, diskUsedBytes: UInt64,
        diskTotalBytes: UInt64, networkBytesPerSecond: Double,
        networkUploadPerSecond: Double, networkDownloadPerSecond: Double,
        collectedAt: Date = Date()
    ) {
        self.processes = processes
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
        self.diskUsedBytes = diskUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.networkBytesPerSecond = networkBytesPerSecond
        self.networkUploadPerSecond = networkUploadPerSecond
        self.networkDownloadPerSecond = networkDownloadPerSecond
        self.collectedAt = collectedAt
    }
}

public struct PortRecord: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let name: String
    public let port: String
    public let address: String
    public let protocolName: String
    public var id: String { "\(pid):\(protocolName):\(address):\(port)" }

    public init(pid: Int32, name: String, port: String, address: String, protocolName: String) {
        self.pid = pid
        self.name = name
        self.port = port
        self.address = address
        self.protocolName = protocolName
    }
}

public enum ProcessCoreError: LocalizedError, Sendable {
    case commandFailed(String, Int32)
    case commandTimedOut(String)
    case malformedOutput(String)
    case systemReadFailed(String)
    case protectedProcess
    case foreignProcess
    case identityUnavailable
    case processChanged
    case signalFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(name, status): "\(name) 读取失败（退出码 \(status)）。"
        case let .commandTimedOut(name): "\(name) 读取超时，请稍后重试。"
        case let .malformedOutput(name): "无法解析 \(name) 返回的进程数据。"
        case let .systemReadFailed(name): "无法读取\(name)。"
        case .protectedProcess: "该进程属于系统、当前工具或其上级进程，已受到保护。"
        case .foreignProcess: "只能结束当前登录用户拥有的进程。"
        case .identityUnavailable: "无法确认进程身份，请刷新列表后重试。"
        case .processChanged: "进程已退出或身份发生变化，请刷新列表。"
        case let .signalFailed(code): "无法结束进程：\(String(cString: strerror(code)))。"
        }
    }
}
