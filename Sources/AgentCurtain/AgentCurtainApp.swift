import AgentCurtainCore
import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = CurtainPaths()
    private lazy var coordinator = CurtainCoordinator(paths: paths)
    private var menuBar: MenuBarController?
    private var controlServer: ControlServer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var signalSources: [DispatchSourceSignal] = []
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(coordinator: coordinator, paths: paths)
        coordinator.onChange = { [weak self] in self?.menuBar?.refresh() }
        installKeyboardMonitors()
        installSignalHandlers()
        startControlServer()
        coordinator.prepare {}
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.phase != .open else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        coordinator.open { _ in
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }

    private func startControlServer() {
        do {
            let server = ControlServer(socketURL: paths.controlSocket) { [weak self] command, completion in
                guard let self else {
                    completion(ControlResponse(ok: false, error: "AgentCurtain is shutting down"))
                    return
                }
                if case .quit = command {
                    self.coordinator.open { response in
                        completion(response)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
                    }
                } else {
                    self.coordinator.handle(command, completion: completion)
                }
            }
            try server.start()
            controlServer = server
        } catch {
            NSLog("AgentCurtain control server failed: %@", error.localizedDescription)
        }
    }

    private func installKeyboardMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShortcut(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShortcut(event)
            return event
        }
    }

    private func handleShortcut(_ event: NSEvent) {
        let required: NSEvent.ModifierFlags = [.control, .option, .command]
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: required) else { return }
        if event.keyCode == 37, coordinator.phase == .open {
            coordinator.draw { _ in }
        } else if event.keyCode == 32, coordinator.phase == .drawing || (coordinator.phase == .open && coordinator.lastError != nil) {
            coordinator.open { _ in }
        }
    }

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
