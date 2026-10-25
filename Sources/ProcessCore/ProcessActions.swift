import Darwin
import Foundation

/// 无提权、无 shell 的进程控制。界面仍须在调用前向用户确认。
public enum ProcessActions {
    public static func canTerminate(_ record: ProcessRecord) -> Bool {
        (try? validate(record)) != nil
    }

    public static func terminate(_ record: ProcessRecord, force: Bool = false) throws {
        try validate(record)
        // 校验紧邻 kill，以 PID 与微秒级启动时间核对采样对象，防止使用陈旧列表。
        // Darwin 的传统 kill API 不提供原子化的进程句柄；不跨越任何异步等待。
        guard Darwin.kill(record.pid, force ? SIGKILL : SIGTERM) == 0 else {
            throw ProcessCoreError.signalFailed(errno)
        }
    }

    private static func validate(_ record: ProcessRecord) throws {
        guard record.pid > 1, record.pid != getpid(), !ownAncestors().contains(record.pid) else {
            throw ProcessCoreError.protectedProcess
        }
        guard let sampled = record.identity else { throw ProcessCoreError.identityUnavailable }
        guard let current = readBSDInfo(record.pid) else { throw ProcessCoreError.processChanged }
        guard sampled.startSeconds == current.pbi_start_tvsec,
              sampled.startMicroseconds == current.pbi_start_tvusec else {
            throw ProcessCoreError.processChanged
        }
        let currentUID = getuid()
        guard currentUID != 0,
              sampled.ownerUID == currentUID, sampled.realUID == currentUID,
              current.pbi_uid == currentUID, current.pbi_ruid == currentUID else {
            throw ProcessCoreError.foreignProcess
        }
        let currentPath = readExecutablePath(record.pid) ?? record.executablePath
        guard current.pbi_flags & UInt32(PROC_FLAG_SYSTEM) == 0,
              !isSystemExecutable(currentPath) else {
            throw ProcessCoreError.protectedProcess
        }
    }

    private static func ownAncestors() -> Set<Int32> {
        var result: Set<Int32> = []
        var pid = getppid()
        while pid > 1, result.insert(pid).inserted,
              let info = readBSDInfo(pid) {
            pid = Int32(info.pbi_ppid)
        }
        return result
    }

    private static func isSystemExecutable(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"]
            .contains(where: path.hasPrefix)
    }
}

func readBSDInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
    return count == MemoryLayout<proc_bsdinfo>.size ? info : nil
}

func readTaskInfo(_ pid: Int32) -> proc_taskinfo? {
    var info = proc_taskinfo()
    let count = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
    return count == MemoryLayout<proc_taskinfo>.size ? info : nil
}

func readExecutablePath(_ pid: Int32) -> String? {
    // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN；该表达式宏不由 Swift 导入。
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
