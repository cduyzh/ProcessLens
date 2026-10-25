import SwiftUI
import AppKit
import ProcessCore

struct BrowserSessionsView: View {
    @EnvironmentObject private var store: ProcessStore
    @State private var pendingSession: BrowserSession?
    @State private var force = false
    @State private var showingSort = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            introduction
            controls
            HStack(spacing: 0) {
                sessionList.frame(width: 292)
                Rectangle().fill(Palette.line).frame(width: 1)
                if let session = store.selectedBrowser {
                    BrowserSessionDetail(session: session) { session, force in
                        self.force = force; pendingSession = session
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(symbol: "globe", title: store.scanningBrowsers ? "正在读取浏览器实例" : "选择一个浏览器实例", message: "查看启动来源、进程树、内存与退出条件。")
                }
            }
        }
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .focusProcessSearch)) { _ in searchFocused = true }
        .alert(force ? "强制退出这个浏览器实例？" : "退出这个浏览器实例？", isPresented: Binding(get: { pendingSession != nil }, set: { if !$0 { pendingSession = nil } })) {
            Button("取消", role: .cancel) { pendingSession = nil }
            Button(force ? "强制退出实例" : "退出实例", role: .destructive) {
                guard let session = pendingSession else { return }
                let selectedForce = force
                pendingSession = nil
                Task { await store.closeBrowser(session, force: selectedForce) }
            }
        } message: {
            if let session = pendingSession {
                Text("\(session.name) · 主进程 \(session.rootPID)\n\(session.ownerDescription)\n\n将核对并处理这个实例的进程树。关联的抓取、页面读取或验收任务可能中断。\(force ? "强制退出会立即终止仍存活的匹配进程。" : "先请求正常退出；仍存活的进程会列入结果，不会自动强制退出。")\n\n不会删除浏览器资料目录。")
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("让自动化浏览器，有迹可循。").font(.system(size: 17, weight: .semibold))
                    Text("识别实例与启动来源，按实例退出后回读进程；通常无需重启 Mac。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { Task { await store.refreshBrowsers() } } label: {
                    Label(store.scanningBrowsers ? "扫描中…" : "重新扫描", systemImage: "arrow.clockwise").font(.system(size: 11))
                }.disabled(store.scanningBrowsers || store.closingBrowserID != nil)
            }
            HStack(spacing: 18) {
                summary("自动化实例", value: String(store.automationBrowsers.count), symbol: "gearshape.2", tint: Palette.accent)
                summary("关联进程", value: String(store.automationBrowsers.reduce(0) { $0 + $1.members.count }), symbol: "point.3.connected.trianglepath.dotted", tint: Palette.blue)
                summary("合计 RSS（估算）", value: Format.bytes(store.automationBrowsers.reduce(UInt64(0)) { $0 + $1.residentMemoryBytes }), symbol: "memorychip", tint: Palette.purple)
                Spacer(minLength: 0)
                if let date = store.browserScannedAt {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("按需扫描").font(.system(size: 9)).foregroundStyle(Palette.muted)
                        Text(date, style: .time).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }.padding(15).background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
            if let report = store.browserCloseReport {
                VStack(alignment: .leading, spacing: 8) {
                    Text("上次操作 · 主进程 \(report.rootPID)").font(.system(size: 10, weight: .medium))
                    Text(report.message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !report.remainingPIDs.isEmpty {
                        HStack(spacing: 12) {
                            Text("仍存活 PID：" + report.remainingPIDs.map(String.init).joined(separator: ", ")).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            Spacer()
                            if let original = store.lastBrowserSession, original.id == report.sessionID {
                                Button("强制处理原进程…", role: .destructive) { force = true; pendingSession = original }.font(.system(size: 10)).disabled(store.closingBrowserID != nil)
                            }
                        }
                    }
                    if !report.unverifiedPIDs.isEmpty {
                        Text("身份待确认 PID：" + report.unverifiedPIDs.map(String.init).joined(separator: ", ") + "；请先重新扫描。")
                            .font(.system(size: 9)).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }.padding(12).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { showingSort.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                    Text(store.browserSort == "memory" ? "内存占用" : store.browserSort == "age" ? "运行时长" : "进程 ID").font(.system(size: 10))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30).panel(radius: 6)
            }.buttonStyle(.plain).accessibilityLabel("浏览器排序方式")
                .popover(isPresented: $showingSort, arrowEdge: .bottom) {
                    VStack(spacing: 3) {
                        sortOption("内存占用", value: "memory")
                        sortOption("运行时长", value: "age")
                        sortOption("进程 ID", value: "pid")
                    }.padding(8).frame(width: 160)
                }
            HStack(spacing: 3) {
                filter("全部", value: "all")
                filter("自动化", value: "automation")
                filter("无头", value: "headless")
            }.padding(3).background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
            Spacer()
            SearchField(query: $store.browserQuery, focused: $searchFocused)
        }.padding(.horizontal, 24).padding(.bottom, 18)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack { Text("浏览器实例"); Spacer(); Text(String(store.filteredBrowsers.count)) }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 18).frame(height: 34).background(Palette.background)
            if store.scanningBrowsers && store.browserScannedAt == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.filteredBrowsers.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "没有匹配的实例", message: "尝试其他筛选，或重新扫描。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.filteredBrowsers) { session in
                            Button { store.selectedBrowserID = session.id } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 9) {
                                        SymbolBadge(symbol: session.isHeadless ? "terminal" : "globe", tint: session.canClose ? Palette.accent : Palette.blue, size: 29)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(session.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                            Text("PID \(session.rootPID) · \(session.members.count) 个进程").font(.system(size: 9)).foregroundStyle(Palette.muted)
                                        }
                                    }
                                    HStack {
                                        Text(session.classification.displayName).font(.system(size: 9)).foregroundStyle(session.canClose ? Palette.accent : .secondary)
                                        Spacer()
                                        Text(Format.bytes(session.residentMemoryBytes)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Text(session.ownerDescription).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.selectedBrowserID == session.id ? Palette.accent.opacity(0.06) : .clear)
                                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(store.selectedBrowserID == session.id ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private func summary(_ title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 9)).foregroundStyle(Palette.muted)
                Text(value).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
            }
        }.frame(minWidth: 118, alignment: .leading)
    }
    private func sortOption(_ title: String, value: String) -> some View {
        Button { store.browserSort = value; showingSort = false } label: {
            HStack { Text(title); Spacer(); if store.browserSort == value { Image(systemName: "checkmark").foregroundStyle(Palette.accent) } }.font(.system(size: 11)).padding(9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func filter(_ title: String, value: String) -> some View {
        Button { store.browserFilter = value } label: {
            Text(title).font(.system(size: 10)).padding(.horizontal, 10).frame(height: 25)
                .foregroundStyle(store.browserFilter == value ? Palette.accent : .secondary)
                .background(store.browserFilter == value ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(store.browserFilter == value ? .isSelected : [])
    }
}

private struct BrowserSessionDetail: View {
    @EnvironmentObject private var store: ProcessStore
    let session: BrowserSession
    let onClose: (BrowserSession, Bool) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    SymbolBadge(symbol: session.isHeadless ? "terminal" : "globe", size: 43)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.name).font(.system(size: 17, weight: .semibold))
                        Text("主进程 \(session.rootPID) · \(session.classification.displayName)").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if session.isHeadless { Text("HEADLESS").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(Palette.purple).padding(7).background(Palette.purple.opacity(0.07), in: Capsule()) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("归属与当前状态", systemImage: "person.crop.rectangle").font(.system(size: 11, weight: .medium))
                    Text(session.ownerDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(session.risk).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    if !session.ancestorChain.isEmpty {
                        Text(session.ancestorChain.joined(separator: "  ←  ")).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(15).panel(radius: 9)
                actions
                section("识别证据", symbol: "checkmark.shield") {
                    ForEach(Array(session.evidence.enumerated()), id: \.offset) { _, evidence in
                        Label(evidence, systemImage: "smallcircle.filled.circle").font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if session.evidence.isEmpty { Text("没有足够的自动化证据，按受保护实例展示。").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                }
                section("资料目录与启动参数", symbol: "folder") {
                    Text(session.profileURL?.path ?? "未指定隔离资料目录").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let profile = session.profileURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([profile]) } label: { Label("在访达中定位资料目录", systemImage: "folder").font(.system(size: 10)).foregroundStyle(Palette.accent) }.buttonStyle(.plain)
                    }
                    Text(session.redactedCommand).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    if let executable = session.members.first(where: { $0.pid == session.rootPID })?.executablePath {
                        Text("程序路径").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted).padding(.top, 4)
                        Text(executable).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if executable.contains("/code_sign_clone") {
                            Text("正在从签名克隆运行；路径本身不代表进程残留。").font(.system(size: 10)).foregroundStyle(Palette.orange)
                        }
                    }
                }
                section("关联进程 · \(session.members.count)", symbol: "list.bullet.indent") {
                    HStack { Text("进程 / PID"); Spacer(); Text("RSS") }.font(.system(size: 9)).foregroundStyle(Palette.muted)
                    ForEach(session.members) { process in
                        HStack(spacing: 8) {
                            Image(systemName: process.pid == session.rootPID ? "globe" : "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 15)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.name).font(.system(size: 10)).lineLimit(1)
                                Text(String(process.pid)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 6)
                            Text(Format.bytes(process.memoryBytes)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    Text("RSS 合计可能重复计算共享页，不等于退出后必然释放的物理内存。").font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                section("内存与磁盘，需要分开看", symbol: "info.circle") {
                    Text("退出实例后会重新读取进程，通常无需重启。若由启动器自动拉起，应先停止对应任务或启动器。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("临时资料与 code_sign_clone 目录的逻辑大小，不等于 APFS 实际可释放空间；有进程正在使用时不能直接删除。本工具不会删除这些目录。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(24)
        }.background(Palette.background)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { onClose(session, false) } label: { Label("退出这个实例…", systemImage: "stop.circle").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(!session.canClose || store.closingBrowserID != nil)
                Button("强制退出…", role: .destructive) { onClose(session, true) }.font(.system(size: 10)).disabled(!session.canClose || store.closingBrowserID != nil)
                if store.closingBrowserID == session.id { ProgressView().controlSize(.small) }
            }
            Text(session.closeRestriction ?? "可能中断关联的 agent 任务；操作前将再次确认实例身份与进程归属。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if !session.canClose {
                Button("在全部进程中查看主进程") {
                    store.navigate(.processes); store.selectedPID = session.rootPID; store.showInspector = true; store.query = String(session.rootPID)
                }.font(.system(size: 10))
                Text("普通浏览器与桌面应用受到整组退出保护；如确需退出，请先保存工作。").font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let report = store.browserCloseReport, report.rootPID == session.rootPID {
                Text(report.message).font(.system(size: 10)).foregroundStyle(Palette.accent)
            }
        }
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
