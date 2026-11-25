import Foundation
import AVFoundation
import CoreAudio

final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    var onCaptureSaved: ((URL) -> Void)?
    var onAutoStopTriggered: (() -> Void)?
    // Chunk callback receives the captured samples, the preceding gap
    // (seconds of silence between the previous chunk's last speech sample
    // and this chunk's first speech sample; 0 for the first chunk of a
    // session), and a flag indicating whether this emit was triggered by
    // the max-chunk duration cap (true) or by a natural pause (false).
    // The latter lets the consumer distinguish mid-speech cuts (where
    // acoustic overlap matters) from clean sentence-break cuts.
    var onChunkBoundary: (([Float], TimeInterval, Bool) -> Void)?
    // Fires on the audio thread each time RMS crosses the chunk-boundary
    // threshold from below (speech-begin transition), including the first
    // speech of a chunk and every resumption after mid-chunk silence.
    // Used by StatusItemController to pre-emptively cancel the pending
    // trailing-period timer the moment the user starts speaking again,
    // rather than waiting for the next chunk to finish transcribing.
    var onSpeechBegin: (() -> Void)?

    // Set to non-nil to enable silence-based auto-stop. Threshold is the RMS
    // floor below which audio counts as silent; duration is how many seconds
    // of continuous silence must elapse before onAutoStopTriggered fires once.
    var autoStopThreshold: Float?
    var autoStopDuration: TimeInterval?

    // Set to non-nil to enable mid-recording chunk boundaries (continuous
    // dictation). When RMS stays below `chunkBoundaryThreshold` for
    // `chunkBoundaryDuration` after speech has been seen since the last
    // boundary, the current buffer is handed to `onChunkBoundary` and
    // cleared. Recording continues. Multiple boundaries can fire per session.
    // No boundary fires during sustained silence (prevents empty chunks).
    var chunkBoundaryThreshold: Float?
    var chunkBoundaryDuration: TimeInterval?

    // Hard cap on chunk duration. When the per-chunk sample count reaches
    // this many seconds of audio while speech has been seen since the last
    // boundary, a chunk is emitted regardless of whether a pause has
    // occurred. Prevents a single chunk from growing unbounded during
    // sustained speech. The cut is a hard cut; whisper handles fragments
    // better than you'd expect for short chunks.
    var chunkBoundaryMaxDuration: TimeInterval?

    // Seconds of trailing audio to retain from a max-chunk-triggered cut
    // and prepend to the next chunk's buffer. Gives whisper acoustic
    // context on both sides of a mid-speech cut so the boundary word is
    // transcribed from a full utterance rather than a fragment. Only
    // applies to max-chunk cuts; pause-triggered cuts never overlap
    // because they end in silence. Nil or 0 disables the behavior.
    var chunkBoundaryOverlapSeconds: TimeInterval?

    private(set) var peakRMS: Float = 0

    // True iff speech has been detected in the current chunk slot and no
    // emit has reset the flag yet. Writes happen on the audio thread;
    // single-Bool reads from any thread are safe in practice. Used by
    // StatusItemController to suppress scheduling the trailing-period
    // timer when a chunk was force-emitted mid-speech (max-chunk cap).
    var isSpeaking: Bool { return chunkHasSpeech }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var buffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "push-to-dictate.audio.buffer")
    private var silentSince: Date?
    private var autoStopFired: Bool = false
    private var chunkHasSpeech: Bool = false
    private var chunkSilentSince: Date?
    private var chunkSampleCount: Int = 0
    // Timestamps for preceding-gap computation. `previousChunkLastSpeechAt`
    // is captured at emitChunk time (the moment silence first began in the
    // emitted chunk). `currentChunkFirstSpeechAt` is captured when the next
    // chunk's first speech-level sample arrives. Their difference is the
    // silence gap between consecutive chunks.
    private var previousChunkLastSpeechAt: Date?
    private var currentChunkFirstSpeechAt: Date?
    // Carried samples from the tail of a max-chunk-triggered emit, waiting
    // to be prepended to the next chunk when speech resumes.
    private var overlapCarry: [Float] = []

    func start() throws {
        if engine.isRunning { return }

        peakRMS = 0
        silentSince = nil
        autoStopFired = false
        chunkHasSpeech = false
        chunkSilentSince = nil
        chunkSampleCount = 0
        previousChunkLastSpeechAt = nil
        currentChunkFirstSpeechAt = nil
        overlapCarry.removeAll(keepingCapacity: true)
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
                          userInfo: [NSLocalizedDescriptionKey:
                            "Could not create converter (input sampleRate=\(inputFormat.sampleRate), " +
                            "channels=\(inputFormat.channelCount), commonFormat=\(inputFormat.commonFormat.rawValue))"])
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

        if !autoStopFired,
           let threshold = autoStopThreshold,
           let duration = autoStopDuration {
            if level < threshold {
                if silentSince == nil {
                    silentSince = Date()
                } else if Date().timeIntervalSince(silentSince!) >= duration {
                    autoStopFired = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onAutoStopTriggered?()
                    }
                }
            } else {
                silentSince = nil
            }
        }

        if let threshold = chunkBoundaryThreshold,
           let duration = chunkBoundaryDuration {
            if level >= threshold {
                if !chunkHasSpeech {
                    if currentChunkFirstSpeechAt == nil {
                        currentChunkFirstSpeechAt = Date()
                    }
                    // Speech-begin transition: discard any pre-speech
                    // silence that accumulated in the buffer since the
                    // last emit (or session start). Otherwise a long
                    // pre-speech silence would push chunkSampleCount
                    // past chunkBoundaryMaxDuration the moment speech
                    // arrived, emitting a chunk containing mostly
                    // silence and triggering whisper hallucinations.
                    // Also reset the sample counter so max-chunk
                    // duration measures speech+within-speech time, not
                    // session-silence time. The current pcm's samples
                    // are appended below; async ordering on bufferQueue
                    // guarantees the clear runs before them.
                    //
                    // If the previous emit was a max-chunk cut and
                    // overlap is configured, overlapCarry holds the
                    // tail samples; seed the new buffer with them so
                    // whisper sees acoustic context across the cut.
                    // Carry is consumed on first use and chunkSampleCount
                    // is pre-seeded with its sample count so max-chunk
                    // duration counts the overlap against the cap.
                    let carryCopy = overlapCarry
                    overlapCarry.removeAll(keepingCapacity: true)
                    bufferQueue.async { [weak self] in
                        self?.buffer.removeAll(keepingCapacity: true)
                        if !carryCopy.isEmpty {
                            self?.buffer.append(contentsOf: carryCopy)
                        }
                    }
                    chunkSampleCount = carryCopy.count
                    onSpeechBegin?()
                }
                chunkHasSpeech = true
                chunkSilentSince = nil
            } else if chunkHasSpeech {
                if chunkSilentSince == nil {
                    chunkSilentSince = Date()
                } else if Date().timeIntervalSince(chunkSilentSince!) >= duration {
                    emitChunk(wasMaxChunkCut: false)
                }
            }
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

        if chunkBoundaryThreshold != nil {
            chunkSampleCount += count
            if chunkHasSpeech,
               let maxDuration = chunkBoundaryMaxDuration,
               Double(chunkSampleCount) / AudioRecorder.targetSampleRate >= maxDuration {
                emitChunk(wasMaxChunkCut: true)
            }
        }
    }

    private func emitChunk(wasMaxChunkCut: Bool) {
        var chunk: [Float] = []
        bufferQueue.sync {
            chunk = buffer
            buffer.removeAll(keepingCapacity: true)
        }
        // On a max-chunk cut, retain the trailing chunkBoundaryOverlapSeconds
        // of audio to be prepended to the next chunk's buffer. Not applied
        // to pause-triggered cuts: they end in silence, so there's no
        // useful acoustic context to carry.
        if wasMaxChunkCut,
           let overlap = chunkBoundaryOverlapSeconds, overlap > 0,
           !chunk.isEmpty {
            let overlapSamples = Int(overlap * AudioRecorder.targetSampleRate)
            if overlapSamples > 0 && overlapSamples < chunk.count {
                overlapCarry = Array(chunk.suffix(overlapSamples))
            }
        }
        // Compute the silence gap preceding this chunk, before resetting
        // state for the next chunk. Gap is 0 for the first chunk of a
        // session (no previous chunk to measure against).
        let gap: TimeInterval
        if let prevEnd = previousChunkLastSpeechAt,
           let currStart = currentChunkFirstSpeechAt {
            gap = currStart.timeIntervalSince(prevEnd)
        } else {
            gap = 0
        }
        // Remember when this chunk's last speech was so the next chunk
        // can measure its preceding gap. chunkSilentSince was set when
        // silence first began after the last speech sample in this chunk.
        previousChunkLastSpeechAt = chunkSilentSince
        currentChunkFirstSpeechAt = nil
        chunkHasSpeech = false
        chunkSilentSince = nil
        chunkSampleCount = 0
        peakRMS = 0
        if chunk.isEmpty { return }
        if let onChunkBoundary = onChunkBoundary {
            DispatchQueue.main.async { onChunkBoundary(chunk, gap, wasMaxChunkCut) }
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
        return AudioRecorder.writeSamplesAsWav(samples: samples, to: url) ? url : nil
    }

    // Writes 16 kHz mono float samples to `url` as a 16-bit PCM WAV.
    // Returns true on success. Exposed for callers (like
    // `StatusItemController`'s per-chunk debug capture) that build their
    // own output paths.
    static func writeSamplesAsWav(samples: [Float], to url: URL) -> Bool {
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
        ) else { return false }
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
            return true
        } catch {
            return false
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
        // Empty UID means "follow the current system default input". Must
        // actively resolve and set it: AVAudioEngine's inputNode retains
        // whatever device was last pinned on its audio unit, so after
        // selecting a specific device once, switching prefs back to
        // Default would otherwise leave the previous device stuck. Also
        // handles the case where System Preferences' default input
        // changes after process start.
        let uid = Preferences.shared.inputDeviceUID
        let resolved: AudioDeviceID?
        if uid.isEmpty {
            resolved = AudioRecorder.systemDefaultInputDeviceID()
        } else {
            resolved = AudioRecorder.audioDeviceID(forUID: uid)
        }
        guard var id = resolved else { return }
        guard let unit = engine.inputNode.audioUnit else { return }
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

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        if status != noErr || id == 0 { return nil }
        return id
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
