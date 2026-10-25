import Darwin
import Foundation
@testable import ProcessCore
import XCTest

/// 所有 launchctl / sfltool 调用都由内存 runner 接管，文件仅存在本测试独占的沙盒。
@MainActor
final class StartupTests: XCTestCase {
    func testLaunchctlOverrideFormatsAndUnknownNeverBecomeEnabled() throws {
        let parsed = try StartupLaunchctl.overrides("""
        disabled services = {
            "fixture.enabled" => false
            "fixture.disabled" => true
            "fixture.text-enabled" => enabled;
            "fixture.text-disabled" => disabled,
        }
        """)
        XCTAssertEqual(parsed, ["fixture.enabled": false, "fixture.disabled": true,
                                "fixture.text-enabled": false, "fixture.text-disabled": true])
        XCTAssertThrowsError(try StartupLaunchctl.overrides("unsupported output"))
        XCTAssertThrowsError(try StartupLaunchctl.overrides("disabled services = {\n\"fixture\" => maybe\n}"))
        XCTAssertThrowsError(try StartupLaunchctl.overrides("disabled services = {\nunknown output\n}"))
    }

    func testBTMIncludesOnlyCurrentUserStartupRecordsAndResolvesAppRelativePaths() throws {
        let parsed = try StartupBTM.parse("""
        Records for UID 502 :
        #1:
        UUID: foreign
        Identifier: foreign.login
        Type: login item (0x4)
        URL: file:///Applications/Foreign.app
        Disposition: [enabled, allowed, visible]
        Records for UID 501 :
        #1:
        Identifier: fixture.app
        Name: Fixture
        Type: app (0x2)
        URL: file:///Applications/Fixture.app
        #2:
        Identifier: fixture.developer
        Type: developer (0x10)
        #3:
        Identifier: fixture.extension
        Type: quicklook (0x200)
        #4:
        Identifier: fixture.login
        Name: Login Fixture
        Type: login item (0x4)
        URL: file:///Applications/Fixture.app/Contents/Library/LoginItems/Helper.app
        Disposition: [enabled, allowed, visible]
        #5:
        Identifier: fixture.agent
        Type: agent (0x10)
        Parent Identifier: fixture.app
        URL: Contents/Library/LaunchAgents/helper.plist
        Disposition: [disabled, allowed]
        #6:
        Identifier: fixture.unknown
        Type: daemon (0x20)
        Disposition: [enabled, visible]
        #7:
        Identifier: fixture.traditional
        Type: legacy agent (0x100)
        URL: file:///Users/fixture/Library/LaunchAgents/traditional.plist
        Disposition: [enabled, allowed]
        """, uid: 501, existingPlists: ["/Users/fixture/Library/LaunchAgents/traditional.plist"])
        XCTAssertEqual(Set(parsed.map(\.label)), ["fixture.login", "fixture.agent", "fixture.unknown"])
        XCTAssertEqual(parsed.first { $0.label == "fixture.login" }?.state, .enabled)
        XCTAssertEqual(parsed.first { $0.label == "fixture.agent" }?.state, .disabled)
        XCTAssertEqual(parsed.first { $0.label == "fixture.unknown" }?.state, .unknown)
        XCTAssertEqual(parsed.first { $0.label == "fixture.agent" }?.plistURL?.path,
                       "/Applications/Fixture.app/Contents/Library/LaunchAgents/helper.plist")
        XCTAssertTrue(parsed.allSatisfy { !$0.canDisable && $0.source == .backgroundTaskManagement })
    }

