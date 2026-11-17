import Foundation

/// Source metadata follows resolved media URLs through Channel copies and quality changes.
/// The live descriptor remains structured: cookies/tokens never become a downloadable feed URL.
public struct MediaDanmakuDescriptor: Sendable, Equatable {
    public let feed: String?
    public let live: JSONValue?
    public let baseURL: String
    public let headers: [String: String]
    public init?(result: [String: JSONValue], baseURL: String, headers: [String: String]) {
        var result = result
        // A playback descriptor can come back from a Python/script wrapper or
        // a stored Channel, without passing through Catalog's choice parser.
        for _ in 0..<4 {
            guard let key = ["data", "result", "play"].first(where: { result[$0] != nil }) else { break }
            var nested = result[key]
            if let text = nested?.string, let data = text.data(using: .utf8) { nested = try? JSONDecoder().decode(JSONValue.self, from: data) }
            guard let fields = nested?.object else { break }
            result.removeValue(forKey: key)
            result.merge(fields) { _, new in new }
        }
        let extra = result["extra"]?.object ?? [:]
        let suppliedFeed = [extra["danmaku"], result["danmaku"]].compactMap { value -> String? in
            guard let feed = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !feed.isEmpty else { return nil }
            return feed
        }.first
        let websocket = suppliedFeed?.lowercased().hasPrefix("ws:") == true || suppliedFeed?.lowercased().hasPrefix("wss:") == true
        let live = [extra["liveDanmaku"], result["liveDanmaku"], websocket ? suppliedFeed.map(JSONValue.string) : nil]
            .compactMap { $0 }.first { value in
                if let text = value.string { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return value.object?.isEmpty == false
            }
        let feed = websocket ? nil : suppliedFeed.flatMap { try? WebAddress.resolve($0, relativeTo: URL(string: baseURL)).absoluteString }
        guard live != nil || feed?.isEmpty == false else { return nil }
        self.feed = feed; self.live = live; self.baseURL = baseURL; self.headers = headers
    }
}
public enum MediaDanmakuRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: MediaDanmakuDescriptor] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    public static func register(_ descriptor: MediaDanmakuDescriptor, for url: URL) {
        lock.withLock {
            let key = url.absoluteString
            order.removeAll { $0 == key }; order.append(key); entries[key] = descriptor
            while order.count > 256 { entries[order.removeFirst()] = nil }
        }
    }
    public static func descriptor(for url: URL) -> MediaDanmakuDescriptor? { lock.withLock { entries[url.absoluteString] } }
    public static func copy(from source: URL, to destination: URL) {
        if let descriptor = descriptor(for: source) { register(descriptor, for: destination) }
    }
}
