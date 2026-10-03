import SwiftUI
import CodexProfileCore

/// Shared by menu rows, settings cards, and the menu-bar image.
enum QuotaDisplayPreferences {
    static let primaryKey = "primaryQuotaShowsUsed"
    static let secondaryKey = "secondaryQuotaShowsUsed"

    static func value(usedPercent: Int, showsUsed: Bool) -> Int {
        let used = min(100, max(0, usedPercent))
        return showsUsed ? used : 100 - used
    }
}

struct QuotaDisplayControlsView: View {
    var showsPrimary = true
    @AppStorage(QuotaDisplayPreferences.primaryKey) private var primaryShowsUsed = false
    @AppStorage(QuotaDisplayPreferences.secondaryKey) private var secondaryShowsUsed = false

    var body: some View {
        HStack(spacing: 8) {
            if self.showsPrimary { self.control("5h", showsUsed: self.$primaryShowsUsed) }
            self.control("week", showsUsed: self.$secondaryShowsUsed)
        }
        .font(.system(size: 10, weight: .medium))
        .help("Choose used or remaining for each window. Colors always indicate how much quota is left.")
    }

    private func control(_ label: String, showsUsed: Binding<Bool>) -> some View {
        Button { showsUsed.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Text("\(label): \(showsUsed.wrappedValue ? "Used" : "Left")")
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .accessibilityLabel("\(label) display")
        .accessibilityValue(showsUsed.wrappedValue ? "Used" : "Remaining")
    }
}

/// Visibility is one choice, so the app always leaves a way to open its menu.
enum MenuBarProviders: String, CaseIterable {
    case codex, claude, both
    static let key = "menuBarProviders"
    var showsCodex: Bool { self != .claude }
    var showsClaude: Bool { self != .codex }
    var label: String {
        switch self {
        case .codex: return "Codex only"
        case .claude: return "Claude Code only"
        case .both: return "Codex and Claude Code"
        }
    }
    static func selection(in defaults: UserDefaults = .standard) -> Self {
        if let value = defaults.string(forKey: self.key), let selected = Self(rawValue: value) { return selected }
        return defaults.object(forKey: "showClaudeInMenuBar") != nil && !defaults.bool(forKey: "showClaudeInMenuBar") ? .codex : .both
    }
    static func set(_ selected: Self, in defaults: UserDefaults = .standard) {
        defaults.set(selected.rawValue, forKey: self.key)
        defaults.set(selected.showsClaude, forKey: "showClaudeInMenuBar")
    }
}

/// Provider selection is extensible; migrate the old three-way choice on first read.
enum ProviderVisibility {
    static let key = "visibleUsageProviders"

    static func selection(in defaults: UserDefaults = .standard) -> [ProviderID] {
        if let stored = defaults.string(forKey: key)?.split(separator: ",").map(String.init) {
            let ids = Set(stored.compactMap(ProviderID.init(rawValue:)))
            if !ids.isEmpty { return ProviderID.allCases.filter { ids.contains($0) } }
        }
        let old = MenuBarProviders.selection(in: defaults)
        return [.codex, .claude].filter { $0 == .codex ? old.showsCodex : old.showsClaude }
    }

    static func set(_ provider: ProviderID, visible: Bool, in defaults: UserDefaults = .standard) {
        var selected = Set(selection(in: defaults))
        if visible { selected.insert(provider) } else { selected.remove(provider) }
        guard !selected.isEmpty else { return }
        defaults.set(ProviderID.allCases.filter { selected.contains($0) }.map(\.rawValue).joined(separator: ","), forKey: key)
    }
}

struct ProviderVisibilityControls: View {
    @AppStorage(ProviderVisibility.key) private var selection = ""

    var body: some View {
        ForEach(ProviderID.allCases, id: \.rawValue) { provider in
            Toggle(provider == .claude ? "Claude Code" : provider.displayName, isOn: Binding(
                get: { _ = selection; return ProviderVisibility.selection().contains(provider) },
                set: { ProviderVisibility.set(provider, visible: $0) }))
            .disabled(ProviderVisibility.selection().count == 1 && ProviderVisibility.selection().contains(provider))
        }
    }
}
