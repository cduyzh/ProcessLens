import SwiftUI
import AppKit
import ProcessCore

/// 菜单栏面板只读取共享快照；不创建计时器，也不触发额外采样。
struct MonitorPanelView: View {
    var closePanel: (() -> Void)? = nil
    @EnvironmentObject private var store: ProcessStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: MonitorTab = .overview
    @State private var processOrder: MonitorProcessOrder = .cpu

    private let mint = Color(hex: 0x71D9C5)
    private let blue = Color(hex: 0x72B8F5)
    private let quiet = Color.white.opacity(0.50)
    private var snapshot: SystemSnapshot? { store.snapshot }
    private var memoryFraction: Double {
        guard let snapshot, snapshot.memoryTotalBytes > 0 else { return 0 }
        return Double(snapshot.memoryUsedBytes) / Double(snapshot.memoryTotalBytes)
    }
    private var topProcesses: [ProcessRecord] {
        let order = tab == .overview ? MonitorProcessOrder.cpu : processOrder
        return Array(store.processes.sorted { first, second in
            if order == .memory {
                return first.memoryBytes == second.memoryBytes ? first.pid < second.pid : first.memoryBytes > second.memoryBytes
            }
            return first.cpuPercent == second.cpuPercent ? first.pid < second.pid : first.cpuPercent > second.cpuPercent
        }.prefix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 22).padding(.top, 19)
            tabStrip.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 17)
            Group {
                if tab == .overview { overview }
                else { processOverview }
            }
            .frame(height: 344, alignment: .top)
            .padding(.horizontal, 20)
            footer
        }
        .frame(width: 408)
        .foregroundStyle(.white.opacity(0.92))
        .background {
            ZStack {
                if !reduceTransparency { MonitorPanelBackdrop() }
                LinearGradient(colors: [Color(hex: 0x1D282C).opacity(reduceTransparency ? 1 : 0.93), Color(hex: 0x1B1E23).opacity(reduceTransparency ? 1 : 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [mint.opacity(0.28), .white.opacity(0.13), .white.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .tint(mint)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ProcessLens").font(.system(size: 19, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(store.paused ? Color.white.opacity(0.36) : mint).frame(width: 5, height: 5)
                    Text(statusText).font(.system(size: 10)).foregroundStyle(quiet)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Button { showPage(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .regular)).frame(width: 32, height: 32)
            }
            .buttonStyle(MonitorActionStyle())
            .help("打开设置")
            .accessibilityLabel("打开 ProcessLens 设置")
        }
    }

    private var statusText: String {
        if store.paused { return snapshot == nil ? "监测已暂停" : "已暂停 · 保留最近快照" }
        if store.samplingInterrupted {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return snapshot.map { "采样中断 · 最近 " + formatter.string(from: $0.collectedAt) } ?? "采样暂不可用"
        }
        if snapshot == nil { return store.error == nil ? "等待首次采样" : "采样暂不可用" }
        return "实时监测 · 每 \(Int(store.refreshInterval)) 秒更新"
    }

    private var tabStrip: some View {
        HStack(spacing: 3) {
            ForEach(MonitorTab.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { tab = item }
                } label: {
                    Text(item.rawValue).font(.system(size: 12, weight: tab == item ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(tab == item ? 0.96 : 0.48))
                        .frame(maxWidth: .infinity).frame(height: 29)
                        .background(tab == item ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(tab == item ? 0.05 : 0)))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(item == .overview ? "查看资源概览" : "查看资源占用较高的进程")
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }

    private var overview: some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                resourceRow(symbol: "cpu", title: "CPU", value: snapshot.map { Format.percent($0.cpuPercent) } ?? "—",
                            detail: "整体使用率", fraction: (snapshot?.cpuPercent ?? 0) / 100,
                            history: store.cpuHistory, ceiling: 100, tint: mint)
                resourceRow(symbol: "memorychip", title: "内存", value: snapshot == nil ? "—" : Format.percent(memoryFraction * 100),
                            detail: memoryDetail, fraction: memoryFraction,
                            history: store.memoryHistory, ceiling: snapshot.map { Double($0.memoryTotalBytes) }, tint: blue)
            }
            HStack(spacing: 10) {
                compactMetric(symbol: "internaldrive", title: "磁盘已用", value: diskValue, detail: diskDetail, tint: .white.opacity(0.65))
                compactMetric(symbol: "arrow.up.arrow.down", title: "网络", value: networkValue, detail: networkDetail, tint: blue)
            }
            VStack(spacing: 6) {
                HStack {
                    Text("CPU 占用较高").font(.system(size: 10, weight: .medium)).foregroundStyle(quiet)
                    Spacer()
                    Text(snapshot.map { "\($0.processes.count) 个进程" } ?? "等待采样").font(.system(size: 9)).foregroundStyle(.white.opacity(0.34))
                }.frame(height: 16)
                if topProcesses.isEmpty { processEmptyState.frame(height: 96) }
                else {
                    VStack(spacing: 0) {
                        ForEach(topProcesses) { process in compactProcessRow(process) }
                    }
                }
            }
        }
    }

    private func resourceRow(symbol: String, title: String, value: String, detail: String, fraction: Double, history: [Double], ceiling: Double?, tint: Color) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 17, weight: .light)).foregroundStyle(tint)
                .frame(width: 37, height: 40)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                    Spacer(minLength: 3)
                    Text(value).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                }
                meter(fraction: fraction, tint: tint)
                Text(detail).font(.system(size: 9)).foregroundStyle(quiet).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            Group {
                if history.count > 1 {
                    Sparkline(values: history, tint: tint, ceiling: ceiling)
                } else {
                    Text("等待采样").font(.system(size: 9)).foregroundStyle(.white.opacity(0.28))
                }
            }
            .frame(width: 81, height: 34)
            .padding(.leading, 5)
        }
        .frame(height: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(value)，\(detail)")
        .help("\(title) · \(detail)。曲线显示最近 \(history.count) 次真实采样。")
    }

    private func meter(fraction: Double, tint: Color) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.68), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * CGFloat(fraction.isFinite ? min(max(fraction, 0), 1) : 0))
                }
        }.frame(height: 4)
        .accessibilityHidden(true)
    }

    private var memoryDetail: String {
        guard let snapshot else { return "等待首次采样" }
        guard snapshot.memoryTotalBytes > 0 else { return "内存容量不可读取" }
        return "\(Format.bytes(snapshot.memoryUsedBytes)) / \(Format.bytes(snapshot.memoryTotalBytes))"
    }
    private var diskValue: String {
        guard let snapshot, snapshot.diskTotalBytes > 0 else { return "—" }
        return Format.percent(Double(snapshot.diskUsedBytes) / Double(snapshot.diskTotalBytes) * 100)
    }
    private var diskDetail: String {
        guard let snapshot, snapshot.diskTotalBytes > 0 else { return "等待容量信息" }
        return "可用 \(Format.bytes(snapshot.diskTotalBytes > snapshot.diskUsedBytes ? snapshot.diskTotalBytes - snapshot.diskUsedBytes : 0))"
    }
    private var networkValue: String {
        guard let snapshot else { return "—" }
        return store.networkHistory.count > 1 ? Format.rate(snapshot.networkBytesPerSecond) : "等待采样"
    }
    private var networkDetail: String {
        guard let snapshot, store.networkHistory.count > 1 else { return "等待第二次采样" }
        return "↓ \(Format.rate(snapshot.networkDownloadPerSecond))"
    }

    private func compactMetric(symbol: String, title: String, value: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(tint).frame(width: 19)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 9)).foregroundStyle(quiet)
                    Spacer(minLength: 0)
                    Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
            }
        }
        .padding(.horizontal, 11).frame(maxWidth: .infinity).frame(height: 52)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.04)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(value)，\(detail)")
        .help(title == "网络" ? "活动物理网络接口的总吞吐，副行显示下载速度。" : "用户目录所在磁盘卷的容量使用情况。")
    }

    private func compactProcessRow(_ process: ProcessRecord) -> some View {
        Button { showProcess(process) } label: {
            HStack(spacing: 10) {
                Image(nsImage: store.icon(for: process)).resizable().interpolation(.high).frame(width: 23, height: 23)
                Text(process.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.80)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 5)
                Text(Format.percent(process.cpuPercent)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(mint)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 5).frame(height: 32).contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(MonitorActionStyle())
        .help("在主窗口查看 \(process.name)（PID \(process.pid)）")
        .accessibilityLabel("\(process.name)，CPU \(Format.percent(process.cpuPercent))。打开进程详情。")
    }

    private var processOverview: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                processSummary(title: "CPU", value: snapshot.map { Format.percent($0.cpuPercent) } ?? "—", symbol: "cpu", tint: mint)
                processSummary(title: "内存", value: snapshot == nil ? "—" : Format.percent(memoryFraction * 100), symbol: "memorychip", tint: blue)
            }
            HStack(spacing: 4) {
                ForEach(MonitorProcessOrder.allCases) { item in
                    Button { processOrder = item } label: {
                        Text(item.rawValue).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(processOrder == item ? mint : .white.opacity(0.43))
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(processOrder == item ? mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("按\(item.rawValue)从高到低排列")
                    .accessibilityLabel("按\(item.rawValue)排序")
                    .accessibilityAddTraits(processOrder == item ? .isSelected : [])
                }
                Spacer()
                Text("前 3 项").font(.system(size: 9)).foregroundStyle(.white.opacity(0.32))
            }
            VStack(spacing: 3) {
                if topProcesses.isEmpty { processEmptyState.frame(height: 186) }
                else {
                    ForEach(topProcesses) { process in detailedProcessRow(process) }
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 9))
                Text(snapshot.map { "当前快照共 \($0.processes.count) 个进程" } ?? "首次采样后显示进程")
                Spacer()
            }
            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            .padding(.horizontal, 4)
        }
    }

    private func processSummary(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .light)).foregroundStyle(tint)
            Text(title).font(.system(size: 10)).foregroundStyle(quiet)
            Spacer(minLength: 2)
            Text(value).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 13).frame(height: 55)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.04)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("整体\(title)使用率：\(value)")
    }

    private func detailedProcessRow(_ process: ProcessRecord) -> some View {
        Button { showProcess(process) } label: {
            HStack(spacing: 11) {
                Image(nsImage: store.icon(for: process)).resizable().interpolation(.high).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(process.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                    Text("PID \(process.pid) · \(process.user)").font(.system(size: 9)).foregroundStyle(quiet).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(processOrder == .cpu ? Format.percent(process.cpuPercent) : Format.bytes(process.memoryBytes))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(processOrder == .cpu ? mint : blue).monospacedDigit()
                    Text(processOrder == .cpu ? Format.bytes(process.memoryBytes) : "CPU \(Format.percent(process.cpuPercent))")
                        .font(.system(size: 9)).foregroundStyle(quiet).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 9).frame(height: 60).contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(MonitorActionStyle())
        .help("在主窗口查看 \(process.name)（PID \(process.pid)）")
        .accessibilityLabel("\(process.name)，进程 ID \(process.pid)，CPU \(Format.percent(process.cpuPercent))，内存 \(Format.bytes(process.memoryBytes))。打开详情。")
    }

    private var processEmptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "waveform.path").font(.system(size: 20, weight: .light)).foregroundStyle(.white.opacity(0.23))
            Text(snapshot == nil ? "等待进程采样" : "暂无可显示的进程").font(.system(size: 11)).foregroundStyle(quiet)
            if snapshot == nil, store.error != nil {
                Text("可在主窗口查看采样状态").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            }
        }.frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Rectangle().fill(.white.opacity(0.085)).frame(height: 1)
            HStack(spacing: 10) {
                Image(systemName: store.paused ? "pause.circle" : "waveform.path.ecg").font(.system(size: 17, weight: .regular)).foregroundStyle(.white.opacity(0.48)).frame(width: 21)
                VStack(alignment: .leading, spacing: 3) {
                    Text("持续监测").font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                    if store.paused, let snapshot {
                        Text(snapshot.collectedAt, format: .dateTime.hour().minute().second())
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                            .accessibilityLabel("最近采样时间")
                    }
                }
                Spacer()
                Toggle("持续监测", isOn: Binding(get: { !store.paused }, set: { store.paused = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(store.paused ? "继续自动采样" : "暂停自动采样，保留最近快照")
                    .accessibilityLabel("持续监测")
                    .accessibilityValue(store.paused ? "已暂停" : "正在监测")
            }.frame(height: 31)
            HStack(spacing: 12) {
                Button { showMainWindow() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 16, weight: .regular)).frame(width: 21)
                        Text("打开主窗口").font(.system(size: 12, weight: .medium))
                    }.padding(.horizontal, 5).frame(height: 30)
                }
                .buttonStyle(MonitorActionStyle())
                .help("打开 ProcessLens 主窗口")
                .accessibilityLabel("打开主窗口")
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "power").font(.system(size: 14))
                        Text("退出").font(.system(size: 11))
                    }.padding(.horizontal, 7).frame(height: 30)
                }
                .buttonStyle(MonitorActionStyle())
                .help("退出 ProcessLens 并停止监测")
                .accessibilityLabel("退出 ProcessLens")
            }
        }
        .foregroundStyle(.white.opacity(0.64))
        .padding(.horizontal, 20).padding(.bottom, 18)
    }

    private func showPage(_ page: NavigationPage) {
        openMain()
        store.navigate(page)
        NSApp.activate(ignoringOtherApps: true)
        close()
    }
    private func showProcess(_ process: ProcessRecord) {
        openMain()
        store.navigate(.processes)
        store.selectedPID = process.pid
        store.showInspector = true
        NSApp.activate(ignoringOtherApps: true)
        close()
    }
    private func showMainWindow() {
        openMain()
        NSApp.activate(ignoringOtherApps: true)
        close()
    }
    private func openMain() {
        if let action = store.openMainWindow { action() }
        else { openWindow(id: "main") }
    }
    private func close() {
        if let closePanel { closePanel() }
        else { dismiss() }
    }
}

private enum MonitorTab: String, CaseIterable, Identifiable {
    case overview = "概览", processes = "进程"
    var id: Self { self }
}
private enum MonitorProcessOrder: String, CaseIterable, Identifiable {
    case cpu = "CPU 占用", memory = "内存占用"
    var id: Self { self }
}

private struct MonitorActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MonitorActionBody(configuration: configuration)
    }
    private struct MonitorActionBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(.white.opacity(configuration.isPressed ? 0.095 : hovering ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

private struct MonitorPanelBackdrop: NSViewRepresentable {
    // macOS 26 introduced the native Liquid Glass view. Keep the older
    // popover material for macOS 14–25 so the same build remains runnable on
    // the supported range. macOS 27 additionally enables the interactive
    // response for the panel's controls.
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            glass.tintColor = NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.18, alpha: 0.30)
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            return glass
        }

        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView else { return }
        glass.cornerRadius = 20
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
    }
}