    func testScanProtectsAdministratorAppleAndDuplicateLabelsAndHonorsDisabledDefaults() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        try fixture.plist("fixture.enabled")
        try fixture.plist("fixture.disabled", disabled: true)
        try fixture.plist("fixture.override", disabled: true)
        try fixture.plist("fixture.duplicate")
        try fixture.plist("fixture.duplicate", filename: "second.plist")
        try fixture.plist("com.apple.fixture")
        try fixture.plist("fixture.admin", directory: fixture.environment.administratorAgents)
        try fixture.plist("fixture.daemon", directory: fixture.environment.administratorDaemons)
        fixture.runner.configure { $0.states["fixture.override"] = false }
        let result = try await fixture.scan()
        XCTAssertEqual(result.items.count, 8)
        XCTAssertTrue(try item("fixture.enabled", in: result).canDisable)
        XCTAssertEqual(try item("fixture.disabled", in: result).state, .disabled)
        XCTAssertFalse(try item("fixture.disabled", in: result).canDisable)
        XCTAssertEqual(try item("fixture.override", in: result).state, .enabled)
        XCTAssertFalse(try item("com.apple.fixture", in: result).canDisable)
        XCTAssertFalse(try item("fixture.admin", in: result).canDisable)
        XCTAssertFalse(try item("fixture.daemon", in: result).canDisable)
        XCTAssertTrue(result.items.filter { $0.label == "fixture.duplicate" }.allSatisfy { !$0.canDisable })
        XCTAssertFalse(fixture.runner.mutatingCalls.contains { !$0.isEmpty })
    }

    func testUnknownLaunchctlStatusAndSymlinkRemainReadOnly() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.safe")
        fixture.runner.configure { $0.overrideOutput = "disabled services = {\n\"fixture.safe\" => uncertain\n}" }
        let unknown = try item("fixture.safe", in: await fixture.scan())
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertFalse(unknown.canDisable)
        fixture.runner.configure { $0.overrideOutput = nil }
        let link = fixture.environment.userAgents.appendingPathComponent("linked.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let scan = try await fixture.scan()
        XCTAssertTrue(scan.items.allSatisfy { !$0.canDisable })
        XCTAssertTrue(scan.items.contains { $0.plistURL == link && $0.state == .unknown })
        XCTAssertFalse(scan.issues.isEmpty)
        XCTAssertTrue(StartupFiles.exists(source))
    }

    func testProtectedSystemSymlinkChainCountsDuplicateLabelsButUserSymlinksStayRejected() throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        try fixture.plist("fixture.unique")
        try fixture.plist("fixture.duplicate")
        let system = fixture.root.appendingPathComponent("System", isDirectory: true)
        let cryptexes = system.appendingPathComponent("Cryptexes", isDirectory: true)
        let targetDirectory = system.appendingPathComponent("Volumes/Preboot/Cryptexes/App/System/Library/LaunchAgents", isDirectory: true)
        for directory in [cryptexes, targetDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let target = try fixture.plist("fixture.duplicate", directory: targetDirectory)
        try FileManager.default.createSymbolicLink(atPath: cryptexes.appendingPathComponent("App").path,
                                                   withDestinationPath: "../Volumes/Preboot/Cryptexes/App")
        let link = fixture.environment.systemAgents.appendingPathComponent("com.apple.fixture.plist")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "../System/Cryptexes/App/System/Library/LaunchAgents/\(target.lastPathComponent)")
        let trust = StartupFiles.SystemReadTrust(root: fixture.root, owner: getuid())
        let counts = try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust)
        XCTAssertEqual(counts, ["fixture.unique": 1, "fixture.duplicate": 2])
        XCTAssertThrowsError(try StartupFiles.read(link))
        // 正式默认策略不能把用户拥有的沙盒误当成 root 拥有的 /System。
        XCTAssertThrowsError(try StartupFiles.duplicateLabels(fixture.environment))
        XCTAssertThrowsError(try StartupFiles.duplicateLabels(fixture.environment,
            systemTrust: .init(root: fixture.root, owner: getuid() + 1)))
        let userLink = fixture.environment.userAgents.appendingPathComponent("linked.plist")
        try FileManager.default.createSymbolicLink(at: userLink, withDestinationURL: target)
        XCTAssertThrowsError(try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust))
        XCTAssertTrue(fixture.runner.calls.isEmpty)
    }

    func testSystemReadOnlyLinksRejectEscapesWritableTargetsBrokenLinksAndCycles() throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let target = try fixture.plist("fixture.target", directory: fixture.root)
        let link = fixture.environment.systemAgents.appendingPathComponent("com.apple.fixture.plist")
        let trust = StartupFiles.SystemReadTrust(root: fixture.root, owner: getuid())
        for destination in ["/usr/bin/true", fixture.root.appendingPathComponent("missing.plist").path, link.path] {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            XCTAssertThrowsError(try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust), destination)
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(chmod(target.path, 0o666), 0)
        XCTAssertThrowsError(try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust))
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust), ["fixture.target": 1])
        XCTAssertEqual(chmod(fixture.environment.systemAgents.path, 0o777), 0)
        XCTAssertThrowsError(try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust))
        XCTAssertEqual(chmod(fixture.environment.systemAgents.path, 0o700), 0)
        XCTAssertTrue(fixture.runner.calls.isEmpty)
    }

    func testSystemHardLinkReadExceptionNeverPermitsUserHardLinks() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let target = try fixture.plist("fixture.system-hardlink", directory: fixture.root)
        let systemLink = fixture.environment.systemAgents.appendingPathComponent("hardlink.plist")
        try FileManager.default.linkItem(at: target, to: systemLink)
        let trust = StartupFiles.SystemReadTrust(root: fixture.root, owner: getuid())
        XCTAssertEqual(try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust), ["fixture.system-hardlink": 1])
        XCTAssertThrowsError(try StartupFiles.read(systemLink))
        let userFile = try fixture.plist("fixture.user-hardlink")
        let userLink = fixture.environment.userAgents.appendingPathComponent("hardlink.plist")
        try FileManager.default.linkItem(at: userFile, to: userLink)
        XCTAssertThrowsError(try StartupFiles.duplicateLabels(fixture.environment, systemTrust: trust))
        let scan = try await fixture.scan()
        XCTAssertTrue(scan.items.allSatisfy { !$0.canDisable })
        XCTAssertTrue(scan.items.filter { $0.source == .userLaunchAgent }.allSatisfy { $0.state == .unknown })
        XCTAssertTrue(fixture.runner.mutatingCalls.isEmpty)
    }

    func testChangedFileSnapshotRefusesBeforeAnyMutation() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.changed")
        let original = try item("fixture.changed", in: await fixture.scan())
        var dictionary = try StartupFiles.dictionary(Data(contentsOf: source))
        dictionary["ProgramArguments"] = ["/usr/bin/true", "changed"]
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: source)
        do {
            _ = try await fixture.actions.disable(original)
            XCTFail("变化后的配置不能沿用旧确认")
        } catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertTrue(fixture.runner.mutatingCalls.isEmpty)
        XCTAssertTrue(StartupFiles.exists(source))
    }

    func testDisableBacksUpAndRestoreEnablesWithoutStoppingOrStartingProcesses() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.roundtrip")
        fixture.runner.configure { $0.loadedPaths["fixture.roundtrip"] = source.path }
        let originalData = try Data(contentsOf: source)
        let original = try item("fixture.roundtrip", in: await fixture.scan())
        let disabled = try await fixture.actions.disable(original)
        let backup = try XCTUnwrap(disabled.backup)
        XCTAssertFalse(StartupFiles.exists(source))
        XCTAssertEqual(try Data(contentsOf: backup.backupURL), originalData)
        XCTAssertEqual(fixture.runner.state("fixture.roundtrip"), true)
        XCTAssertEqual(backup.manifest.phase, "disabled")
        XCTAssertTrue(backup.canRestore)
        XCTAssertFalse(backup.recoveryOnly)
        let restored = try await fixture.actions.restore(backup)
        XCTAssertTrue(restored.restored)
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        XCTAssertFalse(StartupFiles.exists(backup.backupURL))
        XCTAssertEqual(fixture.runner.state("fixture.roundtrip"), false)
        let rescan = try await fixture.scan()
        XCTAssertTrue(rescan.backups.isEmpty)
        XCTAssertEqual(fixture.runner.mutatingCalls.map { $0[0] }, ["disable", "enable"])
        XCTAssertFalse(fixture.runner.calls.contains { ["bootout", "bootstrap", "kickstart", "kill", "remove"].contains($0.first ?? "") })
    }

    func testRestoreNeverOverwritesNewOriginalFile() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.conflict")
        let original = try item("fixture.conflict", in: await fixture.scan())
        let disabled = try await fixture.actions.disable(original)
        let backup = try XCTUnwrap(disabled.backup)
        let replacement = Data("new user file".utf8)
        try replacement.write(to: source)
        let mutationCount = fixture.runner.mutatingCalls.count
        do { _ = try await fixture.actions.restore(backup); XCTFail("原位置的新文件不得覆盖") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertTrue(StartupFiles.exists(backup.backupURL))
        XCTAssertEqual(fixture.runner.mutatingCalls.count, mutationCount)
    }

    func testDisableCommandFailureCompensatesAndKeepsOriginal() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.disable-failure")
        let original = try item("fixture.disable-failure", in: await fixture.scan())
        fixture.runner.configure { $0.failures["disable"] = 1 }
        do { _ = try await fixture.actions.disable(original); XCTFail("应返回停用失败") }
        catch { XCTAssertTrue(error.localizedDescription.contains("停用未完成")) }
        XCTAssertTrue(StartupFiles.exists(source))
        XCTAssertEqual(fixture.runner.state(original.label), false)
        let rescan = try await fixture.scan()
        XCTAssertTrue(rescan.backups.isEmpty)
        XCTAssertEqual(fixture.runner.mutatingCalls.map { $0[0] }, ["disable", "enable"])
    }

    func testRestoreCommandFailureRollsBackBothFileAndOverride() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.restore-failure")
        let original = try item("fixture.restore-failure", in: await fixture.scan())
        let disabled = try await fixture.actions.disable(original)
        let backup = try XCTUnwrap(disabled.backup)
        fixture.runner.configure { $0.failures["enable"] = 1 }
        do { _ = try await fixture.actions.restore(backup); XCTFail("应返回恢复失败") }
        catch { XCTAssertTrue(error.localizedDescription.contains("恢复未完成")) }
        XCTAssertFalse(StartupFiles.exists(source))
        XCTAssertTrue(StartupFiles.exists(backup.backupURL))
        XCTAssertEqual(fixture.runner.state(original.label), true)
        let retry = try await firstBackup(fixture)
        XCTAssertTrue(retry.canRestore)
        _ = try await fixture.actions.restore(retry)
        XCTAssertTrue(StartupFiles.exists(source))
        XCTAssertEqual(fixture.runner.state(original.label), false)
    }

    func testPreparedRecordAfterSimulatedInterruptionRecoversOnlyOriginalStartupEligibility() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.interrupted")
        let original = try Data(contentsOf: source)
        try fixture.preparedRecord(source, label: "fixture.interrupted")
        fixture.runner.configure { $0.states["fixture.interrupted"] = true }
        let backup = try await firstBackup(fixture)
        XCTAssertTrue(backup.canRestore)
        XCTAssertTrue(backup.recoveryOnly)
        XCTAssertFalse(StartupFiles.exists(backup.backupURL))
        _ = try await fixture.actions.restore(backup)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(fixture.runner.state(backup.label), false)
        XCTAssertEqual(fixture.runner.mutatingCalls.map { $0[0] }, ["enable"])
        let rescan = try await fixture.scan()
        XCTAssertTrue(rescan.backups.isEmpty)
    }

    func testPreparedRecordWithChangedOriginalCannotEnableUnrelatedConfiguration() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.changed-recovery")
        try fixture.preparedRecord(source, label: "fixture.changed-recovery")
        try fixture.plist("fixture.changed-recovery", disabled: true)
        fixture.runner.configure { $0.states["fixture.changed-recovery"] = true }
        let backup = try await firstBackup(fixture)
        XCTAssertTrue(backup.recoveryOnly)
        XCTAssertFalse(backup.canRestore)
        do { _ = try await fixture.actions.restore(backup); XCTFail("被修改的原文件不能恢复") }
        catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertTrue(fixture.runner.mutatingCalls.isEmpty)
    }

    func testMoveAndEnableCompensationDoubleFailureStillOffersOriginalRecovery() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.double-failure")
        let original = try item("fixture.double-failure", in: await fixture.scan())
        let originalData = try Data(contentsOf: source)
        let directory = fixture.environment.userAgents
        fixture.runner.configure {
            $0.failures["enable"] = 1
            $0.onDisable = { XCTAssertEqual(chmod(directory.path, 0o500), 0) }
        }
        do { _ = try await fixture.actions.disable(original); XCTFail("移动和补偿应失败") }
        catch { XCTAssertTrue(error.localizedDescription.contains("启动资格回滚未确认")) }
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        fixture.runner.configure { $0.onDisable = nil }
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        XCTAssertEqual(fixture.runner.state(original.label), true)
        let backup = try await firstBackup(fixture)
        XCTAssertEqual(backup.manifest.phase, "prepared")
        XCTAssertTrue(backup.recoveryOnly)
        XCTAssertTrue(backup.canRestore, backup.restoreRestriction ?? "")
        _ = try await fixture.actions.restore(backup)
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        XCTAssertEqual(fixture.runner.state(original.label), false)
        let rescan = try await fixture.scan()
        XCTAssertTrue(rescan.backups.isEmpty)
    }

    func testLoadedServiceMustMatchTopLevelOriginalPathForDisableAndRestore() async throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.loaded")
        let original = try item("fixture.loaded", in: await fixture.scan())
        fixture.runner.configure { $0.loadedPaths[original.label] = "/Applications/Other.app/Contents/Library/LaunchAgents/service.plist" }
        do { _ = try await fixture.actions.disable(original); XCTFail("动态注册的同 Label 服务必须拒绝") }
        catch { XCTAssertTrue(error.localizedDescription.contains("来源不同")) }
        XCTAssertTrue(fixture.runner.mutatingCalls.isEmpty)
        let conflicted = try item(original.label, in: await fixture.scan())
        XCTAssertFalse(conflicted.canDisable)
        fixture.runner.configure { $0.loadedPaths[original.label] = source.path }
        let fresh = try item(original.label, in: await fixture.scan())
        let disabled = try await fixture.actions.disable(fresh)
        let backup = try XCTUnwrap(disabled.backup)
        let count = fixture.runner.mutatingCalls.count
        fixture.runner.configure { $0.loadedPaths[original.label] = "/Applications/Other.app/Contents/Library/LaunchAgents/service.plist" }
        do { _ = try await fixture.actions.restore(backup); XCTFail("恢复也必须核对动态注册同名服务") }
        catch { XCTAssertTrue(error.localizedDescription.contains("来源不同")) }
        XCTAssertEqual(fixture.runner.mutatingCalls.count, count)
        XCTAssertFalse(StartupFiles.exists(source))
        XCTAssertTrue(StartupFiles.exists(backup.backupURL))
        let conflictedBackup = try await firstBackup(fixture)
        XCTAssertFalse(conflictedBackup.canRestore)
    }

    func testNestedPathAndAmbiguousPrintFailureCannotAuthorizeMutation() throws {
        let fixture = try StartupFixture()
        defer { fixture.remove() }
        let source = try fixture.plist("fixture.nested")
        let target = "gui/\(fixture.environment.uid)/fixture.nested"
        fixture.runner.configure { $0.printResults["fixture.nested"] = StartupCommandResult(status: 0, output: """
        \(target) = {
            environment = {
                path = \(source.path)
            }
        }
        """) }
        XCTAssertThrowsError(try StartupLaunchctl.validateLoadedService(label: "fixture.nested", originalURL: source,
                                                                       environment: fixture.environment, runner: fixture.runner))
        fixture.runner.configure { $0.printResults["fixture.nested"] = StartupCommandResult(status: 113, output: "permission denied") }
        XCTAssertThrowsError(try StartupLaunchctl.validateLoadedService(label: "fixture.nested", originalURL: source,
                                                                       environment: fixture.environment, runner: fixture.runner))
    }

    func testRestoreRechecksManifestAfterLaunchctlPrintForBackupAndOriginalRecovery() async throws {
        for recoveryOnly in [false, true] {
            let fixture = try StartupFixture()
            defer { fixture.remove() }
            let source = try fixture.plist("fixture.restore-race")
            let backup: StartupBackup
            if recoveryOnly {
                try fixture.preparedRecord(source, label: "fixture.restore-race")
                fixture.runner.configure { $0.states["fixture.restore-race"] = true }
                backup = try await firstBackup(fixture)
            } else {
                let original = try item("fixture.restore-race", in: await fixture.scan())
                let disabled = try await fixture.actions.disable(original)
                backup = try XCTUnwrap(disabled.backup)
            }
            let target = recoveryOnly ? source : backup.backupURL
            let replacement = Data("different file placed during launchctl print".utf8)
            let mutationCount = fixture.runner.mutatingCalls.count
            var prints = 0
            fixture.runner.configure {
                $0.onPrint = {
                    prints += 1
                    // item() 已完成首次内容校验；第二次 print 在真实恢复动作前发生。
                    if prints == 2 { try replacement.write(to: target) }
                }
            }
            do { _ = try await fixture.actions.restore(backup); XCTFail("校验后的文件替换必须被拒绝") }
            catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
            XCTAssertEqual(try Data(contentsOf: target), replacement)
            XCTAssertEqual(fixture.runner.mutatingCalls.count, mutationCount)
            XCTAssertEqual(fixture.runner.state(backup.label), true)
            if !recoveryOnly { XCTAssertFalse(StartupFiles.exists(source)) }
        }
    }

    private func item(_ label: String, in result: StartupScanResult) throws -> StartupItem {
        try XCTUnwrap(result.items.first { $0.label == label })
    }
    private func firstBackup(_ fixture: StartupFixture) async throws -> StartupBackup {
        let result = try await fixture.scan()
        return try XCTUnwrap(result.backups.first)
    }
}

