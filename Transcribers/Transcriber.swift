import Foundation

enum TranscriberResult {
    case success(String)
    case failure(Error)
}

protocol Transcriber {
    func transcribe(audio: [Float],
                    completion: @escaping (TranscriberResult) -> Void)
}
