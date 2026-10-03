import Cocoa
import CodexProfileCore
import SwiftUI

func resetCountdown(from date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let remaining = date.timeIntervalSince(now)
    guard remaining.isFinite, remaining > 0 else { return "" }
    // Beyond a year, an exact day count adds little and can overflow Int for bad timestamps.
    if remaining > 365 * 24 * 60 * 60 { return ">365d" }
    let diff = Int(remaining)
    let days = diff / 86400
    let hours = (diff % 86400) / 3600
    let mins = (diff % 3600) / 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(mins)m" }
    return "\(mins)m"
}

enum Palette {
    static let accent = Color(red: 0.40, green: 0.55, blue: 0.75)
    static let accentLight = Color(red: 0.45, green: 0.58, blue: 0.72)
    static let success = Color(red: 0.40, green: 0.60, blue: 0.55)
    static let warning = Color(red: 0.75, green: 0.55, blue: 0.30)
    static let danger = Color(red: 0.75, green: 0.38, blue: 0.35)
    static let resetRose = Color(red: 0.66, green: 0.43, blue: 0.49)
    static let mid = Color(red: 0.70, green: 0.55, blue: 0.35)
}

enum ResetCountdownColor {
    static func color(for resetAt: Date?, now: Date = Date(), isStale: Bool = false) -> Color {
        guard !isStale, let resetAt else { return .secondary }
        let remaining = resetAt.timeIntervalSince(now)
        guard remaining > 0 else { return .secondary }
        if remaining <= 60 * 60 { return Palette.success }
        if remaining <= 5 * 60 * 60 { return Palette.warning }
        // Long windows such as weekly quotas read better as neutral metadata.
        if remaining > 24 * 60 * 60 { return .secondary }
        return Palette.resetRose
    }
}

func remainingQuotaPercent(for usedPercent: Int) -> Int {
    100 - min(100, max(0, usedPercent))
}

func remainingQuotaColor(for remainingPercent: Int) -> Color {
    if remainingPercent < 20 { return Palette.danger }
    if remainingPercent < 50 { return Palette.warning }
    return Palette.success
}

func usageWindowLabel(durationMins: Int?, legacyLabel: String) -> String {
    guard let durationMins, durationMins > 0 else { return legacyLabel }
    if durationMins == 7 * 24 * 60 { return "Wk" }
    if durationMins % (24 * 60) == 0 { return "\(durationMins / (24 * 60))d" }
    if durationMins % 60 == 0 { return "\(durationMins / 60)h" }
    return "\(durationMins)m"
}

func planDisplayName(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "" }
    switch raw {
    case "pro", "prolite": return "Pro"
    case "plus": return "Plus"
    case "team": return "Team"
    case "business": return "Business"
    case "enterprise": return "Enterprise"
    case "free": return "Free"
    case "edu", "education": return "Edu"
    default: return raw.capitalized
    }
}

func updatedLabel(from date: Date, now: Date = Date()) -> String {
    let age = max(0, Int(now.timeIntervalSince(date)))
    if age < 60 { return "Updated \(age)s ago" }

    let minutes = age / 60
    if minutes < 60 { return "Updated \(minutes)m ago" }

    let hours = minutes / 60
    if hours < 24 { return "Updated \(hours)h ago" }

    return "Updated \(hours / 24)d ago"
}

func creditsDisplayName(_ value: Double?) -> String? {
    guard let value else { return nil }
    let clamped = max(0, value)
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = clamped >= 100 ? 0 : 1
    formatter.minimumFractionDigits = 0
    guard let formatted = formatter.string(from: NSNumber(value: clamped)) else { return nil }
    return "\(formatted) cr"
}

// MARK: - Toast

enum ToastStyle { case success, error, info }

final class ToastState: ObservableObject {
    @Published var message: String = ""
    @Published var style: ToastStyle = .success
    @Published var isVisible: Bool = false
    private var hideTask: DispatchWorkItem?

    func show(_ message: String, style: ToastStyle = .success) {
        self.hideTask?.cancel()
        self.message = message
        self.style = style
        withAnimation(.easeOut(duration: 0.2)) { self.isVisible = true }
        let item = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.isVisible = false }
        }
        self.hideTask = item
        let duration = style == .error ? 7.0 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }
}

struct ToastOverlay: View {
    @ObservedObject var state: ToastState