private final class StartupFixture {
    let root: URL
    let environment: StartupEnvironment
    let runner = StartupFixtureCommands()
    var actions: StartupActions { StartupActions(environment: environment, runner: runner) }
    init() throws {
        // macOS 的 /var 临时目录经目录枚举会变成 /private/var，违反生产管理器要求的原始规范路径。
        // 使用当前用户缓存目录的独占沙盒；其中 home 完全虚拟，不访问真实 LaunchAgents。
        root = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("Library/Caches/cduyzh-startup-fixture-\(UUID().uuidString)", isDirectory: true)
        environment = StartupEnvironment(home: root.appendingPathComponent("home", isDirectory: true), uid: getuid(),
                                         administratorAgents: root.appendingPathComponent("admin-agents", isDirectory: true),
                                         administratorDaemons: root.appendingPathComponent("admin-daemons", isDirectory: true),
                                         systemAgents: root.appendingPathComponent("system-agents", isDirectory: true))
        for directory in [environment.home, environment.userAgents, environment.administratorAgents,
                          environment.administratorDaemons, environment.systemAgents] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }
    func remove() {
        chmod(environment.userAgents.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
    func scan() async throws -> StartupScanResult { try await StartupInspector(environment: environment, runner: runner).scan() }
    @discardableResult
    func plist(_ label: String, filename: String? = nil, disabled: Bool = false, directory: URL? = nil) throws -> URL {
        let source = (directory ?? environment.userAgents).appendingPathComponent(filename ?? label + ".plist")
        let dictionary: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/true"],
                                          "RunAtLoad": true, "Disabled": disabled]
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: source)
        guard chmod(source.path, 0o600) == 0 else { throw StartupError.transactionFailed("fixture chmod failed") }
        return source
    }
    func preparedRecord(_ source: URL, label: String) throws {
        try StartupFiles.userDirectory(environment.backupRoot, environment: environment, create: true)
        let directory = environment.backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let (_, snapshot) = try StartupFiles.read(source)
        let record = StartupBackupManifest(id: directory.lastPathComponent, label: label, name: label,
                                           originalPath: source.path, createdAt: Date(), sha256: snapshot.sha256,
                                           owner: environment.uid, originalMode: snapshot.mode,
                                           priorOverride: nil, phase: "prepared")
        try StartupFiles.writeManifest(record, at: StartupBackupStore.manifestURL(directory))
    }
}

