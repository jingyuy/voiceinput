# Audio To Text (On-Device)

A dictation **keyboard extension + container app** for iOS. Tap the mic in any
text field, speak, and your words are transcribed **locally on the device** and
inserted into the field — no audio ever leaves the iPhone.

> Everything runs on the device. No audio is ever uploaded.

## Why this architecture exists (the hard-won learnings)

This project started as a plain SwiftUI dictation app, then grew a keyboard
extension. Three architecture attempts preceded the current one — each failed
for a different reason, and the current design exists **because of** those
failures:

1. **A keyboard extension CANNOT record audio.** Verified conclusively on
   iPhone 12 / iOS 26.6.1: `AVAudioEngine`, `AVAudioRecorder`, and
   `AVCaptureSession` all fail at the hardware I/O start
   (`PerformCommand(*ioNode, kAUStartIO…)` → code `2003329396` `'what'`), even
   with Full Access, a granted mic permission, and a perfect 1ch/48 kHz format.
   Three independent audio stacks failing at hardware start = process-level
   denial. Gboard/SwiftKey-style in-keyboard recording is impossible here.

2. **iOS cannot START the microphone while an app is backgrounded.** A
   backgrounded app that tries to initialize the input unit gets
   `NSOSStatusErrorDomain 560557684` (`'!int'`) from `AURemoteIO Initialize` —
   Apple's own log message: *"This problem only occurs if the app is
   backgrounded, else it works fine."* Recording may *continue* in the
   background once started, but it can never *start* there.

3. **A suspended app cannot be woken by Darwin notifications.**
   `CFNotificationCenter` Darwin pings are delivered only to *running*
   processes. The only way a keyboard can wake a dead/suspended container app
   is to cold-launch it via a URL scheme (`attotext://dictate`), which steals
   the foreground.

### The solution: an always-armed microphone

The container app keeps the mic **running continuously**:

- The capture engine starts while the app is **foreground** (scene `.active`,
  init, cold-launch).
- It then runs forever — including in the background (`UIBackgroundModes
  audio`), which also keeps the app process alive.
- A keyboard request (App Group `.requested` + Darwin ping) is adopted **in the
  background** by *starting the recognizer only* — the input unit is never
  re-initialized, so the `'!int'` failure is structurally impossible.
- Tradeoff: an orange microphone indicator stays in the status bar while the
  app is alive, and the mic is "hot" even when you're not dictating.

## How it works

```mermaid
flowchart LR
    KB[Mic tap in keyboard] -->|App Group .requested + token| Shared[Shared store]
    KB -->|Darwin ping| App
    App -->|adopt in background, no re-init| Engine[Armed AVAudioEngine]
    Engine -->|buffers| Req[SFSpeechAudioBufferRecognitionRequest]
    Req -->|on-device model| Task[SFSpeechRecognitionTask]
    Task -->|live text @0.1s| Shared
    Shared -->|poll @0.1s| KB
    KB -->|insert finalText once| Notes[Text field in host app]
```

### Handshake (keyboard ↔ app)

| State | Writer | Meaning |
|---|---|---|
| `.requested` | keyboard | new session with a UUID token |
| `.recording` | app | adopted; streaming `liveText` + `audioLevel` |
| `.transcribing` | app | stop requested; finalizing |
| `.ready` | app | `finalText` published → keyboard inserts once, clears |
| `.failed` | app | `errorMessage` published → keyboard shows it |

Keyboard → app controls: `stopRequested` / `cancelRequested` booleans + Darwin
ping. Heartbeats (`lastActivity`) tell the keyboard the app is alive so it
**never cold-launches** a live app (which would steal the foreground).

### IPC stack

- **App Group** `group.com.example.AudioToTextOnMobile` — `UserDefaults` suite
  shared by both processes (with a local fallback suite if unprovisioned).
- **Darwin notifications** `com.example.AudioToTextOnMobile.dictation` —
  ping-only wakeups (`CFNotificationCenter`, no payload).
- **URL scheme** `attotext://dictate` — the only way to wake a dead app.
- **`UIBackgroundModes: [audio]`** — the armed capture engine keeps the app
  alive in the background.

## Project layout

