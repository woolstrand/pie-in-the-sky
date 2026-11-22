import CoreAudio
import Foundation
import Synchronization

/// Moves audio from the proxy's loopback input to the Bluetooth output.
///
/// Two IOProcs, no aggregate device: an aggregate aligns its sub-devices to the Bluetooth
/// device's reported latency and would add that much real delay. The two devices run on
/// independent clocks, so a ring buffer sits between them and the reader varies its speed by
/// at most ±0.2 % (linear interpolation) to keep the fill level at a small target.
final class Forwarder: @unchecked Sendable {
    struct Stats { var bufferMs: Double; var speedPPM: Int; var resyncs: Int }

    let proxy: AudioObjectID
    let target: AudioObjectID
    let sampleRate: Double

    private let channels = 2
    private let ringFrames: Int
    private let ring: UnsafeMutablePointer<Float32>
    private let targetFill = 1024.0                 // ~23 ms of margin for IO jitter

    private let written = Atomic<Int>(0)            // frames written so far (producer)
    private let resyncs = Atomic<Int>(0)
    private let lastFill = Atomic<Int>(0)
    private let lastRatioPPM = Atomic<Int>(0)

    // Consumer-only state (touched only on the target's IO thread).
    private var readPos = 0.0
    private var ratio = 1.0
    private var reading = false

    private var inProc: AudioDeviceIOProcID?
    private var outProc: AudioDeviceIOProcID?

    init(proxy: AudioObjectID, target: AudioObjectID, sampleRate: Double) {
        self.proxy = proxy
        self.target = target
        self.sampleRate = sampleRate
        ringFrames = Int(sampleRate * 4)
        ring = .allocate(capacity: ringFrames * channels)
        ring.initialize(repeating: 0, count: ringFrames * channels)
    }

    deinit { ring.deallocate() }

    var stats: Stats {
        Stats(bufferMs: Double(lastFill.load(ordering: .relaxed)) / sampleRate * 1000,
              speedPPM: lastRatioPPM.load(ordering: .relaxed),
              resyncs: resyncs.load(ordering: .relaxed))
    }

    /// Starts both IOProcs. Can block for a while when the Bluetooth output is waking up.
    func start() -> Bool {
        var status = AudioDeviceCreateIOProcIDWithBlock(&inProc, proxy, nil) { [unowned self] _, input, _, _, _ in
            self.produce(input)
        }
        guard status == noErr, inProc != nil else { return false }
        status = AudioDeviceCreateIOProcIDWithBlock(&outProc, target, nil) { [unowned self] _, _, _, output, _ in
            self.consume(output)
        }
        guard status == noErr, outProc != nil else { stop(); return false }
        AudioDeviceStart(proxy, inProc)
        AudioDeviceStart(target, outProc)
        return true
    }

    /// Stops and destroys both IOProcs. Safe to call when a device has already disappeared.
    func stop() {
        if let p = inProc { AudioDeviceStop(proxy, p); AudioDeviceDestroyIOProcID(proxy, p) }
        if let p = outProc { AudioDeviceStop(target, p); AudioDeviceDestroyIOProcID(target, p) }
        inProc = nil
        outProc = nil
    }

    private func produce(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0, let src = list[0].mData?.assumingMemoryBound(to: Float32.self) else { return }
        let ch = max(Int(list[0].mNumberChannels), 1)
        let frames = Int(list[0].mDataByteSize) / 4 / ch
        var w = written.load(ordering: .relaxed)
        for f in 0..<frames {
            let base = (w % ringFrames) * channels
            for c in 0..<channels { ring[base + c] = c < ch ? src[f * ch + c] : 0 }
            w += 1
        }
        written.store(w, ordering: .releasing)
    }

    private func consume(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(output)
        for b in list { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        guard list.count > 0, let dst = list[0].mData?.assumingMemoryBound(to: Float32.self) else { return }
        let ch = max(Int(list[0].mNumberChannels), 1)
        let frames = Int(list[0].mDataByteSize) / 4 / ch
        let w = written.load(ordering: .acquiring)

        if !reading {
            // (Re)start: place the read head exactly targetFill behind the writer.
            if Double(w) < targetFill + 2 { return }
            readPos = Double(w) - targetFill
            ratio = 1
            reading = true
        }
        var fill = Double(w) - readPos
        if fill < 2 || fill > Double(ringFrames) * 0.75 {   // underrun or overrun: resync next cycle
            resyncs.add(1, ordering: .relaxed)
            reading = false
            return
        }
        // Proportional controller with smoothing; at most ±0.2 % speed change (inaudible).
        let error = (fill - targetFill) / sampleRate          // seconds off target
        let wanted = 1 + max(-0.002, min(0.002, error * 0.05))
        ratio += (wanted - ratio) * 0.01
        for f in 0..<frames {
            let i = Int(readPos), frac = Float32(readPos - Double(i))
            let a = (i % ringFrames) * channels, b = ((i + 1) % ringFrames) * channels
            for c in 0..<min(channels, ch) { dst[f * ch + c] = ring[a + c] + (ring[b + c] - ring[a + c]) * frac }
            readPos += ratio
        }
        fill = Double(w) - readPos
        lastFill.store(Int(fill), ordering: .relaxed)
        lastRatioPPM.store(Int((ratio - 1) * 1_000_000), ordering: .relaxed)
    }
}
