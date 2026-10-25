import SwiftUI
import ProcessCore

struct PortsView: View {
    @EnvironmentObject private var store: ProcessStore
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("谁在使用这些端口？").font(.system(size: 15, weight: .semibold))
                    Text("TCP 监听与 UDP 绑定端点 · 当前用户可见范围").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { Task { await store.refreshPorts() } } label: {
                    Label("刷新端口", systemImage: "arrow.clockwise").font(.system(size: 11))
                }.disabled(store.loadingPorts)
            }.padding(24)
            HStack(spacing: 12) {
                SortDropdown(forPorts: true)
                Text("\(store.filteredPorts.count) 个端点").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                SearchField(query: $store.query, focused: $focused)
            }.padding(.horizontal, 24).padding(.bottom, 20)
            HStack {
                Text("进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 80, alignment: .leading)
                Text("协议").frame(width: 75, alignment: .leading)
                Text("端口").frame(width: 85, alignment: .leading)
                Text("绑定地址").frame(width: 200, alignment: .leading)
                Color.clear.frame(width: 26)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 24).frame(height: 34).background(Color.primary.opacity(0.02))
            if store.loadingPorts {
                ProgressView("正在读取端口…").font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.filteredPorts.isEmpty {
                EmptyState(symbol: "network", title: "没有可见的监听端口", message: store.query.isEmpty ? "端口不会自动刷新，点击刷新可读取最新状态。" : "试试进程名称、PID、地址或端口号。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.filteredPorts) { port in portRow(port) }
                    }
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text("端口按需读取；其他用户或受系统保护的进程可能不可见。")
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .focusProcessSearch)) { _ in focused = true }
    }
    private func portRow(_ port: PortRecord) -> some View {
        HStack {
            HStack(spacing: 10) {
                SymbolBadge(symbol: "terminal", tint: Palette.blue, size: 28)
                Text(port.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(String(port.pid)).frame(width: 80, alignment: .leading)
            Text(port.protocolName).foregroundStyle(Palette.blue).frame(width: 75, alignment: .leading)
            Text(port.port).fontWeight(.medium).frame(width: 85, alignment: .leading)
            Text(port.address).foregroundStyle(Palette.muted).lineLimit(1).frame(width: 200, alignment: .leading).textSelection(.enabled)
            ToolButton(symbol: "doc.on.doc", label: "复制端点 \(port.address):\(port.port)") { store.copy("\(port.address):\(port.port)") }.frame(width: 26)
        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).frame(height: 57)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.6)).frame(height: 0.5).padding(.horizontal, 24) }
            .contextMenu {
                Button("查看进程详情") {
                    store.navigate(.processes); store.selectedPID = port.pid; store.showInspector = true
                }
                Button("复制端口号") { store.copy(port.port) }
                Button("复制 PID") { store.copy(String(port.pid)) }
            }
    }
}
