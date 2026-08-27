import Foundation

/// Darwin-level cross-process notification. Payload-free ping: the receiver
/// re-reads the shared defaults to learn what changed.
///
/// LIMITATION: Darwin notifications are only delivered to RUNNING processes.
/// A suspended app won't be woken by one — that's why the keyboard falls
/// back to opening the app via the `attotext://` URL when the app isn't
/// running (or is suspended).
enum DarwinNotifications {

    static let name = "com.example.AudioToTextOnMobile.dictation"

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Registers a handler for the dictation ping. Retain the returned
    /// object for the lifetime of the observation; it unregisters itself
    /// on deinit. The handler is dispatched on the main queue.
    static func observe(handler: @escaping () -> Void) -> Observation {
        Observation(name: name, handler: handler)
    }

    final class Observation {
        private let name: CFString
        private let box: HandlerBox

        fileprivate init(name: String, handler: @escaping () -> Void) {
            self.name = name as CFString
            self.box = HandlerBox(handler)
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(box).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let box = Unmanaged<HandlerBox>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async { box.handler() }
                },
                self.name,
                nil,
                .deliverImmediately
            )
        }

        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(box).toOpaque(),
                CFNotificationName(rawValue: name),
                nil
            )
        }
    }

    private final class HandlerBox {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }
}
