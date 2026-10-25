import Darwin
import Foundation

/// 在独立 actor 读取真实 argv。参数仅在内存中用于判定，公开快照只保留白名单摘要。
public actor BrowserInspector {
    private let sampler = ProcessSampler()

    public init() {}

    public func scan() async throws -> [BrowserSession] {
        let snapshot = try await sampler.sample()
        try Task.checkCancellation()
        var arguments: [Int32: [String]] = [:]
        var electronBundles: [String: Bool] = [:]
        var electronPIDs: Set<Int32> = []
        for record in snapshot.processes {
            try Task.checkCancellation()
            let electron: Bool
            if let bundle = BrowserSessionBuilder.applicationBundlePath(record.executablePath) {
                if let cached = electronBundles[bundle] { electron = cached }
                else {
                    electron = FileManager.default.fileExists(atPath: bundle + "/Contents/Frameworks/Electron Framework.framework")
                    electronBundles[bundle] = electron
                }
            } else { electron = record.name.caseInsensitiveCompare("Electron") == .orderedSame }
            if electron { electronPIDs.insert(record.pid) }
            if electron || BrowserSessionBuilder.isBrowserExecutable(record.executablePath)
                || BrowserSessionBuilder.isCrashHandler(record.executablePath) {
                if let argv = BrowserArguments.read(pid: record.pid) { arguments[record.pid] = argv }
            }
        }
        let sessions = BrowserSessionBuilder.build(
            records: snapshot.processes, arguments: arguments, electronPIDs: electronPIDs,
            currentUID: getuid(), now: snapshot.collectedAt,
            canControl: ProcessActions.canTerminate
        )
        try Task.checkCancellation()
        return sessions
    }
}

enum BrowserArguments {
    static func read(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var argumentMax: Int32 = 0
        var maxSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.argmax", &argumentMax, &maxSize, nil, 0) != 0 { argumentMax = 262_144 }
        var size = min(max(Int(argumentMax), 4096), 1_048_576)
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parse(Array(bytes.prefix(size)))
    }