private final class StartupFixtureCommands: StartupCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var states: [String: Bool] = [:]
    var failures: [String: Int] = [:]
    var loadedPaths: [String: String] = [:]
    var printResults: [String: StartupCommandResult] = [:]
    var overrideOutput: String?
    var onDisable: (() throws -> Void)?
    var onPrint: (() throws -> Void)?
    var calls: [[String]] { lock.withLock { recorded } }
    var mutatingCalls: [[String]] { calls.filter { ["disable", "enable"].contains($0.first ?? "") } }
    func configure(_ body: (StartupFixtureCommands) -> Void) { lock.withLock { body(self) } }
    func state(_ label: String) -> Bool? { lock.withLock { states[label] } }
    func run(_ executable: String, _ arguments: [String]) throws -> StartupCommandResult {
        try lock.withLock {
            recorded.append(arguments)
            if executable == "/usr/bin/sfltool" {
                return StartupCommandResult(status: 0, output: "Records for UID \(getuid()) :\n")
            }
            guard executable == "/bin/launchctl", arguments.count == 2 else {
                throw StartupError.refused("fixture refuses unexpected executable or arguments")
            }
            let command = arguments[0]
            if command == "print-disabled" {
                let output = overrideOutput ?? "disabled services = {\n"
                    + states.sorted { $0.key < $1.key }.map { "\"\($0.key)\" => \($0.value ? "true" : "false")" }.joined(separator: "\n") + "\n}"
                return StartupCommandResult(status: 0, output: output)
            }
            let label = String(arguments[1].split(separator: "/").last ?? "")
            if command == "print" {
                try onPrint?()
                if let result = printResults[label] { return result }
                if let path = loadedPaths[label] {
                    return StartupCommandResult(status: 0, output: "\(arguments[1]) = {\n\tpath = \(path)\n\tstate = running\n}")
                }
                return StartupCommandResult(status: 113, output: "Bad request.\nCould not find service \"\(label)\" in domain for user gui: \(getuid())")
            }
            guard ["disable", "enable"].contains(command) else {
                throw StartupError.refused("fixture forbids process lifecycle or other launchctl commands")
            }
            if let count = failures[command], count > 0 {
                failures[command] = count - 1
                return StartupCommandResult(status: 5, output: "fixture command failure")
            }
            states[label] = command == "disable"
            if command == "disable" { try onDisable?() }
            return StartupCommandResult(status: 0, output: "")
        }
    }
}
