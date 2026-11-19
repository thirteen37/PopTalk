import AVFoundation
import CoreAudio
import FluidAudio
import os

/// Captures the microphone while the hotkey is held; returns 16 kHz mono Float32.
final class AudioRecorder: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let samples = OSAllocatedUnfairLock(initialState: [Float]())
    private var sampleRate: Double = 48_000

    func start(deviceUID: String?) throws {
        // Fresh engine each time: a long-lived one keeps a stale format after device changes
        // (AirPods connecting), and installTap then raises an uncatchable ObjC exception.
        engine = AVAudioEngine()
        if let uid = deviceUID, var id = Self.deviceID(forUID: uid), let unit = engine.inputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        samples.withLock { $0.removeAll(keepingCapacity: true) }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [samples] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
            samples.withLock { $0.append(contentsOf: chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns the recording resampled to 16 kHz mono.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let raw = samples.withLock { $0 }
        guard !raw.isEmpty else { return [] }
        return (try? AudioConverter().resample(raw, from: sampleRate)) ?? []
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }
}
