import Darwin
import Foundation
import ProcessCore
import XCTest

@MainActor
final class ProcessCoreTests: XCTestCase {
    func testRealSamplingAndInitialDeltaBaseline() async throws {
        let sampler = ProcessSampler()
        let first = try await sampler.sample()
        XCTAssertFalse(first.processes.isEmpty)
        XCTAssertEqual(first.cpuPercent, 0, "首帧建立 CPU 计数基线")
        XCTAssertEqual(first.networkBytesPerSecond, 0, "首帧建立网络计数基线")
        XCTAssertGreaterThan(first.memoryTotalBytes, 0)
        XCTAssertGreaterThan(first.memoryUsedBytes, 0)
        XCTAssertLessThanOrEqual(first.memoryUsedBytes, first.memoryTotalBytes)
        XCTAssertGreaterThan(first.diskTotalBytes, 0)
        XCTAssertLessThanOrEqual(first.diskUsedBytes, first.diskTotalBytes)
        XCTAssertEqual(Set(first.processes.map(\.pid)).count, first.processes.count)

        let ownRecord = try XCTUnwrap(first.processes.first { $0.pid == getpid() })
        XCTAssertGreaterThan(ownRecord.threadCount, 0)
        XCTAssertGreaterThan(ownRecord.memoryBytes, 0)
        XCTAssertFalse(ownRecord.executablePath.isEmpty)

        try await Task.sleep(for: .milliseconds(200))
        let second = try await sampler.sample()
        XCTAssertTrue(second.cpuPercent.isFinite)
        XCTAssertTrue((0...100).contains(second.cpuPercent))
        XCTAssertGreaterThanOrEqual(second.networkUploadPerSecond, 0)
        XCTAssertGreaterThanOrEqual(second.networkDownloadPerSecond, 0)
        XCTAssertTrue(second.networkBytesPerSecond.isFinite)
        XCTAssertEqual(second.networkBytesPerSecond,
                       second.networkUploadPerSecond + second.networkDownloadPerSecond,
                       accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(second.collectedAt, first.collectedAt)
    }

    func testOwnAndSystemProcessesAreProtectedAndPublicRecordsCannotForgeIdentity() async throws {
        let snapshot = try await ProcessSampler().sample()
        let ownRecord = try XCTUnwrap(snapshot.processes.first { $0.pid == getpid() })
        XCTAssertFalse(ProcessActions.canTerminate(ownRecord))
        XCTAssertThrowsError(try ProcessActions.terminate(ownRecord)) { error in
            guard case ProcessCoreError.protectedProcess = error else {
                return XCTFail("自身保护返回了错误的原因：\(error)")
            }
        }
        if let launchd = snapshot.processes.first(where: { $0.pid == 1 }) {
            XCTAssertFalse(ProcessActions.canTerminate(launchd))
            XCTAssertThrowsError(try ProcessActions.terminate(launchd, force: true))
        }

        let forged = ProcessRecord(
            pid: 222_222, parentPID: 1, name: "伪造记录", user: NSUserName(),
            cpuPercent: 0, memoryBytes: 0, threadCount: 0, state: "S", elapsed: "00:00",
            executablePath: "/tmp/does-not-exist", isApplication: false
        )
        XCTAssertFalse(ProcessActions.canTerminate(forged))
        XCTAssertThrowsError(try ProcessActions.terminate(forged)) { error in
            guard case ProcessCoreError.identityUnavailable = error else {
                return XCTFail("公开初始化器应无法构造信号操作身份：\(error)")
            }
        }
    }

    func testListeningPortsDiscoversAnOwnedLoopbackSocket() async throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = UInt8(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(descriptor, 1), 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &size)
            }
        }
        XCTAssertEqual(named, 0)
        let port = String(UInt16(bigEndian: address.sin_port))
        let ports = try await ProcessSampler().listeningPorts()
        XCTAssertTrue(ports.contains { $0.pid == getpid() && $0.port == port && $0.protocolName == "TCP" })
        XCTAssertEqual(Set(ports.map(\.id)).count, ports.count)
    }

    func testSignalsOnlyTargetOwnedFixtureAndRejectItsStaleRecord() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cduyzh-process-core-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.c")
        let executable = directory.appendingPathComponent("owned-process-fixture")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)

        // 构建自有进程；复制系统 /bin/sleep 可能被 AMFI 直接 SIGKILL，无法验证 SIGTERM。
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            return XCTFail("无法编译自有测试进程：\(compiler.terminationStatus)")
        }

        let sampler = ProcessSampler()
        for force in [false, true] {
            let child = Process()
            child.executableURL = executable
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            defer {
                if child.isRunning { child.terminate() }
                child.waitUntilExit()
            }
            let snapshot = try await sampler.sample()
            let record = try XCTUnwrap(snapshot.processes.first { $0.pid == child.processIdentifier })
            XCTAssertTrue(ProcessActions.canTerminate(record))
            try ProcessActions.terminate(record, force: force)
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .uncaughtSignal)
            XCTAssertEqual(child.terminationStatus, force ? SIGKILL : SIGTERM)
            XCTAssertFalse(ProcessActions.canTerminate(record))
            XCTAssertThrowsError(try ProcessActions.terminate(record)) { error in
                guard case ProcessCoreError.processChanged = error else {
                    return XCTFail("陈旧记录应被拒绝：\(error)")
                }
            }
        }
    }

    func testCancelledSamplingDoesNotPublishSnapshot() async throws {
        let sampler = ProcessSampler()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sampler.sample()
        }
        do {
            _ = try await task.value
            XCTFail("已取消的任务不应返回快照")
        } catch is CancellationError {
            // 任务取消得到传播。
        }
    }
}
