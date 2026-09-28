import AppKit
import SwiftUI

@main
struct TareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TranscriptionStore()

    var body: some Scene {
        WindowGroup("Tare") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 620)
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
        NSApp.activate(ignoringOtherApps: true)
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
