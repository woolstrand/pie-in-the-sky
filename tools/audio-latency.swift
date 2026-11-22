// Prints every output device with the latency figures players use for A/V sync.
// Run: swift tools/audio-latency.swift   (the default output is marked with *)

import CoreAudio
import Foundation

func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = def; var size = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
    return st == noErr ? v : def
}
func name(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf else { return "?" }
    return s.takeRetainedValue() as String
}
func fourcc(_ v: UInt32) -> String {
    String(bytes: [24,16,8,0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)"
}
let out = kAudioObjectPropertyScopeOutput
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
let defOut: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0)

print(ISO8601DateFormatter().string(from: Date()))
for id in ids {
    var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: out, mElement: kAudioObjectPropertyElementMain)
    var ssize: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize)
    if ssize == 0 { continue } // no output streams
    var streams = [AudioStreamID](repeating: 0, count: Int(ssize) / 4)
    AudioObjectGetPropertyData(id, &saddr, 0, nil, &ssize, &streams)
    let sr: Float64 = prop(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0)
    let lat: UInt32 = prop(id, kAudioDevicePropertyLatency, out, 0)
    let safety: UInt32 = prop(id, kAudioDevicePropertySafetyOffset, out, 0)
    let buf: UInt32 = prop(id, kAudioDevicePropertyBufferFrameSize, out, 0)
    let transport: UInt32 = prop(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0)
    let running: UInt32 = prop(id, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, 0)
    let sLat = streams.map { (prop($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0))) }
    let total = Double(lat + safety + buf + (sLat.max() ?? 0))
    let ms = { (f: UInt32) in sr > 0 ? String(format: "%.1fms", Double(f) / sr * 1000) : "-" }
    print("\(id == defOut ? "*" : " ") \(name(id)) [\(fourcc(transport))] sr=\(Int(sr)) running=\(running)")
    print("    deviceLatency=\(lat) (\(ms(lat)))  safetyOffset=\(safety) (\(ms(safety)))  buffer=\(buf) (\(ms(buf)))  streamLatency=\(sLat)")
    print(String(format: "    TOTAL presentation latency ≈ %.1f ms", sr > 0 ? total / sr * 1000 : 0))
}
