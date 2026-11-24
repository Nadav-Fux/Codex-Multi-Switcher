import CodexProfileCore
import SwiftUI

/// Claude preferences deliberately have their own storage keys.
private enum ClaudeQuotaPreferences {
    static let fiveHourKey = "claudePrimaryQuotaShowsUsed"
    static let weekKey = "claudeSecondaryQuotaShowsUsed"
    static let modelWeekKey = "claudeModelWeeklyQuotaShowsUsed"
}

private struct ClaudeQuotaControls: View {
    var showsModelWeek = false
    @AppStorage(ClaudeQuotaPreferences.fiveHourKey) private var fiveHourShowsUsed = false
    @AppStorage(ClaudeQuotaPreferences.weekKey) private var weekShowsUsed = false
    @AppStorage(ClaudeQuotaPreferences.modelWeekKey) private var modelWeekShowsUsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                control("5h", value: $fiveHourShowsUsed)
                control("week", value: $weekShowsUsed)
            }
            if showsModelWeek { control("model week", value: $modelWeekShowsUsed) }
        }
        .font(.system(size: 10, weight: .medium))
        .help("Claude display preferences. Colors indicate remaining quota for fresh observations matching the current account; cached or unverified values are gray.")
    }

    private func control(_ label: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Text("\(label): \(value.wrappedValue ? "Used" : "Left")")
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 8))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .accessibilityLabel("Claude \(label) display")
        .accessibilityValue(value.wrappedValue ? "Used" : "Remaining")
    }
}

