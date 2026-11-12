import Foundation
import AVFoundation

final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    var onCaptureSaved: ((URL) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var buffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "push-to-dictate.audio.buffer")

    func start() throws {
        if engine.isRunning { return }

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

        if !captured.isEmpty, let url = writeDebugWav(samples: captured) {
            onCaptureSaved?(url)
        }

        return captured
    }

    private func handleInputBuffer(_ pcm: AVAudioPCMBuffer) {
        guard let converter = converter, let outFormat = outputFormat else { return }

        let level = computeRMS(pcm)
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
                samples.withUnsafeBufferPointer { ptr in
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
}
