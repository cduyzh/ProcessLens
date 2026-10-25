import SwiftUI
import AppKit
import ProcessCore

struct WorkspaceView: View {
    @EnvironmentObject private var store: ProcessStore
    @State private var pendingAction: ProcessRecord?
    @State private var forceQuit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                if let error = store.error { banner(error, symbol: "exclamationmark.circle", color: .orange, isError: true) }
                if let notice = store.notice { banner(notice, symbol: "checkmark.circle", color: Palette.accent, isError: false) }
                if store.page == .settings {
                    SettingsView()
                } else if store.page == .browsers {
                    BrowserSessionsView()
                    footer
                } else if store.page == .startup {
                    StartupItemsView()
                    footer
                } else if store.page == .diskImages {
                    DiskImagesView()
                    footer
                } else {
                    if store.page == .overview { ResourceCards().padding(.horizontal, 24).padding(.bottom, 24) }
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if store.page == .ports { PortsView() }
                            else { ProcessListView(onTerminate: requestTermination) }
                        }
                        if store.showInspector && store.page != .ports {
                            Rectangle().fill(Palette.line).frame(width: 1)
                            InspectorView(onTerminate: requestTermination).frame(width: 262)
                        }
                    }
                    footer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
        }
        .background(Palette.background)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $store.showReleaseHistory) { ReleaseHistoryView() }
        .alert(forceQuit ? "强制退出这个进程？" : "结束这个进程？", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button(forceQuit ? "强制退出" : "结束进程", role: .destructive) {
                if let process = pendingAction { store.terminate(process, force: forceQuit) }
                pendingAction = nil
            }
        } message: {
            if let process = pendingAction {
                Text("\(process.name) · PID \(process.pid)\n\(forceQuit ? "强制退出会立即终止进程，未保存的工作可能丢失。" : "将发送退出信号，应用中未保存的工作可能丢失。")")
            }
        }
    }

    private func requestTermination(_ process: ProcessRecord, _ force: Bool) { forceQuit = force; pendingAction = process }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.7)
                    Text("/").foregroundStyle(Palette.muted)
                    Text(store.page == .settings ? "PREFERENCES" : "ACTIVITY").font(.system(size: 9, weight: .medium)).tracking(1.5)
                }.foregroundStyle(.secondary)
                Text(store.page.title).font(.system(size: 25, weight: .semibold)).tracking(-0.6)
            }
            Spacer()
            if store.page != .settings {
                HStack(spacing: 6) {
                    StatusDot(color: store.paused ? .orange : Palette.accent)
                    Text(store.paused ? "已暂停" : "实时监测").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(store.paused ? .orange : Palette.accent)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background((store.paused ? Color.orange : Palette.accent).opacity(0.07), in: Capsule())
                HStack(spacing: 3) {
                    ToolButton(symbol: store.paused ? "play" : "pause", label: store.paused ? "继续监测 ⇧⌘P" : "暂停监测 ⇧⌘P", selected: store.paused) { store.paused.toggle() }
                    ToolButton(symbol: "arrow.clockwise", label: "立即刷新 ⌘R") {
                        Task {
                            await store.refresh()
                            if store.page == .ports { await store.refreshPorts() }
                            if store.page == .browsers { await store.refreshBrowsers() }
                            if store.page == .startup { await store.refreshStartup() }
                            if store.page == .diskImages { await store.refreshDiskImages() }
                        }
                    }.disabled(store.sampling || store.loadingPorts || store.scanningBrowsers || store.scanningStartup || store.scanningDiskImages || store.operatingDiskImages)
                    if store.page != .ports && store.page != .browsers && store.page != .startup && store.page != .diskImages {
                        ToolButton(symbol: "square.and.arrow.up", label: "导出当前列表为 CSV ⌘S") { store.exportCSV() }.disabled(store.snapshot == nil)
                        Divider().frame(height: 17).padding(.horizontal, 5)
                        ToolButton(symbol: "sidebar.right", label: "显示 / 隐藏详情 ⌥⌘I", selected: store.showInspector) { store.showInspector.toggle() }
                    }
                }
            }
        }
        .padding(.horizontal, 26).padding(.top, 32).padding(.bottom, 24)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            StatusDot(color: store.error == nil ? Palette.accent : .orange)
            Text(footerCount)
            Text("·").foregroundStyle(Palette.muted)
            Text(footerRefreshStatus)
            Spacer()
            if let date = footerDate {
                Text("上次更新").foregroundStyle(Palette.muted)
                Text(date, style: .time).monospacedDigit()
            }
            Text("全部数据仅在本机处理").padding(.leading, 12).foregroundStyle(Palette.muted)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 22).frame(height: 35)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var footerCount: String {
        if store.page == .diskImages { return "\(store.diskImages.count) 个已挂载镜像" }
        return store.snapshot == nil ? "正在读取系统进程…" : "\(store.processes.count) 个进程"
    }

    private var footerRefreshStatus: String {
        if store.page == .diskImages { return store.scanningDiskImages ? "正在扫描" : "按需扫描" }
        return store.paused ? "自动刷新已暂停" : "每 \(Int(store.refreshInterval)) 秒更新"
    }

    private var footerDate: Date? {
        store.page == .diskImages ? store.diskImageScannedAt : store.snapshot?.collectedAt
    }

    private func banner(_ text: String, symbol: String, color: Color, isError: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 11)).textSelection(.enabled)
            Spacer()
            ToolButton(symbol: "xmark", label: "关闭提示") { if isError { store.error = nil } else { store.notice = nil } }
        }.padding(.leading, 12).padding(.trailing, 5).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24).padding(.bottom, 12)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: ProcessStore
    private var hostName: String { Host.current().localizedName ?? "这台 Mac" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 37, height: 37)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Process").font(.system(size: 18, weight: .semibold)).tracking(-0.5)
                    Text("BY CDUYZH").font(.system(size: 8, weight: .medium)).tracking(1.8).foregroundStyle(Palette.muted)
                }
            }.padding(.horizontal, 23).padding(.top, 56).padding(.bottom, 34)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            Text("监测").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 26).padding(.bottom, 10)
            VStack(spacing: 4) {
                navigation(.overview)
                navigation(.processes, count: store.processes.count)
                navigation(.applications, count: store.applicationCount)
            }.padding(.horizontal, 12)
            Text("工具").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 26).padding(.top, 29).padding(.bottom, 10)
            VStack(spacing: 4) {
                navigation(.favorites, count: store.favoriteCount)
                navigation(.browsers)
                navigation(.startup)
                navigation(.diskImages, count: store.diskImages.count)
                navigation(.ports)
            }.padding(.horizontal, 12)
                }
            }.scrollIndicators(.hidden).padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").font(.system(size: 17, weight: .light)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hostName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text("macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 11))
                    Text("本地运行 · 隐私优先").font(.system(size: 10))
                }.foregroundStyle(Palette.accent)
            }.padding(14).panel(radius: 10).padding(.horizontal, 16).padding(.bottom, 20)
            navigation(.settings).padding(.horizontal, 12).padding(.bottom, 13)
            HStack {
                Text("CDUYZH TOOLS").tracking(1.3)
                Spacer()
                Button("v\(AppVersion.current.version)") { store.showReleaseHistory = true }.buttonStyle(.plain).help("查看版本与更新历史")
            }.font(.system(size: 8, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 23).padding(.bottom, 17)
        }
        .frame(width: 202).frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }
    private func navigation(_ page: NavigationPage, count: Int? = nil) -> some View {
        Button { store.navigate(page) } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).font(.system(size: 14, weight: store.page == page ? .semibold : .regular)).frame(width: 20)
                Text(page.title).font(.system(size: 12, weight: store.page == page ? .semibold : .regular))
                Spacer(minLength: 2)
                if let count, count > 0 {
                    Text(String(count)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(store.page == page ? Palette.accent : .secondary)
                }
            }
            .foregroundStyle(store.page == page ? Palette.accent : Color.primary.opacity(0.67))
            .padding(.horizontal, 12).frame(height: 37)
            .background(store.page == page ? Palette.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(store.page == page ? .isSelected : [])
    }
}

