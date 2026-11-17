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
}
