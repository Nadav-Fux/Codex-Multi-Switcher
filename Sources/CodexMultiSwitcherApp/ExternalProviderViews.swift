import CodexProfileCore
import SwiftUI
import AppKit

struct ExternalProviderMenuSection: View {
    @ObservedObject var store: ExternalProviderStore
    let provider: ProviderID
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        if provider == .antigravity, let logo = ExternalProviderIconRenderer.antigravityLogo {
                            Image(nsImage: logo).resizable().scaledToFit().frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                        }
                        Text(provider.displayName).font(.system(size: 12, weight: .semibold))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                Spacer()
                if store.refreshing.contains(provider) { ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 12, height: 12) }
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("\(provider.displayName) settings")
            }
            if !isCollapsed {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        ProviderUsageContent(snapshot: store.snapshots[provider], provider: provider, now: context.date, compact: true)
                    }
                    .frame(maxHeight: 250)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: 290, alignment: .leading)
    }

    static func height(snapshot: ProviderUsageSnapshot?, collapsed: Bool) -> CGFloat {
        guard !collapsed else { return 32 }
        let groups = Set(snapshot?.buckets.map(\.group) ?? []).count
        let rows = snapshot?.buckets.count ?? 0
        let glmExtra = snapshot?.provider == .glm ? 250 : 0
        return 40 + min(250, CGFloat(60 + rows * 58 + groups * 22 + glmExtra))
    }
}

struct ExternalProviderSettings: View {
    @ObservedObject var store: ExternalProviderStore
    let provider: ProviderID
    @AppStorage(ProviderVisibility.key) private var visibleProviders = ""
    @AppStorage("glmReadZCodeBenefits") private var readsZCodeBenefits = true
    @State private var glmKey = ""
    @State private var glmKeyStored = false
    @State private var credentialError: String?
    @State private var connectingKey = false
    @AppStorage("antigravityMenuBucket.gemini") private var geminiBucket = ""
    @AppStorage("antigravityMenuBucket.other") private var otherBucket = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    HStack(spacing: 6) {
                        if provider == .antigravity, let logo = ExternalProviderIconRenderer.antigravityLogo {
                            Image(nsImage: logo).resizable().scaledToFit().frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            Text(provider.displayName)
                        } else {
                            Label(provider.displayName, systemImage: provider.symbolName)
                        }
                    }.font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Refresh") { store.refresh(provider, force: true) }
                        .disabled(store.refreshing.contains(provider))
                }
                Toggle("Show in menu bar", isOn: Binding(
                    get: { _ = visibleProviders; return ProviderVisibility.selection().contains(provider) },
                    set: { ProviderVisibility.set(provider, visible: $0) }))
                    .disabled(ProviderVisibility.selection().count == 1 && ProviderVisibility.selection().contains(provider))
                Text(provider == .antigravity
                     ? "Reads quota through your existing statusline helper connection, after verifying its account matches Antigravity. Gemini and other model quotas remain separate."
                     : "Reads your Z.ai GLM Coding Plan subscription quota. Local token counts and pay-as-you-go API balance are separate from subscription limits.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if provider == .antigravity {
                    bucketPicker("Gemini in menu bar", group: .gemini, selection: $geminiBucket)
                    bucketPicker("Other models in menu bar", group: .other, selection: $otherBucket)
                }
                Divider()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProviderUsageContent(snapshot: store.snapshots[provider], provider: provider, now: context.date, compact: false)
                }
                Divider()
                Text("CONNECTION").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(provider == .antigravity
                    ? "Use the same account in Antigravity and the antigravity-usage statusline helper. This section observes quota; account switching remains managed by Antigravity. Quotas may be shared by several models; shared pools are shown once when the service identifies them."
                    : "Connect your Personal Z.ai Coding Plan key for quota and usage. Its key stays in this app’s Keychain. Reset cards and Flash grants are read separately from your existing local ZCode sign-in; credentials are decoded only in memory using ZCode’s published format. Redeem cards in ZCode.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if provider == .glm {
                    Button(connectingKey ? "Waiting for macOS permission…" : "Connect Saved Z.ai Key…") {
                        connectingKey = true
                        credentialError = nil
                        NSApp.activate(ignoringOtherApps: true)
                        Task { @MainActor in
                            defer { connectingKey = false }
                            do {
                                let exists = try await Task.detached {
                                    try GLMCredentialStore.load(allowInteraction: true) != nil
                                }.value
                                glmKeyStored = exists
                                if exists { store.credentialsDidChange(.glm) }
                                else { credentialError = "No saved Coding Plan key was found. Add your key below." }
                            } catch { credentialError = error.localizedDescription }
                        }
                    }.disabled(connectingKey)
                    Text("Reconnect the existing saved key after an app update if macOS requests Keychain permission. This does not replace the key.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("Read reset cards and Start Plan / Flash balances from local ZCode sign-in", isOn: $readsZCodeBenefits)
                        .onChange(of: readsZCodeBenefits) { _, _ in store.credentialsDidChange(.glm) }
                    SecureField("Z.ai Coding Plan API key", text: $glmKey)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save Key & Refresh") {
                            do {
                                try GLMCredentialStore.save(glmKey)
                                glmKey = ""; glmKeyStored = true; credentialError = nil
                                store.credentialsDidChange(.glm)
                            } catch { credentialError = error.localizedDescription }
                        }.disabled(glmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove Saved Key") {
                            do {
                                try GLMCredentialStore.remove()
                                glmKeyStored = false; credentialError = nil
                                store.credentialsDidChange(.glm)
                            } catch { credentialError = error.localizedDescription }
                        }.disabled(!glmKeyStored)
                    }
                    Text(glmKeyStored ? "A Coding Plan key is stored securely." : "No Coding Plan key is stored.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let credentialError { Text(credentialError).font(.system(size: 11)).foregroundStyle(Palette.warning) }
                    Link("Open Z.ai API key management", destination: URL(string: "https://z.ai/manage-apikey/apikey-list")!)
                    Button("Open ZCode") {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ZCode.app"),
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                Link("Official usage documentation", destination: URL(string: provider == .antigravity
                    ? "https://www.antigravity.google/docs/cli/commands/usage"
                    : "https://zcode.z.ai/en/docs/usage-stats")!)
            }.padding(24)
        }
        .onAppear {
            if provider == .glm {
                do { glmKeyStored = try GLMCredentialStore.load() != nil }
                catch { credentialError = error.localizedDescription }
            }
        }
        .onDisappear { glmKey = "" }
    }

    @ViewBuilder private func bucketPicker(_ title: String, group: ProviderUsageBucketGroup, selection: Binding<String>) -> some View {
        let buckets = store.snapshots[provider]?.buckets.filter { $0.group == group } ?? []
        if !buckets.isEmpty {
            Picker(title, selection: selection) {
                Text("Automatic").tag("")
                ForEach(buckets) { Text($0.title).tag($0.id) }
            }.pickerStyle(.menu)
        }
    }
}