    var body: some View {
        if self.state.isVisible {
            VStack {
                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: self.iconName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(self.state.message)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundStyle(self.foregroundColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(self.borderColor, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            }
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var iconName: String {
        switch self.state.style {
        case .success: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var foregroundColor: Color {
        switch self.state.style {
        case .success: Palette.success
        case .error: Palette.danger
        case .info: Palette.accent
        }
    }

    private var borderColor: Color {
        switch self.state.style {
        case .success: Palette.success.opacity(0.3)
        case .error: Palette.danger.opacity(0.3)
        case .info: Palette.accent.opacity(0.3)
        }
    }
}

// MARK: - SwiftUI Views (progress bar adapted from codexbar)

struct UsageBar: View {
    let percent: Double
    let tint: Color

    private static let markerPercents: [Double] = [25, 50, 75]

    var body: some View {
        Canvas { context, size in
            let fillWidth = size.width * min(100, max(0, self.percent)) / 100
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            let trackPath = Path { p in p.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(.primary.opacity(0.10)))

            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { p in p.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fillPath, with: .color(self.tint))
            }

            let markerWidth: CGFloat = 1.5
            for markerPct in Self.markerPercents {
                let x = size.width * markerPct / 100
                let markerRect = CGRect(x: x - markerWidth / 2, y: 0, width: markerWidth, height: size.height)
                context.fill(Path(markerRect), with: .color(.primary.opacity(0.3)))
            }
        }
        .frame(height: 6)
    }
}

struct UsageRow: View {
    let label: String
    let usedPercent: Int
    let resetAt: Date?
    let isHighlighted: Bool
    let showsUsed: Bool
    var cached = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let showsCached = self.cached || self.resetAt.map { $0 <= now } == true
            let quotaColor = self.quotaColor(at: now)
            HStack(spacing: 4) {
                Text(self.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(self.isHighlighted ? .primary : .secondary)
                    .frame(width: 24, alignment: .leading)

                UsageBar(percent: Double(self.displayPercent), tint: quotaColor)

                Text("\(showsCached ? "Cached " : "")\(self.displayPercent)% \(self.showsUsed ? "used" : "left")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(quotaColor)
                    .frame(width: showsCached ? 108 : 62, alignment: .trailing)

                Text(resetCountdown(from: self.resetAt, now: now))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ResetCountdownColor.color(for: self.resetAt, now: now, isStale: self.cached))
                    .frame(width: 42, alignment: .trailing)
                    .help(self.resetAt.map { "Quota resets \($0.formatted(date: .complete, time: .shortened))" } ?? "Reset time unavailable")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(showsCached ? "Cached " : "")\(self.label) quota: \(self.displayPercent) percent \(self.showsUsed ? "used" : "remaining")")
            .accessibilityValue(self.resetAt.map { "Resets \($0.formatted(date: .complete, time: .shortened))" } ?? "Reset time unavailable")
        }
    }

    private var displayPercent: Int {
        QuotaDisplayPreferences.value(usedPercent: self.usedPercent, showsUsed: self.showsUsed)
    }

    private var remainingPercent: Int {
        remainingQuotaPercent(for: self.usedPercent)
    }

    private func quotaColor(at now: Date) -> Color {
        let showsCached = self.cached || self.resetAt.map { $0 <= now } == true
        return showsCached ? .secondary : remainingQuotaColor(for: self.remainingPercent)
    }
}

struct BankedResetSummaryView: View {
    let snapshot: UsageSnapshot

    private static let maximumVisibleExpirations = 4
    private static let lineHeight: CGFloat = 14

    /// Include the spacing above the summary when sizing the menu's NSHostingView.
    static func extraHeight(for snapshot: UsageSnapshot?) -> CGFloat {
        guard let snapshot, snapshot.bankedResetCount != nil else { return 0 }
        return Self.contentHeight(for: snapshot) + 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise.circle")
                Text("\(self.count) banked reset\(self.count == 1 ? "" : "s")")
                Spacer(minLength: 4)
                if !self.visibleExpirations.isEmpty {
                    Text("Expires · local time")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(self.count > 0 ? Palette.accent : Color.secondary)
            .frame(height: Self.lineHeight)

            ForEach(Array(self.visibleExpirations.enumerated()), id: \.offset) { index, expiry in
                HStack(spacing: 5) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                    Text(expiry.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "No expiry")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let expiry {
                        Text(expiry > Date() ? resetCountdown(from: expiry) : "Expired")
                            .foregroundStyle(Self.expirationColor(for: expiry))
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .frame(height: Self.lineHeight)
                .help(expiry.map { "Banked reset expires \($0.formatted(date: .complete, time: .shortened))" } ?? "This banked reset has no expiration date")
            }

            if let note = Self.detailNote(for: self.snapshot) {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: Self.lineHeight, alignment: .leading)
            }
        }
        .frame(height: Self.contentHeight(for: self.snapshot), alignment: .topLeading)
    }

    private var count: Int { max(0, self.snapshot.bankedResetCount ?? 0) }

    private var visibleExpirations: [Date?] {
        Array(Self.sortedExpirations(for: self.snapshot).prefix(Self.maximumVisibleExpirations))
    }

    private static func sortedExpirations(for snapshot: UsageSnapshot) -> [Date?] {
        (snapshot.bankedResetExpirations ?? []).sorted {
            ($0 ?? .distantFuture) < ($1 ?? .distantFuture)
        }
    }

    private static func detailNote(for snapshot: UsageSnapshot) -> String? {
        let count = max(0, snapshot.bankedResetCount ?? 0)
        let detailsCount = snapshot.bankedResetExpirations?.count ?? 0
        if detailsCount > Self.maximumVisibleExpirations {
            return "+\(detailsCount - Self.maximumVisibleExpirations) more dates in Settings"
        }
        if detailsCount < count {
            return detailsCount == 0 ? "Expiry dates unavailable" : "\(count - detailsCount) expiry date\(count - detailsCount == 1 ? "" : "s") unavailable"
        }
        return nil
    }

    private static func contentHeight(for snapshot: UsageSnapshot) -> CGFloat {
        let rows = min(Self.maximumVisibleExpirations, snapshot.bankedResetExpirations?.count ?? 0)
        let noteRows = Self.detailNote(for: snapshot) == nil ? 0 : 1
        return CGFloat(1 + rows + noteRows) * Self.lineHeight
    }

    private static func expirationColor(for expiry: Date) -> Color {
        let secondsRemaining = expiry.timeIntervalSinceNow
        if secondsRemaining < 24 * 3600 { return Palette.danger }
        if secondsRemaining < 72 * 3600 { return Palette.warning }
        return .secondary
    }
}

struct UsageHeaderView: View {
    let isRefreshing: Bool
    let updatedAt: Date?
    let failingProfiles: Int
    let trackedProfiles: Int
    var showsPrimaryControl = true
    var updateSubject = "Latest account"
    var showsTitle = true

    static let baseHeight: CGFloat = 68
    static let failureHeight: CGFloat = 83

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if self.showsTitle {
                Text("Codex")
                    .font(.system(size: 12, weight: .semibold))
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(self.statusLabel(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(self.statusLabel(now: context.date))
            }

            QuotaDisplayControlsView(showsPrimary: self.showsPrimaryControl)
                .padding(.top, 3)

            if self.showsFailure {
                Label(self.failureLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 290, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    var showsFailure: Bool {
        !self.isRefreshing && self.failingProfiles > 0
    }

    private func statusLabel(now: Date) -> String {
        let age = self.updatedAt.map { updatedLabel(from: $0, now: now) } ?? "No usage data"
        return "\(self.updateSubject) · \(age)" + (self.isRefreshing ? " · Refreshing…" : "")
    }

    private var failureLabel: String {
        if self.failingProfiles == self.trackedProfiles {
            return "Refresh failing - numbers are out of date"
        }
        return "Refresh failing for \(self.failingProfiles) of \(self.trackedProfiles)"
    }
}

struct ProviderSectionHeaderView: View {
    static let height: CGFloat = 32

    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: self.onToggle) {
            HStack(spacing: 7) {
                Text(self.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: self.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint(self.isCollapsed ? "Expand section" : "Collapse section")
    }
}

struct ProfileCardView: View {
    let profile: ProfileConfig
    let status: ProfileStatus
    let isActive: Bool
    let duplicateLine: String?
    let onSwitch: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @AppStorage(QuotaDisplayPreferences.primaryKey) private var primaryShowsUsed = false
    @AppStorage(QuotaDisplayPreferences.secondaryKey) private var secondaryShowsUsed = false

    var body: some View {
        Button(action: self.onSwitch) {
            VStack(alignment: .leading, spacing: 3) {
                self.headerRow
                if let duplicateLine, !duplicateLine.isEmpty {
                    Label(duplicateLine, systemImage: "square.stack.3d.up.trianglebadge.exclamationmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.warning)
                        .lineLimit(1)
                }
                self.statusContent
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 290, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(ProfileCardButtonStyle(
            isActive: self.isActive,
            isHovered: self.isHovered,
            colorScheme: self.colorScheme))
        .onHover { hovering in
            self.isHovered = hovering
        }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.isHovered)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if self.isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel("Active profile")
            }
            Text(self.profile.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(self.titleColor)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 5) {
                if let credits = self.credits {
                    Text(credits)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(self.metadataColor)
                }

                if let planName = self.planType {
                    Text(planName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(self.metadataColor)
                }
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch self.status {
        case .available(let snap):
            self.usageBars(snap, cached: UsageFreshness.isCached(fetchedAt: snap.fetchedAt, isActive: self.isActive))
        case .loading:
            Text("No data yet")
                .font(.system(size: 10))
                .foregroundStyle(self.metadataColor)
        case .stale(let snap):
            if let snap {
                self.usageBars(snap, cached: true)
            } else {
                Text("No data yet")
                    .font(.system(size: 10))
                    .foregroundStyle(self.metadataColor)
            }
        case .reloginNeeded(let snap):
            if let snap { self.usageBars(snap, cached: true) }
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("Re-login needed")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Palette.warning)
        case .notSetUp:
            Text("Click to set up")
                .font(.system(size: 10))
                .foregroundStyle(Palette.accentLight)
        }
    }

    private func usageBars(_ snap: UsageSnapshot, cached: Bool = false) -> some View {
        VStack(spacing: 2) {
            if snap.hasPrimaryWindow {
                UsageRow(
                    label: usageWindowLabel(
                        durationMins: snap.primaryWindowDurationMins,
                        legacyLabel: "5h"),
                    usedPercent: snap.primaryUsedPercent,
                    resetAt: snap.primaryResetAt,
                    isHighlighted: self.isActive || self.isHovered,
                    showsUsed: self.primaryShowsUsed, cached: cached)
            }
            if snap.hasSecondaryWindow {
                UsageRow(
                    label: usageWindowLabel(
                        durationMins: snap.secondaryWindowDurationMins,
                        legacyLabel: "Wk"),
                    usedPercent: snap.secondaryUsedPercent,
                    resetAt: snap.secondaryResetAt,
                    isHighlighted: self.isActive || self.isHovered,
                    showsUsed: self.secondaryShowsUsed, cached: cached)
            }
            if snap.bankedResetCount != nil {
                BankedResetSummaryView(snapshot: snap)
            }
        }
        .help(cached ? "Cached observation from \(snap.fetchedAt.formatted(date: .abbreviated, time: .shortened)). Refresh to confirm current quota." : "Quota reported by Codex at \(snap.fetchedAt.formatted(date: .abbreviated, time: .standard))")
    }

    private var planType: String? {
        guard let snap = self.status.snapshot else { return nil }
        return planDisplayName(snap.planType)
    }

    private var credits: String? {
        guard let snap = self.status.snapshot else { return nil }
        return creditsDisplayName(snap.creditsRemaining)
    }

    private var titleColor: Color {
        let base = Color(nsColor: .labelColor)
        return self.isActive || self.isHovered ? base : base.opacity(0.94)
    }

    private var metadataColor: Color {
        let base = Color(nsColor: .secondaryLabelColor)
        return self.isActive || self.isHovered ? base : base.opacity(0.82)
    }
}

private struct ProfileCardButtonStyle: ButtonStyle {
    let isActive: Bool
    let isHovered: Bool
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        let visualState = ProfileCardVisualState(
            isActive: self.isActive,
            isHovered: self.isHovered,
            isPressed: configuration.isPressed,
            colorScheme: self.colorScheme)

        return configuration.label
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(visualState.fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(visualState.borderColor, lineWidth: visualState.borderWidth)
            }
    }
}

private struct ProfileCardVisualState {
    let isActive: Bool
    let isHovered: Bool
    let isPressed: Bool
    let colorScheme: ColorScheme

    var fillColor: Color {
        if self.isPressed {
            return self.neutralWash(dark: 0.14, light: 0.10)
        }
        if self.isActive && self.isHovered {
            return self.neutralWash(dark: 0.13, light: 0.085)
        }
        if self.isActive {
            return self.accentedWash(dark: 0.085, light: 0.055)
        }
        if self.isHovered {
            return self.neutralWash(dark: 0.085, light: 0.055)
        }
        return .clear
    }

    var borderColor: Color {
        if self.isPressed {
            return Palette.accent.opacity(self.colorScheme == .dark ? 0.26 : 0.22)
        }
        if self.isActive {
            return Palette.accent.opacity(self.colorScheme == .dark ? 0.22 : 0.18)
        }
        if self.isHovered {
            return Color.primary.opacity(self.colorScheme == .dark ? 0.12 : 0.08)
        }
        return .clear
    }

    var borderWidth: CGFloat {
        (self.isActive || self.isHovered || self.isPressed) ? 1 : 0
    }

    private func neutralWash(dark: Double, light: Double) -> Color {
        Color.primary.opacity(self.colorScheme == .dark ? dark : light)
    }

    private func accentedWash(dark: Double, light: Double) -> Color {
        Palette.accent.opacity(self.colorScheme == .dark ? dark : light)
    }
}

// MARK: - Menu Bar Icon

/// Cached credentials/refresh failures must not present historical quota as current.
extension ProfileStatus {
    var usageIsCached: Bool {
        if case .available = self { return false }
        return true
    }
}
