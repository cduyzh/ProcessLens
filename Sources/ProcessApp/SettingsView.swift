import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var store: ProcessStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("让监测符合你的节奏。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                settingsSection(title: "监测与外观", symbol: "slider.horizontal.3", tint: Palette.accent) {
                    settingRow("刷新频率", subtitle: "高频采样会增加进程管理器自身的资源占用。") {
                        HStack(spacing: 5) {
                            ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { interval in
                                choice("\(Int(interval)) 秒", selected: store.refreshInterval == interval) { store.refreshInterval = interval }
                            }
                        }
                    }
                    Divider().opacity(0.5)
                    settingRow("界面外观", subtitle: "浅色、深色或跟随 macOS 系统设置。") {
                        HStack(spacing: 5) {
                            choice("跟随系统", selected: store.appearance == "system") { store.appearance = "system" }
                            choice("浅色", selected: store.appearance == "light") { store.appearance = "light" }
                            choice("深色", selected: store.appearance == "dark") { store.appearance = "dark" }
                        }
                    }
                    Divider().opacity(0.5)
                    settingRow("在菜单栏显示", subtitle: "点击顶部图标，展开资源监控与高占用进程面板。") {
                        Toggle("在菜单栏显示", isOn: $store.showMenuBar).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                settingsSection(title: "键盘快捷键", symbol: "keyboard", tint: Palette.purple) {
                    shortcut("搜索进程", keys: "⌘ F")
                    shortcut("立即刷新", keys: "⌘ R")
                    shortcut("暂停 / 继续监测", keys: "⇧ ⌘ P")
                    shortcut("显示 / 隐藏详情", keys: "⌥ ⌘ I")
                    shortcut("导出当前列表", keys: "⌘ S")
                    shortcut("打开设置", keys: "⌘ ,")
                }
                settingsSection(title: "数据与进程操作", symbol: "lock.shield", tint: Palette.blue) {
                    information("全部在本机完成", detail: "进程、资源与端口数据不会上传。关注列表和界面偏好保存在本机。", symbol: "externaldrive.badge.checkmark")
                    information("操作前二次确认", detail: "仅允许结束当前用户的非保护进程。执行前会重新核对 PID、用户与启动时间。", symbol: "hand.raised")
                    information("数据口径", detail: "进程 CPU 以单个逻辑核心为 100%，多线程程序可能超过 100%；总 CPU 按全机核心归一化。内存为驻留内存（RSS）。", symbol: "chart.bar.xaxis")
                    information("端口与采样边界", detail: "端口按需读取，UDP 展示绑定端点。首帧 CPU 和网络需等待下一次采样形成差值。", symbol: "network")
                }
                about
            }.padding(.horizontal, 32).padding(.top, 4).padding(.bottom, 36).frame(maxWidth: 900)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func settingsSection<Content: View>(title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) { SymbolBadge(symbol: symbol, tint: tint, size: 26); Text(title).font(.system(size: 13, weight: .semibold)) }
            VStack(spacing: 18, content: content).padding(20).panel()
        }
    }
    private func settingRow<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer()
            content()
        }
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .medium : .regular)).foregroundStyle(selected ? Palette.accent : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Palette.accent.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Palette.accent.opacity(0.25) : Palette.line))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func shortcut(_ title: String, keys: String) -> some View {
        HStack { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Text(keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 4).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5)) }
    }
    private func information(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .light)).foregroundStyle(Palette.accent).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text("ProcessLens").font(.system(size: 17, weight: .semibold))
                    Text("版本 \(AppVersion.current.displayString) · \(AppVersion.current.isInstalled ? "已安装到本机" : "开发构建")").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text("MACOS NATIVE").font(.system(size: 8, weight: .medium)).tracking(1.4).foregroundStyle(Palette.accent)
            }
            Divider().opacity(0.5)
            Text("看清每个进程，让 Mac 从容运行。").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(AppVersion.current.runPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            if let date = AppVersion.current.buildDateDisplayString {
                Text("构建时间  \(date)").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if let revision = AppVersion.current.sourceRevision, let hash = AppVersion.current.sourceHash {
                Text("来源  \(revision.prefix(16))  ·  SHA-256 \(hash.prefix(12))").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            HStack {
                Button { store.showReleaseHistory = true } label: { Label("查看更新历史", systemImage: "clock.arrow.circlepath").font(.system(size: 11)) }
                Spacer()
                Text(AppVersion.current.updateStatusText).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Text("通过本地安装包更新；历史记录与当前版本随应用一起保存。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(22).panel()
    }
}
