import SwiftUI
import AppKit
import ProcessCore

struct InspectorView: View {
    @EnvironmentObject private var store: ProcessStore
    let onTerminate: (ProcessRecord, Bool) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("进程详情").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                ToolButton(symbol: "xmark", label: "关闭详情") { store.showInspector = false }
            }.padding(.leading, 20).padding(.trailing, 9).frame(height: 48)
            if let process = store.selectedProcess {
                ScrollView {
                    VStack(alignment: .leading, spacing: 21) {
                        identity(process)
                        metrics(process)
                        properties(process)
                        executable(process)
                        actions(process)
                    }.padding(.horizontal, 20).padding(.top, 7).padding(.bottom, 24)
                }
            } else {
                EmptyState(symbol: "cursorarrow.click", title: store.selectedPID == nil ? "选择一个进程" : "进程已退出", message: "从左侧列表选择进程，查看资源和运行详情。")
            }
        }.frame(maxHeight: .infinity).background(Palette.background)
    }

    private func identity(_ process: ProcessRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(nsImage: store.icon(for: process)).resizable().frame(width: 48, height: 48)
                Spacer()
                ToolButton(symbol: store.favorites.contains(process.executablePath) ? "star.fill" : "star", label: store.favorites.contains(process.executablePath) ? "取消关注" : "关注进程", selected: store.favorites.contains(process.executablePath)) { store.toggleFavorite(process) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(process.name).font(.system(size: 17, weight: .semibold)).textSelection(.enabled).lineLimit(3)
                HStack(spacing: 7) {
                    StatusDot(color: process.state.contains("T") ? .orange : Palette.accent)
                    Text(stateName(process.state)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(Palette.muted)
                    Text("PID \(process.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
    private func metrics(_ process: ProcessRecord) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Label("CPU", systemImage: "cpu").font(.system(size: 9)).foregroundStyle(Palette.orange)
                Text(Format.percent(process.cpuPercent)).font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Palette.line).frame(width: 1, height: 32).padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 7) {
                Label("内存", systemImage: "memorychip").font(.system(size: 9)).foregroundStyle(Palette.purple)
                Text(Format.bytes(process.memoryBytes)).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).panel(radius: 9)
    }
    private func properties(_ process: ProcessRecord) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeading("运行信息")
            property("用户", value: process.user)
            property("父进程", value: "\(store.processes.first { $0.pid == process.parentPID }?.name ?? "—") (\(process.parentPID))")
            property("线程", value: process.threadCount < 0 ? "不可读取" : String(process.threadCount))
            property("运行时间", value: process.elapsed)
            property("进程类型", value: process.isApplication ? "应用程序" : "后台服务")
            property("系统状态", value: process.state)
        }
    }
    private func executable(_ process: ProcessRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { sectionHeading("可执行文件"); Spacer(); ToolButton(symbol: "doc.on.doc", label: "复制可执行路径") { store.copy(process.executablePath) } }.frame(height: 20)
            Text(process.executablePath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.executablePath)]) } label: {
                Label("在访达中显示", systemImage: "folder").font(.system(size: 10)).foregroundStyle(Palette.accent)
            }.buttonStyle(.plain).disabled(!FileManager.default.fileExists(atPath: process.executablePath))
        }
    }
    private func actions(_ process: ProcessRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(Palette.line).frame(height: 1).padding(.bottom, 8)
            Button { onTerminate(process, false) } label: {
                Label("结束进程…", systemImage: "stop.circle").font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 33)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            }.buttonStyle(.plain).disabled(!ProcessActions.canTerminate(process))
            Button { onTerminate(process, true) } label: {
                Label("强制退出…", systemImage: "xmark.octagon").font(.system(size: 10)).foregroundStyle(ProcessActions.canTerminate(process) ? .red.opacity(0.8) : .secondary).frame(maxWidth: .infinity).frame(height: 28)
            }.buttonStyle(.plain).disabled(!ProcessActions.canTerminate(process))
            Text(ProcessActions.canTerminate(process) ? "结束前请确认已保存相关工作。" : "此进程受保护或属于其他用户。")
                .font(.system(size: 9)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.top, 3)
        }
    }
    private func sectionHeading(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
    private func property(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Palette.muted).frame(width: 56, alignment: .leading)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 10)).lineLimit(2)
    }
    private func stateName(_ state: String) -> String {
        if state.contains("Z") { return "已终止 · 等待回收" }
        if state.contains("T") { return "已停止" }
        if state.contains("R") { return "正在运行" }
        if state.contains("I") { return "空闲" }
        return "休眠中"
    }
}
