import Foundation

/// Media transports accepted by the native FFmpeg build. Subscription/API URLs
/// still use WebAddress's HTTP-only contract.
public enum MediaAddress {
    public static let streamingSchemes: Set<String> = ["rtmp", "rtmps", "rtsp", "rtsps", "udp", "rtp"]

    public static func resolve(_ text: String, relativeTo base: URL? = nil) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = URLComponents(string: value)?.scheme?.lowercased(), streamingSchemes.contains(scheme) {
            guard let url = URL(string: value), let host = url.host, !host.isEmpty,
                  !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw TVError.invalidURL }
            return url
        }
        return try WebAddress.resolve(value, relativeTo: base)
    }
}
