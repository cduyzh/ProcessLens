import Darwin
import Foundation

public enum BrowserSessionActions {
    /// 每次操作重新扫描。根已退出时，显式 force 可凭原快照逐个重核仍存活后代。
    /// force 仅由显式调用选择；普通退出不会自动升级为 SIGKILL。
    public static func close(_ session: BrowserSession, force: Bool = false) async throws -> BrowserCloseReport {
        guard session.canClose, session.classification == .automation else {
            throw BrowserInspectionError.protectedSession(session.closeRestriction ?? "该浏览器实例受到保护。")
        }
        try Task.checkCancellation()
        let scanned = try await BrowserInspector().scan()
        guard let originalRoot = session.members.first(where: { $0.pid == session.rootPID }) else {
            throw BrowserInspectionError.sessionChanged
        }
        let freshByPID: [Int32: ProcessRecord]
        let retryAfterRootExit: Bool
        if let current = scanned.first(where: { $0.id == session.id }), current.canClose,
           current.classification == .automation, current.profileURL == session.profileURL,
           let currentRoot = current.members.first(where: { $0.pid == session.rootPID }),
           BrowserSessionBuilder.sameIdentity(originalRoot, currentRoot),
           originalRoot.executablePath == currentRoot.executablePath,
           canStillIdentifyForSignal(originalRoot) {
            freshByPID = Dictionary(current.members.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            retryAfterRootExit = false
        } else if force, liveness(originalRoot) == .exited {
            // 不从新扫描扩展 PID；原始不可变快照是已确认的归属来源。
            let verified = session.members.filter {
                $0.pid != session.rootPID && canRetryAfterRootExit($0, session: session)
            }
            freshByPID = Dictionary(verified.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            retryAfterRootExit = true
        } else {
            throw BrowserInspectionError.sessionChanged
        }
        let requested = session.members.map(\.pid)
        var signalled: [Int32] = []
        var skipped: [Int32] = []
        // 根进程先收到退出请求，留出短暂时间让浏览器自行清理 renderer。
        try Task.checkCancellation()
        if !retryAfterRootExit {
            try ProcessActions.terminate(originalRoot, force: force)
            signalled.append(originalRoot.pid)
            try await Task.sleep(for: .milliseconds(300))
        } else {
            skipped.append(originalRoot.pid)
        }
        for record in session.members where record.pid != session.rootPID {
            try Task.checkCancellation()
            guard let fresh = freshByPID[record.pid], BrowserSessionBuilder.sameIdentity(record, fresh),
                  canStillIdentifyForSignal(record),
                  !retryAfterRootExit || canRetryAfterRootExit(record, session: session) else {
                skipped.append(record.pid)
                continue
            }
            do {
                try ProcessActions.terminate(record, force: force)
                signalled.append(record.pid)
            } catch {
                // 某个成员已退出或变为受保护对象时不扩大操作范围，继续回读其他成员。
                skipped.append(record.pid)
            }
        }
        try await Task.sleep(for: .milliseconds(650))
        let statuses = session.members.map { ($0.pid, liveness($0)) }
        let remaining = statuses.filter { $0.1 == .running }.map(\.0)
        let unverified = statuses.filter { $0.1 == .unknown }.map(\.0)
        let profileExists = session.profileURL.map { FileManager.default.fileExists(atPath: $0.path) }
        let message: String
        if remaining.isEmpty && unverified.isEmpty {
            message = "已确认原快照中的进程全部退出。配置目录未删除。"
        } else {
            message = "已发送\(force ? "强制退出" : "正常退出")请求，仍有 \(remaining.count) 个原快照进程运行、\(unverified.count) 个无法确认；请重新扫描。配置目录未删除。"
        }
        return BrowserCloseReport(sessionID: session.id, rootPID: session.rootPID, requestedPIDs: requested,
                                  signalledPIDs: signalled, remainingPIDs: remaining,
                                  unverifiedPIDs: unverified, skippedPIDs: skipped,
                                  profileStillExists: profileExists, message: message)
    }

    private static func canStillIdentifyForSignal(_ record: ProcessRecord) -> Bool {
        guard let identity = record.identity, let info = readBSDInfo(record.pid) else { return false }
        // 僵尸已结束执行，不再计入仍在运行；PID 重用也不算原实例残留。
        return info.pbi_status != UInt32(SZOMB)
            && info.pbi_start_tvsec == identity.startSeconds
            && info.pbi_start_tvusec == identity.startMicroseconds
            && info.pbi_uid == identity.ownerUID && info.pbi_ruid == identity.realUID
            && readExecutablePath(record.pid) == record.executablePath
    }

    private static func canRetryAfterRootExit(_ record: ProcessRecord, session: BrowserSession) -> Bool {
        guard canStillIdentifyForSignal(record), ProcessActions.canTerminate(record),
              BrowserSessionBuilder.isBrowserExecutable(record.executablePath),
              let argv = BrowserArguments.read(pid: record.pid) else { return false }
        if let bundle = BrowserSessionBuilder.applicationBundlePath(record.executablePath),
           FileManager.default.fileExists(atPath: bundle + "/Contents/Frameworks/Electron Framework.framework") {
            return false
        }
        let profile = BrowserArguments.profile(in: argv)
        if let profile, BrowserSessionBuilder.isDailyProfile(profile) { return false }
        if let profile, profile != session.profileURL { return false }
        let sameProfile = session.profileURL != nil && profile == session.profileURL
        let automation = BrowserArguments.has("--headless", in: argv)
            || BrowserArguments.has("--enable-automation", in: argv)
            || BrowserArguments.has("--remote-debugging-pipe", in: argv)
            || BrowserArguments.has("--remote-debugging-port", in: argv)
        return sameProfile || automation
    }

    private enum Liveness { case exited, running, unknown }

    /// 回读存活状态不复用信号资格：同一进程 exec / 变更 UID 后仍然算存活。
    private static func liveness(_ record: ProcessRecord) -> Liveness {
        guard let identity = record.identity else { return .unknown }
        if let info = readBSDInfo(record.pid) {
            guard info.pbi_start_tvsec == identity.startSeconds,
                  info.pbi_start_tvusec == identity.startMicroseconds else { return .exited }
            return info.pbi_status == UInt32(SZOMB) ? .exited : .running
        }
        // signal 0 只查询存在性，不向进程投递信号；权限不足不能冒充“已退出”。
        if Darwin.kill(record.pid, 0) == 0 { return .unknown }
        return errno == ESRCH ? .exited : .unknown
    }
}
