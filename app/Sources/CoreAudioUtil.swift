import CoreAudio
import Foundation
import os

let log = Logger(subsystem: "io.github.woolstrand.pieinthesky", category: "app")

/// Thin helpers over the CoreAudio HAL C API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let proxyUID = "PieInTheSky_UID"
    /// Custom property of the proxy driver: reported output latency in ms (CFNumber).
    static let latencySelector: AudioObjectPropertySelector = 0x62746C74 // 'btlt'

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func u32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var a = address(selector, scope); var v: UInt32 = 0; var size = UInt32(4)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    static func f64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64 {
        var a = address(selector); var v: Float64 = 0; var size = UInt32(8)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    @discardableResult
    static func setF64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: Float64) -> OSStatus {
        var a = address(selector); var v = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, 8, &v)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector); var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    // MARK: Devices

    static var devices: [AudioObjectID] { ids(system, kAudioHardwarePropertyDevices) }
    static var defaultOutput: AudioObjectID { u32(system, kAudioHardwarePropertyDefaultOutputDevice) }

    static func setDefaultOutput(_ id: AudioObjectID) {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice); var v = id
        AudioObjectSetPropertyData(system, &a, 0, nil, 4, &v)
    }

    static func name(_ id: AudioObjectID) -> String { string(id, kAudioObjectPropertyName) ?? "?" }
    static func uid(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    static func device(uid: String) -> AudioObjectID? { devices.first { self.uid($0) == uid } }
    static func exists(_ id: AudioObjectID) -> Bool { devices.contains(id) }
    static var proxy: AudioObjectID? { device(uid: proxyUID) }

    static func hasOutput(_ id: AudioObjectID) -> Bool {
        !ids(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty
    }

    static func isBluetooth(_ id: AudioObjectID) -> Bool {
        let t = u32(id, kAudioDevicePropertyTransportType)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func isBuiltIn(_ id: AudioObjectID) -> Bool {
        u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
    }

    /// What players use to delay video: device latency + safety offset + buffer + stream latency.
    static func presentationLatencyMs(_ id: AudioObjectID) -> Double {
        let out = kAudioObjectPropertyScopeOutput
        let rate = f64(id, kAudioDevicePropertyNominalSampleRate)
        let stream = ids(id, kAudioDevicePropertyStreams, out).map { u32($0, kAudioStreamPropertyLatency) }.max() ?? 0
        let frames = u32(id, kAudioDevicePropertyLatency, out) + u32(id, kAudioDevicePropertySafetyOffset, out)
            + u32(id, kAudioDevicePropertyBufferFrameSize, out) + stream
        return rate > 0 ? Double(frames) / rate * 1000 : 0
    }

    // MARK: Proxy latency (custom property)

    static func proxyLatencyMs(_ proxy: AudioObjectID) -> Double? {
        var a = address(latencySelector); var ref: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(proxy, &a, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return (ref.takeRetainedValue() as? NSNumber)?.doubleValue
    }

    @discardableResult
    static func setProxyLatencyMs(_ proxy: AudioObjectID, _ ms: Double) -> OSStatus {
        var a = address(latencySelector)
        let number = NSNumber(value: ms) as CFNumber
        var ref = Unmanaged<CFPropertyList>.passUnretained(number)   // the HAL expects a CFPropertyListRef
        return withExtendedLifetime(number) {
            AudioObjectSetPropertyData(proxy, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFPropertyList>>.size), &ref)
        }
    }

    // MARK: Volume

    /// A place where an output volume can be read, written and observed.
    struct VolumeRef { let object: AudioObjectID; let address: AudioObjectPropertyAddress }

    /// Prefers volume control objects (Bluetooth devices expose volume only there), falls back to
    /// the device-level property on the main element or on channels 1/2.
    static func volumeRefs(_ id: AudioObjectID) -> [VolumeRef] {
        let controls = ids(id, kAudioObjectPropertyControlList).filter {
            u32($0, kAudioObjectPropertyClass) == kAudioVolumeControlClassID
                && u32($0, kAudioControlPropertyScope) == kAudioObjectPropertyScopeOutput
        }
        if !controls.isEmpty {
            return controls.map { VolumeRef(object: $0, address: address(kAudioLevelControlPropertyScalarValue)) }
        }
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        let refs = elements.compactMap { el -> VolumeRef? in
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el)
            return AudioObjectHasProperty(id, &a) ? VolumeRef(object: id, address: a) : nil
        }
        return refs.first?.address.mElement == kAudioObjectPropertyElementMain ? [refs[0]] : refs
    }

    static func volume(_ id: AudioObjectID) -> Float32? {
        guard let r = volumeRefs(id).first else { return nil }
        var a = r.address; var v: Float32 = 0; var size = UInt32(4)
        return AudioObjectGetPropertyData(r.object, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ id: AudioObjectID, _ value: Float32) {
        for r in volumeRefs(id) {
            var a = r.address; var v = max(0, min(1, value))
            AudioObjectSetPropertyData(r.object, &a, 0, nil, 4, &v)
        }
    }
}

/// Keeps track of property listener blocks so they can be removed later.
final class ListenerBag {
    private var items: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func add(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(id, &a, queue, block)
        if status == noErr { items.append((id, address, block)) }
        else { log.error("listener on \(id) failed: \(status)") }
    }

    func removeAll() {
        for (id, address, block) in items {
            var a = address
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        items.removeAll()
    }
}
