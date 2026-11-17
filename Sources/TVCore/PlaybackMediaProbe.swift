import Foundation

public enum PlaybackMediaProbe {
    /// WebDAV/Emby redirects can end at download.aspx or /stream. Read only a bounded prefix before
    /// choosing AVPlayer or the existing repackager; never wait for an entire HTTP 200 response body.
    public static func needsRemux(_ url: URL, headers: [String: String], session: URLSession = .shared) async -> Bool {
        if Remux.handles(name: url.lastPathComponent) { return true }
        guard ["http", "https"].contains(url.scheme ?? ""),
              !["m3u8", "mpd", "mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav"].contains(url.pathExtension.lowercased()) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 8)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return false }
            var head = Data()
            for try await byte in bytes {
                head.append(byte)
                if head.count == 16 { break }
            }
            return Remux.handles(head)
        } catch { return false }
    }
}
