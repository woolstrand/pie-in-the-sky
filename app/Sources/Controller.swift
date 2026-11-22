import CoreAudio
import Foundation
import os

/// Decides when to route audio through the proxy and keeps the routing, latency and volume in sync.
/// Everything except `snapshot` runs on `queue`.
final class Controller: @unchecked Sendable {
    enum State: Equatable {
        case noDriver
        case off                                       // automatic mode disabled
        case idle(String)                              // reason, shown in the menu
        case starting(String)                          // Bluetooth device name
        case active(target: String, reportedMs: Double)
        case failed(String)
    }

    struct Snapshot {
        var state: State = .idle("")
        var stats: Forwarder.Stats?
        var proxyLatencyMs: Double?
    }

    static let shared = Controller()

    let queue = DispatchQueue(label: "bt-latency-proxy.controller")
    var onChange: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var _snapshot = Snapshot()
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        var s = _snapshot
        s.stats = forwarderForStats?.stats
        return s
    }

    private var forwarder: Forwarder?
    private weak var forwarderForStats: Forwarder?
    private var targetUID: String?
    private var systemListeners: ListenerBag!
    private var sessionListeners: ListenerBag!
    private var suppressAutoUntil = Date.distantPast

    private init() {
        systemListeners = ListenerBag(queue: queue)
        sessionListeners = ListenerBag(queue: queue)
    }

    func start() {
        queue.async { [self] in
            let sys = CA.system
            systemListeners.add(sys, CA.address(kAudioHardwarePropertyDevices)) { [self] in devicesChanged() }
            systemListeners.add(sys, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [self] in evaluate() }
            evaluate()
        }
    }

    /// Called on quit: stop forwarding and give the output back to the Bluetooth device.
    func shutdown() {
        queue.sync { disengage(restoreDefault: true) }
    }

    func settingsChanged() {
        queue.async { [self] in
            if let proxy = CA.proxy { CA.setProxyLatencyMs(proxy, Settings.latencyMs) }
            if !Settings.enabled { disengage(restoreDefault: true) }
            evaluate()
        }
    }

    /// Before the driver is reinstalled coreaudiod restarts and all device IDs change.
    func prepareForDriverChange() {
        queue.sync {
            disengage(restoreDefault: true)
            suppressAutoUntil = Date().addingTimeInterval(5)
        }
    }

    // MARK: - Decision logic

    private func devicesChanged() {
        if let fwd = forwarder, !CA.exists(fwd.target) || !CA.exists(fwd.proxy) {
            // The Bluetooth device went away (or coreaudiod restarted).
            let proxyWasDefault = CA.proxy.map { CA.defaultOutput == $0 } ?? false
            teardown()
            if proxyWasDefault { fallBackToLocalOutput() }
        }
        evaluate()
        // Freshly connected Bluetooth devices settle their latency a moment later.
        for delay in [1.5, 5.0] { queue.asyncAfter(deadline: .now() + delay) { [self] in evaluate() } }
    }

    private func evaluate() {
        guard let proxy = CA.proxy else {
            teardown()
            publish(.noDriver)
            return
        }
        let current = CA.defaultOutput

        if let fwd = forwarder {
            if current == proxy { return }                         // all good
            if current == fwd.target && Settings.enabled {          // user re-picked the headset
                CA.setDefaultOutput(proxy)
                return
            }
            disengage(restoreDefault: false)                        // user picked another output
        }

        guard Settings.enabled else { publish(.off); return }
        guard Date() >= suppressAutoUntil else { return }

        if current == proxy {
            // Proxy selected without a session (e.g. after a crash, or chosen by hand).
            if let bt = bluetoothOutputs().first {
                engage(proxy: proxy, target: bt)
            } else {
                fallBackToLocalOutput()
                publish(.idle("No Bluetooth output connected"))
            }
            return
        }

        guard CA.isBluetooth(current) else {
            publish(.idle("Output is not Bluetooth"))
            return
        }
        let reported = CA.presentationLatencyMs(current)
        if Settings.thresholdMs > 0 && reported < Settings.thresholdMs {
            publish(.idle(String(format: "%@ reports %.0f ms — fine as is", CA.name(current), reported)))
            return
        }
        engage(proxy: proxy, target: current)
    }

    private func bluetoothOutputs() -> [AudioObjectID] {
        CA.devices.filter { CA.isBluetooth($0) && CA.hasOutput($0) }
    }

    private func fallBackToLocalOutput() {
        let outputs = CA.devices.filter { CA.hasOutput($0) && $0 != CA.proxy }
        if let local = outputs.first(where: CA.isBuiltIn) ?? outputs.first { CA.setDefaultOutput(local) }
    }

    // MARK: - Session

    private func engage(proxy: AudioObjectID, target: AudioObjectID) {
        let name = CA.name(target)
        publish(.starting(name))

        let rate = CA.f64(target, kAudioDevicePropertyNominalSampleRate)
        guard rate > 0 else { publish(.failed("\(name): unknown sample rate")); return }
        if CA.f64(proxy, kAudioDevicePropertyNominalSampleRate) != rate {
            CA.setF64(proxy, kAudioDevicePropertyNominalSampleRate, rate)
            Thread.sleep(forTimeInterval: 0.3)                       // the driver applies it asynchronously
        }
        CA.setProxyLatencyMs(proxy, Settings.latencyMs)

        let fwd = Forwarder(proxy: proxy, target: target, sampleRate: rate)
        guard fwd.start() else { publish(.failed("Could not start audio on \(name)")); return }
        forwarder = fwd
        targetUID = CA.uid(target)
        lock.lock(); forwarderForStats = fwd; lock.unlock()

        if let v = CA.volume(target) { CA.setVolume(proxy, v) }
        mirrorVolume(proxy: proxy, target: target)
        // A sample-rate change (e.g. the headset switching to the hands-free profile) needs a restart.
        sessionListeners.add(target, CA.address(kAudioDevicePropertyNominalSampleRate)) { [self] in restart() }

        CA.setDefaultOutput(proxy)
        publish(.active(target: name, reportedMs: CA.presentationLatencyMs(target)))
    }

    private func restart() {
        guard let fwd = forwarder,
              CA.f64(fwd.target, kAudioDevicePropertyNominalSampleRate) != fwd.sampleRate else { return }
        let proxy = fwd.proxy, target = fwd.target
        teardown()
        if CA.exists(target) && CA.exists(proxy) { engage(proxy: proxy, target: target) } else { evaluate() }
    }

    private func mirrorVolume(proxy: AudioObjectID, target: AudioObjectID) {
        // Both directions. Each side remembers the value it last saw, so a listener reacts only to
        // a real change on its own side; the tolerance absorbs devices that quantize the value.
        let tolerance: Float32 = 0.005
        var lastProxy = CA.volume(proxy) ?? 0
        var lastTarget = CA.volume(target) ?? 0
        // Changes made by other processes (volume keys, the menu bar slider, headset buttons) arrive
        // only as a device-level notification with wildcard scope/element; own changes arrive on the
        // control objects. Listen to both; the last-seen values filter duplicates.
        let anyVolume = CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeWildcard,
                                   kAudioObjectPropertyElementWildcard)
        func volumeSources(_ id: AudioObjectID) -> [(AudioObjectID, AudioObjectPropertyAddress)] {
            [(id, anyVolume)] + CA.volumeRefs(id).map { ($0.object, $0.address) }
        }
        for (object, address) in volumeSources(proxy) {
            sessionListeners.add(object, address) {
                guard let p = CA.volume(proxy), abs(p - lastProxy) > tolerance else { return }
                log.notice("volume: proxy \(p) -> target")
                lastProxy = p
                CA.setVolume(target, p)
                lastTarget = CA.volume(target) ?? p
            }
        }
        for (object, address) in volumeSources(target) {
            sessionListeners.add(object, address) {
                guard let t = CA.volume(target), abs(t - lastTarget) > tolerance else { return }
                log.notice("volume: target \(t) -> proxy")
                lastTarget = t
                CA.setVolume(proxy, t)
                lastProxy = CA.volume(proxy) ?? t
            }
        }
    }

    private func disengage(restoreDefault: Bool) {
        guard let fwd = forwarder else { return }
        let proxyIsDefault = CA.defaultOutput == fwd.proxy
        let uid = targetUID
        teardown()
        if restoreDefault && proxyIsDefault {
            if let uid, let target = CA.device(uid: uid) { CA.setDefaultOutput(target) } else { fallBackToLocalOutput() }
        }
        publish(Settings.enabled ? .idle("Stopped") : .off)
    }

    private func teardown() {
        sessionListeners.removeAll()
        forwarder?.stop()
        lock.lock(); forwarderForStats = nil; lock.unlock()
        forwarder = nil
        targetUID = nil
    }

    private func publish(_ state: State) {
        log.notice("state: \(String(describing: state), privacy: .public)")
        let latency = CA.proxy.flatMap(CA.proxyLatencyMs)
        lock.lock()
        _snapshot.state = state
        _snapshot.proxyLatencyMs = latency
        lock.unlock()
        onChange?()
    }
}
