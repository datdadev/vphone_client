import SwiftUI
import UIKit

/// Brings up the real iOS keyboard and forwards each keystroke to the guest.
///
/// Implemented with `UIKeyInput` on an otherwise empty view rather than a
/// UITextField: there's no local text to edit here — every keypress belongs to
/// the guest — so a text field would just create a second, out-of-sync copy of
/// the text and fight the guest over autocorrect and selection.
final class KeyboardInputUIView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onDismiss: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onBackspace?()
    }

    // Typing into someone else's screen: local correction would be guesswork.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onDismiss?()
        return result
    }
}

struct KeyboardInput: UIViewRepresentable {
    @Binding var isActive: Bool
    let connection: ConnectionManager

    func makeUIView(context: Context) -> KeyboardInputUIView {
        let view = KeyboardInputUIView()
        view.onText = { connection.typeText($0) }
        view.onBackspace = { connection.typeBackspace() }
        view.onDismiss = {
            DispatchQueue.main.async { isActive = false }
        }
        return view
    }

    func updateUIView(_ uiView: KeyboardInputUIView, context: Context) {
        if isActive, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isActive, uiView.isFirstResponder {
            _ = uiView.resignFirstResponder()
        }
    }
}
