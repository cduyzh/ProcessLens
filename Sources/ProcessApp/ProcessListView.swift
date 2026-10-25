import SwiftUI
import ProcessCore

struct ProcessListView: View {
    @EnvironmentObject private var store: ProcessStore
    var onTerminate: (ProcessRecord, Bool) -> Void
    @FocusState private var searchFocused: Bool
    private var records: [ProcessRecord] { store.filteredProcesses }

    var body: some View {
        VStack(spacing: 0) {
            sectionTitle
            controls
            columnHeader
            if store.snapshot == nil {
                VStack(spacing: 15) { ProgressView().controlSize(.small); Text("正在读取本机进程…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                EmptyState(symbol: store.page == .favorites ? "star" : "magnifyingglass", title: store.page == .favorites && store.query.isEmpty ? "关注值得留意的进程" : "没有匹配的进程", message: store.page == .favorites && store.query.isEmpty ? "在进程详情中点击星标，便可在这里快速查看。" : "试试名称、PID、用户名或可执行文件路径。")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(records) { process in
                                ProcessRow(process: process, selected: store.selectedPID == process.pid)
                                    .onTapGesture { store.selectedPID = process.pid }
                                    .contextMenu { contextMenu(process) }
                                    .id(process.pid)
                            }
                        }
                    }.scrollIndicators(.visible)
                }
            }
        }
        .background(Palette.surface)
        .onReceive(NotificationCenter.default.publisher(for: .focusProcessSearch)) { _ in searchFocused = true }
    }

    private var sectionTitle: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(store.page == .overview ? "进程活动" : store.page.title).font(.system(size: 14, weight: .semibold))
            Text(String(records.count)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3).background(Color.primary.opacity(0.045), in: Capsule())
            Spacer()
            Text(store.page == .favorites ? "按可执行路径持续关注" : "点击进程查看详情").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(.horizontal, 23).padding(.top, 19).padding(.bottom, 15)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            SortDropdown()
            if store.page != .applications {
                HStack(spacing: 2) {
                    ForEach(ProcessScope.allCases, id: \.self) { scope in
                        Button { store.scope = scope } label: {
                            Text(scope.rawValue).font(.system(size: 10, weight: store.scope == scope ? .medium : .regular))
                                .foregroundStyle(store.scope == scope ? Color.primary : .secondary)
                                .padding(.horizontal, 10).frame(height: 25)
                                .background(store.scope == scope ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .shadow(color: .black.opacity(store.scope == scope ? 0.05 : 0), radius: 2, y: 1)
                        }.buttonStyle(.plain).accessibilityAddTraits(store.scope == scope ? .isSelected : [])
                    }
                }.padding(3).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            }
            Spacer(minLength: 0)
            SearchField(query: $store.query, focused: $searchFocused)
        }.padding(.horizontal, 22).padding(.bottom, 17)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("进程名称").frame(maxWidth: .infinity, alignment: .leading)
            Button { store.sort = .cpu } label: {
                HStack(spacing: 3) { Text("CPU"); if store.sort == .cpu { Image(systemName: "chevron.down").font(.system(size: 7)) } }
                    .frame(width: 62, alignment: .trailing)
            }.buttonStyle(.plain)
            Button { store.sort = .memory } label: { Text("内存").frame(width: 78, alignment: .trailing) }.buttonStyle(.plain)
            Text("PID").frame(width: 62, alignment: .trailing)
            Text("用户").frame(width: 69, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
        .padding(.horizontal, 23).frame(height: 32)
        .background(Color.primary.opacity(0.018))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    @ViewBuilder private func contextMenu(_ process: ProcessRecord) -> some View {
        Button("查看详情", systemImage: "info.circle") { store.selectedPID = process.pid; store.showInspector = true }
        Button(store.favorites.contains(process.executablePath) ? "取消关注" : "关注进程", systemImage: "star") { store.toggleFavorite(process) }
        Button("复制 PID", systemImage: "doc.on.doc") { store.copy(String(process.pid)) }
        Button("复制可执行路径", systemImage: "folder") { store.copy(process.executablePath) }
        Divider()
        Button("结束进程…", systemImage: "stop.circle", role: .destructive) { onTerminate(process, false) }.disabled(!ProcessActions.canTerminate(process))
        Button("强制退出…", systemImage: "xmark.octagon", role: .destructive) { onTerminate(process, true) }.disabled(!ProcessActions.canTerminate(process))
    }
}

struct ProcessRow: View {
    @EnvironmentObject private var store: ProcessStore
    let process: ProcessRecord
    let selected: Bool
    @State private var hover = false
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: store.icon(for: process)).resizable().interpolation(.high).frame(width: 25, height: 25)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(process.name).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
                        if store.favorites.contains(process.executablePath) { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Palette.orange) }
                    }
                    Text(process.isApplication ? "应用程序" : (process.user == "root" ? "系统进程" : "后台进程"))
                        .font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.percent(process.cpuPercent)).foregroundStyle(process.cpuPercent >= 40 ? Palette.orange : Color.secondary).frame(width: 62, alignment: .trailing)
            Text(Format.bytes(process.memoryBytes)).frame(width: 78, alignment: .trailing)
            Text(String(process.pid)).foregroundStyle(Palette.muted).frame(width: 62, alignment: .trailing)
            Text(process.user).foregroundStyle(Palette.muted).lineLimit(1).frame(width: 69, alignment: .trailing)
        }
        .font(.system(size: 10)).monospacedDigit()
        .padding(.horizontal, 23).frame(height: 53)
        .background(selected ? Palette.accent.opacity(0.065) : Color.primary.opacity(hover ? 0.025 : 0))
        .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3, height: 22) } }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.55)).frame(height: 0.5).padding(.leading, 23) }
        .contentShape(Rectangle()).onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { store.selectedPID = process.pid }
    }
}

struct SortDropdown: View {
    @EnvironmentObject private var store: ProcessStore
    @State private var showing = false
    var forPorts = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.left.and.arrow.up.right").rotationEffect(.degrees(-45)).font(.system(size: 10))
                Text(forPorts ? (store.sort == .name ? "进程名称" : store.sort == .pid ? "进程 ID" : "端口排序") : store.sort.rawValue).font(.system(size: 10))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }.foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
        }.buttonStyle(.plain).accessibilityLabel("排序方式")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("排序方式").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 9).padding(.vertical, 6)
                    ForEach(forPorts ? [.cpu, .name, .pid] : ProcessSort.allCases, id: \.self) { sort in
                        Button { store.sort = sort; showing = false } label: {
                            HStack {
                                Text(forPorts && sort == .cpu ? "端口排序" : sort.rawValue)
                                Spacer()
                                if store.sort == sort || (forPorts && sort == .cpu && store.sort == .memory) { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                            }.font(.system(size: 12)).padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(7).frame(width: 165)
            }
    }
}

struct SearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("搜索名称 / PID", text: $query).textFieldStyle(.plain).font(.system(size: 10)).focused(focused).accessibilityLabel("搜索进程")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.muted) }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            } else { Text("⌘ F").font(.system(size: 9)).foregroundStyle(Palette.muted) }
        }.padding(.horizontal, 9).frame(width: 171, height: 30)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused.wrappedValue ? Palette.accent.opacity(0.5) : Palette.line))
    }
}
