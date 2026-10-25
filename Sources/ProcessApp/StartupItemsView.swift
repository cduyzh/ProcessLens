import SwiftUI
import AppKit
import ServiceManagement
import ProcessCore

struct StartupItemsView: View {
    @EnvironmentObject private var store: ProcessStore
    @State private var showBackups = false
    @State private var selectedBackupID: String?
    @State private var pendingItem: StartupItem?
    @State private var pendingBackup: StartupBackup?
    @State private var showSort = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            introduction
            controls
            HStack(spacing: 0) {
                list.frame(width: 310)
                Rectangle().fill(Palette.line).frame(width: 1)
                ScrollView {
                    if showBackups, let backup = selectedBackup {
                        backupDetail(backup).padding(24)
                    } else if !showBackups, let item = store.selectedStartupItem {
                        itemDetail(item).padding(24)
                    } else {
                        EmptyState(symbol: "power.circle", title: showBackups ? "选择一个备份" : "选择一个启动项", message: "查看来源、启动条件与可用的管理方式。")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
            }
        }.background(Palette.surface)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
            .onReceive(NotificationCenter.default.publisher(for: .focusProcessSearch)) { _ in searchFocused = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await store.refreshStartup() } }
            .alert(pendingBackup == nil ? "停用这个启动项？" : "恢复这个启动项？", isPresented: Binding(get: { pendingItem != nil || pendingBackup != nil }, set: { if !$0 { pendingItem = nil; pendingBackup = nil } })) {
                Button("取消", role: .cancel) { pendingItem = nil; pendingBackup = nil }
                if let item = pendingItem {
                    Button("停用并备份", role: .destructive) {
                        pendingItem = nil
                        Task { await store.disableStartup(item) }
                    }
                } else if let backup = pendingBackup {
                    Button("恢复启动项") {
                        pendingBackup = nil
                        Task { await store.restoreStartup(backup) }
                    }
                }
            } message: {
                if let item = pendingItem {
                    Text("\(item.name)\n\(item.label)\n\n将禁止此项后续自动启动，并将原配置移到可恢复备份。当前正在运行的任务不会被结束。")
                } else if let backup = pendingBackup {
                    Text(backup.recoveryOnly
                         ? "\(backup.name)\n\(backup.originalURL.path)\n\n原配置仍在原位。将核对文件完整性，只恢复后续启动资格，不会立即运行程序。"
                         : "\(backup.name)\n\(backup.originalURL.path)\n\n将核对备份完整性，恢复原配置并重新允许后续启动，不会立即运行程序。若原位置已有新文件，则拒绝覆盖。")
                }
            }
    }

    private var selectedBackup: StartupBackup? {
        backups.first { $0.id == selectedBackupID } ?? backups.first
    }
    private var backups: [StartupBackup] {
        store.startupBackups.filter { store.startupQuery.isEmpty || [$0.name, $0.label, $0.originalURL.path].contains { $0.localizedCaseInsensitiveContains(store.startupQuery) } }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("开机后，哪些项目会自己运行？").font(.system(size: 17, weight: .semibold))
                    Text("查看登录项、后台任务与按需服务，按来源决定是否保留。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { SMAppService.openSystemSettingsLoginItems() } label: { Label("系统登录项设置", systemImage: "arrow.up.forward.square").font(.system(size: 11)) }
                Button { Task { await store.refreshStartup() } } label: { Label("重新扫描", systemImage: "arrow.clockwise").font(.system(size: 11)) }.disabled(store.scanningStartup || store.updatingStartupID != nil)
            }
            HStack(spacing: 28) {
                summary("发现条目", value: store.startupItems.count, symbol: "list.bullet.rectangle", tint: Palette.blue)
                summary("可直接停用", value: store.startupItems.filter(\.canDisable).count, symbol: "power", tint: Palette.accent)
                summary("恢复记录", value: store.startupBackups.count, symbol: "arrow.uturn.backward.circle", tint: Palette.purple)
                Spacer()
                if let date = store.startupScannedAt { Text(date, style: .time).font(.system(size: 10)).foregroundStyle(Palette.muted) }
            }.padding(15).background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
            if !store.startupIssues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(store.startupIssues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(Palette.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { showSort.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                    Text(store.startupSort == "name" ? "名称排序" : store.startupSort == "source" ? "来源排序" : "状态排序").font(.system(size: 10))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30).panel(radius: 6)
            }.buttonStyle(.plain).accessibilityLabel("启动项排序方式")
                .popover(isPresented: $showSort, arrowEdge: .bottom) {
                    VStack(spacing: 3) {
                        sortOption("名称排序", value: "name")
                        sortOption("来源排序", value: "source")
                        sortOption("状态排序", value: "state")
                    }.padding(8).frame(width: 160)
                }
            HStack(spacing: 2) {
                filter("全部", value: "all")
                filter("可停用", value: "manageable")
                filter("只读", value: "system")
                Button { showBackups = true } label: {
                    Text("备份").font(.system(size: 10)).padding(.horizontal, 10).frame(height: 25)
                        .foregroundStyle(showBackups ? Palette.accent : .secondary)
                        .background(showBackups ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }.padding(3).background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
            Spacer(minLength: 2)
            SearchField(query: $store.startupQuery, focused: $searchFocused)
        }.padding(.horizontal, 24).padding(.bottom, 18)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack { Text(showBackups ? "已停用的配置备份" : "启动与后台条目"); Spacer(); Text(String(showBackups ? backups.count : store.filteredStartupItems.count)) }
                .font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 17).frame(height: 34).background(Palette.background)
            if store.scanningStartup && store.startupScannedAt == nil {
                ProgressView("正在读取启动项…").font(.system(size: 11)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showBackups {
                if backups.isEmpty {
                    EmptyState(symbol: "archivebox", title: "还没有停用备份", message: "停用用户启动配置后，可在这里恢复。")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(backups) { backup in
                                Button { selectedBackupID = backup.id } label: {
                                    listLabel(backup.name, subtitle: backup.label, state: backup.recoveryOnly ? "待恢复" : "已备份", tint: Palette.purple, selected: selectedBackup?.id == backup.id)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else if store.filteredStartupItems.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "没有匹配的条目", message: "试试其他筛选，或重新扫描。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.filteredStartupItems) { item in
                            Button { store.selectedStartupID = item.id } label: {
                                listLabel(item.name, subtitle: item.source.displayName + " · " + item.kind.displayName, state: item.state.displayName, tint: item.canDisable ? Palette.accent : Palette.blue, selected: store.selectedStartupID == item.id)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func listLabel(_ name: String, subtitle: String, state: String, tint: Color, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolBadge(symbol: "power.circle", tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1); Spacer(); Text(state).font(.system(size: 9)).foregroundStyle(tint) }
                Text(subtitle).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(2)
            }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(selected ? Palette.accent.opacity(0.06) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }.contentShape(Rectangle())
    }

    private func itemDetail(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                SymbolBadge(symbol: "power", tint: Palette.accent, size: 42)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.name).font(.system(size: 18, weight: .semibold))
                    Text(item.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                property("来源", item.source.displayName)
                property("类型", item.kind.displayName)
                property("启动状态", item.state.displayName)
                property("登录时运行", item.runAtLoad.map { $0 ? "是" : "否" } ?? (item.source == .backgroundTaskManagement ? "由系统管理" : "未声明"))
                property("保持运行", item.keepAlive.map { $0 ? "是" : "否" } ?? (item.source == .backgroundTaskManagement ? "由系统管理" : "未声明"))
            }.padding(16).panel(radius: 9)
            VStack(alignment: .leading, spacing: 12) {
                Text("管理建议").font(.system(size: 12, weight: .semibold))
                Text(advice(for: item)).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Text(item.managementReason).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button { pendingItem = item } label: { Label("停用并保留备份…", systemImage: "power").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(!item.canDisable || store.updatingStartupID != nil || store.scanningStartup)
                    if !item.canDisable { Button("在系统设置管理") { SMAppService.openSystemSettingsLoginItems() }.font(.system(size: 10)) }
                    if store.updatingStartupID == item.id { ProgressView().controlSize(.small) }
                }
                Text("停用只影响后续启动，不会结束当前任务。可在「备份」中恢复。").font(.system(size: 9)).foregroundStyle(Palette.muted)
            }
            if let plist = item.plistURL { pathSection("配置文件", url: plist) }
            if let executable = item.executablePath {
                VStack(alignment: .leading, spacing: 9) {
                    Text("可执行文件").font(.system(size: 11, weight: .medium))
                    Text(executable).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !item.details.isEmpty { Text(item.details).font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func backupDetail(_ backup: StartupBackup) -> some View {
        VStack(alignment: .leading, spacing: 21) {
            Label(backup.name, systemImage: "archivebox").font(.system(size: 18, weight: .semibold))
            Text(backup.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            Text(backup.createdAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
            Button { pendingBackup = backup } label: { Label("恢复启动配置…", systemImage: "arrow.uturn.backward").font(.system(size: 11)) }.disabled(!backup.canRestore || store.updatingStartupID != nil)
            Text(backup.restoreRestriction ?? (backup.recoveryOnly ? "配置仍在原位，上次操作的启动资格未完全回滚。恢复会核对原文件，只修复后续启动资格。" : "恢复前核对文件完整性；原路径若已有配置，不会覆盖。恢复不会立即启动程序。"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            pathSection("原始位置", url: backup.originalURL)
            if !backup.recoveryOnly { pathSection("备份位置", url: backup.backupURL) }
            Text("SHA-256  " + backup.sha256).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func advice(for item: StartupItem) -> String {
        if item.state == .disabled { return "此项已停用。是否仍有进程正在运行，需要在进程列表另行查看。" }
        if item.kind == .onDemandAgent { return "这是按需服务，并不表示每次登录都会运行。建议先确认用途，再决定是否停用。" }
        if item.keepAlive == true { return "此项配置了保持运行。若不再使用对应功能，可考虑停用后续自动启动。" }
        return "根据使用习惯决定是否保留；停用启动项并不卸载应用，也不直接代表节省了多少内存。"
    }
    private func pathSection(_ title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(url.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("在访达中定位", systemImage: "folder").font(.system(size: 10)).foregroundStyle(Palette.accent) }.buttonStyle(.plain)
        }
    }
    private func property(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Palette.muted); Spacer(); Text(value).foregroundStyle(.secondary) }.font(.system(size: 10))
    }
    private func summary(_ title: String, value: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) { Image(systemName: symbol).foregroundStyle(tint); VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 9)).foregroundStyle(Palette.muted); Text(String(value)).font(.system(size: 17, weight: .medium, design: .rounded)) } }
    }
    private func filter(_ title: String, value: String) -> some View {
        Button { showBackups = false; store.startupFilter = value } label: {
            Text(title).font(.system(size: 10)).padding(.horizontal, 9).frame(height: 25).foregroundStyle(!showBackups && store.startupFilter == value ? Palette.accent : .secondary)
                .background(!showBackups && store.startupFilter == value ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
    private func sortOption(_ title: String, value: String) -> some View {
        Button { store.startupSort = value; showSort = false } label: {
            HStack { Text(title); Spacer(); if store.startupSort == value { Image(systemName: "checkmark").foregroundStyle(Palette.accent) } }.font(.system(size: 11)).padding(9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
