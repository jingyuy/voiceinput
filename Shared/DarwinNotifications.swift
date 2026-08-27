import Foundation

/// Darwin notification names shared by both processes.
///
/// Darwin notifications are **ping-only** — they carry no payload. All data
/// travels through the App Group suite; a ping just says "something changed,
/// go read it". A ping can wake a suspended app but does NOT launch a killed
/// one (that's what the URL scheme is for).
enum DarwinNotificationName: String {
    case recordingRequested = "com.example.AudioToTextOnMobile.recordingRequested"
    case stopRequested = "com.example.AudioToTextOnMobile.stopRequested"
    case cancelRequested = "com.example.AudioToTextOnMobile.cancelRequested"
    case statusChanged = "com.example.AudioToTextOnMobile.statusChanged"
    case transcriptionReady = "com.example.AudioToTextOnMobile.transcriptionReady"

    var cfName: CFNotificationName {
        CFNotificationName(rawValue as CFString)
    }
}

/// Thin wrapper around the Darwin notification center.
enum DarwinNotifications {
    static func post(_ name: DarwinNotificationName) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name.cfName,
            nil,
            nil,
            true
        )
    }

    /// Registers an observer. **Keep the returned token alive** for the whole
    /// observation — the token's deinit removes the observer.
    /// The handler is delivered on the main queue.
    static func observe(_ name: DarwinNotificationName, handler: @escaping () -> Void) -> DarwinNotificationObserver {
        DarwinNotificationObserver(name: name, handler: handler)
    }
}

final class DarwinNotificationObserver {
    private let name: DarwinNotificationName
    private let handler: () -> Void

    fileprivate init(name: DarwinNotificationName, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, rawObserver, _, _, _ in
                guard let rawObserver else { return }
                let observer = Unmanaged<DarwinNotificationObserver>
                    .fromOpaque(rawObserver).takeUnretainedValue()
                DispatchQueue.main.async {
                    observer.handler()
                }
            },
            name.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            name.cfName,
            nil
        )
    }
}
