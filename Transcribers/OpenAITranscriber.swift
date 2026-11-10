import Foundation

final class OpenAITranscriber: Transcriber {
    var apiKey: String
    var model: String = "whisper-1"

    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audio: [Float],
                    completion: @escaping (TranscriberResult) -> Void) {}
}
