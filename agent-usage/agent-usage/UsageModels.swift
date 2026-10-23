import Foundation

enum Provider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    var logo: String { self == .claude ? "ClaudeLogo" : "CodexLogo" }
    var loginHelp: String {
        self == .claude
            ? "Open claude in Terminal and run /login, then refresh here."
            : "Run codex login in Terminal using your ChatGPT account, then refresh here. Use the file-based credential store (~/.codex/auth.json)."
    }
}

struct UsageWindow: Sendable {
    let seconds: Double?
    let utilization: Double?
    let resetsAt: Date?

    var label: String {
        guard let seconds else { return "—" }
        if seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(seconds / 86400))d" }
        if seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 60))m"
    }
    var percent: String { utilization.map { "\(Int($0.rounded(.down)))%" } ?? "—" }
    var fraction: Double { min(1, max(0, (utilization ?? 0) / 100)) }
    static let unavailable = UsageWindow(seconds: nil, utilization: nil, resetsAt: nil)
}

struct ExtraUsage: Decodable, Sendable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?
    let currency: String?
    let utilization: Double?
}

struct UsageReading: Sendable {
    let windows: [UsageWindow]
    let extra: ExtraUsage?
    let fetchedAt: Date
}

struct UsageFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct ClaudeConnectionRequired: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

// Missing/null windows are legitimate. A missing provider envelope or malformed
// field is a parsing error, so it cannot replace the last successful reading.
enum UsageParser {
    private struct ClaudeResponse: Decodable {
        let fiveHour: ClaudeWindow?
        let sevenDay: ClaudeWindow?
        let extraUsage: ExtraUsage?
        enum CodingKeys: String, CodingKey { case fiveHour, sevenDay, extraUsage }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.fiveHour) || values.contains(.sevenDay) else {
                throw UsageFailure(message: "Claude response is missing usage windows. The endpoint may have changed.")
            }
            fiveHour = try values.decodeIfPresent(ClaudeWindow.self, forKey: .fiveHour)
            sevenDay = try values.decodeIfPresent(ClaudeWindow.self, forKey: .sevenDay)
            extraUsage = try values.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        }
    }
    private struct ClaudeWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }
    private struct CodexResponse: Decodable { let rateLimit: CodexLimits }
    private struct CodexLimits: Decodable {
        let primaryWindow: CodexWindow?
        let secondaryWindow: CodexWindow?
    }
    private struct CodexWindow: Decodable {
        let limitWindowSeconds: Double
        let usedPercent: Double?
        let resetAt: Double?
    }

    static func parse(_ data: Data, provider: Provider) throws -> UsageReading {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            switch provider {
            case .claude:
                let value = try decoder.decode(ClaudeResponse.self, from: data)
                let windows = try [(value.fiveHour, 18000.0), (value.sevenDay, 604800.0)].map { window, seconds in
                    UsageWindow(seconds: seconds, utilization: try percentage(window?.utilization),
                                resetsAt: try date(window?.resetsAt))
                }
                return UsageReading(windows: windows, extra: value.extraUsage, fetchedAt: Date())
            case .codex:
                let value = try decoder.decode(CodexResponse.self, from: data)
                let windows = try [value.rateLimit.primaryWindow, value.rateLimit.secondaryWindow].map { window -> UsageWindow in
                    guard let window else { return UsageWindow.unavailable }
                    guard window.limitWindowSeconds.isFinite, window.limitWindowSeconds >= 60,
                          window.limitWindowSeconds < 315360000 else {
                        throw UsageFailure(message: "Codex returned an invalid usage window duration.")
                    }
                    return UsageWindow(seconds: window.limitWindowSeconds,
                                       utilization: try percentage(window.usedPercent),
                                       resetsAt: window.resetAt.map(Date.init(timeIntervalSince1970:)))
                }.sorted { ($0.seconds ?? .infinity) < ($1.seconds ?? .infinity) }
                return UsageReading(windows: windows, extra: nil, fetchedAt: Date())
            }
        } catch let error as UsageFailure { throw error }
        catch { throw UsageFailure(message: "Could not parse \(provider.name) usage. The endpoint may have changed (\(type(of: error))).") }
    }

    private static func percentage(_ value: Double?) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value >= 0, value <= 100 else {
            throw UsageFailure(message: "The provider returned utilization outside 0–100%.")
        }
        return value
    }
    private static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw UsageFailure(message: "Claude returned an unrecognized reset time.")
        }
        return date
    }
}