struct ClaudeProfilesTab: View {
    @ObservedObject var store: ClaudeProfileStore
    @ObservedObject var toast: ToastState
    @AppStorage(ProviderVisibility.key) private var menuBarProviders = ""
    @AppStorage("showClaudeInMenuBar") private var legacyShowClaude = true
    @State private var detailID: String?
    @State private var label = ""
    @State private var editingID: String?
    @State private var pendingRemoval: String?
    @FocusState private var labelFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if let profile = store.profiles.first(where: { $0.id == detailID }) {
                detail(profile)
            } else {
                Text("Choose a Claude account")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            detailID = store.selectedID
            syncLabel()
        }
        .onChange(of: detailID) { _, _ in commitLabel(); syncLabel() }
        .onDisappear { commitLabel() }
        .onChange(of: store.error) { _, error in
            if let error { toast.show(error, style: .error) }
        }
        .alert("Remove Claude profile?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let id = pendingRemoval {
                    perform("Profile removed") { store.removeProfile(id: id) }
                    detailID = store.selectedID
                }
                pendingRemoval = nil
            }
        } message: {
            Text("Remove this profile from the switcher. Existing Claude sessions continue running.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $detailID) {
                Section("Claude accounts") {
                    ForEach(store.profiles) { profile in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(profile.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if profile.id == store.selectedID {
                                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                                }
                            }
                            Text(claudeAccountLabel(store.statuses[profile.id]))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        .tag(profile.id)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button {
                    commitLabel()
                    perform("Claude profile added") { store.addProfile(label: "Claude account") }
                    if store.error == nil { store.refresh() }
                    detailID = store.selectedID
                    syncLabel()
                } label: { Image(systemName: "plus") }
                .help("Add a separate Claude account directory")
                .accessibilityLabel("Add Claude account")
                .disabled(store.isRefreshing)
                Button { pendingRemoval = detailID } label: { Image(systemName: "minus") }
                    .disabled(store.profiles.first(where: { $0.id == detailID })?.isDefault != false)
                    .accessibilityLabel("Remove Claude profile")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 200)
    }

    private func detail(_ profile: ClaudeProfile) -> some View {
        let status = store.statuses[profile.id]
        let state = store.connectionState(profile)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Claude Code").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Refresh") { store.refresh(force: true) }
                        .disabled(store.isRefreshing || store.isAuthorizingCredential)
                }
                Toggle("Show in menu bar", isOn: Binding(
                    get: {
                        _ = self.menuBarProviders
                        _ = self.legacyShowClaude
                        return ProviderVisibility.selection().contains(.claude)
                    },
                    set: { show in
                        ProviderVisibility.set(.claude, visible: show)
                    }))
                ClaudeConnectionBanner(state: state, authorizing: store.isAuthorizingCredential,
                                       onConnect: { store.connectNativeAccount(id: profile.id) },
                                       onSignIn: {
                                           beginAction("Opening Claude sign-in in a new terminal…") { store.signIn(id: profile.id) }
                                       })
                VStack(alignment: .leading, spacing: 3) {
                    Text(claudeAccountLabel(status)).font(.system(size: 13, weight: .medium))
                    if let subscription = status?.auth?.subscription, !subscription.isEmpty {
                        Text(subscription.capitalized).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let organization = status?.auth?.organization, !organization.isEmpty {
                        Text(organization).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ClaudeQuotaControls(showsModelWeek: status?.usage?.modelWeekly != nil)
                ClaudeUsageDetail(snapshot: status?.usage)
                if let resets = status?.usage?.resets {
                    ClaudeLimitResetsView(resets: resets)
                }
                if let error = store.error, error != status?.error, state.isHealthy {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Palette.warning).textSelection(.enabled)
                }
                Divider()
                Text("NEW SESSIONS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("The selected account is used by new Claude terminal sessions. Running sessions keep their account.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(profile.id == store.selectedID ? "Selected for new sessions" : "Use for New Sessions") {
                        perform("Claude account selected for new sessions") { store.select(id: profile.id) }
                    }
                    .disabled(profile.id == store.selectedID)
                    Button("Open New Session") {
                        beginAction("Opening a new Claude terminal session…") { store.openSession(id: profile.id) }
                    }
                }
                .disabled(status?.busy == true)
                HStack {
                    Text("Label:").foregroundStyle(.secondary)
                    TextField("Account label", text: $label)
                        .textFieldStyle(.roundedBorder)
                        .focused($labelFocused)
                        .onSubmit { commitLabel() }
                        .onChange(of: labelFocused) { _, focused in if !focused { commitLabel() } }
                }
                .font(.system(size: 13))
                DisclosureGroup("Advanced") {
                    advanced(profile, status: status)
                        .padding(.top, 8)
                }
                .font(.system(size: 12))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func advanced(_ profile: ClaudeProfile, status: ClaudeProfileStatus?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(profile.isDefault ? "Default Claude directory" : "Separate Claude directory")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(profile.configDirectory).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Sign In Again…") {
                    beginAction("Opening Claude sign-in in a new terminal…") { store.signIn(id: profile.id) }
                }
                if store.supportsNativeUsage(profile) {
                    Button(store.isAuthorizingCredential ? "Waiting for macOS permission…" : "Reconnect Usage Access…") {
                        store.connectNativeAccount(id: profile.id)
                    }
                    .disabled(store.isRefreshing || store.isAuthorizingCredential)
                }
            }
            .disabled(status?.busy == true)
            Text(store.supportsNativeUsage(profile)
                 ? "Usage for this account is read directly from Claude in the background. Reconnect is only needed if macOS stops allowing it."
                 : "Usage for this account is recorded by Claude sessions opened with it (through its statusline). It is set up automatically after sign-in.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(status?.bridgeInstalled == true ? "Reinstall Session Recorder" : "Install Session Recorder") {
                    beginAction("Installing Claude usage recorder…") { store.installBridge(id: profile.id) }
                }
                if status?.bridgeInstalled == true {
                    Button("Remove Session Recorder") {
                        perform("Original Claude statusline restored") { store.restoreBridge(id: profile.id) }
                    }
                }
            }
            .disabled(status?.busy == true)
            Text("The session recorder adds a small step to this account's Claude statusline and keeps your existing statusline output. "
                 + (store.supportsNativeUsage(profile) ? "It is optional for this account." : "It is required for usage of this account."))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            if let snapshot = status?.usage {
                Text("\(claudeSourceLabel(snapshot)) · observed \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let next = store.nextUsageRefresh[profile.id], next > Date() {
                Text("Next automatic check at \(next.formatted(date: .omitted, time: .shortened)).")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func syncLabel() {
        editingID = detailID
        label = store.profiles.first(where: { $0.id == detailID })?.label ?? ""
    }

    private func commitLabel() {
        guard let id = editingID, let profile = store.profiles.first(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.label else { return }
        perform("Label saved") { store.renameProfile(id: id, label: trimmed) }
    }

    private func beginAction(_ message: String, action: () -> Void) {
        action()
        if let error = store.error { toast.show(error, style: .error) }
        else { toast.show(message, style: .info) }
    }

    private func perform(_ message: String, action: () -> Void) {
        action()
        if let error = store.error { toast.show(error, style: .error) }
        else { toast.show(message) }
    }
}

private func claudeAccountLabel(_ status: ClaudeProfileStatus?) -> String {
    if let email = status?.auth?.email, !email.isEmpty { return email }
    if status?.busy == true { return "Checking account…" }
    switch status?.auth?.loggedIn {
    case true: return "Signed in"
    case false: return "Sign-in needed"
    default: return "Account status unavailable"
    }
}

/// Limit resets Claude granted this account, like Codex's banked resets.
/// Shown only: spending one stays a deliberate step in Claude Code.
private struct ClaudeLimitResetsView: View {
    let resets: [ClaudeLimitReset]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIMIT RESETS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            let shown = resets.filter { $0.left > 0 || $0.usableNow }
            if shown.isEmpty {
                Text("Claude does not report limit resets to Claude Code for this account yet. The Claude app may still list them under Settings › Usage, where they can be used.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(shown) { reset in
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(reset.kind))
                            .foregroundStyle(reset.paused ? Color.secondary : Palette.success)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(reset)).font(.system(size: 12, weight: .medium))
                            Text(Self.detail(reset)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(reset.left) left").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                }
                Text("Use one in Claude Code with /limit-reset. This app only shows them and never uses one.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    static func title(_ reset: ClaudeLimitReset) -> String {
        switch reset.kind {
        case .full: return "Full reset (5-hour and weekly)"
        case .weekly: return "Weekly reset"
        case .session: return "5-hour reset"
        case .fable: return "Fable reset"
        }
    }

    static func detail(_ reset: ClaudeLimitReset) -> String {
        var parts: [String] = []
        switch reset.kind {
        case .fable: parts.append("gives back only what Fable used this week")
        case .full: parts.append("refills every limit")
        case .weekly: parts.append("refills the weekly limit")
        case .session: parts.append("refills the 5-hour limit")
        }
        if let endsAt = reset.endsAt { parts.append("use by \(endsAt.formatted(date: .abbreviated, time: .shortened))") }
        if reset.paused { parts.append("paused") }
        return parts.joined(separator: " · ")
    }

    static func symbol(_ kind: ClaudeLimitReset.Kind) -> String {
        switch kind {
        case .full: return "arrow.counterclockwise.circle.fill"
        case .weekly: return "calendar.circle.fill"
        case .session: return "clock.arrow.circlepath"
        case .fable: return "sparkles"
        }
    }
}

private struct ClaudeConnectionBanner: View {
    let state: ClaudeConnectionState
    let authorizing: Bool
    let onConnect: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                switch state {
                case .needsApproval:
                    Button(authorizing ? "Waiting for macOS permission…" : "Connect Claude…", action: onConnect)
                        .buttonStyle(.borderedProminent).disabled(authorizing).padding(.top, 2)
                case .needsSignIn:
                    Button("Sign In…", action: onSignIn).buttonStyle(.borderedProminent).padding(.top, 2)
                default: EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35)))
    }

    private var tint: Color {
        switch state {
        case .connected: return Palette.success
        case .checking: return .secondary
        case .needsSignIn, .needsApproval: return Palette.warning
        case .problem: return Palette.danger
        }
    }

    private var icon: String {
        switch state {
        case .connected: return "checkmark.circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .needsSignIn: return "person.crop.circle.badge.exclamationmark"
        case .needsApproval: return "lock.circle"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch state {
        case .connected: return "Connected"
        case .checking: return "Checking Claude…"
        case .needsSignIn: return "Sign in to this Claude account"
        case .needsApproval: return "One-time approval needed"
        case .problem: return "Usage could not be read"
        }
    }

    private var detail: String? {
        switch state {
        case .connected(let how): return how
        case .checking: return nil
        case .needsSignIn: return "Opens Claude sign-in in Terminal. Usage starts updating automatically afterwards."
        case .needsApproval: return "macOS needs your OK once so usage can update in the background. Choose Always Allow when it asks."
        case .problem(let message): return message
        }
    }
}

private func claudeSourceLabel(_ snapshot: ClaudeUsageSnapshot) -> String {
    switch snapshot.source {
    case .oauthUsage:
        return snapshot.accountVerified ? "Claude account usage · account matched" : "Claude account usage · account unverified"
    case .legacyStatusline: return "Legacy statusline cache · account unverified"
    case .nativeBridge:
        return snapshot.accountVerified ? "Claude bridge · account matched" : "Claude bridge · account unverified"
    }
}

private func claudeUsageIsCached(_ snapshot: ClaudeUsageSnapshot?, window: ClaudeUsageWindow? = nil,
                                now: Date = Date()) -> Bool {
    guard let snapshot else { return false }
    return snapshot.isStale || !snapshot.accountVerified || (window?.resetsAt.map { $0 <= now } ?? false)
}

private func claudeFreshnessLabel(_ snapshot: ClaudeUsageSnapshot) -> String {
    if !snapshot.isStale && snapshot.accountVerified { return updatedLabel(from: snapshot.observedAt) }
    return "Last known values · \(updatedLabel(from: snapshot.observedAt))"
}

private struct ClaudeUsageDetail: View {
    let snapshot: ClaudeUsageSnapshot?
    @AppStorage(ClaudeQuotaPreferences.fiveHourKey) private var fiveHourShowsUsed = false
    @AppStorage(ClaudeQuotaPreferences.weekKey) private var weekShowsUsed = false
    @AppStorage(ClaudeQuotaPreferences.modelWeekKey) private var modelWeekShowsUsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            window("5 hour", value: snapshot?.fiveHour, showsUsed: fiveHourShowsUsed)
            window("Weekly", value: snapshot?.sevenDay, showsUsed: weekShowsUsed)
            if let modelWeekly = snapshot?.modelWeekly {
                window("Model weekly", value: modelWeekly, showsUsed: modelWeekShowsUsed)
            }
            if let snapshot {
                Text(claudeFreshnessLabel(snapshot)).font(.system(size: 11))
                    .foregroundStyle(claudeUsageIsCached(snapshot) ? Palette.warning : Color.secondary)
                    .help("\(claudeSourceLabel(snapshot)) · observed \(snapshot.observedAt.formatted(date: .complete, time: .standard))")
            } else {
                Text("No usage yet. It appears after the first successful check.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func window(_ label: String, value: ClaudeUsageWindow?, showsUsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(value.map { claudePercent($0.usedPercentage, showsUsed: showsUsed, cached: claudeUsageIsCached(snapshot, window: $0)) } ?? "Unavailable")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .help(claudeUsageIsCached(snapshot, window: value)
                        ? "Cached observation. Refresh checks the default account; separate accounts update through a new Claude response using the bridge."
                        : "Account usage or a saved Claude statusline observation; see the source below")
            }
            if let value, value.usedPercentage.isFinite {
                UsageBar(percent: claudeDisplayValue(value.usedPercentage, showsUsed: showsUsed),
                         tint: claudeQuotaColor(value.usedPercentage, cached: claudeUsageIsCached(snapshot, window: value)))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(value.resetsAt.map {
                        "Resets \($0.formatted(date: .abbreviated, time: .standard)) · \(claudeCountdown($0, now: context.date))"
                    } ?? "Reset time unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(ResetCountdownColor.color(
                        for: value.resetsAt,
                        now: context.date,
                        isStale: claudeUsageIsCached(snapshot, window: value, now: context.date)))
                }
            }
        }
    }
}

