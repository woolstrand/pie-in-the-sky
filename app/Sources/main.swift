import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller.shared
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        controller.onChange = { DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.updateIcon() } }
        updateIcon()

        controller.start()
        DispatchQueue.main.async { [self] in
            switch DriverInstaller.status {
            case .missing:
                offerInstall("BT Latency Proxy needs its audio driver",
                             "The driver adds the “BT Latency Proxy” output. Installing it asks for an administrator password and interrupts audio for a second.")
            case .outdated:
                offerInstall("The audio driver needs an update",
                             "This version of the app comes with a newer driver. Updating asks for an administrator password and interrupts audio for a second.")
            case .current:
                break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: - Status item

    func updateIcon() {
        let symbol: String
        switch controller.snapshot.state {
        case .active: symbol = "headphones.circle.fill"
        case .noDriver, .failed: symbol = "exclamationmark.triangle"
        default: symbol = "headphones"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BT Latency Proxy")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snap = controller.snapshot

        switch snap.state {
        case .noDriver:
            info("Driver not installed")
        case .off:
            info("Off")
        case .idle(let reason):
            info("Idle")
            if !reason.isEmpty { info(reason) }
        case .starting(let name):
            info("Starting on \(name)…")
        case .active(let target, let reportedMs):
            info("Active on \(target)")
            info(String(format: "Reports %.0f ms, players now see %.0f ms", reportedMs,
                        CA.proxy.map(CA.presentationLatencyMs) ?? 0))
            if let s = snap.stats {
                info(String(format: "Buffer %.0f ms · drift %+d ppm · resyncs %d", s.bufferMs, s.speedPPM, s.resyncs))
            }
        case .failed(let message):
            info("Error: \(message)")
        }
        menu.addItem(.separator())

        let auto = item("Automatic", #selector(toggleEnabled))
        auto.state = Settings.enabled ? .on : .off
        menu.addItem(auto)

        let threshold = NSMenu()
        for ms in [300.0, 500, 800, 0] {
            let i = item(ms == 0 ? "Always for Bluetooth" : "\(Int(ms)) ms", #selector(setThreshold(_:)))
            i.representedObject = ms
            i.state = Settings.thresholdMs == ms ? .on : .off
            threshold.addItem(i)
        }
        submenu("Engage when latency is above", threshold)

        let delay = NSMenu()
        delay.addItem(disabled("Picture ahead of sound → increase"))
        delay.addItem(disabled("Sound ahead of picture → decrease"))
        delay.addItem(.separator())
        for ms in stride(from: 100.0, through: 400, by: 50) {
            let i = item("\(Int(ms)) ms", #selector(setLatency(_:)))
            i.representedObject = ms
            i.state = Settings.latencyMs == ms ? .on : .off
            delay.addItem(i)
        }
        delay.addItem(.separator())
        for step in [10.0, -10.0] {
            let i = item(step > 0 ? "+10 ms" : "−10 ms", #selector(adjustLatency(_:)))
            i.representedObject = step
            delay.addItem(i)
        }
        submenu(String(format: "Video delay: %.0f ms", Settings.latencyMs), delay)
        menu.addItem(.separator())

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        switch DriverInstaller.status {
        case .missing: menu.addItem(item("Install Driver…", #selector(installDriver)))
        case .outdated: menu.addItem(item("Update Driver…", #selector(installDriver)))
        case .current: menu.addItem(item("Reinstall Driver…", #selector(installDriver)))
        }
        menu.addItem(item("Uninstall…", #selector(uninstall)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func info(_ text: String) { menu.addItem(disabled(text)) }

    private func disabled(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        menu.addItem(i)
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        controller.settingsChanged()
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        Settings.thresholdMs = sender.representedObject as? Double ?? 500
        controller.settingsChanged()
    }

    @objc private func setLatency(_ sender: NSMenuItem) {
        Settings.latencyMs = sender.representedObject as? Double ?? 250
        controller.settingsChanged()
    }

    @objc private func adjustLatency(_ sender: NSMenuItem) {
        Settings.latencyMs += sender.representedObject as? Double ?? 0
        controller.settingsChanged()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Could not change the login item", error.localizedDescription)
        }
    }

    @objc private func installDriver() {
        controller.prepareForDriverChange()
        if let error = DriverInstaller.install() {
            if error != "Cancelled." { alert("Driver installation failed", error) }
        }
        controller.settingsChanged()
    }

    @objc private func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall BT Latency Proxy?"
        a.informativeText = "This removes the audio driver (administrator password required) and the login item, then quits. Afterwards move the app to the Trash."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        controller.prepareForDriverChange()
        if DriverInstaller.status != .missing, let error = DriverInstaller.uninstall() {
            if error != "Cancelled." { alert("Could not remove the driver", error) }
            controller.settingsChanged()
            return
        }
        try? SMAppService.mainApp.unregister()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    private func offerInstall(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        installDriver()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
