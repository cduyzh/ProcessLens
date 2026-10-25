import Darwin
import Foundation

struct StartupCommandResult: Sendable {
    let status: Int32
    let output: String
}

protocol StartupCommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> StartupCommandResult
}

struct StartupSystemCommands: StartupCommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> StartupCommandResult {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        try process.run()
        let watch = StartupCommandWatch(process)
        let timeout = DispatchWorkItem { watch.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard !watch.didExpire else { throw StartupError.commandFailed("启动项命令读取超时。") }
        return StartupCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

private final class StartupCommandWatch: @unchecked Sendable {
    private let process: Process
    private let identity: proc_bsdinfo?
    private let lock = NSLock()
    private var expired = false
    init(_ process: Process) { self.process = process; identity = readBSDInfo(process.processIdentifier) }
    var didExpire: Bool { lock.withLock { expired } }
    func expire() {
        guard process.isRunning else { return }
        lock.withLock { expired = true }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            guard process.isRunning, let original = identity, let now = readBSDInfo(process.processIdentifier),
                  now.pbi_start_tvsec == original.pbi_start_tvsec,
                  now.pbi_start_tvusec == original.pbi_start_tvusec else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

enum StartupLaunchctl {
    /// 同名 SMAppService 可在 app 包内动态注册，不一定出现在传统 LaunchAgents 目录。
    /// 只接受该 Label 尚未加载，或其顶层 path 正是我们核对过的原 plist。
    static func validateLoadedService(label: String, originalURL: URL, environment: StartupEnvironment,
                                      runner: any StartupCommandRunning) throws {
        let target = "gui/\(environment.uid)/\(label)"
        let result = try runner.run("/bin/launchctl", ["print", target])
        if result.status != 0 {
            let missing = "Could not find service \"\(label)\" in domain for user gui: \(environment.uid)"
            guard result.status == 113, result.output.split(separator: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == missing
            }) else { throw StartupError.refused("无法确认已加载同 Label 服务的来源，禁止修改启动资格。") }
            return
        }
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == target + " = {" else {
            throw StartupError.refused("launchctl 服务身份输出未知，禁止修改启动资格。")
        }
        var depth = 0
        var paths: [String] = []
        for line in lines {
            if depth == 1, line.hasPrefix("path = ") {
                paths.append(String(line.dropFirst("path = ".count)))
            }
            if line.hasSuffix("= {") || line == "{" { depth += 1 }
            else if line == "}" { depth -= 1 }
            guard depth >= 0 else { throw StartupError.refused("launchctl 服务结构未知，禁止修改启动资格。") }
        }
        guard depth == 0, paths.count == 1, paths[0].hasPrefix("/"),
              URL(fileURLWithPath: paths[0]).standardizedFileURL == originalURL.standardizedFileURL else {
            throw StartupError.refused("已加载的同 Label 服务来源不同或不明；可能由 app 内 SMAppService 注册，禁止修改。")
        }
    }

    static func overrides(_ output: String) throws -> [String: Bool] {
        guard output.contains("disabled services"), output.contains("{"), output.contains("}") else {
            throw StartupError.commandFailed("无法解析 launchctl 停用状态，未将未知状态当作启用。")
        }
        var result: [String: Bool] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "disabled services = {" || line == "}" || line.isEmpty { continue }
            guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else {
                throw StartupError.commandFailed("launchctl 返回了无法识别的停用状态格式。")
            }
            let label = String(line[line.index(after: line.startIndex)..<end])
            let remainder = line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard remainder.hasPrefix("=>"), result[label] == nil else {
                throw StartupError.commandFailed("launchctl 返回了重复或无法识别的停用状态。")
            }
            let value = remainder.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";,"))
            if value == "true" || value == "disabled" { result[label] = true }
            else if value == "false" || value == "enabled" { result[label] = false }
            else { throw StartupError.commandFailed("launchctl 返回了未知停用状态。") }
        }
        return result
    }

    static func read(_ runner: any StartupCommandRunning, domain: String) throws -> [String: Bool] {
        let result = try runner.run("/bin/launchctl", ["print-disabled", domain])
        guard result.status == 0 else { throw StartupError.commandFailed("无法读取 \(domain) 的 launchctl 状态（\(result.status)）。") }
        return try overrides(result.output)
    }

    static func set(_ disabled: Bool, label: String, environment: StartupEnvironment,
                    runner: any StartupCommandRunning) throws {
        let target = "gui/\(environment.uid)/\(label)"
        let result = try runner.run("/bin/launchctl", [disabled ? "disable" : "enable", target])
        guard result.status == 0 else { throw StartupError.commandFailed("launchctl \(disabled ? "disable" : "enable") 失败（\(result.status)）。") }
        let states = try read(runner, domain: "gui/\(environment.uid)")
        guard states[label] == disabled else { throw StartupError.commandFailed("launchctl 修改后状态未确认，请重新扫描。") }
    }
}
