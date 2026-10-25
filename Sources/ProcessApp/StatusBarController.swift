import AppKit
import SwiftUI
import Combine
import ProcessCore

/// 原生状态栏入口与 transient popover，复用同一份资源快照。
@MainActor
final class StatusBarController: NSObject {
    private let store: ProcessStore
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var subscriptions: Set<AnyCancellable> = []

    init(store: ProcessStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: 74)
        super.init()
        item.autosaveName = "cduyzhProcessTool.monitor"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("ProcessLens 监控面板")
        }
        let content = MonitorPanelView(closePanel: { [weak self] in self?.popover.performClose(nil) })
            .environmentObject(store)
        let hosting = NSHostingController(rootView: content)
        hosting.preferredContentSize = NSSize(width: 408, height: 575)
        popover.contentViewController = hosting
        popover.contentSize = hosting.preferredContentSize
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        store.$showMenuBar.removeDuplicates().sink { [weak self] visible in
            self?.item.isVisible = visible
            if !visible { self?.popover.performClose(nil) }
        }.store(in: &subscriptions)
        store.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.updateLabel(snapshot: snapshot, paused: self.store.paused)
        }.store(in: &subscriptions)
        store.$paused.removeDuplicates().sink { [weak self] paused in
            guard let self else { return }
            self.updateLabel(snapshot: self.store.snapshot, paused: paused)
        }.store(in: &subscriptions)
    }

    func showPanel() {
        guard store.showMenuBar, let button = item.button else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        if let window = popover.contentViewController?.view.window {
            window.title = "ProcessLens 监控面板"
            window.identifier = NSUserInterfaceItemIdentifier("monitor-panel")
            window.setAccessibilityLabel("ProcessLens 监控面板")
            window.makeKey()
        }
    }

    func invalidate() {
        popover.performClose(nil)
        subscriptions.removeAll()
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    private func updateLabel(snapshot: SystemSnapshot?, paused: Bool) {
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: paused ? "pause.circle" : "waveform.path.ecg", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        button.image = image
        let value = snapshot.map { Format.percent($0.cpuPercent) } ?? "—"
        button.title = snapshot.map { String(format: "%5.1f%%", $0.cpuPercent) } ?? "  —  "
        button.toolTip = "ProcessLens · CPU \(value)\(paused ? " · 已暂停" : "")"
        button.setAccessibilityValue("CPU \(value)\(paused ? "，监测已暂停" : "")")
    }
}
