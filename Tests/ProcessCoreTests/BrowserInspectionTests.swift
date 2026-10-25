import Darwin
import Foundation
@testable import ProcessCore
import XCTest

@MainActor
final class BrowserInspectionTests: XCTestCase {
    private func record(
        _ pid: Int32, parent: Int32 = 1, name: String = "Google Chrome for Testing",
        path: String? = nil, uid: UInt32 = 501, start: UInt64 = 1000
    ) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: parent, name: name, user: "fixture", cpuPercent: 0,
                      memoryBytes: 1024, threadCount: 1, state: "S", elapsed: "01:00",
                      executablePath: path ?? "/fixture/\(name)", isApplication: false,
                      bundleIdentifier: nil,
                      identity: ProcessIdentity(ownerUID: uid, realUID: uid, flags: 0,
                                                startSeconds: start, startMicroseconds: 17))
    }

    private func sessions(
        _ records: [ProcessRecord], argv: [Int32: [String]], electron: Set<Int32> = []
    ) -> [BrowserSession] {
        BrowserSessionBuilder.build(records: records, arguments: argv, electronPIDs: electron,
                                    currentUID: 501, now: Date(timeIntervalSince1970: 2000),
                                    canControl: { _ in true })
    }

    func testProcArgsParserPreservesArgumentBoundariesAndExcludesEnvironment() throws {
        let argv = ["/fixture/chrome", "--user-data-dir", "/tmp/profile with spaces", "", "https://example.test/?token=secret"]
        var argc = Int32(argv.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/fixture/chrome".utf8) + [0, 0, 0]
        for argument in argv { bytes += Array(argument.utf8) + [0] }
        bytes += Array("SECRET_ENV=should-never-be-parsed".utf8) + [0]
        XCTAssertEqual(BrowserArguments.parse(bytes), argv)
        XCTAssertNil(BrowserArguments.parse([0, 0, 0]))
        XCTAssertNil(BrowserArguments.parse([255, 255, 255, 127, 0]))
        XCTAssertEqual(BrowserArguments.value("--user-data-dir", in: argv), "")
        XCTAssertNil(BrowserArguments.profile(in: argv), "Chromium 不会把下一个 argv 当成开关值")
        XCTAssertEqual(BrowserArguments.value("--user-data-dir", in: ["chrome", "--user-data-dir=/tmp/profile with spaces"]), "/tmp/profile with spaces")
    }

    func testAutomationGroupsOnlyItsAncestryAndExplicitProfile() throws {
        let records = [record(100, parent: 50),
                       record(101, parent: 100, name: "Google Chrome for Testing Helper (Renderer)"),
                       record(102, parent: 100, name: "chrome_crashpad_handler"),
                       record(103, name: "Google Chrome Helper (GPU)"),
                       record(200, name: "Google Chrome"), record(201, parent: 200, name: "Google Chrome Helper"),
                       record(50, parent: 40, name: "node"),
                       record(40, parent: 1, name: "Electron", path: "/Applications/Trae CN.app/Contents/MacOS/Electron")]
        let argv: [Int32: [String]] = [
            100: ["chrome", "--headless=new", "--enable-automation", "--user-data-dir=/tmp/browser-fixture-a"],
            101: ["chrome", "--type=renderer"],
            103: ["chrome", "--type=gpu-process", "--user-data-dir=/tmp/browser-fixture-a"],
            200: ["chrome"], 201: ["chrome", "--type=renderer"]
        ]
        let found = sessions(records, argv: argv)
        let automation = try XCTUnwrap(found.first { $0.rootPID == 100 })
        XCTAssertEqual(Set(automation.members.map(\.pid)), [100, 101, 102, 103])
        XCTAssertEqual(automation.residentMemoryBytes, 4096)
        XCTAssertTrue(automation.canClose)
        XCTAssertEqual(automation.classification, .automation)
        XCTAssertEqual(automation.ownerDescription, "Trae CN · 父进程 node (PID 50)")
        XCTAssertTrue(automation.ancestorChain.contains("Electron (PID 40) · Trae CN"))
        XCTAssertFalse(automation.isOrphanCandidate)
        XCTAssertEqual(automation.age, 1000)
        let daily = try XCTUnwrap(found.first { $0.rootPID == 200 })
        XCTAssertEqual(Set(daily.members.map(\.pid)), [200, 201])
        XCTAssertFalse(daily.canClose)
        XCTAssertEqual(daily.classification, .dailyBrowser)
    }

    func testDailyProfilesAndOrdinaryElectronStayProtectedDespiteAutomationFlags() throws {
        let argv: [Int32: [String]] = [
            100: ["chrome", "--headless", "--enable-automation", "--user-data-dir=/Users/example/Library/Application Support/Google/Chrome"],
            200: ["Electron", "--remote-debugging-port=9222", "--user-data-dir=/tmp/electron-fixture"],
            300: ["chrome", "--headless", "--enable-automation"],
            400: ["chrome", "--user-data-dir=/Users/example/custom-browser-profile"],
            500: ["chrome", "--user-data-dir=/tmp/my-personal-profile"]
        ]
        let found = sessions([record(100), record(200, name: "Electron"), record(300), record(400), record(500)],
                             argv: argv, electron: [200])
        XCTAssertFalse(found.contains(where: \.canClose))
        XCTAssertEqual(found.first { $0.rootPID == 100 }?.classification, .dailyBrowser)
        XCTAssertEqual(found.first { $0.rootPID == 200 }?.classification, .application)
        XCTAssertEqual(found.first { $0.rootPID == 300 }?.classification, .dailyBrowser)
        XCTAssertEqual(found.first { $0.rootPID == 400 }?.classification, .unverified)
        XCTAssertEqual(found.first { $0.rootPID == 500 }?.classification, .unverified)
    }

    func testChromiumEffectiveSwitchesCannotBypassDailyProfileProtection() throws {
        let daily = "/Users/example/Library/Application Support/Google/Chrome"
        let repeated = ["chrome", "--headless", "--user-data-dir=/tmp/test", "-user-data-dir=" + daily]
        XCTAssertEqual(BrowserArguments.profile(in: repeated)?.path, daily)
        let protected = try XCTUnwrap(sessions([record(100)], argv: [100: repeated]).first)
        XCTAssertFalse(protected.canClose)
        let terminatedSwitches = ["chrome", "--", "--headless", "--user-data-dir=/tmp/test"]
        XCTAssertFalse(BrowserArguments.has("--headless", in: terminatedSwitches))
        XCTAssertNil(BrowserArguments.profile(in: terminatedSwitches))
    }

    func testLaunchdParentIsOnlyACandidateAndForeignMemberBlocksClosing() throws {
        let argv: [Int32: [String]] = [100: ["chrome", "--enable-automation", "--user-data-dir=/tmp/browser-fixture"]]
        let candidate = try XCTUnwrap(sessions([record(100)], argv: argv).first)
        XCTAssertTrue(candidate.isOrphanCandidate)
        XCTAssertTrue(candidate.evidence.contains { $0.contains("不代表已确认孤儿") })
        XCTAssertTrue(candidate.risk.contains("仍被自动化任务使用"))
        let mixed = try XCTUnwrap(sessions([record(100), record(101, parent: 100, name: "Google Chrome Helper", uid: 502)], argv: argv).first)
        XCTAssertFalse(mixed.canClose)
        XCTAssertTrue(mixed.closeRestriction?.contains("不全属于当前用户") == true)
    }

    func testRedactedCommandContainsOnlyAllowedFlags() throws {
        let summary = BrowserArguments.redacted(executable: "/tmp/chrome", arguments: [
            "chrome", "--headless=new", "--enable-automation", "--remote-debugging-port=9222",
            "--user-data-dir=/tmp/profile-private-token", "https://example.test/?token=secret-token",
            "--proxy-server=https://user:private-password@example.test", "--headers=Authorization:Bearer private-bearer",
            "--type=renderer", "--remote-debugging-address=private-address"
        ])
        for secret in ["secret-token", "private-password", "private-bearer", "private-address", "profile-private-token", "example.test"] {
            XCTAssertFalse(summary.contains(secret))
        }
        XCTAssertTrue(summary.contains("--headless"))
        XCTAssertTrue(summary.contains("--remote-debugging-port=9222"))
        XCTAssertTrue(summary.contains("--user-data-dir=[本地配置目录]"))
    }

    func testChangedSnapshotCannotSendSignals() async throws {
        let fake = try XCTUnwrap(sessions([record(222_222, name: "headless_shell")],
                                           argv: [222_222: ["headless_shell", "--headless"]]).first)
        XCTAssertTrue(fake.canClose)
        do {
            _ = try await BrowserSessionActions.close(fake)
            XCTFail("不存在的进程身份应被重新扫描拒绝")
        } catch BrowserInspectionError.sessionChanged {
            // 完全伪造的测试快照不会给任何真实浏览器发送信号。
        }
    }

    func testControlledCloseUsesOnlyOwnedFixtureAndNeverEscalatesImplicitly() async throws {
        try await exerciseOwnedFixture(rootIgnoresTERM: true)
    }

    func testExitedRootCanForceOnlyItsOriginalSurvivingRenderer() async throws {
        try await exerciseOwnedFixture(rootIgnoresTERM: false)
    }

    private func exerciseOwnedFixture(rootIgnoresTERM: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cduyzh-browser-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = directory.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("fixture.c")
        let executable = directory.appendingPathComponent("headless_shell")
        try """
        #include <unistd.h>
        #include <signal.h>
        #include <string.h>
        int main(int argc, char **argv) {
            signal(SIGTERM, SIG_IGN);
            if (argc > 1 && strcmp(argv[1], "--type=renderer") == 0) {
                pid_t owner = getppid();
                int orphan_ticks = 0;
                for (int i = 0; i < 300; i++) {
                    if (owner == 1 || getppid() != owner) { orphan_ticks++; }
                    if (orphan_ticks > 50) { return 0; }
                    usleep(100000);
                }
                return 0;
            }
            for (int i = 1; i < argc; i++) {
                if (strcmp(argv[i], "--fixture-root-exits") == 0) { signal(SIGTERM, SIG_DFL); }
            }
            if (fork() == 0) { execl(argv[0], argv[0], "--type=renderer", argv[1], (char *)0); _exit(1); }
            sleep(30); return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { return XCTFail("自有 fixture 编译失败") }

        let child = Process()
        child.executableURL = executable
        child.arguments = ["--user-data-dir=" + profile.path, "--headless"]
        if !rootIgnoresTERM { child.arguments?.append("--fixture-root-exits") }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        var ownedMembers: [ProcessRecord] = []
        defer {
            for member in ownedMembers where ProcessActions.canTerminate(member) {
                try? ProcessActions.terminate(member, force: true)
            }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            // 失败在首次完整快照之前时，fixture 后代也会在父退出后 5 秒内自行结束。
            usleep(ownedMembers.count < 2 ? 5_200_000 : 200_000)
        }
        let inspector = BrowserInspector()
        var ownedSession: BrowserSession?
        for _ in 0..<20 {
            let scanned = try await inspector.scan()
            if let session = scanned.first(where: { $0.rootPID == child.processIdentifier }) {
                ownedMembers = session.members
                if session.members.count == 2 { ownedSession = session; break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let session = try XCTUnwrap(ownedSession)
        XCTAssertTrue(session.canClose)
        XCTAssertEqual(session.members.count, 2)
        let normal = try await BrowserSessionActions.close(session)
        XCTAssertEqual(Set(normal.requestedPIDs), Set(session.members.map(\.pid)))
        XCTAssertFalse(normal.remainingPIDs.isEmpty, "忽略 SIGTERM 的 fixture 应继续运行，不得自动升级")
        XCTAssertEqual(child.isRunning, rootIgnoresTERM)
        if !rootIgnoresTERM {
            XCTAssertFalse(normal.remainingPIDs.contains(child.processIdentifier))
            XCTAssertEqual(normal.remainingPIDs.count, 1)
        }
        let forced = try await BrowserSessionActions.close(session, force: true)
        child.waitUntilExit()
        XCTAssertTrue(forced.remainingPIDs.isEmpty)
        XCTAssertEqual(child.terminationStatus, rootIgnoresTERM ? SIGKILL : SIGTERM)
        XCTAssertTrue(forced.unverifiedPIDs.isEmpty)
        XCTAssertEqual(forced.profileStillExists, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path), "进程操作不得删除配置目录")
    }
}