```
AudioToTextOnMobile/
├── AudioToTextOnMobile/          Container app (owns capture + recognition)
│   ├── App/AudioToTextOnMobileApp.swift    scene phases, onOpenURL, overlay
│   ├── Services/KeyboardDictationCoordinator.swift
│   ├── Views/TranscriptionView.swift       standalone dictation UI
│   └── Views/Components/DictationSessionOverlay.swift
├── AudioToTextKeyboard/          Keyboard extension (UI + IPC only)
│   ├── KeyboardViewController.swift
│   ├── ViewModels/KeyboardState.swift      polling, timeouts, insert-once
│   └── Views/…                             mic button, recording overlay
├── Shared/                       Compiled into BOTH targets
│   ├── AppGroup.swift
│   ├── DarwinNotifications.swift
│   ├── DictationSharedState.swift          the state machine above
│   ├── AudioCaptureService.swift           always-armed AVAudioEngine
│   ├── SpeechRecognitionService.swift      on-device SFSpeechRecognizer
│   └── ObjCExceptionCatcher.*              NSException safety net
└── project.yml                   XcodeGen source of truth (entitlements here!)
```

## Build, install & test

Requires Xcode 26+ (iOS 26 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(2.46+), a signed Apple developer team, and a **physical iPhone** — third-party
keyboards cannot be tested in the simulator (the simulator host apps crash with
a UIKit/TextInput bug unrelated to this project).

```bash
# 1. Generate the Xcode project (entitlements are regenerated FROM project.yml)
xcodegen generate

# 2. Build for the device (UDID from: xcrun devicectl list devices)
xcodebuild -project AudioToTextOnMobile.xcodeproj -scheme AudioToTextOnMobile \
  -destination 'id=<UDID>' -derivedDataPath build build

# 3. Install + launch
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/AudioToTextOnMobile.app
xcrun devicectl device process launch --device <UDID> com.example.AudioToTextOnMobile

# 4. Verify the app group is embedded in BOTH signatures
codesign -d --entitlements :- build/Build/Products/Debug-iphoneos/AudioToTextOnMobile.app
codesign -d --entitlements :- build/Build/Products/Debug-iphoneos/AudioToTextOnMobile.app/PlugIns/AudioToTextKeyboard.appex
```

### On-device setup

1. Settings → General → Keyboard → Keyboards → **Add New Keyboard** → *Audio To
   Text* → toggle **Full Access** ON.
2. **Open the app once** (grant Microphone + Speech if prompted) — this arms
   the mic. The orange mic indicator is expected.
3. Background the app (home button).
4. In Notes (or any field), tap the mic in the keyboard → stay in Notes,
   "Listening…" with live text → tap **stop** → text is inserted.

> After reinstalling the keyboard, **remove and re-add** it in Settings —
> LaunchServices caches `NSExtensionAttributes`.

### Known limitation

If the container app is **force-quit**, the next mic tap cold-launches it once
(a dead process cannot record and cannot be woken in the background). It stays
armed afterwards.

## Gotchas worth remembering

- **`xcodegen generate` TRUNCATES `.entitlements` files to empty `<dict/>` on
  every run** — silently. The build succeeds but the app installs *without*
  the App Group (no shared container → "app isn't installed"). Fix: declare the
  entitlement content in `project.yml` (`entitlements.properties`), and verify
  with `codesign -d --entitlements :-` after every rebuild.
- `CFNotificationCenterAddObserver` takes a `CFString` name but
  `CFNotificationCenterRemoveObserver` takes a `CFNotificationName` — not
  symmetric.
- Swift `do/catch` cannot catch Objective-C `NSException`s — AVFoundation calls
  must run inside an `ObjCExceptionCatcher` wrapper in the keyboard process.
- The on-device recognizer finalizes slowly; publish the live transcript
  promptly (~3s) rather than racing a long timeout, and never use short
  matching timeouts in two processes sharing a finish boundary.
- `UIInputViewController.requestOpenAccess` was removed in iOS 26.5 — Full
  Access is enabled purely in Settings.
- `PrimaryLanguage` must be declared in `NSExtension → NSExtensionAttributes`
  in the keyboard Info.plist or the host app crashes
  (`TIGetDefaultDictationLanguagesForKeyboardLanguage(nil)`).

## Privacy

- Mic + speech permission descriptions configured in `project.yml`.
- Recognition locale: `en-US` (`SpeechRecognitionService(locale:)`).
- All recognition is on-device; the always-armed mic is the privacy cost of
  instant background dictation.

## Roadmap

- Locale picker for multilingual on-device recognition
- Punctuation/capitalization post-processing with Natural Language
- Replace the always-armed mic with a configurable opt-in
- Swap the recognizer for a custom on-device model (e.g. WhisperKit) behind the
  same `SpeechRecognitionService` interface