private struct ProviderUsageContent: View {
    let snapshot: ProviderUsageSnapshot?
    let provider: ProviderID
    let now: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            if let account = snapshot?.account {
                Text(account.email ?? account.displayName ?? "Connected account")
                    .font(.system(size: compact ? 10 : 13, weight: .medium)).lineLimit(1)
                if let plan = snapshot?.plan { Text(plan.name).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary) }
            }
            let message = ProviderQuotaPresentation.message(snapshot, provider: provider)
            if !message.isEmpty { Text(message).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach([ProviderUsageBucketGroup.gemini, .other, .general], id: \.rawValue) { group in
                let buckets = snapshot?.buckets.filter { $0.group == group } ?? []
                if !buckets.isEmpty {
                    if provider == .antigravity {
                        Text(group == .gemini ? "GEMINI" : group == .other ? "OTHER MODELS" : "OTHER QUOTAS")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(buckets) { bucket in
                        ProviderQuotaRow(provider: provider, bucket: bucket, snapshot: snapshot, now: now, compact: compact)
                    }
                }
            }
            if provider == .glm, let snapshot {
                GLMUsageDetailsView(snapshot: snapshot, now: now, compact: compact)
            }
            if let observedAt = snapshot?.observedAt {
                Text(snapshot?.isCurrent(at: now) == true ? updatedLabel(from: observedAt) : "Last observation · " + updatedLabel(from: observedAt))
                    .font(.system(size: compact ? 9 : 11)).foregroundStyle(.tertiary)
                    .help(observedAt.formatted(date: .complete, time: .standard))
            }
            if !compact, let snapshot { Text(snapshot.source).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderQuotaRow: View {
    let provider: ProviderID
    let bucket: ProviderUsageBucket
    let snapshot: ProviderUsageSnapshot?
    let now: Date
    let compact: Bool
    @AppStorage private var showsUsed: Bool

    init(provider: ProviderID, bucket: ProviderUsageBucket, snapshot: ProviderUsageSnapshot?, now: Date, compact: Bool) {
        self.provider = provider; self.bucket = bucket; self.snapshot = snapshot; self.now = now; self.compact = compact
        _showsUsed = AppStorage(wrappedValue: false, ProviderQuotaPresentation.modeKey(provider, bucket))
    }

    var body: some View {
        let remaining = ProviderQuotaPresentation.remaining(bucket, snapshot: snapshot, at: now)
        let amount = remaining.map { showsUsed ? 100 - $0 : $0 }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(bucket.title).font(.system(size: compact ? 10 : 12, weight: .medium)).lineLimit(1).help([bucket.title, bucket.detail].compactMap { $0 }.joined(separator: " · "))
                Spacer(minLength: 0)
                Button(showsUsed ? "Used" : "Left") { showsUsed.toggle() }
                    .font(.system(size: 9)).buttonStyle(.bordered).controlSize(.mini)
                    .accessibilityLabel("\(provider.displayName) \(bucket.group == .gemini ? "Gemini " : bucket.group == .other ? "Other models " : "")\(bucket.title) display")
                Text(amount.map { "\(Int($0.rounded()))%" } ?? "Unavailable")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(remaining.map { quotaColor(remaining: $0) } ?? Color.secondary)
            }
            if !compact, let detail = bucket.detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let amount, let remaining { UsageBar(percent: amount, tint: quotaColor(remaining: remaining)) }
            Text(bucket.resetAt.map {
                $0 > now ? (compact ? "Resets \(resetCountdown(from: $0))" : "Resets \($0.formatted(date: .abbreviated, time: .standard)) · \(resetCountdown(from: $0))") : "Reset due · refresh needed"
            } ?? "Reset time unavailable")
                .font(.system(size: compact ? 9 : 11))
                .foregroundStyle(ResetCountdownColor.color(
                    for: bucket.resetAt,
                    now: now,
                    isStale: snapshot?.isCurrent(at: now) != true))
                .help(bucket.resetAt.map { $0.formatted(date: .complete, time: .standard) } ?? "Reset time unavailable")
        }
    }

    private func quotaColor(remaining: Double) -> Color {
        remaining >= 50 ? Palette.success : remaining >= 20 ? Palette.warning : Palette.danger
    }
}
