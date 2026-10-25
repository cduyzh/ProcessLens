import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ProcessCore

enum NavigationPage: String, CaseIterable, Identifiable {
    case overview, processes, applications, favorites, browsers, startup, diskImages, ports, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return "进程概览"
        case .processes: return "全部进程"
        case .applications: return "应用进程"
        case .favorites: return "关注的进程"
        case .browsers: return "浏览器诊断"
        case .startup: return "开机启动项"
        case .diskImages: return "安装镜像"
        case .ports: return "监听端口"
        case .settings: return "设置"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .processes: return "list.bullet.rectangle"
        case .applications: return "app.dashed"
        case .favorites: return "star"
        case .browsers: return "globe"
        case .startup: return "power.circle"
        case .diskImages: return "externaldrive"
        case .ports: return "network"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum ProcessSort: String, CaseIterable {
    case cpu = "CPU 占用", memory = "内存占用", name = "进程名称", pid = "进程 ID"
}

enum ProcessScope: String, CaseIterable { case all = "全部", apps = "应用", background = "后台" }

@MainActor
final class ProcessStore: ObservableObject {
    var openMainWindow: (() -> Void)?
    @Published var page: NavigationPage = .overview
    @Published var query = ""
    @Published var scope: ProcessScope = .all
    @Published var sort: ProcessSort = .cpu
    @Published var selectedPID: Int32?
    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var ports: [PortRecord] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var networkHistory: [Double] = []
    @Published private(set) var diskHistory: [Double] = []
    @Published var paused = false
    @Published var showInspector = true
    @Published private(set) var sampling = false
    @Published private(set) var loadingPorts = false
    @Published var error: String?
    @Published var notice: String?
    @Published var showReleaseHistory = false
    @Published private(set) var browserSessions: [BrowserSession] = []
    @Published private(set) var browserScannedAt: Date?
    @Published private(set) var scanningBrowsers = false
    @Published private(set) var closingBrowserID: String?
    @Published var selectedBrowserID: String?
    @Published var browserQuery = ""
    @Published var browserFilter = "all"
    @Published var browserSort = "memory"
    @Published private(set) var browserCloseReport: BrowserCloseReport?
    @Published private(set) var lastBrowserSession: BrowserSession?
    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var startupBackups: [StartupBackup] = []
    @Published private(set) var startupIssues: [String] = []
    @Published private(set) var startupScannedAt: Date?
    @Published private(set) var scanningStartup = false
    @Published private(set) var updatingStartupID: String?
    @Published var selectedStartupID: String?
    @Published var startupQuery = ""
    @Published var startupFilter = "all"
    @Published var startupSort = "name"
    @Published private(set) var diskImages: [MountedDiskImage] = []
    @Published private(set) var diskImageScannedAt: Date?
    @Published private(set) var scanningDiskImages = false
    @Published private(set) var operatingDiskImages = false
    @Published private(set) var diskImageActionReport: DiskImageActionReport?
    @Published var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favoriteExecutables") }
    }
    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }
    @Published var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    @Published var showMenuBar: Bool {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar") }
    }
    private let sampler = ProcessSampler()
    private let browserInspector = BrowserInspector()
    private let startupInspector = StartupInspector()
    private let startupActions = StartupActions()
    private let diskImageInspector = DiskImageInspector()
    private var monitoringTask: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]
    private var lastSamplingError: String?
    private var lastPortError: String?
    private var startupRevision = 0
    private var startupRefreshPending = false
    var samplingInterrupted: Bool { lastSamplingError != nil }

    init() {
        let defaults = UserDefaults.standard
        favorites = Set(defaults.stringArray(forKey: "favoriteExecutables") ?? [])
        let savedInterval = defaults.double(forKey: "refreshInterval")
        refreshInterval = [1.0, 2.0, 5.0, 10.0].contains(savedInterval) ? savedInterval : 2
        appearance = defaults.string(forKey: "appearance") ?? "system"
        showMenuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
    }

    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : (appearance == "light" ? .light : nil) }
    var processes: [ProcessRecord] { snapshot?.processes ?? [] }
    var selectedProcess: ProcessRecord? { processes.first { $0.pid == selectedPID } }
    var applicationCount: Int { processes.filter(\.isApplication).count }
    var favoriteCount: Int { processes.filter { favorites.contains($0.executablePath) }.count }
    var filteredProcesses: [ProcessRecord] {
        processes.filter { record in
            let pageMatches: Bool
            switch page {
            case .applications: pageMatches = record.isApplication
            case .favorites: pageMatches = favorites.contains(record.executablePath)
            default: pageMatches = true
            }
            let scopeMatches = scope == .all || (scope == .apps ? record.isApplication : !record.isApplication)
            let queryMatches = query.isEmpty || [record.name, String(record.pid), record.user, record.executablePath].contains { $0.localizedCaseInsensitiveContains(query) }
            return pageMatches && scopeMatches && queryMatches
        }.sorted { a, b in
            switch sort {
            case .cpu: return a.cpuPercent == b.cpuPercent ? a.pid < b.pid : a.cpuPercent > b.cpuPercent
            case .memory: return a.memoryBytes == b.memoryBytes ? a.pid < b.pid : a.memoryBytes > b.memoryBytes
            case .name: return a.name == b.name ? a.pid < b.pid : a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .pid: return a.pid < b.pid
            }
        }
    }
    var filteredPorts: [PortRecord] {
        ports.filter { query.isEmpty || [$0.name, $0.port, $0.address, String($0.pid)].contains { $0.localizedCaseInsensitiveContains(query) } }
            .sorted { a, b in
                if sort == .name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                if sort == .pid { return a.pid < b.pid }
                return (Int(a.port) ?? 0) < (Int(b.port) ?? 0)
            }
    }

    func navigate(_ next: NavigationPage) {
        page = next; query = ""; scope = .all
        if next == .ports { Task { await refreshPorts() } }
        if next == .browsers { Task { await refreshBrowsers() } }
        if next == .startup { Task { await refreshStartup() } }
        if next == .diskImages { Task { await refreshDiskImages() } }
    }

    func start() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if !self.paused { await self.refresh(automatic: true) }
                let interval = self.refreshInterval
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            }
        }
    }

    func stop() { monitoringTask?.cancel(); monitoringTask = nil }

    func refresh(automatic: Bool = false) async {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }
        do {
            let next = try await sampler.sample()
            try Task.checkCancellation()
            guard !automatic || !paused else { return }
            snapshot = next
            append(next.cpuPercent, to: &cpuHistory)
            append(Double(next.memoryUsedBytes), to: &memoryHistory)
            append(next.networkBytesPerSecond, to: &networkHistory)
            append(Double(next.diskUsedBytes), to: &diskHistory)
            if selectedPID == nil { selectedPID = next.processes.first { $0.pid == ProcessInfo.processInfo.processIdentifier }?.pid ?? next.processes.first?.pid }
            if error == lastSamplingError { error = nil }
            lastSamplingError = nil
        } catch is CancellationError { return }
        catch { lastSamplingError = error.localizedDescription; self.error = lastSamplingError }
    }

    func refreshPorts() async {
        guard !loadingPorts else { return }
        loadingPorts = true
        defer { loadingPorts = false }
        do {
            let next = try await sampler.listeningPorts()
            try Task.checkCancellation()
            ports = next
            if error == lastPortError { error = nil }
            lastPortError = nil
        } catch is CancellationError { return }
        catch { lastPortError = error.localizedDescription; self.error = lastPortError }
    }

    var selectedBrowser: BrowserSession? { browserSessions.first { $0.id == selectedBrowserID } }
    var automationBrowsers: [BrowserSession] { browserSessions.filter { $0.classification == .automation } }
    var filteredBrowsers: [BrowserSession] {
        browserSessions.filter { session in
            let filterMatches = browserFilter == "all" || (browserFilter == "automation" && session.classification == .automation) || (browserFilter == "headless" && session.isHeadless)
            let queryMatches = browserQuery.isEmpty || [session.name, String(session.rootPID), session.ownerDescription, session.profileURL?.path ?? ""].contains { $0.localizedCaseInsensitiveContains(browserQuery) }
            return filterMatches && queryMatches
        }.sorted { a, b in
            if browserSort == "pid" { return a.rootPID < b.rootPID }
            if browserSort == "age" { return (a.age ?? 0) > (b.age ?? 0) }
            return a.residentMemoryBytes == b.residentMemoryBytes ? a.rootPID < b.rootPID : a.residentMemoryBytes > b.residentMemoryBytes
        }
    }

    func refreshBrowsers() async {
        guard !scanningBrowsers else { return }
        scanningBrowsers = true
        defer { scanningBrowsers = false }
        do {
            let sessions = try await browserInspector.scan()
            try Task.checkCancellation()
            browserSessions = sessions
            browserScannedAt = Date()
            if !sessions.contains(where: { $0.id == selectedBrowserID }) {
                selectedBrowserID = sessions.first(where: \.canClose)?.id ?? sessions.first?.id
            }
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }

    func closeBrowser(_ session: BrowserSession, force: Bool) async {
        guard closingBrowserID == nil else { return }
        closingBrowserID = session.id
        lastBrowserSession = session
        defer { closingBrowserID = nil }
        do {
            let report = try await BrowserSessionActions.close(session, force: force)
            browserCloseReport = report
            notice = report.message
            await refreshBrowsers()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func append(_ value: Double, to array: inout [Double]) {
        array.append(value)
        if array.count > 40 { array.removeFirst(array.count - 40) }
    }

    var selectedStartupItem: StartupItem? { startupItems.first { $0.id == selectedStartupID } }
    var filteredStartupItems: [StartupItem] {
        startupItems.filter { item in
            let filterMatches = startupFilter == "all" || (startupFilter == "manageable" && item.canDisable) || (startupFilter == "system" && !item.canDisable)
            return filterMatches && (startupQuery.isEmpty || [item.name, item.label, item.source.displayName, item.executablePath ?? ""].contains { $0.localizedCaseInsensitiveContains(startupQuery) })
        }.sorted { a, b in
            if startupSort == "state", a.state != b.state { return a.state.displayName < b.state.displayName }
            if startupSort == "source", a.source != b.source { return a.source.displayName < b.source.displayName }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func refreshStartup() async {
        guard !scanningStartup, updatingStartupID == nil else { startupRefreshPending = true; return }
        scanningStartup = true
        let revision = startupRevision
        defer {
            scanningStartup = false
            if startupRefreshPending && updatingStartupID == nil {
                startupRefreshPending = false
                Task { await refreshStartup() }
            }
        }
        do {
            let result = try await startupInspector.scan()
            try Task.checkCancellation()
            guard revision == startupRevision, updatingStartupID == nil else { startupRefreshPending = true; return }
            startupItems = result.items; startupBackups = result.backups; startupIssues = result.issues; startupScannedAt = result.scannedAt
            if !result.items.contains(where: { $0.id == selectedStartupID }) {
                selectedStartupID = result.items.first(where: \.canDisable)?.id ?? result.items.first?.id
            }
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }

    func disableStartup(_ item: StartupItem) async {
        guard updatingStartupID == nil else { return }
        updatingStartupID = item.id
        startupRevision += 1
        do {
            let report = try await startupActions.disable(item)
            notice = report.message
        } catch { self.error = error.localizedDescription }
        updatingStartupID = nil
        await refreshStartup()
    }

    func restoreStartup(_ backup: StartupBackup) async {
        guard updatingStartupID == nil else { return }
        updatingStartupID = backup.id
        startupRevision += 1
        do {
            let report = try await startupActions.restore(backup)
            notice = report.message
        } catch { self.error = error.localizedDescription }
        updatingStartupID = nil
        await refreshStartup()
    }

    func refreshDiskImages() async {
        guard !scanningDiskImages, !operatingDiskImages else { return }
        scanningDiskImages = true
        defer { scanningDiskImages = false }
        do {
            let images = try await diskImageInspector.scan()
            try Task.checkCancellation()
            diskImages = images
            diskImageScannedAt = Date()
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }

    func ejectDiskImages(_ images: [MountedDiskImage], movingInstallersToTrash: Bool) async {
        guard !images.isEmpty, !operatingDiskImages else { return }
        if movingInstallersToTrash && images.contains(where: { !$0.canMoveInstallerToTrash }) {
            error = "所选镜像中包含无法安全移到废纸篓的来源文件；请改用“仅推出”或重新选择。"
            return
        }
        operatingDiskImages = true
        let report = await DiskImageActions.eject(images, movingInstallersToTrash: movingInstallersToTrash)
        operatingDiskImages = false
        diskImageActionReport = report
        notice = report.message
        await refreshDiskImages()
    }

    func toggleFavorite(_ process: ProcessRecord) {
        if favorites.contains(process.executablePath) { favorites.remove(process.executablePath) }
        else { favorites.insert(process.executablePath) }
    }

    func icon(for process: ProcessRecord) -> NSImage {
        if let cached = icons[process.executablePath] { return cached }
        let image: NSImage
        if process.executablePath.contains(".app/") {
            let prefix = process.executablePath.components(separatedBy: ".app/")[0] + ".app"
            image = NSWorkspace.shared.icon(forFile: prefix)
        } else if process.executablePath.hasPrefix("/") {
            image = NSWorkspace.shared.icon(forFile: process.executablePath)
        } else {
            image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        icons[process.executablePath] = image
        return image
    }

    func terminate(_ process: ProcessRecord, force: Bool) {
        do {
            try ProcessActions.terminate(process, force: force)
            notice = "已向 \(process.name)（\(process.pid)）发送\(force ? "强制退出" : "退出")信号"
            Task { await refresh() }
        } catch { self.error = error.localizedDescription }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "已复制到剪贴板"
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "processes-\(formatter.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func escaped(_ value: String) -> String {
            // Quoted CSV fields still need spreadsheet formula protection.
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: value.hasPrefix) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = "PID,Parent PID,Name,User,CPU %,Memory Bytes,Threads,State,Elapsed,Executable"
        let rows = filteredProcesses.map { record in
            [String(record.pid), String(record.parentPID), escaped(record.name), escaped(record.user), String(format: "%.2f", record.cpuPercent), String(record.memoryBytes), String(record.threadCount), escaped(record.state), escaped(record.elapsed), escaped(record.executablePath)].joined(separator: ",")
        }
        do { try ("\u{feff}" + ([header] + rows).joined(separator: "\r\n")).write(to: url, atomically: true, encoding: .utf8); notice = "已导出 \(rows.count) 个进程" }
        catch { self.error = error.localizedDescription }
    }
}
