import Foundation
import AVFoundation
import CoreAudio

final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    var onCaptureSaved: ((URL) -> Void)?

    private(set) var peakRMS: Float = 0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var buffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "push-to-dictate.audio.buffer")

    func start() throws {
        if engine.isRunning { return }

        peakRMS = 0
        try applyPreferredInputDevice()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create output format"])
        }
        outputFormat = outFormat

        guard let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create converter"])
        }
        converter = conv

        bufferQueue.sync { buffer.removeAll(keepingCapacity: true) }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] pcm, _ in
            self?.handleInputBuffer(pcm)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        guard engine.isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        var captured: [Float] = []
        bufferQueue.sync {
            captured = buffer
            buffer.removeAll(keepingCapacity: true)
        }

        converter = nil
        outputFormat = nil

        if !captured.isEmpty, Preferences.shared.saveDebugRecordings,
           let url = writeDebugWav(samples: captured) {
            onCaptureSaved?(url)
        }

        return captured
    }

    private func handleInputBuffer(_ pcm: AVAudioPCMBuffer) {
        guard let converter = converter, let outFormat = outputFormat else { return }

        let level = computeRMS(pcm)
        if level > peakRMS { peakRMS = level }
        if let onLevel = onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }

        let outCapacity = AVAudioFrameCount(
            ceil(Double(pcm.frameLength) * outFormat.sampleRate / pcm.format.sampleRate) + 64
        )
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            return
        }

        var error: NSError?
        var inputProvided = false
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return pcm
        }

        if status == .error { return }

        guard let channelData = outBuf.floatChannelData else { return }
        let count = Int(outBuf.frameLength)
        if count == 0 { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        bufferQueue.async { [weak self] in
            self?.buffer.append(contentsOf: samples)
        }
    }

    private func computeRMS(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let channelData = pcm.floatChannelData else { return 0 }
        let channels = Int(pcm.format.channelCount)
        let frames = Int(pcm.frameLength)
        if frames == 0 || channels == 0 { return 0 }
        var sum: Float = 0
        for ch in 0..<channels {
            let data = channelData[ch]
            for i in 0..<frames {
                let v = data[i]
                sum += v * v
            }
        }
        return (sum / Float(frames * channels)).squareRoot()
    }

    private func writeDebugWav(samples: [Float]) -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("push-to-dictate/debug", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return nil
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("recording-\(fmt.string(from: Date())).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)

            let chunkFrames = 4096
            var offset = 0
            while offset < samples.count {
                let remaining = samples.count - offset
                let toWrite = min(chunkFrames, remaining)
                guard let buf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                                 frameCapacity: AVAudioFrameCount(toWrite)) else { break }
                buf.frameLength = AVAudioFrameCount(toWrite)
                guard let chData = buf.floatChannelData else { break }
                _ = samples.withUnsafeBufferPointer { ptr in
                    memcpy(chData[0],
                           ptr.baseAddress!.advanced(by: offset),
                           toWrite * MemoryLayout<Float>.size)
                }
                try file.write(from: buf)
                offset += toWrite
            }
            return url
        } catch {
            return nil
        }
    }

    deinit {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Input device selection

    private func applyPreferredInputDevice() throws {
        let uid = Preferences.shared.inputDeviceUID
        guard !uid.isEmpty else { return }
        guard let deviceID = AudioRecorder.audioDeviceID(forUID: uid) else { return }
        var id = deviceID
        let au = engine.inputNode.audioUnit
        guard let unit = au else { return }
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        if status != noErr {
            throw NSError(domain: "AudioRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Could not set input device (OSStatus \(status))"])
        }
    }

    static func availableInputDevices() -> [(uid: String, name: String)] {
        let deviceIDs = allAudioDeviceIDs()
        var results: [(uid: String, name: String)] = []
        for id in deviceIDs {
            if !deviceHasInputStreams(id) { continue }
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else {
                continue
            }
            let name = stringProperty(id, selector: kAudioObjectPropertyName) ?? uid
            results.append((uid: uid, name: name))
        }
        return results.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allAudioDeviceIDs() {
            if stringProperty(id, selector: kAudioDevicePropertyDeviceUID) == uid {
                return id
            }
        }
        return nil
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        if status != noErr || dataSize == 0 { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
        if status != noErr { return [] }
        return ids
    }

    private static func deviceHasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMaster
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        if status != noErr || size == 0 { return false }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                     alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bytes.deallocate() }
        status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, bytes)
        if status != noErr { return false }
        let listPtr = bytes.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        for buffer in buffers {
            if buffer.mNumberChannels > 0 { return true }
        }
        return false
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var cfString: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        if status != noErr { return nil }
        return cfString as String
    }
}