    /// KERN_PROCARGS2 = argc + exec path + NUL padding + argc 个 NUL 分隔参数 + 环境变量。
    static func parse(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 65_536 else { return nil }
        var offset = 4
        guard let execEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = execEnd + 1
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<Int(argc) {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: bytes[offset..<end], as: UTF8.self))
            offset = end + 1
        }
        return arguments
    }

    static func value(_ flag: String, in arguments: [String]) -> String? {
        switches(in: arguments)[String(flag.drop(while: { $0 == "-" }))]
    }

    static func has(_ flag: String, in arguments: [String]) -> Bool {
        value(flag, in: arguments) != nil
    }

    private static func switches(in arguments: [String]) -> [String: String] {
        // 遵循 Chromium POSIX CommandLine：= 内取值、重复开关最后一个生效、-- 停止解析。
        // 不把分离的下一个 argv 当成值，否则会误将实际使用默认资料的 Chrome 判为隔离实例。
        // https://github.com/chromium/chromium/blob/main/base/command_line.cc
        let whitespace = CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}")
        var result: [String: String] = [:]
        for raw in arguments.dropFirst() {
            let argument = raw.trimmingCharacters(in: whitespace)
            if argument == "--" { break }
            let switchBody: Substring
            if argument.hasPrefix("--") { switchBody = argument.dropFirst(2) }
            else if argument.hasPrefix("-") { switchBody = argument.dropFirst() }
            else { continue }
            guard !switchBody.isEmpty else { continue }
            let parts = switchBody.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            result[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
        }
        return result
    }

    static func profile(in arguments: [String]) -> URL? {
        guard let path = value("--user-data-dir", in: arguments), path.hasPrefix("/"),
              !path.contains("\n"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func redacted(executable: String, arguments: [String]?) -> String {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard let arguments else { return name + " [启动参数不可读取]" }
        var summary = [name]
        for flag in ["--headless", "--enable-automation", "--remote-debugging-pipe", "--no-startup-window"] {
            if has(flag, in: arguments) { summary.append(flag) }
        }
        if let port = value("--remote-debugging-port", in: arguments), UInt16(port) != nil {
            summary.append("--remote-debugging-port=" + port)
        }
        if let type = value("--type", in: arguments),
           ["renderer", "utility", "gpu-process", "zygote", "broker"].contains(type) {
            summary.append("--type=" + type)
        }
        if profile(in: arguments) != nil { summary.append("--user-data-dir=[本地配置目录]") }
        // URL、headers、代理、扩展参数、环境变量及所有其他参数都不进入展示结果。
        return summary.joined(separator: " ")
    }
}

enum BrowserSessionBuilder {
    private struct Facts {
        let record: ProcessRecord
        let arguments: [String]?
        let electron: Bool
        let profile: URL?
        let subprocess: Bool
    }

    static func applicationBundlePath(_ path: String) -> String? {
        guard let marker = path.range(of: ".app/") else { return nil }
        return String(path[..<marker.lowerBound]) + ".app"
    }

    static func isBrowserExecutable(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return ["google chrome", "google chrome for testing", "chromium", "chrome", "headless_shell",
                "chrome-headless-shell", "microsoft edge", "brave browser", "vivaldi", "opera"]
            .contains(name)
            || ["google chrome helper", "google chrome for testing helper", "chromium helper", "microsoft edge helper", "brave browser helper"]
                .contains { name.hasPrefix($0) }
    }

    static func isCrashHandler(_ path: String) -> Bool {
        ["chrome_crashpad_handler", "crashpad_handler"].contains(URL(fileURLWithPath: path).lastPathComponent)
    }

    static func isDailyProfile(_ profile: URL) -> Bool {
        let path = profile.path.lowercased()
        let suffixes = ["/library/application support/google/chrome", "/library/application support/chromium",
                        "/library/application support/microsoft edge", "/library/application support/bravesoftware/brave-browser",
                        "/library/application support/vivaldi", "/library/application support/arc",
                        "/library/application support/com.operasoftware.opera"]
        return suffixes.contains { path.contains($0 + "/") || path.hasSuffix($0) }
    }

    static func isAutomationProfile(_ profile: URL) -> Bool {
        let path = profile.path.lowercased()
        return path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
            || path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/")
            || path.contains("/browser-qa/") || path.contains("/playwright/")
            || path.contains("/playwright_") || path.contains("/puppeteer_")
    }

    static func sameIdentity(_ left: ProcessRecord, _ right: ProcessRecord) -> Bool {
        guard let a = left.identity, let b = right.identity else { return false }
        return left.pid == right.pid && a.ownerUID == b.ownerUID && a.realUID == b.realUID
            && a.startSeconds == b.startSeconds && a.startMicroseconds == b.startMicroseconds
    }

    static func build(
        records: [ProcessRecord], arguments: [Int32: [String]], electronPIDs: Set<Int32>,
        currentUID: UInt32, now: Date, canControl: (ProcessRecord) -> Bool
    ) -> [BrowserSession] {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let facts: [Int32: Facts] = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            let electron = electronPIDs.contains(record.pid)
            guard electron || isBrowserExecutable(record.executablePath) else { return nil }
            let argv = arguments[record.pid]
            let helperName = record.name.lowercased().contains("helper")
            return (record.pid, Facts(record: record, arguments: argv, electron: electron,
                                     profile: argv.flatMap(BrowserArguments.profile),
                                     subprocess: helperName || argv.map { BrowserArguments.has("--type", in: $0) } == true))
        })
        var rootPIDs = Set(facts.values.filter { !$0.subprocess }.map { $0.record.pid })

        func nearestRoot(for pid: Int32) -> Int32? {
            var visited: Set<Int32> = []
            var cursor = byPID[pid]?.parentPID ?? 0
            while cursor > 1, visited.insert(cursor).inserted {
                if rootPIDs.contains(cursor) { return cursor }
                cursor = byPID[cursor]?.parentPID ?? 0
            }
            return nil
        }

        // 不带可见主进程的 helper 也展示；只有明确自有自动化证据才允许后续退出。
        var unresolved = facts.values.filter { !rootPIDs.contains($0.record.pid) && nearestRoot(for: $0.record.pid) == nil }
            .sorted { $0.record.pid < $1.record.pid }
        while !unresolved.isEmpty {
            let first = unresolved.removeFirst()
            if let profile = first.profile {
                let matchingRoots = rootPIDs.filter { facts[$0]?.profile == profile }
                if matchingRoots.count == 1 { continue }
            }
            rootPIDs.insert(first.record.pid)
            unresolved.removeAll { fact in
                nearestRoot(for: fact.record.pid) != nil
                    || (first.profile != nil && first.profile == fact.profile && first.electron == fact.electron)
            }
        }

        var memberships = Dictionary(uniqueKeysWithValues: rootPIDs.map { ($0, [Int32]()) })
        for fact in facts.values {
            let pid = fact.record.pid
            if rootPIDs.contains(pid) { memberships[pid, default: []].append(pid); continue }
            if let root = nearestRoot(for: pid) { memberships[root, default: []].append(pid); continue }
            if let profile = fact.profile {
                let roots = rootPIDs.filter { facts[$0]?.profile == profile && facts[$0]?.electron == fact.electron }
                if roots.count == 1, let root = roots.first { memberships[root, default: []].append(pid) }
            }
        }
        // crashpad 没有 user-data-dir；仅用可证明的直接祖先关系纳入，不凭相同名字关联。
        for record in records where isCrashHandler(record.executablePath) {
            if let root = nearestRoot(for: record.pid) { memberships[root, default: []].append(record.pid) }
        }

        return rootPIDs.compactMap { rootPID -> BrowserSession? in
            guard let root = facts[rootPID] else { return nil }
            let members = (memberships[rootPID] ?? [rootPID]).compactMap { byPID[$0] }
                .sorted { left, right in
                    if (left.pid == rootPID) != (right.pid == rootPID) { return left.pid == rootPID }
                    return left.pid < right.pid
                }
            let argv = root.arguments ?? []
            let headless = BrowserArguments.has("--headless", in: argv)
                || ["headless_shell", "chrome-headless-shell"].contains(root.record.name.lowercased())
            let automation = BrowserArguments.has("--enable-automation", in: argv)
            let debug = BrowserArguments.has("--remote-debugging-port", in: argv)
                || BrowserArguments.has("--remote-debugging-pipe", in: argv)
            let automationProfile = root.profile.map(isAutomationProfile) ?? false
            let dailyProfile = root.profile.map(isDailyProfile) ?? false
            let dedicatedShell = ["headless_shell", "chrome-headless-shell"].contains(root.record.name.lowercased())
            let explicitAutomation = root.arguments != nil && (headless || automation || debug)
            let isolatedProfile = root.profile != nil && !dailyProfile
            let classification: BrowserSessionClassification
            if root.electron { classification = .application }
            else if dailyProfile || (!isolatedProfile && !dedicatedShell) { classification = .dailyBrowser }
            else if explicitAutomation { classification = .automation }
            else { classification = .unverified }
            var evidence: [String] = []
            if root.arguments == nil { evidence.append("当前权限无法读取启动参数") }
            if headless { evidence.append("无头浏览器标记") }
            if automation { evidence.append("--enable-automation") }
            if debug { evidence.append("远程调试端口或管道标记") }
            if automationProfile { evidence.append("配置目录位于临时或自动化工具路径") }
            if dailyProfile { evidence.append("配置目录属于日常浏览器用户资料，强制保护") }
            if root.electron { evidence.append("Electron 桌面应用，强制保护") }
            if !isolatedProfile && !dedicatedShell { evidence.append("未确认隔离的配置目录，按日常浏览器保护") }
            if root.subprocess { evidence.append("当前根为独立 helper，未找到可见主进程") }
            let orphan = classification == .automation && root.record.parentPID == 1
            if root.record.parentPID == 1 { evidence.append("父 PID 为 1；仅为来源线索，不代表已确认孤儿") }
            let allOwned = currentUID != 0 && members.allSatisfy {
                $0.identity?.ownerUID == currentUID && $0.identity?.realUID == currentUID
            }
            let canClose = classification == .automation && allOwned && members.allSatisfy(canControl)
            let restriction: String?
            if classification == .dailyBrowser { restriction = "日常配置或未确认隔离配置，禁止整组退出。" }
            else if classification == .application { restriction = "普通 Electron 桌面应用受到保护。" }
            else if classification == .unverified { restriction = "缺少明确的自动化启动证据。" }
            else if !allOwned { restriction = "成员不全属于当前用户，或无法核实进程身份。" }
            else if !canClose { restriction = "至少一个成员属于受保护进程。" }
            else { restriction = nil }
            var ancestorChain: [String] = []
            var nearestAncestorApplication: String?
            var visited: Set<Int32> = []
            var cursor = root.record.parentPID
            while cursor > 0, visited.insert(cursor).inserted, ancestorChain.count < 8 {
                guard let record = byPID[cursor] else {
                    ancestorChain.append("PID \(cursor)（不可读取）")
                    break
                }
                var label = "\(record.name) (PID \(record.pid))"
                if let bundle = applicationBundlePath(record.executablePath) {
                    let application = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                    if !application.isEmpty {
                        if nearestAncestorApplication == nil { nearestAncestorApplication = application }
                        label += " · \(application)"
                    }
                }
                ancestorChain.append(label)
                cursor = record.parentPID
            }
            let owner: String
            if root.record.parentPID == 1 {
                owner = "launchd 接管 · 启动来源需确认"
            } else if let application = nearestAncestorApplication {
                let parent = byPID[root.record.parentPID].map { "\($0.name) (PID \($0.pid))" }
                    ?? ancestorChain.first ?? "不可读取"
                owner = "\(application) · 父进程 \(parent)"
            } else {
                owner = ancestorChain.first ?? "父进程不可见 · 来源需确认"
            }
            let age = root.record.identity.map { max(0, now.timeIntervalSince1970 - Double($0.startSeconds)) }
            let identity = root.record.identity.map { "\($0.startSeconds).\($0.startMicroseconds)" } ?? "unknown"
            let rss = members.reduce(UInt64(0)) { sum, record in
                let (value, overflow) = sum.addingReportingOverflow(record.memoryBytes)
                return overflow ? UInt64.max : value
            }
            return BrowserSession(
                id: "\(rootPID)-\(identity)", rootPID: rootPID, name: root.record.name,
                members: members, residentMemoryBytes: rss, profileURL: root.profile,
                isHeadless: headless, evidence: evidence,
                redactedCommand: BrowserArguments.redacted(executable: root.record.executablePath, arguments: root.arguments),
                ownerDescription: owner, ancestorChain: ancestorChain, age: age,
                classification: classification,
                risk: classification == .automation
                    ? "可能仍被自动化任务使用；确认任务已结束后再退出。RSS 含共享页，不等于可释放内存。"
                    : "受保护，仅供诊断。RSS 含共享页，不等于可释放内存。",
                isOrphanCandidate: orphan, canClose: canClose, closeRestriction: restriction
            )
        }.sorted { lhs, rhs in
            if lhs.canClose != rhs.canClose { return lhs.canClose }
            return lhs.residentMemoryBytes > rhs.residentMemoryBytes
        }
    }
}
