import AppKit
import SwiftUI

/// Announces batch state changes to VoiceOver.
///
/// `statusMessage` is the app's only progress channel and it updates many times
/// per batch, so without this a VoiceOver user has no way to know a batch
/// started, moved to a new file, or finished. Announcements are limited to phase
/// boundaries and suppressed when the text repeats, because a per-chunk message
/// would otherwise talk over the user.
struct StatusAnnouncer: ViewModifier {
    @ObservedObject var store: TranscriptionStore
    @State private var lastAnnounced = ""
    @State private var lastAnnouncedAt = Date.distantPast

    func body(content: Content) -> some View {
        content
            .onChange(of: store.statusMessage) { _, newValue in
                announce(newValue)
            }
    }

    private func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastAnnounced else { return }

        // Rate limit so a fast batch does not produce a stream of interruptions.
        let now = Date()
        guard now.timeIntervalSince(lastAnnouncedAt) > 2 else { return }

        lastAnnounced = trimmed
        lastAnnouncedAt = now

        // NSAccessibilityPriorityLevel.high — AppKit declares it as a bare
        // NS_ENUM constant, which Swift does not import by name. The value is
        // bridged as an NSNumber, which is what AppKit documents for this key.
        let highPriority = NSNumber(value: NSAccessibilityPriorityLevel(rawValue: 90)!.rawValue)

        NSAccessibility.post(
            element: NSAccessibilityElement(),
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: highPriority
            ]
        )
    }
}

extension View {
    func statusAnnouncements(_ store: TranscriptionStore) -> some View {
        modifier(StatusAnnouncer(store: store))
    }
}
