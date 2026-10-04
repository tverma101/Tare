import SwiftUI

/// The sections of Settings. Settings is a page of the one window, not a
/// separate window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case cloud
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .cloud: return "Cloud"
        case .library: return "Library"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .cloud: return "cloud"
        case .library: return "film.stack"
        }
    }
}

/// Which page the window shows.
enum AppPage: Equatable {
    case transcribe
    case settings(SettingsTab)
}
