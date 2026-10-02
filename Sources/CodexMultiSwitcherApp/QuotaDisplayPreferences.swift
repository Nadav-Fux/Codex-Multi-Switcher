import SwiftUI

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
