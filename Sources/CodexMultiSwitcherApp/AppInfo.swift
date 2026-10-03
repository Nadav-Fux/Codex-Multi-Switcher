import Foundation

// MARK: - App Info

enum AppInfo {
    static var isLocalBuild: Bool {
        #if CODEX_MULTI_SWITCHER_LOCAL
            return true
        #else
            return false
        #endif
    }
    static var isPreview: Bool {
        #if CODEX_MULTI_SWITCHER_PREVIEW
            return true
        #else
            return false
        #endif
    }
    static let name = "CodexMultiSwitcher"
    static let version = "0.3.3"
    static let issueURL = URL(string: "https://github.com/Nadav-Fux/codex-multi-switcher/issues/new")!
}
