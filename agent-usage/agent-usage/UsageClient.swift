import Foundation
import Security
import LocalAuthentication
import Darwin

actor UsageClient {
    private struct ClaudeCredentials: Decodable {
        struct OAuth: Decodable, Sendable { let accessToken: String; let expiresAt: Double }
        let claudeAiOauth: OAuth
    }
    private struct CodexCredentials: Decodable {
        struct Tokens: Decodable { let access_token: String; let account_id: String }
        let tokens: Tokens
    }

    private var cachedClaudeCredentials: ClaudeCredentials.OAuth?
    private let credentialReader: @Sendable (Bool) throws -> Data
    private let claudeRenewer: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private let requestLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(credentialReader: @escaping @Sendable (Bool) throws -> Data = { try UsageClient.readClaudeKeychain(allowInteraction: $0) },
         claudeRenewer: @escaping @Sendable () async throws -> Void = { try await UsageClient.renewClaude() },
         requestLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await UsageClient.loadRequest($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentialReader = credentialReader
        self.claudeRenewer = claudeRenewer
        self.requestLoader = requestLoader
        self.now = now
    }

    func fetch(_ provider: Provider, reconnectClaude: Bool = false) async throws -> UsageReading {
        var request: URLRequest
        switch provider {
        case .claude:
            let credentials = try await claudeCredentials(allowInteraction: reconnectClaude)
            request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.0.32", forHTTPHeaderField: "User-Agent")
        case .codex:
            let credentials = try readCodexCredentials()
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(credentials.access_token)", forHTTPHeaderField: "Authorization")
            request.setValue(credentials.account_id, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do { (data, response) = try await requestLoader(request) }
        catch { throw UsageFailure(message: "\(provider.name) request failed: \(error.localizedDescription)") }
        guard let response = response as? HTTPURLResponse else {
            throw UsageFailure(message: "\(provider.name) returned a non-HTTP response.")
        }
        if provider == .claude && response.statusCode == 401 {
            cachedClaudeCredentials = nil
            throw ClaudeConnectionRequired(message: "Claude rejected the saved login. Reconnect Claude to read the current credentials.")
        }
        guard response.statusCode == 200 else {
            let retry = response.value(forHTTPHeaderField: "Retry-After").map { " Retry after: \($0)." } ?? ""
            let login = [401, 403].contains(response.statusCode) ? " \(provider.loginHelp)" : ""
            throw UsageFailure(message: "\(provider.name) usage request returned HTTP \(response.statusCode).\(retry)\(login)")
        }
        return try UsageParser.parse(data, provider: provider)
    }

    private func claudeCredentials(allowInteraction: Bool) async throws -> ClaudeCredentials.OAuth {
        if !allowInteraction, let cached = cachedClaudeCredentials, isCurrent(cached) { return cached }
        cachedClaudeCredentials = nil
        var credentials = try decodeClaudeCredentials(credentialReader(allowInteraction))
        if !isCurrent(credentials) {
            guard allowInteraction else {
                throw ClaudeConnectionRequired(message: "Claude's login has expired. Reconnect Claude to renew it.")
            }
            try await claudeRenewer()
            credentials = try decodeClaudeCredentials(credentialReader(true))
            guard isCurrent(credentials) else {
                throw ClaudeConnectionRequired(message: "Claude credentials are still expired after renewal. \(Provider.claude.loginHelp)")
            }
        }
        cachedClaudeCredentials = credentials
        return credentials
    }

    private func isCurrent(_ credentials: ClaudeCredentials.OAuth) -> Bool {
        credentials.expiresAt / 1000 > now().timeIntervalSince1970 + 60
    }

    private func decodeClaudeCredentials(_ data: Data) throws -> ClaudeCredentials.OAuth {
        guard let credentials = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
              !credentials.claudeAiOauth.accessToken.isEmpty else {
            throw ClaudeConnectionRequired(message: "Claude Keychain credentials have an unexpected format. \(Provider.claude.loginHelp)")
        }
        return credentials.claudeAiOauth
    }

    private static func readClaudeKeychain(allowInteraction: Bool) throws -> Data {
        // Claude uses the legacy login keychain. Suppress its UI as well as the
        // per-query authentication UI. Restore the process setting before returning;
        // this synchronous read never suspends while interaction is disabled.
        var previousInteraction: DarwinBoolean = true
        if !allowInteraction {
            guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw ClaudeConnectionRequired(message: "Cannot read Claude credentials silently. Reconnect Claude to allow Keychain access.")
            }
        }
        defer {
            if !allowInteraction { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }
        }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            throw ClaudeConnectionRequired(message: "Cannot read Claude Code credentials: \(reason). Reconnect Claude to allow access. \(Provider.claude.loginHelp)")
        }
        return data
    }

    private static func loadRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // An ephemeral session keeps credentials and usage out of disk caches.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }

    private func readCodexCredentials() throws -> CodexCredentials.Tokens {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let credentials = try? JSONDecoder().decode(CodexCredentials.self, from: data),
              !credentials.tokens.access_token.isEmpty, !credentials.tokens.account_id.isEmpty else {
            throw UsageFailure(message: "Cannot read Codex ChatGPT credentials. \(Provider.codex.loginHelp)")
        }
        return credentials.tokens
    }

    private static func renewClaude() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageFailure(message: "Claude credentials expired, but the claude CLI was not found in ~/.local/bin, Homebrew, or PATH. \(Provider.claude.loginHelp)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "ok", "--model", "haiku"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw UsageFailure(message: "Could not start Claude to renew credentials. \(Provider.claude.loginHelp)") }
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        if process.isRunning {
            process.terminate()
            try await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw UsageFailure(message: "Claude login renewal timed out. \(Provider.claude.loginHelp)")
        }
        // Like the script, re-read credentials even if the prompt exited nonzero:
        // the CLI may have renewed OAuth before its inference request failed.
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
