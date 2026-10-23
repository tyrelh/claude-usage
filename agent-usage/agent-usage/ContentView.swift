import SwiftUI

struct ContentView: View {
    let stores: [ProviderStore]
    let providers: ProviderSettings
    let login: LoginSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(stores.filter { providers.isShown($0.provider) }.enumerated()), id: \.element.provider) { index, store in
                    if index > 0 { Divider() }
                    ProviderDetailView(store: store)
                        .frame(width: 314)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 18) {
                ForEach(stores, id: \.provider) { store in
                    let provider = store.provider
                    let locked = providers.isShown(provider) && !providers.canHide(provider)
                    Toggle("Show \(provider.name)", isOn: Binding(get: { providers.isShown(provider) }, set: { providers.setShown(provider, $0) }))
                        .disabled(locked)
                        .help(locked ? "At least one provider must stay visible" : "")
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small)
            if login.needsApproval {
                Button("Approve in Login Items…") { login.openSettings() }
            }
            if let error = login.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Quit Agent Usage") { NSApplication.shared.terminate(nil) }.font(.caption)
            }
        }
        .padding(18)
    }
}

private struct ProviderDetailView: View {
    let store: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(store.provider.logo).resizable().renderingMode(.template).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.provider.name).font(.headline)
                    Text("Subscription usage").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh \(store.provider.name) usage").accessibilityLabel("Refresh \(store.provider.name) usage")
                    .disabled(store.isRefreshing)
            }
            ForEach(Array(store.windows.enumerated()), id: \.offset) { index, window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(window.seconds == nil ? "\(index == 0 ? "First" : "Second") window unavailable" : "\(window.label) window")
                        Spacer()
                        Text(window.utilization == nil ? "Unavailable" : "\(window.percent) used").monospacedDigit()
                    }.font(.subheadline)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.09))
                            Capsule().fill(Color(UsageColors.color(window.utilization)))
                                .frame(width: geometry.size.width * window.fraction)
                        }
                    }.frame(height: 7)
                    if let reset = window.resetsAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            HStack(spacing: 4) {
                                Text(reset > context.date ? "Resets" : "Reset was")
                                Text(reset, style: .relative)
                                Text(reset > context.date ? "from now" : "ago")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(reset, format: .dateTime.weekday().month().day().hour().minute())
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Reset time unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let extra = store.reading?.extra {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra usage\(extra.isEnabled == false ? " · disabled" : "")").font(.subheadline.weight(.medium))
                    if let used = extra.usedCredits {
                        Text("\(used.formatted())\(extra.currency.map { " " + $0 } ?? " credits") used\(extra.monthlyLimit.map { " of " + $0.formatted() } ?? "")")
                            .font(.caption)
                    } else { Text("Credits unavailable").font(.caption) }
                    if let utilization = extra.utilization { Text("\(utilization.formatted())% of monthly limit").font(.caption) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(store.status).font(.caption).foregroundStyle(store.error == nil ? Color.secondary : Color.orange)
                if let date = store.reading?.fetchedAt {
                    Text("Last success: \(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.error {
                    Text(error).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Refreshes every 10 minutes.").font(.caption).foregroundStyle(.secondary)
                if store.provider == .claude {
                    Button("Reconnect Claude…") { store.refresh(reconnectClaude: true) }
                        .disabled(store.isRefreshing)
                    Text(store.needsReconnect ? "Reconnect to allow Keychain access or renew your login." : "Background refreshes never ask for your Keychain password.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Reconnecting may ask for Keychain access. Expired logins renew through Claude CLI; its small prompt may use plan allowance.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

        }
    }
}
