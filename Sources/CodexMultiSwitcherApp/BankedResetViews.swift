import CodexProfileCore
import SwiftUI

struct ProfileQuotaView: View {
    let snapshot: UsageSnapshot
    var cached = false
    @AppStorage(QuotaDisplayPreferences.primaryKey) private var primaryShowsUsed = false
    @AppStorage(QuotaDisplayPreferences.secondaryKey) private var secondaryShowsUsed = false

    private var weeklyOnly: Bool {
        !self.snapshot.hasPrimaryWindow && self.snapshot.hasSecondaryWindow
            && self.snapshot.secondaryWindowDurationMins == 10080
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if !self.weeklyOnly {
                    QuotaWindowCard(title: "5h", used: self.snapshot.hasPrimaryWindow ? self.snapshot.primaryUsedPercent : nil,
                        resetAt: self.snapshot.primaryResetAt, cached: self.cached, showsUsed: self.$primaryShowsUsed)
                }
                QuotaWindowCard(title: "week", used: self.snapshot.hasSecondaryWindow ? self.snapshot.secondaryUsedPercent : nil,
                    resetAt: self.snapshot.secondaryResetAt, cached: self.cached, showsUsed: self.$secondaryShowsUsed)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(self.cached ? "Cached · " : "")\(updatedLabel(from: self.snapshot.fetchedAt, now: context.date))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct QuotaWindowCard: View {
    let title: String
    let used: Int?
    let resetAt: Date?
    let cached: Bool
    @Binding var showsUsed: Bool

    private var showsCached: Bool { self.cached || self.resetAt.map { $0 <= Date() } == true }
    private var value: Int? { self.used.map { QuotaDisplayPreferences.value(usedPercent: $0, showsUsed: self.showsUsed) } }
    private var tint: Color {
        guard let used, !self.showsCached else { return .secondary }
        return remainingQuotaColor(for: remainingQuotaPercent(for: used))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(self.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button(self.showsUsed ? "Used ↔" : "Left ↔") { self.showsUsed.toggle() }
                    .controlSize(.mini).buttonStyle(.bordered)
                    .help("Change between used and remaining. Cached observations are gray.")
            }
            if let value = self.value {
                if self.showsCached {
                    Text("Cached observation").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(value)%").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(self.showsUsed ? "used" : "remaining")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .foregroundStyle(self.tint)
                UsageBar(percent: Double(value), tint: self.tint)
                if let resetAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(resetAt > context.date
                             ? "Resets \(resetAt.formatted(date: .abbreviated, time: .shortened)) · \(resetCountdown(from: resetAt, now: context.date))"
                             : "Reset due · refresh needed")
                            .font(.system(size: 11))
                            .foregroundStyle(ResetCountdownColor.color(for: resetAt, now: context.date, isStale: self.cached))
                    }
                } else {
                    Text("Reset time unavailable").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Unavailable").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                Text("Not reported by Codex for this plan.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(self.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(self.tint.opacity(0.16)))
    }
}

struct BankedResetInventoryView: View {
    let profileID: String
    let profileLabel: String
    let snapshot: UsageSnapshot
    @ObservedObject var scheduler: BankedResetScheduler
    @ObservedObject var toast: ToastState

    private var credits: [BankedResetCredit] {
        (self.snapshot.bankedResetCredits ?? []).filter(\.isAvailable).sorted {
            ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }
    }

    private var history: [BankedResetSchedule] {
        self.scheduler.schedules.values.filter { record in
            record.profileID == self.profileID && !self.credits.contains(where: { $0.id == record.creditID })
        }.sorted { $0.scheduledAt > $1.scheduledAt }
    }

    var body: some View {
        if let count = self.snapshot.bankedResetCount {
            VStack(alignment: .leading, spacing: 10) {
                Divider().padding(.vertical, 3)
                HStack {
                    Label("Banked resets", systemImage: "arrow.counterclockwise.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(count) available")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                }
                Text("Using a reset restarts the eligible 5h and weekly allowances and changes the weekly reset date.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !self.credits.isEmpty {
                    ForEach(Array(self.credits.enumerated()), id: \.element.id) { index, credit in
                        BankedResetCreditCard(profileID: self.profileID, profileLabel: self.profileLabel,
                            number: index + 1, credit: credit, scheduler: self.scheduler, toast: self.toast)
                            .id("\(self.profileID):\(credit.id)")
                    }
                } else if count > 0 {
                    self.legacyDates
                } else {
                    Text("No banked resets available.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !self.credits.isEmpty && self.credits.count < count {
                    Text("Codex returned details for \(self.credits.count) of \(count) resets. Only resets with an ID can be scheduled.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Times use \(TimeZone.current.identifier). Schedules run while this app is open, your Mac is awake, and the network is available. Missed attempts are checked after opening or waking.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let message = self.scheduler.lastMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
                ForEach(self.history) { record in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: record.completedAt == nil ? "clock" : "checkmark.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            if let completed = record.completedAt {
                                Text("Reset confirmed \(completed.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                Text(record.enabled ? "Scheduled reset is awaiting confirmation" : "Reset schedule stopped")
                            }
                            if let error = record.lastError { Text(error).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if record.enabled {
                            Button("Cancel") {
                                do { try self.scheduler.cancelSchedule(profileID: self.profileID, creditID: record.creditID) }
                                catch { self.toast.show(error.localizedDescription, style: .error) }
                            }.controlSize(.mini).disabled(self.scheduler.isRunning)
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var legacyDates: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array((self.snapshot.bankedResetExpirations ?? []).enumerated()), id: \.offset) { index, date in
                Text("Reset \(index + 1) · \(date.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No expiry")")
            }
            Text("This Codex response did not include reset IDs. Refresh to check for scheduling support.")
                .foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
}

private struct BankedResetCreditCard: View {
    let profileID: String
    let profileLabel: String
    let number: Int
    let credit: BankedResetCredit
    @ObservedObject var scheduler: BankedResetScheduler
    @ObservedObject var toast: ToastState
    @State private var mode: BankedResetScheduleMode = .beforeExpiry
    @State private var date = Date().addingTimeInterval(3600)
    @State private var hours = 24
    @State private var minutes = 0
    @State private var expanded = false
    @State private var working = false
    @State private var confirmUse = false

    private var record: BankedResetSchedule? {
        self.scheduler.schedule(for: self.profileID, creditID: self.credit.id)
    }
    private var trigger: Date? {
        self.mode == .atDate ? self.date : self.credit.expiresAt?.addingTimeInterval(-(Double(self.hours) * 60 + Double(self.minutes)) * 60)
    }
    private var validBeforeExpiryOffset: Bool {
        (0...720).contains(self.hours) && (0...59).contains(self.minutes)
            && (1...(720 * 60)).contains(self.hours * 60 + self.minutes)
    }
    private var canEdit: Bool { !AppInfo.isPreview && !self.scheduler.isRunning && !self.working && self.credit.isRedeemable() }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reset \(self.number)").font(.system(size: 13, weight: .semibold))
                    if let expiry = self.credit.expiresAt {
                        Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(expiry > context.date ? "\(resetCountdown(from: expiry)) remaining" : "Expired")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(expiry.timeIntervalSince(context.date) < 86400 ? Palette.warning : Palette.accent)
                        }
                    } else { Text("No expiry").font(.system(size: 12)).foregroundStyle(.secondary) }
                    if let granted = self.credit.grantedAt {
                        Text("Granted \(granted.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 6)
                Button("Use now…") { self.confirmUse = true }
                    .controlSize(.small).disabled(!self.canEdit)
            }
            if let record = self.record {
                self.scheduleStatus(record)
            }
            Button {
                self.expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Schedule automatic reset")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schedule automatic reset")
            .accessibilityValue(self.expanded ? "Expanded" : "Collapsed")
            .help("Click anywhere on this row to show or hide the schedule settings.")
            if self.expanded {
                self.editor.padding(.top, 8)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .onAppear {
            if let record = self.record {
                self.mode = record.mode; self.date = record.scheduledAt; self.hours = record.hoursBeforeExpiry
                self.minutes = record.minutesBeforeExpiry ?? 0
            } else if self.credit.expiresAt == nil { self.mode = .atDate }
        }
        .alert("Use this reset for \(self.profileLabel)?", isPresented: self.$confirmUse) {
            Button("Cancel", role: .cancel) {}
            Button("Use reset") { self.perform { try await self.scheduler.useNow(profileID: self.profileID, credit: self.credit) } }
        } message: {
            Text("This consumes one banked reset and restarts the eligible 5h and weekly allowances. The weekly reset date will change.")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("When", selection: self.$mode) {
                Text("At a date & time").tag(BankedResetScheduleMode.atDate)
                Text("Before expiry").tag(BankedResetScheduleMode.beforeExpiry)
            }.pickerStyle(.segmented).labelsHidden()
            if self.mode == .atDate {
                DatePicker("Run at", selection: self.$date, displayedComponents: [.date, .hourAndMinute])
            } else {
                HStack(spacing: 6) {
                    TextField("Hours", value: self.$hours, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 68)
                    Text("hours")
                    TextField("Minutes", value: self.$minutes, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 68)
                    Text("minutes before expiry").foregroundStyle(.secondary)
                }
                .onChange(of: self.hours) { _, value in self.hours = min(720, max(0, value)) }
                .onChange(of: self.minutes) { _, value in self.minutes = min(59, max(0, value)) }
                if !self.validBeforeExpiryOffset {
                    Text(self.hours == 0 && self.minutes == 0
                         ? "Choose at least 1 minute before expiry."
                         : "The maximum is 720 hours; use 0 minutes at that limit.")
                        .font(.system(size: 11)).foregroundStyle(Palette.warning)
                }
            }
            if let trigger = self.trigger {
                Text(trigger <= Date() ? "Due now · enabling will run this reset immediately" : "Will run \(trigger.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(trigger <= Date() ? Palette.warning : Palette.accent)
            } else {
                Text("No expiry date supplied. Choose a date & time instead.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button(self.trigger.map { $0 <= Date() } == true ? "Enable and run now" : "Save & enable schedule") {
                self.perform {
                    try await self.scheduler.saveSchedule(profileID: self.profileID, credit: self.credit,
                        mode: self.mode, date: self.date, hours: self.hours, minutes: self.minutes)
                }
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(self.mode == .beforeExpiry && !self.validBeforeExpiryOffset)
            Text("No reset runs until you enable a schedule. A request that cannot be confirmed is retried with the same request ID.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.disabled(!self.canEdit)
    }

    private func scheduleStatus(_ record: BankedResetSchedule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let completed = record.completedAt {
                    Label("Used \(completed.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle")
                } else if record.enabled {
                    Label(record.triggerDate(expiresAt: self.credit.expiresAt).map {
                        "Scheduled \($0.formatted(date: .abbreviated, time: .standard))"
                    } ?? "Scheduled", systemImage: "clock")
                    Spacer()
                    Button("Cancel") {
                        do { try self.scheduler.cancelSchedule(profileID: self.profileID, creditID: self.credit.id) }
                        catch { self.toast.show(error.localizedDescription, style: .error) }
                    }.controlSize(.mini).disabled(self.scheduler.isRunning)
                } else { Text("Schedule off") }
            }.foregroundStyle(Palette.accent)
            if let error = record.lastError { Text(error).foregroundStyle(.secondary) }
        }.font(.system(size: 11))
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !self.working else { return }
        self.working = true
        Task { @MainActor in
            defer { self.working = false }
            do { try await action(); self.toast.show(self.scheduler.lastMessage ?? "Saved", style: .info) }
            catch { self.toast.show(error.localizedDescription, style: .error) }
        }
    }
}
