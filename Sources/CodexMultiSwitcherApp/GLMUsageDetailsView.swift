import CodexProfileCore
import SwiftUI

struct GLMUsageDetailsView: View {
    let snapshot: ProviderUsageSnapshot
    let now: Date
    let compact: Bool
    @State private var showsMonitor = false

    private var monitor: GLMMonitorUsageSnapshot? { snapshot.glmMonitor }
    private var benefits: GLMAccountBenefitsSnapshot? { snapshot.glmAccountBenefits }
    private var monitorCurrent: Bool { monitor.map { isFresh($0.observedAt, verified: snapshot.accountVerified) } ?? false }
    private var benefitsCurrent: Bool {
        benefits.map { isFresh($0.sourceObservedAt, verified: $0.accountVerified) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            accountBenefitsSection
            publishedCampaign
            Divider()
            DisclosureGroup("Usage details · API key", isExpanded: $showsMonitor) {
                monitorSection.padding(.top, 6)
            }
            .font(.system(size: compact ? 10 : 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            sectionHeading("API-key monitor · 24-hour request window")
            Text("Coding Plan API key scope · " + utcWindowLabel(monitor))
                .font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let monitor {
                freshness(monitor.observedAt, verified: snapshot.accountVerified, compact: compact)
                if let subscription = monitor.subscription {
                    detailLine("Subscription", subscription.productName, verified: monitorCurrent)
                    detailLine("Next plan date", subscription.nextRenewTime ?? "Unavailable", verified: monitorCurrent)
                    if let cycle = subscription.billingCycle { detailLine("Billing cycle", cycle, verified: monitorCurrent) }
                } else {
                    detailLine("Subscription", "Unavailable", verified: monitorCurrent)
                    detailLine("Next plan date", "Unavailable", verified: monitorCurrent)
                }

                if let usage = monitor.modelUsage {
                    detailLine("Reported aggregate tokens", usage.totalTokensUsage.map(grouped) ?? "Unavailable", verified: monitorCurrent)
                    detailLine("Model calls", usage.totalModelCallCount.map(grouped) ?? "Unavailable", verified: monitorCurrent)
                    if usage.models.isEmpty {
                        detailLine("Per-model tokens", "Unavailable", verified: monitorCurrent)
                    } else {
                        sectionLabel("Reported per-model tokens")
                        ForEach(Array(usage.models.enumerated()), id: \.offset) { _, model in
                            detailLine(model.modelName, grouped(model.totalTokens), indent: true, verified: monitorCurrent)
                        }
                    }
                    if let total = usage.totalTokensUsage, !usage.models.isEmpty,
                       usage.models.reduce(0, { $0 + $1.totalTokens }) != total {
                        Text("The service aggregate and model summaries differ; both are shown independently.")
                            .font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    detailLine("Tokens and model calls", "Unavailable", verified: monitorCurrent)
                }

                if let tools = monitor.toolUsage {
                    sectionLabel("Tool calls")
                    detailLine("Network search", tools.totalNetworkSearchCount.map(grouped) ?? "Unavailable", indent: true, verified: monitorCurrent)
                    detailLine("Web read", tools.totalWebReadMcpCount.map(grouped) ?? "Unavailable", indent: true, verified: monitorCurrent)
                    detailLine("Zread", tools.totalZreadMcpCount.map(grouped) ?? "Unavailable", indent: true, verified: monitorCurrent)
                    detailLine("Search MCP", tools.totalSearchMcpCount.map(grouped) ?? "Unavailable", indent: true, verified: monitorCurrent)
                } else {
                    detailLine("Tool calls", "Unavailable", verified: monitorCurrent)
                }
            } else {
                detailLine("Monitor data", "Unavailable", verified: false)
                Text("This key-based monitor does not verify that it belongs to the ZCode account shown below.")
                    .font(.system(size: compact ? 9 : 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountBenefitsSection: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            sectionHeading("ZCode account benefits")
            Text("Separate signed-in ZCode account scope · not verified as the API-key account")
                .font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let benefits {
                freshness(benefits.sourceObservedAt, verified: benefitsCurrent, compact: compact)
                resetCards(benefits.resetStatus)
                startPlanBalances(benefits.startPlan)
                if benefits.campaignDiscounts != nil { campaigns(benefits.campaignDiscounts) }
            } else {
                detailLine("Account benefits", "Unavailable", verified: false)
            }
        }
    }

    @ViewBuilder private func resetCards(_ status: GLMCodingPlanResetStatus?) -> some View {
        sectionLabel("Issued reset cards · expiry")
        if let status {
            resetGroup("5-hour", opportunities: status.availableFiveHourResets.sorted { $0.expiresAt < $1.expiresAt }, verified: benefitsCurrent)
            resetGroup("Weekly", opportunities: status.availableWeekResets.sorted { $0.expiresAt < $1.expiresAt }, verified: benefitsCurrent)
        } else {
            detailLine("5-hour cards", "Unavailable", indent: true, verified: false)
            detailLine("Weekly cards", "Unavailable", indent: true, verified: false)
        }
    }

    @ViewBuilder private func resetGroup(_ title: String, opportunities: [GLMCodingPlanResetOpportunity], verified: Bool) -> some View {
        if !opportunities.isEmpty {
            detailLine(title, "\(opportunities.count) issued cards", indent: true, verified: verified)
        }
        if opportunities.isEmpty {
            detailLine(title, "No issued cards", indent: true, verified: verified)
        } else {
            ForEach(Array(opportunities.enumerated()), id: \.offset) { index, card in
                let label = opportunities.count == 1 ? title : "\(title) card \(index + 1)"
                Text("\(label) · expires \(card.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: compact ? 9 : 11, weight: .medium))
                    .foregroundStyle(expiryColor(card.expiresAt, verified: verified))
                    .help("Issued reset card expiry: \(card.expiresAt.formatted(date: .complete, time: .standard))")
            }
        }
    }

    @ViewBuilder private func startPlanBalances(_ startPlan: GLMStartPlanBenefits?) -> some View {
        sectionLabel("Start Plan balances · bucket expiry")
        if let startPlan {
            if startPlan.plans.isEmpty {
                detailLine("Plan details", "Unavailable", indent: true, verified: benefitsCurrent)
            } else {
                ForEach(Array(startPlan.plans.enumerated()), id: \.offset) { _, plan in
                    detailLine(plan.name ?? plan.planID ?? "Plan", plan.status ?? "Status unavailable", indent: true,
                               verified: benefitsCurrent)
                    if let endsAt = plan.endsAt {
                        detailLine("Plan ends", endsAt.formatted(date: .abbreviated, time: .shortened), indent: true,
                                   verified: benefitsCurrent)
                    }
                }
            }
            if startPlan.balances.isEmpty {
                detailLine("Quota buckets", "Unavailable", indent: true, verified: benefitsCurrent)
            } else {
                ForEach(Array(startPlan.balances.enumerated()), id: \.offset) { _, bucket in
                    balanceRow(bucket, verified: benefitsCurrent)
                }
            }
        } else {
            detailLine("Quota buckets", "Unavailable", indent: true, verified: false)
            if let reason = benefits?.startPlanUnavailableReason {
                Text(reason).font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func campaigns(_ discounts: [GLMCampaignDiscount]?) -> some View {
        sectionLabel("Published campaign details")
        if let discounts {
            if discounts.isEmpty {
                detailLine("Campaign details", "None returned", indent: true, verified: benefitsCurrent)
            } else {
                ForEach(Array(discounts.enumerated()), id: \.offset) { _, campaign in
                    let name = campaign.campaignName ?? campaign.rewardMode ?? "Campaign"
                    let fields = [
                        campaign.campaignDiscountAmount.map { "Reported discount \(grouped($0))" },
                        campaign.rewardMode.map { "Reward type \($0)" },
                        campaign.rewardAmount.map { "Reward amount \(grouped($0))" },
                        campaign.applyScene.map { "Applies to \($0)" },
                        campaign.rewardDetail.map { "Details \($0)" },
                    ].compactMap { $0 }
                    detailLine(name, fields.joined(separator: " · ").ifEmpty("Details available"),
                               indent: true, verified: benefitsCurrent)
                }
                Text("Campaign values are shown as returned; they are not applied to quota totals.")
                    .font(.system(size: compact ? 9 : 11)).foregroundStyle(.tertiary)
            }
        } else {
            detailLine("Campaign details", "Unavailable", indent: true, verified: false)
        }
    }

    private var publishedCampaign: some View {
        VStack(alignment: .leading, spacing: 4) {
            Link("GLM-5.3-Flash campaign rules ↗", destination: URL(string: "https://docs.z.ai/devpack/notice/event-glm-5.3-flash")!)
            Text("Published offer: Sep 3–Oct 7, 2026 · daily 23:00–09:00 Singapore time. Paid Coding Plans: no quota consumption in ZCode/AutoClaw; doubled quota in other supported agents. ZCode 3.10+ is required; exhausted 5-hour or weekly quota blocks participation until refill.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Published rules are separate from your personal Flash token balance and do not verify an account-specific boost.")
                .foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: compact ? 9 : 11))
    }

    private func balanceRow(_ bucket: GLMStartPlanBalance, verified: Bool) -> some View {
        let name = bucket.showName ?? bucket.capabilities?.first(where: { $0.lowercased().hasPrefix("model:") })
            .map { String($0.dropFirst("model:".count)) } ?? bucket.meter ?? "Quota bucket"
        let quantity = bucket.remainingUnits
        let quantityLabel = "Remaining"
        let unitsText: String
        if let quantity, let total = bucket.totalUnits {
            unitsText = "\(quantityLabel) \(grouped(quantity)) / \(grouped(total)) \(bucket.unitType ?? "units")"
        } else if let quantity {
            unitsText = "\(quantityLabel) \(grouped(quantity)) \(bucket.unitType ?? "units") · total unavailable"
        } else {
            unitsText = "Balance unavailable"
        }
        let reservedText = bucket.reservedUnits.map { "Reserved \(grouped($0))" }
        let availableText = bucket.availableUnits.map { "Available now \(grouped($0))" }
        let percent = quantity.flatMap { remaining in
            bucket.totalUnits.flatMap { total in total > 0 && remaining <= total ? 100 * remaining / total : nil }
        }
        let percentText = percent.map { "\(Int($0.rounded()))% left" }
        let expiryText = bucket.expiresAt.map { "\($0 <= now ? "Expired" : "Expires") \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "Bucket expiry unavailable"
        return VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            detailLine(name, [percentText, unitsText, availableText, reservedText].compactMap { $0 }.joined(separator: " · "), indent: true, verified: verified)
            Text(expiryText).font(.system(size: compact ? 9 : 11))
                .foregroundStyle(bucket.expiresAt.map { expiryColor($0, verified: verified) } ?? Color.secondary)
                .padding(.leading, compact ? 8 : 12)
        }
    }

    private func freshness(_ observedAt: Date, verified: Bool, compact: Bool) -> some View {
        let fresh = isFresh(observedAt, verified: verified)
        return Text("\(fresh ? "Current" : "Stale or unverified") · observed \(observedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: compact ? 9 : 11)).foregroundStyle(fresh ? Color.secondary : Color.secondary.opacity(0.8))
            .help("Source observation: \(observedAt.formatted(date: .complete, time: .standard))")
    }

    private func detailLine(_ title: String, _ value: String, indent: Bool = false, verified: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).lineLimit(1)
            Spacer(minLength: 5)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: compact ? 9 : 11))
        .foregroundStyle(verified ? Color.primary : Color.secondary)
        .padding(.leading, indent ? (compact ? 8 : 12) : 0)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: compact ? 9 : 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: compact ? 9 : 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.top, compact ? 1 : 3)
    }

    private func isFresh(_ date: Date, verified: Bool) -> Bool {
        guard verified else { return false }
        let age = now.timeIntervalSince(date)
        return age >= -30 && age <= 180
    }

    private func expiryColor(_ date: Date, verified: Bool) -> Color {
        guard verified, isFresh(benefits?.sourceObservedAt ?? .distantPast, verified: verified) else { return .secondary }
        let remaining = date.timeIntervalSince(now)
        if remaining < 0 { return .secondary }
        return remaining <= 24 * 60 * 60 ? Palette.danger : Color.primary
    }

    private func utcWindowLabel(_ monitor: GLMMonitorUsageSnapshot?) -> String {
        guard let monitor else { return "window unavailable" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d HH:mm 'UTC'"
        return "\(formatter.string(from: monitor.windowStart))–\(formatter.string(from: monitor.windowEnd))"
    }

    private func grouped(_ value: Int) -> String { value.formatted(.number) }
    private func grouped(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { self.isEmpty ? fallback : self }
}