struct ResourceCards: View {
    @EnvironmentObject private var store: ProcessStore
    var body: some View {
        HStack(spacing: 13) {
            MetricCard(title: "CPU", symbol: "cpu", tint: Palette.orange,
                       value: store.snapshot.map { String(format: "%.1f", $0.cpuPercent) } ?? "—", unit: "%",
                       subtitle: "\(ProcessInfo.processInfo.activeProcessorCount) 核心 · 总使用率", history: store.cpuHistory, ceiling: 100)
            MetricCard(title: "内存", symbol: "memorychip", tint: Palette.purple,
                       value: store.snapshot.map { String(format: "%.1f", Double($0.memoryUsedBytes) / 1_073_741_824) } ?? "—", unit: "GB",
                       subtitle: store.snapshot.map { "共 \(Format.bytes($0.memoryTotalBytes)) · 压力\($0.memoryPressure)" } ?? "正在读取…", history: store.memoryHistory,
                       ceiling: store.snapshot.map { Double($0.memoryTotalBytes) })
            MetricCard(title: "磁盘", symbol: "internaldrive", tint: Palette.accent,
                       value: store.snapshot.map { String(format: "%.0f", Double($0.diskUsedBytes) / 1_000_000_000) } ?? "—", unit: "GB",
                       subtitle: store.snapshot.map { "可用 \(Format.bytes($0.diskTotalBytes - min($0.diskUsedBytes, $0.diskTotalBytes)))" } ?? "启动磁盘", history: store.diskHistory,
                       ceiling: store.snapshot.map { Double($0.diskTotalBytes) })
            MetricCard(title: "网络", symbol: "arrow.up.arrow.down", tint: Palette.blue,
                       value: store.snapshot.map { String(format: "%.1f", $0.networkBytesPerSecond / 1024) } ?? "—", unit: "KB/s",
                       subtitle: store.snapshot.map { "↓ \(Format.rate($0.networkDownloadPerSecond))  ↑ \(Format.rate($0.networkUploadPerSecond))" } ?? "正在读取…", history: store.networkHistory)
        }
    }
}

struct MetricCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let unit: String
    let subtitle: String
    let history: [Double]
    var ceiling: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4)
            }
            HStack(alignment: .bottom, spacing: 5) {
                Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-1).monospacedDigit().contentTransition(.identity)
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.top, 14)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1).padding(.top, 5)
            Sparkline(values: history, tint: tint, ceiling: ceiling).frame(height: 30).padding(.top, 12)
        }.padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 7).frame(maxWidth: .infinity).panel()
    }
}
