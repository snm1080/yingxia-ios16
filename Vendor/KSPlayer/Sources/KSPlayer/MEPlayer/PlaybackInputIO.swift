import Foundation
import FFmpegKit

/// Preserve the source URL given to libavformat while serving its exact bytes
/// from the optional cache. Observe every input IO, including manifest children,
/// so HLS/DASH traffic remains measurable when the root format has no `pb`.
/// The reader owns this object until avformat_close_input finishes, including
/// nested demuxer opens and failures; FFmpeg owns and closes each AVIOContext.
final class PlaybackInputIO: @unchecked Sendable {
    private let original: String
    private let transport: String
    private let counterLock = NSLock()
    private var inputs: [UInt: UnsafeMutablePointer<AVIOContext>] = [:]
    private var closedBytes: Int64 = 0
    private var publishedBytes: Int64 = 0

    var bytesRead: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return publishedBytes
    }

    /// Called by the format's single native reader after probe/read operations.
    /// Only that reader examines FFmpeg counters; UI sampling reads a scalar.
    func publishBytes() {
        counterLock.lock()
        defer { counterLock.unlock() }
        publishedBytes = totalBytes()
    }

    private func totalBytes() -> Int64 {
        var total = closedBytes
        for input in inputs.values {
            let count = max(0, input.pointee.bytes_read)
            if count > Int64.max - total { return .max }
            total += count
        }
        return total
    }

    private func opened(_ input: UnsafeMutablePointer<AVIOContext>) {
        counterLock.lock()
        inputs[UInt(bitPattern: input)] = input
        counterLock.unlock()
    }

    private func closing(_ input: UnsafeMutablePointer<AVIOContext>) {
        counterLock.lock()
        if inputs.removeValue(forKey: UInt(bitPattern: input)) != nil {
            let count = max(0, input.pointee.bytes_read)
            closedBytes = count > Int64.max - closedBytes ? .max : closedBytes + count
        }
        publishedBytes = totalBytes()
        counterLock.unlock()
    }

    init(originalURL: URL, transportURL: URL) {
        original = originalURL.isFileURL ? originalURL.path : originalURL.absoluteString
        transport = transportURL.isFileURL ? transportURL.path : transportURL.absoluteString
    }

    func install(on format: UnsafeMutablePointer<AVFormatContext>) {
        format.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        format.pointee.io_open = { context, output, address, flags, options in
            guard let context, let address, let opaque = context.pointee.opaque else { return -22 }
            let mapping = Unmanaged<PlaybackInputIO>.fromOpaque(opaque).takeUnretainedValue()
            let source = String(cString: address)
            let mapped = (flags & AVIO_FLAG_WRITE) == 0 && source == mapping.original
            var localOptions: OpaquePointer?
            // A callback normally receives options, but some nested demuxers omit
            // them. Keep whitelist/blacklist handling equivalent to FFmpeg's default.
            let status = withUnsafeMutablePointer(to: &localOptions) { local in
                let fields = options ?? local
                defer { if options == nil { av_dict_free(local) } }
                if let whitelist = context.pointee.protocol_whitelist {
                    av_dict_set(fields, "protocol_whitelist", whitelist, 0)
                }
                if let blacklist = context.pointee.protocol_blacklist {
                    av_dict_set(fields, "protocol_blacklist", blacklist, 0)
                }
                // Keep the source's HTTP options on the app-owned loopback request.
                // An extensionless manifest is handed back to the original server
                // with a redirect, and its demuxer inherits these options for keys
                // and segments. The cache itself uses the stored per-track headers.
                var interrupt = context.pointee.interrupt_callback
                return (mapped ? mapping.transport : source).withCString { url in
                    avio_open2(output, url, flags, &interrupt, fields)
                }
            }
            if status >= 0, (flags & AVIO_FLAG_WRITE) == 0, let input = output?.pointee {
                mapping.opened(input)
            }
            return status
        }
        format.pointee.io_close2 = { context, input in
            guard let input else { return 0 }
            if let opaque = context?.pointee.opaque {
                // Capture the count before closing. The UI never retains a freed
                // segment pointer, and the counter lock never covers network IO.
                Unmanaged<PlaybackInputIO>.fromOpaque(opaque).takeUnretainedValue().closing(input)
            }
            var closing = Optional(input)
            return avio_closep(&closing)
        }
    }
}
