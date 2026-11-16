import Foundation
import AVFoundation

final class WhisperCppTranscriber: Transcriber {
    var executableURL: URL
    var modelURL: URL
    var language: String = "en"

    // When non-nil, overrides `Preferences.beamSize` for this transcriber
    // instance only. Used by continuous dictation to force a different beam
    // (currently 3) without mutating the user's saved preference used by
    // one-shot dictation.
    var beamSizeOverride: Int?

    // When non-nil and non-empty, seeds whisper's language-model state via
    // the `--prompt` flag so it has context about what came before the audio
    // being transcribed. Used by continuous dictation to pass the last N
    // characters of prior transcript into each chunk, reducing boundary
    // artifacts (word duplication, mishears, hallucinated filler).
    var initialPrompt: String?

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
            _ = samples.withUnsafeBufferPointer { ptr in
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

        let prefs = Preferences.shared
        let beam = String(beamSizeOverride ?? prefs.beamSize)
        let process = Process()
        process.launchPath = executableURL.path
        var args: [String] = [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-l", language,
            "-t", String(prefs.transcriptionThreads),
            "-bs", beam,
            "-bo", beam,
            "-nt"
        ]
        if let prompt = initialPrompt, !prompt.isEmpty {
            args.append(contentsOf: ["--prompt", prompt])
        }
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes concurrently during execution. Without this, long
        // transcriptions fill the ~16-64KB pipe buffer, whisper-cli blocks on
        // write, and waitUntilExit() deadlocks.
        var outData = Data()
        var errData = Data()
        let dataLock = NSLock()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            dataLock.lock(); outData.append(d); dataLock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            dataLock.lock(); errData.append(d); dataLock.unlock()
        }

        process.launch()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let finalOut = stdoutPipe.fileHandleForReading.availableData
        let finalErr = stderrPipe.fileHandleForReading.availableData
        dataLock.lock()
        outData.append(finalOut)
        errData.append(finalErr)
        dataLock.unlock()

        let text = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
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
