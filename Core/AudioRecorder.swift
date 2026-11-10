import Foundation
import AVFoundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var buffer: [Float] = []

    static let targetSampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?

    func start() throws {}

    func stop() -> [Float] {
        let captured = buffer
        buffer.removeAll()
        return captured
    }
}
