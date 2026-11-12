import Foundation
import AVFoundation

final class WhisperCppTranscriber: Transcriber {
    var executableURL: URL
    var modelURL: URL
    var language: String = "en"
    var threads: Int = 4

    init(executableURL: URL, modelURL: URL) {
        self.executableURL = executableURL
        self.modelURL = modelURL
    }

    func transcribe(audio: [Float],
                    completion: @escaping (TranscriberResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let wavURL = try self.writeTempWav(samples: audio)
                defer { try? FileManager.default.removeItem(at: wavURL) }
                let text = try self.runWhisperCli(wavURL: wavURL)
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func writeTempWav(samples: [Float]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p2d-\(UUID().uuidString).wav")

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
        ) else {
            throw NSError(domain: "WhisperCppTranscriber", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build output format"])
        }

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
    }

    private func runWhisperCli(wavURL: URL) throws -> String {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(domain: "WhisperCppTranscriber", code: 11,
                          userInfo: [NSLocalizedDescriptionKey:
                            "whisper-cli not found or not executable at \(executableURL.path)"])
        }
        guard fm.fileExists(atPath: modelURL.path) else {
            throw NSError(domain: "WhisperCppTranscriber", code: 12,
                          userInfo: [NSLocalizedDescriptionKey:
                            "model not found at \(modelURL.path)"])
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-l", language,
            "-t", String(threads),
            "-nt"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let snippet = String(errText.suffix(400))
            throw NSError(domain: "WhisperCppTranscriber",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "whisper-cli exited with status \(process.terminationStatus): \(snippet)"])
        }

        return text
    }
}
