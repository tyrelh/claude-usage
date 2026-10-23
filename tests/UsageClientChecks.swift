import Foundation
import os

@main
struct UsageClientChecks {
    struct State {
        var now = Date()
        var token = "first"
        var expiresAt = Date().addingTimeInterval(3600)
        var blocked = false
        var reads: [Bool] = []
        var requests: [String] = []
        var renewals = 0
        var status = 200
    }

    static func client(_ state: OSAllocatedUnfairLock<State>) -> UsageClient {
        UsageClient(credentialReader: { allowInteraction in
            try state.withLock { value in
                value.reads.append(allowInteraction)
                if value.blocked && !allowInteraction {
                    throw ClaudeConnectionRequired(message: "Keychain requires permission")
                }
                return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                    "accessToken": value.token, "expiresAt": value.expiresAt.timeIntervalSince1970 * 1000
                ]])
            }
        }, claudeRenewer: {
            state.withLock { value in
                value.renewals += 1
                value.token = "renewed"
                value.expiresAt = Date().addingTimeInterval(3600)
            }
        }, requestLoader: { request in
            state.withLock { value in
                value.requests.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                let response = HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: nil, headerFields: nil)!
                // Change the usage on every request to ensure only credentials are cached.
                let body = Data("{\"five_hour\":{\"utilization\":\(value.requests.count)}}".utf8)
                return (body, response)
            }
        }, now: { state.withLock { $0.now } })
    }

    static func requiresReconnect(_ client: UsageClient) async {
        do {
            _ = try await client.fetch(.claude)
            fatalError("Expected reconnect requirement")
        } catch is ClaudeConnectionRequired {} catch { fatalError("Unexpected error: \(error)") }
    }

    static func main() async throws {
        let state = OSAllocatedUnfairLock(initialState: State())
        let monitor = client(state)
        let first = try await monitor.fetch(.claude)
        // Simulate Claude rewriting its item and revoking access between polls.
        state.withLock { $0.blocked = true }
        let second = try await monitor.fetch(.claude)
        precondition(first.windows[0].utilization == 1 && second.windows[0].utilization == 2)
        state.withLock {
            precondition($0.reads == [false])
            precondition($0.requests == ["Bearer first", "Bearer first"])
        }

        // An explicit reconnect bypasses a valid cached token and permits a prompt.
        state.withLock { $0.token = "switched-account" }
        _ = try await monitor.fetch(.claude, reconnectClaude: true)
        state.withLock {
            precondition($0.reads == [false, true])
            precondition($0.requests.last == "Bearer switched-account")
        }

        // Revoked tokens are discarded; the next background read remains silent.
        state.withLock { $0.status = 401 }
        await requiresReconnect(monitor)
        await requiresReconnect(monitor)
        state.withLock {
            precondition($0.reads == [false, true, false])
            precondition($0.requests.count == 4)
            precondition($0.renewals == 0)
            $0.status = 200
        }
        _ = try await monitor.fetch(.claude, reconnectClaude: true)

        // Near-expired credentials never start Claude CLI during background polling.
        let expired = OSAllocatedUnfairLock(initialState: State(expiresAt: Date().addingTimeInterval(30)))
        let expiredMonitor = client(expired)
        await requiresReconnect(expiredMonitor)
        expired.withLock {
            precondition($0.renewals == 0 && $0.requests.isEmpty && $0.reads == [false])
        }
        _ = try await expiredMonitor.fetch(.claude, reconnectClaude: true)
        _ = try await expiredMonitor.fetch(.claude)
        expired.withLock {
            precondition($0.renewals == 1 && $0.reads == [false, true, true])
            precondition($0.requests == ["Bearer renewed", "Bearer renewed"])
        }

        // Once the cached token reaches the expiry buffer, read fresh credentials silently.
        let ageing = OSAllocatedUnfairLock(initialState: State())
        let ageingMonitor = client(ageing)
        _ = try await ageingMonitor.fetch(.claude)
        ageing.withLock {
            $0.now = $0.expiresAt.addingTimeInterval(-30)
            $0.token = "refreshed-by-cli"
            $0.expiresAt = $0.now.addingTimeInterval(3600)
        }
        _ = try await ageingMonitor.fetch(.claude)
        ageing.withLock {
            precondition($0.reads == [false, false] && $0.renewals == 0)
            precondition($0.requests == ["Bearer first", "Bearer refreshed-by-cli"])
        }

        // A fresh app instance cannot silently reuse a previous instance's token.
        let restarted = client(state)
        await requiresReconnect(restarted)
        print("Usage client checks passed: fresh subscription readings, memory-only tokens, silent reads, reconnect, expiry, renewal, and HTTP 401 recovery.")
    }
}
