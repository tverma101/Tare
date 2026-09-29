import AppKit
import SwiftUI

@main
struct TareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TranscriptionStore()

    var body: some Scene {
        // A single Window rather than a WindowGroup. The app declares audio and
        // video document types, and a WindowGroup opened one new empty window per
        // file sent to it — opening 40 files from Finder produced 40 windows.
        Window("Tare", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 620)
                // SwiftUI owns the open-files event, so the AppDelegate's
                // application(_:open:) is never delivered and files sent to the
                // app — Finder's Open With, a Dock drop, or
                // `open -a Tare <files>` — used to arrive nowhere. This is the
                // path that actually receives them.
                .onOpenURL { url in
                    store.addFiles([url])
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files...") {
                    store.presentFilePicker()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(store.isRunning || store.isPreparingModel ? "Cancel Batch" : "Start Batch") {
                    if store.isRunning || store.isPreparingModel {
                        store.cancelBatch()
                    } else {
                        store.startBatch()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!store.canStart && !store.isRunning && !store.isPreparingModel)
            }
        }
        Settings {
            SettingsView(store: store)
                .frame(minWidth: 420, idealWidth: 520, minHeight: 480, idealHeight: 640)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Deliberately no NSApp.activate() here. macOS already brings a regular
        // app forward when the user clicks its window or its Dock icon. Calling
        // activate on launch yanked focus away from whatever the user was doing
        // — for example when a Finder Quick Action or a script started Tare, or
        // during an automated build-and-capture run.
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        PendingOpenFiles.shared.append(urls)
        NotificationCenter.default.post(
            name: .tareOpenFiles,
            object: nil,
            userInfo: ["urls": urls]
        )
    }
}

extension Notification.Name {
    static let tareOpenFiles = Notification.Name("tareOpenFiles")
}

final class PendingOpenFiles: @unchecked Sendable {
    static let shared = PendingOpenFiles()

    private let lock = NSLock()
    private var urls: [URL] = []

    private init() {}

    func append(_ newURLs: [URL]) {
        lock.lock()
        urls.append(contentsOf: newURLs)
        lock.unlock()
    }

    func drain() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let drained = urls
        urls.removeAll()
        return drained
    }
}
