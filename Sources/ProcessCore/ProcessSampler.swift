import Darwin
import Foundation

/// 所有命令与系统读取均由 actor 执行，不阻塞 MainActor。
public actor ProcessSampler {
    private struct ProcessTiming {
        let identity: ProcessIdentity
        let ticks: UInt64
        let timestamp: TimeInterval
    }
    private struct NetworkCounters {
        let received: UInt64
        let sent: UInt64
    }
    private var previousCPU: [UInt32]?
    private var processTimings: [Int32: ProcessTiming] = [:]
    private var previousNetwork: [String: NetworkCounters] = [:]
    private var previousNetworkTime: TimeInterval?
    private var bundleCache: [String: String] = [:]
    private let cpuTimebase: Double

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        cpuTimebase = Double(timebase.numer) / Double(max(1, timebase.denom)) / 1_000_000_000
    }

    public func sample() throws -> SystemSnapshot {
        try Task.checkCancellation()
        let output = try runCommand("/bin/ps", arguments: [
            "-axo", "pid=,ppid=,uid=,user=,pcpu=,rss=,stat=,etime=,comm="
        ])
        let now = ProcessInfo.processInfo.systemUptime
        let processes = try parseProcesses(output, timestamp: now)
        let cpu = try readCPUPercent()
        let memory = try readMemory()
        let disk = try readDisk()
        let network = readNetwork(timestamp: now)
        try Task.checkCancellation()
        return SystemSnapshot(
            processes: processes, cpuPercent: cpu,
            memoryUsedBytes: memory.used, memoryTotalBytes: memory.total,
            memoryPressure: memory.pressure, diskUsedBytes: disk.used, diskTotalBytes: disk.total,
            networkBytesPerSecond: network.upload + network.download,
            networkUploadPerSecond: network.upload,
            networkDownloadPerSecond: network.download, collectedAt: Date()
        )
    }

    /// TCP 仅列 LISTEN；UDP 列本地已绑定端点。权限不足的其他用户 socket 不可见。
    public func listeningPorts() throws -> [PortRecord] {
        try Task.checkCancellation()
        let tcp = try runCommand("/usr/sbin/lsof", arguments: [
            "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"
        ], allowEmptyExit: true)
        let udp = try runCommand("/usr/sbin/lsof", arguments: [
            "-nP", "-iUDP", "-FpcnP"
        ], allowEmptyExit: true)
        try Task.checkCancellation()
        var seen: Set<String> = []
        return (parsePorts(tcp) + parsePorts(udp))
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.port == rhs.port { return lhs.pid < rhs.pid }
                return (Int(lhs.port) ?? 0) < (Int(rhs.port) ?? 0)
            }
    }

    private func parseProcesses(_ output: String, timestamp: TimeInterval) throws -> [ProcessRecord] {
        var timings: [Int32: ProcessTiming] = [:]
        var records: [ProcessRecord] = []
        for line in output.split(separator: "\n") {
            try Task.checkCancellation()
            let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 9,
                  let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  let ownerUID = UInt32(fields[2]), let rssKiB = UInt64(fields[5]) else { continue }
            let bsd = readBSDInfo(pid)
            let task = readTaskInfo(pid)
            let path = readExecutablePath(pid) ?? String(fields[8])
            let identity = bsd.map {
                ProcessIdentity(ownerUID: $0.pbi_uid, realUID: $0.pbi_ruid, flags: $0.pbi_flags,
                                startSeconds: $0.pbi_start_tvsec, startMicroseconds: $0.pbi_start_tvusec)
            }
            var cpu: Double = 0
            if let task, let identity, identity.ownerUID == ownerUID {
                let ticks = task.pti_total_user &+ task.pti_total_system
                if let previous = processTimings[pid], previous.identity == identity,
                   ticks >= previous.ticks, timestamp > previous.timestamp {
                    cpu = Double(ticks - previous.ticks) * cpuTimebase / (timestamp - previous.timestamp) * 100
                }
                timings[pid] = ProcessTiming(identity: identity, ticks: ticks, timestamp: timestamp)
            } else {
                // 内核拒绝 task info 时，ps 提供系统计算的近期 CPU 百分比。
                cpu = Double(fields[4]) ?? 0
            }
            let appPath = applicationBundlePath(path)
            let bundleID: String?
            if let appPath {
                if let cached = bundleCache[appPath] { bundleID = cached.isEmpty ? nil : cached }
                else {
                    bundleID = Bundle(path: appPath)?.bundleIdentifier
                    bundleCache[appPath] = bundleID ?? ""
                }
            } else { bundleID = nil }
            let binaryName = URL(fileURLWithPath: path).lastPathComponent
            records.append(ProcessRecord(
                pid: pid, parentPID: parent,
                name: binaryName.isEmpty ? String(fields[8]) : binaryName,
                user: String(fields[3]), cpuPercent: max(0, cpu),
                memoryBytes: task?.pti_resident_size ?? rssKiB * 1024,
                threadCount: task.map { Int($0.pti_threadnum) } ?? -1,
                state: String(fields[6]), elapsed: String(fields[7]), executablePath: path,
                isApplication: appPath != nil, bundleIdentifier: bundleID, identity: identity
            ))
        }
        guard !records.isEmpty else { throw ProcessCoreError.malformedOutput("ps") }
        processTimings = timings
        return records.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func applicationBundlePath(_ path: String) -> String? {
        // 首个 .app 是所属主应用，嵌套 Helper 也能显示该应用的图标。
        guard let marker = path.range(of: ".app/") else { return nil }
        return String(path[..<marker.lowerBound]) + ".app"
    }

    private func readCPUPercent() throws -> Double {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ProcessCoreError.systemReadFailed("CPU 使用率") }
        let current = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousCPU = current }
        guard let previous = previousCPU else { return 0 }
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return 0 }
        return min(100, max(0, Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) * 100))
    }

    private func readMemory() throws -> (used: UInt64, total: UInt64, pressure: String) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ProcessCoreError.systemReadFailed("内存使用量") }
        let total = ProcessInfo.processInfo.physicalMemory
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        // 活跃页 + 有线页 + 压缩器物理页，排除可回收的 inactive 文件缓存。
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        var pressureLevel: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &size, nil, 0)
        let pressure: String
        if status != 0 { pressure = "未知" }
        else if pressureLevel & 4 != 0 { pressure = "紧张" }
        else if pressureLevel & 2 != 0 { pressure = "偏高" }
        else { pressure = "正常" }
        return (min(total, usedPages * UInt64(pageSize)), total, pressure)
    }

    private func readDisk() throws -> (used: UInt64, total: UInt64) {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let total = (attributes[.systemSize] as? NSNumber)?.uint64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value else {
            throw ProcessCoreError.systemReadFailed("磁盘容量")
        }
        return (total > free ? total - free : 0, total)
    }

    private func readNetwork(timestamp: TimeInterval) -> (upload: Double, download: Double) {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return (0, 0) }
        defer { freeifaddrs(first) }
        var current: [String: NetworkCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee
            cursor = item.ifa_next
            let name = String(cString: item.ifa_name)
            // 只累计物理 en 接口，避免 utun / bridge / awdl 将同一数据重复计算。
            guard name.hasPrefix("en"), item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  current[name] == nil, let data = item.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = NetworkCounters(received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes))
        }
        defer {
            previousNetwork = current
            previousNetworkTime = timestamp
        }
        guard let previousTime = previousNetworkTime, timestamp > previousTime else { return (0, 0) }
        let interval = timestamp - previousTime
        var upload: UInt64 = 0
        var download: UInt64 = 0
        for (name, counters) in current {
            guard let old = previousNetwork[name] else { continue }
            // 接口重置或 32 位计数器回绕时丢弃该间隔，避免虚假的吞吐峰值。
            if counters.sent >= old.sent { upload += counters.sent - old.sent }
            if counters.received >= old.received { download += counters.received - old.received }
        }
        return (Double(upload) / interval, Double(download) / interval)
    }

    private func parsePorts(_ output: String) -> [PortRecord] {
        var pid: Int32 = 0
        var name = ""
        var protocolName = ""
        var result: [PortRecord] = []
        for raw in output.split(separator: "\n") {
            guard let key = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch key {
            case "p": pid = Int32(value) ?? 0
            case "c": name = value
            case "f": protocolName = ""
            case "P": protocolName = value
            case "n":
                let local = String(value.components(separatedBy: "->").first ?? value)
                guard pid > 0, let colon = local.lastIndex(of: ":") else { continue }
                let port = String(local[local.index(after: colon)...])
                guard UInt16(port) != nil else { continue }
                result.append(PortRecord(pid: pid, name: name, port: port,
                                         address: String(local[..<colon]), protocolName: protocolName))
            default: break
            }
        }
        return result
    }
}

