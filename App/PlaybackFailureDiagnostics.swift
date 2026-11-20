import Foundation

/// Native playback errors may include signed media URLs in their descriptions.
/// Diagnostic reports retain only the known domain and numeric cause chain.
enum PlaybackFailureDiagnostics {
    static func codes(_ error: Error) -> String {
        let known: Set<String> = ["KSPlayerErrorDomain", "KSPlayer.DolbyVision", "KSPlayer.NativeCodec", "NSOSStatusErrorDomain",
                                  "NSURLErrorDomain", "AVFoundationErrorDomain", "CoreMediaErrorDomain",
                                  "NSCocoaErrorDomain"]
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>(), result: [String] = []
        while let failure = current, result.count < 4, seen.insert(ObjectIdentifier(failure)).inserted {
            result.append("\(known.contains(failure.domain) ? failure.domain : "other"):\(failure.code)")
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result.joined(separator: ">")
    }

    /// The identity of a resolved playback address: host, port and path
    /// only, never the query — a signed query is a secret and also changes
    /// without the address's identity changing. For the loopback proxy
    /// addresses the sources hand out, the port and the path token are what
    /// distinguish one resolution from another, so two resolutions of the
    /// same episode can be told apart (or caught returning the same dead
    /// address) from a single diagnostic line.
    static func address(_ url: URL?) -> String {
        guard let url else { return "-" }
        let host = url.host() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(host)\(port)\(url.path())"
    }
}
