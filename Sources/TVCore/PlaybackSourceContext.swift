import Foundation

/// Source identity is available before URL preparation. A dispatcher's HTTP
/// suffix or missing duration must not turn a subscription live stream into VOD.
public enum PlaybackSourceContext {
    public static func isLive(route: String, fields: [String: JSONValue] = [:], group: String = "") -> Bool {
        if fields["isLive"] == .bool(true) || fields["live"] == .bool(true) || fields["type"]?.string == "live" { return true }
        if group == "直播线路" { return true }
        let path = URLComponents(string: route)?.path ?? route
        return path.range(of: #"(?:^|/)spider/(?:live|live2vod)(?:/|$)"#, options: .regularExpression) != nil
    }
}
