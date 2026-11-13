import Foundation
import AVFoundation

final class OpenAITranscriber: Transcriber {
    var apiKey: String
    var model: String = "whisper-1"
    var language: String = "en"

    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audio: [Float],
                    completion: @escaping (TranscriberResult) -> Void) {
        guard !apiKey.isEmpty else {
            completion(.failure(NSError(domain: "OpenAITranscriber", code: 20,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is empty"])))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let wavURL = try self.writeTempWav(samples: audio)
                defer { try? FileManager.default.removeItem(at: wavURL) }
                let wavData = try Data(contentsOf: wavURL)
                let boundary = "p2d-" + UUID().uuidString
                let body = self.buildMultipartBody(wavData: wavData, boundary: boundary)

                var request = URLRequest(url: self.endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("multipart/form-data; boundary=\(boundary)",
                                 forHTTPHeaderField: "Content-Type")
                request.httpBody = body

                let task = self.session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        completion(.failure(error)); return
                    }
                    guard let data = data else {
                        completion(.failure(NSError(domain: "OpenAITranscriber", code: 21,
                            userInfo: [NSLocalizedDescriptionKey: "no response body"])))
                        return
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        let snippet = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
                        completion(.failure(NSError(domain: "OpenAITranscriber",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey:
                                "HTTP \(http.statusCode): \(snippet)"])))
                        return
                    }
                    let text = (String(data: data, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(.success(text))
                }
                task.resume()
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func buildMultipartBody(wavData: Data, boundary: String) -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                .data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)
        appendField(name: "language", value: language)
        appendField(name: "response_format", value: "text")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(("Content-Disposition: form-data; name=\"file\"; " +
                     "filename=\"audio.wav\"\r\n").data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        return body
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
            throw NSError(domain: "OpenAITranscriber", code: 22,
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
}