private func claudeDisplayValue(_ used: Double, showsUsed: Bool) -> Double {
    let bounded = min(100, max(0, used))
    return showsUsed ? bounded : 100 - bounded
}

private func claudePercent(_ used: Double, showsUsed: Bool, cached: Bool = false) -> String {
    guard used.isFinite else { return "Unavailable" }
    return "\(cached ? "Cached " : "")\(Int(claudeDisplayValue(used, showsUsed: showsUsed).rounded()))% \(showsUsed ? "used" : "left")"
}

private func claudeQuotaColor(_ used: Double, cached: Bool = false) -> Color {
    guard used.isFinite, !cached else { return .secondary.opacity(0.65) }
    return remainingQuotaColor(for: Int((100 - min(100, max(0, used))).rounded()))
}

private func claudeCountdown(_ date: Date, now: Date = Date()) -> String {
    date > now ? resetCountdown(from: date, now: now) : "reset passed; waiting for a new Claude response"
}

/// Menu height is fixed per visible row; extra accounts remain accessible in Settings.
struct ClaudeMenuSectionView: View {
    @ObservedObject var store: ClaudeProfileStore
    var isCollapsed = false
    var onToggle: () -> Void = {}
    let onSettings: () -> Void
    let onOpen: (String) -> Void
    private static let visibleLimit = 3
    private static let rowHeight: CGFloat = 112
    private static let headerHeight = ProviderSectionHeaderView.height
    private static let detailsHeight: CGFloat = 44
    private static let footerHeight: CGFloat = 34

