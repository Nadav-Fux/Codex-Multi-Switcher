/// Read-only adapter boundary for provider usage integrations.
///
/// Implementations may inspect a provider's existing local session or call a
/// usage endpoint, but must not mutate provider state or persist credentials.
/// Return categorized failures in `ProviderUsageSnapshot.state`; do not include
/// raw responses, headers, tokens, cookies, or backend error dumps in snapshots.
public protocol UsageProviderAdapter: Sendable {
    var providerID: ProviderID { get }

    func readUsageSnapshot() async -> ProviderUsageSnapshot
}