/// argv 直接传给固定的系统二进制，任何进程名、搜索词、路径均不会进入 shell。
private func runCommand(_ executable: String, arguments: [String], allowEmptyExit: Bool = false) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    try process.run()
    let watchdog = CommandWatchdog(process: process)
    let timeout = DispatchWorkItem { watchdog.expire() }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
    defer { timeout.cancel() }
    // 先读再 wait，避免 ps 输出超过 pipe 容量后互相等待。
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try Task.checkCancellation()
    if watchdog.didExpire {
        throw ProcessCoreError.commandTimedOut(URL(fileURLWithPath: executable).lastPathComponent)
    }
    guard process.terminationStatus == 0 || (allowEmptyExit && process.terminationStatus == 1 && data.isEmpty) else {
        throw ProcessCoreError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent, process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self)
}

/// 仅管理本次自行启动的 ps / lsof。锁保护 timeout 标志，进程退出后取消定时器。
private final class CommandWatchdog: @unchecked Sendable {
    private let process: Process
    private let startSeconds: UInt64?
    private let startMicroseconds: UInt64?
    private let lock = NSLock()
    private var expired = false

    init(process: Process) {
        self.process = process
        let identity = readBSDInfo(process.processIdentifier)
        startSeconds = identity?.pbi_start_tvsec
        startMicroseconds = identity?.pbi_start_tvusec
    }

    var didExpire: Bool { lock.withLock { expired } }

    func expire() {
        guard process.isRunning else { return }
        lock.withLock { expired = true }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            guard process.isRunning,
                  let current = readBSDInfo(process.processIdentifier),
                  current.pbi_start_tvsec == startSeconds,
                  current.pbi_start_tvusec == startMicroseconds else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