    static func height(for store: ClaudeProfileStore, isCollapsed: Bool = false) -> CGFloat {
        guard !isCollapsed else { return headerHeight }
        return headerHeight + detailsHeight + (hasModelWeek(in: store) ? 24 : 0) + (store.error == nil ? 0 : 18) + visibleProfiles(in: store).reduce(CGFloat(0)) { height, profile in
            height + rowHeight + (store.statuses[profile.id]?.usage?.modelWeekly == nil ? 0 : 16)
        } + footerHeight
    }

    private static func visibleProfiles(in store: ClaudeProfileStore) -> [ClaudeProfile] {
        let selected = store.profiles.filter { $0.id == store.selectedID }
        let rest = store.profiles.filter { $0.id != store.selectedID }
        return Array((selected + rest).prefix(Self.visibleLimit))
    }

    private static func hasModelWeek(in store: ClaudeProfileStore) -> Bool {
        visibleProfiles(in: store).contains { store.statuses[$0.id]?.usage?.modelWeekly != nil }
    }

    private var visibleProfiles: [ClaudeProfile] { Self.visibleProfiles(in: store) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ProviderSectionHeaderView(title: "Claude Code", isCollapsed: self.isCollapsed, onToggle: self.onToggle)
                if !self.isCollapsed {
                    Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .frame(width: 32, height: Self.headerHeight)
                        .contentShape(Rectangle())
                        .disabled(store.isRefreshing)
                        .accessibilityLabel("Refresh Claude usage")
                        .help("Refresh Claude usage")
                }
            }
            if !self.isCollapsed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(store.isRefreshing ? "Reading Claude accounts…" : "Accounts for new terminal sessions")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    ClaudeQuotaControls(showsModelWeek: visibleProfiles.contains { store.statuses[$0.id]?.usage?.modelWeekly != nil })
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10)).foregroundStyle(Palette.warning)
                            .lineLimit(1).help(error)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: Self.detailsHeight + (Self.hasModelWeek(in: store) ? 24 : 0) + (store.error == nil ? 0 : 18))
                ForEach(visibleProfiles) { profile in
                    ClaudeMenuProfileRow(profile: profile, status: store.statuses[profile.id],
                                         selected: profile.id == store.selectedID,
                                         onChoose: { store.select(id: profile.id) },
                                         onOpen: { onOpen(profile.id) })
                        .frame(height: Self.rowHeight + (store.statuses[profile.id]?.usage?.modelWeekly == nil ? 0 : 16))
                }
                Button(action: onSettings) {
                    HStack {
                        Text("Manage all Claude accounts (\(store.profiles.count))…")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }
                    .font(.system(size: 11)).padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .frame(height: Self.footerHeight)
            }
        }
        .frame(width: 290, height: Self.height(for: store, isCollapsed: self.isCollapsed), alignment: .topLeading)
    }
}

