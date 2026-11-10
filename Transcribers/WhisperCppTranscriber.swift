import Foundation

final class WhisperCppTranscriber: Transcriber {
    var executableURL: URL
    var modelURL: URL

    init(executableURL: URL, modelURL: URL) {
        self.executableURL = executableURL
        self.modelURL = modelURL
    }

    func transcribe(audio: [Float],
                    completion: @escaping (TranscriberResult) -> Void) {}
}
