import Foundation

public enum SubscriptionUpdateFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    public static let enabledKey = "local.subscription.autoUpdate.enabled"
    public static let frequencyKey = "local.subscription.autoUpdate.frequency"
    case automatic, daily, weekly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自动更新"
        case .daily: "每隔24小时更新"
        case .weekly: "每隔7天更新"
        }
    }
    public var interval: TimeInterval? {
        switch self {
        case .automatic: nil
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }
}

/// One check per source per foreground, with intervals measured from successful
/// checks only. Network failures consume this trigger but remain due next time.
@MainActor public final class SubscriptionUpdateSchedule {
    public struct Check: Equatable, Sendable {
        public let address: String
        fileprivate let foreground: UInt64
    }
    private static let successKey = "local.subscription.autoUpdate.success"
    private let defaults: UserDefaults
    private let now: () -> Date
    private var successes: [String: Date]
    private var foreground: UInt64 = 0
    private var active = false
    private var attempted: [String: UInt64] = [:]
    private var inFlight: [String: Check] = [:]
    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        successes = defaults.data(forKey: Self.successKey)
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }
    public func enterForeground() {
        guard !active else { return }
        active = true; foreground &+= 1
    }
    public func leaveForeground() { active = false }
    public func lastSuccess(for address: String) -> Date? { successes[address] }
    public func begin(address: String, frequency: SubscriptionUpdateFrequency) -> Check? {
        guard active, inFlight[address] == nil, attempted[address] != foreground else { return nil }
        if let interval = frequency.interval, let last = successes[address] {
            let elapsed = now().timeIntervalSince(last)
            // A changed wall clock must not strand a saved success in the future.
            guard elapsed < 0 || elapsed >= interval else { return nil }
        }
        let check = Check(address: address, foreground: foreground)
        attempted[address] = foreground; inFlight[address] = check
        return check
    }
    public func complete(_ check: Check, succeeded: Bool) {
        guard inFlight[check.address] == check else { return }
        inFlight[check.address] = nil
        if succeeded {
            successes[check.address] = now()
            defaults.set(try? JSONEncoder().encode(successes), forKey: Self.successKey)
        }
    }
    /// A user enabling checks/changing frequency requests a new check opportunity.
    /// An existing request still owns its lease and cannot overlap a second one.
    public func settingsChanged() { attempted.removeAll() }
    public func forget(_ address: String) {
        successes[address] = nil; attempted[address] = nil; inFlight[address] = nil
        defaults.set(try? JSONEncoder().encode(successes), forKey: Self.successKey)
    }
}

public struct SubscriptionUpdateFingerprint: Codable, Equatable, Sendable {
    public let md5: String
    public let origin: URL
}

public struct SubscriptionUpdateResult: Sendable {
    /// Nil means the previous document is still valid; callers must not rebuild it.
    public let subscription: Subscription?
    public let fingerprint: SubscriptionUpdateFingerprint
}

extension HTTPClient {
    /// Compare actual received bytes. A same-body redirect to another directory
    /// still refreshes, because relative spider/ext paths resolve from that origin.
    public func subscriptionUpdate(_ url: URL, previous: Subscription?, fingerprint: SubscriptionUpdateFingerprint?) async throws -> SubscriptionUpdateResult {
        let (data, finalURL) = try await get(url, headers: ["User-Agent": Self.subscriptionUserAgent], cachePolicy: .reloadIgnoringLocalCacheData)
        let next = SubscriptionUpdateFingerprint(md5: LocalSourceLibrary.md5(data), origin: finalURL)
        if let previous, previous.origin == finalURL {
            if fingerprint == next { return SubscriptionUpdateResult(subscription: nil, fingerprint: next) }
            // Pre-update saved subscriptions did not preserve source bytes. Compare
            // decoded JSON once to establish the baseline without a needless reset.
            if fingerprint == nil, let raw = try? SubscriptionDocument.decode(data) {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                if let old = try? encoder.encode(previous.raw), let fresh = try? encoder.encode(raw),
                   LocalSourceLibrary.md5(old) == LocalSourceLibrary.md5(fresh) {
                    return SubscriptionUpdateResult(subscription: nil, fingerprint: next)
                }
            }
        }
        guard case .subscription(let value) = try await subscriptionImport(data, origin: finalURL, requestedURL: url) else {
            throw TVError.unsupported("此地址已不再返回订阅内容，保留原有版本")
        }
        return SubscriptionUpdateResult(subscription: value, fingerprint: next)
    }
}
