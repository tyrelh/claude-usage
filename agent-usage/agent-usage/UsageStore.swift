import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class ProviderStore {
    let provider: Provider
    private(set) var reading: UsageReading?
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var needsReconnect = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let client = UsageClient()

    init(provider: Provider) { self.provider = provider }
    var windows: [UsageWindow] { reading?.windows ?? [.unavailable, .unavailable] }
    var marker: String { error != nil ? "!" : (reading == nil ? "…" : "") }
    var status: String {
        if isRefreshing { return "Refreshing…" }
        if error != nil { return reading == nil ? "Unavailable" : "Stale · showing last successful reading" }
        return reading == nil ? "Waiting for first reading" : "Updated successfully"
    }

    func refresh(reconnectClaude: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?()
        Task {
            do {
                reading = try await client.fetch(provider, reconnectClaude: reconnectClaude)
                error = nil
                needsReconnect = false
            } catch {
                self.error = error.localizedDescription
                needsReconnect = error is ClaudeConnectionRequired
            }
            isRefreshing = false
            onChange?()
        }
    }
}

@MainActor @Observable
final class ProviderSettings {
    private static let key = "hiddenProviders"
    private(set) var hidden: Set<Provider>
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        let hidden = Set(stored.compactMap(Provider.init(rawValue:)))
        // Never start with every provider hidden, or nothing would be clickable.
        self.hidden = hidden.count < Provider.allCases.count ? hidden : []
    }

    func isShown(_ provider: Provider) -> Bool { !hidden.contains(provider) }
    func canHide(_ provider: Provider) -> Bool { isShown(provider) && hidden.count + 1 < Provider.allCases.count }

    func setShown(_ provider: Provider, _ shown: Bool) {
        guard shown != isShown(provider), shown || canHide(provider) else { return }
        if shown { hidden.remove(provider) } else { hidden.insert(provider) }
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Self.key)
        onChange?()
    }
}

@MainActor @Observable
final class LoginSettings {
    private(set) var enabled = false
    private(set) var needsApproval = false
    private(set) var error: String?

    init() { reload() }
    func reload() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }
    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = "Could not change launch at login: \(error.localizedDescription)" }
        reload()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