private struct ClaudeMenuProfileRow: View {
    let profile: ClaudeProfile
    let status: ClaudeProfileStatus?
    let selected: Bool
    let onChoose: () -> Void
    let onOpen: () -> Void
    @AppStorage(ClaudeQuotaPreferences.fiveHourKey) private var fiveHourShowsUsed = false
    @AppStorage(ClaudeQuotaPreferences.weekKey) private var weekShowsUsed = false
    @AppStorage(ClaudeQuotaPreferences.modelWeekKey) private var modelWeekShowsUsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Button(action: onChoose) {
                    HStack(spacing: 5) {
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                        Text(profile.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose this Claude account for new sessions")
                Spacer(minLength: 3)
                Button("Open", action: onOpen).controlSize(.mini)
                    .disabled(status?.busy == true)
                    .help("Open a new Claude terminal session")
            }
            Text(claudeAccountLabel(status)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            quota("5h", window: status?.usage?.fiveHour, showsUsed: fiveHourShowsUsed)
            quota("Wk", window: status?.usage?.sevenDay, showsUsed: weekShowsUsed)
            if let modelWeekly = status?.usage?.modelWeekly {
                quota("Mwk", window: modelWeekly, showsUsed: modelWeekShowsUsed)
                    .help("Model weekly quota")
            }
            Text(status?.usage.map { claudeFreshnessLabel($0) } ?? "Usage unavailable")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                .help(status?.usage.map { "Observed \($0.observedAt.formatted(date: .complete, time: .standard))" } ?? "No saved observation")
            Text(status?.usage.map { claudeSourceLabel($0) } ?? "No saved Claude observation")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .help(status?.usage.map { claudeSourceLabel($0) } ?? "No saved Claude observation")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.accent.opacity(0.06) : Color.clear)
    }

    private func quota(_ label: String, window: ClaudeUsageWindow?, showsUsed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 22, alignment: .leading)
            if let window, window.usedPercentage.isFinite {
                UsageBar(percent: claudeDisplayValue(window.usedPercentage, showsUsed: showsUsed),
                         tint: claudeQuotaColor(window.usedPercentage, cached: claudeUsageIsCached(status?.usage, window: window)))
                Text(claudePercent(window.usedPercentage, showsUsed: showsUsed, cached: claudeUsageIsCached(status?.usage, window: window)))
                    .frame(width: claudeUsageIsCached(status?.usage, window: window) ? 108 : 62, alignment: .trailing)
                    .help(claudeUsageIsCached(status?.usage, window: window)
                        ? "Cached observation. Refresh checks the default account; separate accounts update through a new Claude response using the bridge."
                        : "Account usage or a saved Claude statusline observation; see the source below")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(window.resetsAt.map { $0 > context.date ? resetCountdown(from: $0, now: context.date) : "Due" } ?? "—")
                        .frame(width: 44, alignment: .trailing).lineLimit(1)
                        .foregroundStyle(ResetCountdownColor.color(
                            for: window.resetsAt,
                            now: context.date,
                            isStale: claudeUsageIsCached(status?.usage, window: window, now: context.date)))
                        .help(window.resetsAt.map { "Resets \($0.formatted(date: .complete, time: .standard))" } ?? "Reset time unavailable")
                }
            } else {
                Text("Unavailable").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}
