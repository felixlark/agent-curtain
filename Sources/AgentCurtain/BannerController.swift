import AppKit

final class BannerController {
    enum Presentation: CaseIterable {
        case enabling, protected, disabling, released, failed

        var status: String {
            switch self {
            case .enabling: return "启用中"
            case .protected: return "屏幕关闭·输入锁定"
            case .disabling: return "解除中"
            case .released: return "已解除"
            case .failed: return "操作失败"
            }
        }

        var detail: String {
            switch self {
            case .enabling: return "⌃⌥⌘U 取消"
            case .protected: return "⌃⌥⌘U 解除"
            case .disabling: return "恢复屏幕…"
            case .released: return "可正常操作"
            case .failed: return "请查看菜单"
            }
        }

        var background: NSColor {
            switch self {
            case .protected: return BannerController.featureColor
            case .enabling, .disabling: return NSColor(srgbRed: 1, green: 0.86, blue: 0.86, alpha: 1)
            case .released: return NSColor(srgbRed: 0.90, green: 0.96, blue: 0.92, alpha: 1)
            case .failed: return NSColor(srgbRed: 1, green: 0.88, blue: 0.70, alpha: 1)
            }
        }

        var foreground: NSColor { self == .protected ? .white : NSColor(srgbRed: 0.40, green: 0.12, blue: 0.12, alpha: 1) }
    }

    static let featureColor = NSColor(srgbRed: 0.75, green: 0.10, blue: 0.10, alpha: 1)
    private(set) var windows: [NSWindow] = []
    private(set) var presentation: Presentation = .protected
    private var screenObserver: NSObjectProtocol?
    private var isVisible = false
    private var dismissal: DispatchWorkItem?
    private var generation = 0
    var onScreensChanged: (() -> Void)?
    var displayCount: Int { windows.count }

    func show(_ presentation: Presentation = .protected) {
        precondition(Thread.isMainThread)
        generation += 1
        dismissal?.cancel()
        dismissal = nil
        self.presentation = presentation
        NSApp.unhideWithoutActivation()
        if isVisible {
            windows.forEach { update($0, animated: true) }
        } else {
            isVisible = true
            rebuild()
        }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.rebuild()
                self?.onScreensChanged?()
            }
        }
    }

    func finishRelease() {
        show(.released)
        let current = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            for window in self.windows {
                for segment in window.contentView?.subviews.compactMap({ $0 as? BannerSegment }) ?? [] {
                    segment.fadeOut()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.generation == current else { return }
                self.hide()
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func hide() {
        precondition(Thread.isMainThread)
        generation += 1
        dismissal?.cancel()
        dismissal = nil
        isVisible = false
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func rebuild() {
        guard isVisible else { return }
        windows.forEach { $0.close() }
        windows.removeAll()
        NSScreen.screens.forEach { windows.append(makeWindow(on: $0)) }
    }

    private func makeWindow(on screen: NSScreen) -> NSWindow {
        let topInset = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        let height = topInset > 0 ? topInset : NSStatusBar.system.thickness
        // Keep the whole indicator centered. On a notched screen reserve the
        // camera cutout, placing equal-width status and shortcut wings beside it.
        let notchGap: CGFloat
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // NSWindow can snap a half-point origin down to a whole point. Keep
            // one point of clearance on each side so neither wing touches the notch.
            notchGap = ceil(2 * max(screen.frame.midX - left.maxX, right.minX - screen.frame.midX)) + 2
        } else {
            notchGap = 0
        }
        let wingWidth: CGFloat = 140
        let width = min(notchGap > 0 ? notchGap + wingWidth * 2 : 220, screen.frame.width)
        let rect = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: rect.size),
                              styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        // NSWindow's screen initializer uses screen-local coordinates.
        window.setFrame(rect, display: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false
        window.canHide = false
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        if notchGap > 0 {
            content.addSubview(BannerSegment(frame: NSRect(x: 0, y: 0, width: wingWidth, height: height), role: .status))
            content.addSubview(BannerSegment(frame: NSRect(x: width - wingWidth, y: 0, width: wingWidth, height: height), role: .detail))
        } else {
            content.addSubview(BannerSegment(frame: content.bounds, role: .combined))
        }
        window.contentView = content
        update(window, animated: false)
        window.orderFrontRegardless()
        return window
    }

    private func update(_ window: NSWindow, animated: Bool) {
        window.title = "AgentCurtain · \(presentation.status)"
        for segment in window.contentView?.subviews.compactMap({ $0 as? BannerSegment }) ?? [] {
            let status = presentation == .protected
                ? (ProcessInfo.processInfo.environment["CURTAIN_BANNER_TEXT"] ?? presentation.status)
                : presentation.status
            let text: String
            switch segment.role {
            case .status: text = status
            case .detail: text = presentation.detail
            case .combined: text = "\(status) · \(presentation.detail)"
            }
            segment.apply(text: text, presentation: presentation, animated: animated)
        }
    }
}

private final class BannerSegment: NSView {
    enum Role { case combined, status, detail }
    let role: Role
    private let label = NSTextField(labelWithString: "")

    init(frame: NSRect, role: Role) {
        self.role = role
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(text: String, presentation: BannerController.Presentation, animated: Bool) {
        label.stringValue = text
        label.textColor = presentation.foreground
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 8, y: floor((bounds.height - height) / 2), width: bounds.width - 16, height: height)
        layer?.removeAnimation(forKey: "dismiss")
        layer?.opacity = 1
        let previous = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        let next = presentation.background.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = next
        CATransaction.commit()
        if animated, let previous {
            let transition = CABasicAnimation(keyPath: "backgroundColor")
            transition.fromValue = previous
            transition.toValue = next
            transition.duration = 0.25
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(transition, forKey: "state")
        }
    }

    func fadeOut() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.2
        layer?.opacity = 0
        layer?.add(fade, forKey: "dismiss")
    }
}
