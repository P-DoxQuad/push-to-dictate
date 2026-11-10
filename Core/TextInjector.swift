import Cocoa

final class TextInjector {
    enum Method { case paste, typed }

    var method: Method = .paste

    func insert(_ text: String) {
        switch method {
        case .paste: pasteInsert(text)
        case .typed: typedInsert(text)
        }
    }

    private func pasteInsert(_ text: String) {}
    private func typedInsert(_ text: String) {}
}
