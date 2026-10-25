import SwiftUI
import AppKit

struct ReleaseHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []
    private let version = AppVersion.current

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 49, height: 49)
                VStack(alignment: .leading, spacing: 6) {
                    Text("版本与更新历史").font(.system(size: 21, weight: .semibold))
                    Text("ProcessLens · \(version.displayString)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text(version.isInstalled ? "已安装到本机" : "开发构建").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent).padding(.horizontal, 10).padding(.vertical, 7).background(Palette.accent.opacity(0.08), in: Capsule())
            }.padding(26)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if version.releaseHistory.isEmpty {
                        EmptyState(symbol: "clock.arrow.circlepath", title: "未能读取更新记录", message: "请重新构建或重新安装应用包。")
                    } else {
                        ForEach(version.releaseHistory) { release in releaseCard(release) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label(version.updateStatusText, systemImage: "externaldrive").font(.system(size: 11, weight: .medium))
                        Text("当前使用本地构建与安装更新，记录随应用保存。这里的版本日期不表示已经对外发布。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: 10)
                }.padding(24)
            }.background(Palette.background)
            HStack {
                Text("版本号、构建号与应用包记录一致。").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 740, height: 640)
        .background(Palette.surface)
        .onAppear { if let latest = version.releaseHistory.first { expanded.insert(latest.id) } }
    }

    private func releaseCard(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(release.id) { expanded.remove(release.id) }
                else { expanded.insert(release.id) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    SymbolBadge(symbol: release.version == version.version ? "sparkles" : "clock.arrow.circlepath", tint: release.version == version.version ? Palette.accent : Palette.blue, size: 31)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(release.displayString).font(.system(size: 14, weight: .semibold))
                            if release.version == version.version && release.build == version.build { Text("当前版本").font(.system(size: 9)).foregroundStyle(Palette.accent) }
                        }
                        Text(release.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(release.dateDisplayString).font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Image(systemName: expanded.contains(release.id) ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 5)
                }.padding(17).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded.contains(release.id) {
                VStack(alignment: .leading, spacing: 13) {
                    Text(release.summary).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(release.highlights.enumerated()), id: \.offset) { _, highlight in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Palette.accent.opacity(0.65)).frame(width: 4, height: 4).padding(.top, 5)
                            Text(highlight).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                        }
                    }
                    if !release.notes.isEmpty {
                        Divider().opacity(0.5)
                        ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 18)
            }
        }.panel(radius: 10)
    }
}
