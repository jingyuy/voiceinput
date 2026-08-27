import SwiftUI
import UIKit

/// The keyboard extension's root controller. Hosts a SwiftUI interface and
/// forwards text insertion / input-mode switching to `textDocumentProxy`.
///
/// The keyboard never touches the microphone — the container app records and
/// transcribes. This controller only coordinates via the App Group.
final class KeyboardViewController: UIInputViewController {

    private var keyboardState: KeyboardState?

    override func viewDidLoad() {
        super.viewDidLoad()

        // CRITICAL: declare a primary language. Without it, UIKit's dictation
        // controller calls `TIGetDefaultDictationLanguagesForKeyboardLanguage(nil)`
        // when this keyboard appears, which throws
        // "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil" and
        // crashes the HOST app (Reminders/Notes/Safari). Any BCP-47 tag works —
        // we recognize US English in the container app.
        primaryLanguage = "en-US"

        let state = KeyboardState(controller: self)
        keyboardState = state

        let hostingController = UIHostingController(rootView: KeyboardRootView(state: state))
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Do NOT reset session state here: viewWillAppear fires for many
        // reasons (host-app switches, keyboard re-presentation), and a live
        // dictation session must survive them.
        keyboardState?.refreshFullAccessStatus()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The keyboard is going away (host app switched, keyboard dismissed,
        // another keyboard selected). Stop recording and discard the session
        // — we never insert text after the keyboard is no longer visible.
        keyboardState?.cancelDictation()
    }

    // MARK: - Actions (called from SwiftUI)

    func insertText(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }

    func switchToNextInputMode() {
        advanceToNextInputMode()
    }
}
