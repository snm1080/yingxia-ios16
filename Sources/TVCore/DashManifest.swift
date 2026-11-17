import Foundation

/// CatPaw Bilibili supplies a static SegmentBase MPD, with authenticated proxy URLs for each track.
/// Keep those URLs and their indexes; DashStreams presents the same fragments to AVPlayer as HLS.
enum DashManifest {
    static func recognizes(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "mpd" { return true }
        guard ["localhost", "127.0.0.1"].contains(url.host ?? ""), url.path.hasSuffix("/proxy") else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "do" && $0.value == "mpd" } == true
    }

    static func stream(_ url: URL, name: String, headers: [String: String], session: URLSession) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TVError.http(status) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { throw TVError.unsupported("DASH 播放清单过大") }
            data.append(byte)
        }
        let dash = try parse(data, base: response.url ?? url, name: name)
        guard let address = try await DashStreams.stream(dash, headers: headers, danmaku: nil, session: session) else {
            throw TVError.unsupported("DASH 播放清单没有本设备支持的视频轨道")
        }
        MediaDanmakuRegistry.copy(from: url, to: address)
        return address
    }

    static func parse(_ data: Data, base: URL, name: String) throws -> [String: JSONValue] {
        let reader = Reader(base: base, label: name)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.unsupported, reader.periods == 1, !reader.videos.isEmpty else {
            throw TVError.unsupported("此 DASH 播放清单暂不支持，需包含完整的视频及音频分段索引")
        }
        return ["video": .array(reader.videos.map(JSONValue.object)), "audio": .array(reader.audio.map(JSONValue.object)),
                "duration": .string(reader.duration)]
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let base: URL
        let label: String
        var videos: [[String: JSONValue]] = [], audio: [[String: JSONValue]] = []
        var periods = 0, unsupported = false
        var duration = "0"
        private var adaptation: [String: String] = [:]
        private var track: [String: String]?
        private var text = ""
        init(base: URL, label: String) { self.base = base; self.label = label }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "MPD":
                if attributes["type"] != "static" { unsupported = true }
                if let value = attributes["mediaPresentationDuration"],
                   let expression = try? NSRegularExpression(pattern: #"^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$"#),
                   let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) {
                    let units: [Double] = [3600, 60, 1]
                    let seconds = (1...3).reduce(0.0) { total, index in
                        guard let range = Range(match.range(at: index), in: value), let count = Double(value[range]) else { return total }
                        return total + count * units[index - 1]
                    }
                    duration = String(seconds)
                }
            case "Period": periods += 1
            case "AdaptationSet": adaptation = attributes
            case "Representation": track = adaptation.merging(attributes) { _, new in new }
            case "SegmentBase":
                track?["indexRange"] = attributes["indexRange"]
                if let offset = attributes["presentationTimeOffset"], offset != "0" { unsupported = true }
            case "Initialization":
                track?["initialization"] = attributes["range"]
                if attributes["sourceURL"] != nil { unsupported = true }
            case "ContentProtection", "SegmentTemplate", "SegmentList": unsupported = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "BaseURL", track != nil { track?["url"] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if name == "Representation", let fields = track {
                defer { track = nil }
                let mime = fields["mimeType"] ?? ""
                guard ["video/mp4", "audio/mp4"].contains(mime), let raw = fields["url"],
                      let url = URL(string: raw, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme ?? "") else {
                    unsupported = true; return
                }
                var result = fields.mapValues(JSONValue.string)
                result["id"] = .number(Double(Int(fields["id"] ?? "") ?? Int(fields["height"] ?? "") ?? 1))
                result["label"] = .string(label)
                result["urls"] = .array([.string(url.absoluteString)])
                guard Representation(result) != nil else { unsupported = true; return }
                if mime == "video/mp4" { videos.append(result) } else { audio.append(result) }
            }
        }
    }
}
