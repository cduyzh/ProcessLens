import SwiftUI
import AppKit

@main
struct ProcessToolApp: App {
    @StateObject private var store = ProcessStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ProcessLens", id: "main") {
            GeometryReader { geometry in
                WorkspaceView().environmentObject(store)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
                .preferredColorScheme(store.colorScheme)
                .tint(Palette.accent)
                .frame(minWidth: 1080, minHeight: 700)
                .background(WindowActionBridge().environmentObject(store))
                .onAppear { delegate.configure(store: store); store.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.navigate(.settings) }.keyboardShortcut(",")
            }
            CommandGroup(after: .toolbar) {
                Button("显示监控面板") { delegate.showMonitor() }.disabled(!store.showMenuBar)
                Divider()
                Button(store.paused ? "继续自动刷新" : "暂停自动刷新") { store.paused.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("立即刷新") { Task {
                    await store.refresh()
                    if store.page == .ports { await store.refreshPorts() }
                    if store.page == .browsers { await store.refreshBrowsers() }
                    if store.page == .startup { await store.refreshStartup() }
                    if store.page == .diskImages { await store.refreshDiskImages() }
                } }.keyboardShortcut("r")
                Divider()
                Button("显示 / 隐藏详情") { store.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("搜索进程") { NotificationCenter.default.post(name: .focusProcessSearch, object: nil) }.keyboardShortcut("f")
            }
            CommandGroup(replacing: .saveItem) {
                Button("导出当前进程…") { store.exportCSV() }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 ProcessLens") { store.navigate(.settings) }
                Button("更新历史…") { store.showReleaseHistory = true }
                Divider()
                Button("浏览器诊断…") { store.navigate(.browsers) }
                Button("开机启动项…") { store.navigate(.startup) }
                Button("安装镜像…") { store.navigate(.diskImages) }
            }
        }
    }

}

extension Notification.Name { static let focusProcessSearch = Notification.Name("processTool.focusSearch") }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: ProcessStore?
    private var statusBar: StatusBarController?

    func configure(store: ProcessStore) {
        self.store = store
        if statusBar == nil { statusBar = StatusBarController(store: store) }
    }
    func showMonitor() { statusBar?.showPanel() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        statusBar?.invalidate()
        store?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

private struct WindowActionBridge: View {
    @EnvironmentObject private var store: ProcessStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            store.openMainWindow = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
