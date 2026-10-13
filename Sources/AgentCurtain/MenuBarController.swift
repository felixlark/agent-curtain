import AgentCurtainCore
import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let coordinator: CurtainCoordinator
    private let paths: CurtainPaths
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var refreshTimer: Timer?

    init(coordinator: CurtainCoordinator, paths: CurtainPaths) {
        self.coordinator = coordinator
        self.paths = paths
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let symbol: String
        switch coordinator.phase {
        case .drawn: symbol = "eye.slash.fill"
        case .drawing, .opening: symbol = "hourglass"
        default: symbol = "eye"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: coordinator.statusSummary)
        statusItem.button?.toolTip = coordinator.statusSummary
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let summary = NSMenuItem(title: coordinator.statusSummary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        if let warning = coordinator.recoveryWarning {
            let notice = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
            notice.isEnabled = false
            menu.addItem(notice)
        }
        menu.addItem(.separator())

        switch coordinator.phase {
        case .open:
            if coordinator.lastError != nil {
                menu.addItem(item("重试恢复屏幕与窗口", action: #selector(openCurtain), key: "u"))
            }
            menu.addItem(item("启用保护", action: #selector(drawCurtain), key: "l"))
        case .drawn:
            menu.addItem(item("解除保护", action: #selector(openCurtain), key: "u"))
        case .drawing:
            menu.addItem(item("取消启用", action: #selector(openCurtain), key: "u"))
        default:
            let transition = NSMenuItem(title: coordinator.statusSummary, action: nil, keyEquivalent: "")
            transition.isEnabled = false
            menu.addItem(transition)
        }

        menu.addItem(.separator())
        menu.addItem(item("编辑白名单…", action: #selector(editAllowlist)))
        menu.addItem(item("编辑拒绝名单…", action: #selector(editDenylist)))
        let safety = NSMenuItem(title: "弱于真锁屏：仅阻挡机会型接触", action: nil, keyEquivalent: "")
        safety.isEnabled = false
        menu.addItem(safety)
        menu.addItem(.separator())
        menu.addItem(item("退出 AgentCurtain", action: #selector(quit), key: "q"))
    }

    @objc private func drawCurtain() {
        coordinator.draw { [weak self] _ in self?.refresh() }
    }

    @objc private func openCurtain() {
        coordinator.open { [weak self] _ in self?.refresh() }
    }

    @objc private func editAllowlist() { openConfig(paths.allowlist) }
    @objc private func editDenylist() { openConfig(paths.denylist) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openConfig(_ url: URL) {
        _ = try? CurtainConfiguration.load(from: paths)
        NSWorkspace.shared.open(url)
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.control, .option, .command] }
        return item
    }
}
