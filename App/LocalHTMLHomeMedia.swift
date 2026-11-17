import Foundation
import TVCore

/// Decode only this document's resource capability before media leaves WebKit.
/// Static MPD parsing remains the same strict TVCore parser used by playback.
enum LocalHTMLHomeMedia {
    static func unwrap(_ payload: [String: Any], resourceBase: String) throws -> [String: Any] {
        var result = payload
        let inherited = try LocalHTMLHomePolicy.headers(payload["headers"] as? [String: String] ?? [:])
        var mediaHeaders: [String: String]?
        for key in ["url", "mediaUrl", "audioUrl", "audioURL"] {
            guard let value = result[key] as? String else { continue }
            let normalized = try media(value, resourceBase: resourceBase)
            result[key] = normalized.url
            if let headers = normalized.headers {
                if let existing = mediaHeaders, canonical(existing) != canonical(headers) { throw LocalHTMLHomeError("该首页的音视频使用不同请求头，请在原页面选择其他播放方式。") }
                mediaHeaders = headers
            }
        }
        if let mediaHeaders {
            for (name, value) in inherited {
                if let expected = mediaHeaders.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value, expected != value {
                    throw LocalHTMLHomeError("首页媒体请求头冲突。")
                }
            }
            result["headers"] = mediaHeaders.merging(inherited) { _, rhs in rhs }
        }
        for key in ["pic", "vod_pic", "wallPic", "wallpaper", "poster"] {
            if let value = result[key] as? String, value.hasPrefix("yingxia-home:") { result[key] = try resource(value, base: resourceBase).url }
        }
        if let episodes = result["episodes"] as? [[String: Any]] { result["episodes"] = try episodes.map { try unwrap($0, resourceBase: resourceBase) } }
        return result
    }
    private static func canonical(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
    }
    private static func resource(_ value: String, base: String) throws -> (url: String, headers: [String: String]) {
        guard value.hasPrefix(base + "?"), let components = URLComponents(string: value) else { throw LocalHTMLHomeError("首页媒体资源凭证无效，请重新选择该媒体。") }
        let query = components.queryItems ?? []
        guard query.filter({ $0.name == "url" }).count == 1, query.filter({ $0.name == "headers" }).count <= 1,
              query.allSatisfy({ ["url", "headers"].contains($0.name) }), let url = query.first(where: { $0.name == "url" })?.value else { throw LocalHTMLHomeError("首页媒体资源地址无效。") }
        let address = try LocalHTMLHomePolicy.address(url)
        let text = query.first(where: { $0.name == "headers" })?.value ?? "{}"
        guard text.utf8.count <= 65536, let fields = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else { throw LocalHTMLHomeError("首页媒体资源请求头无效。") }
        return (address.absoluteString, try LocalHTMLHomePolicy.headers(fields))
    }
    private static func media(_ value: String, resourceBase: String) throws -> (url: String, headers: [String: String]?) {
        if value.hasPrefix("yingxia-home:") { let result = try resource(value, base: resourceBase); return (result.url, result.headers) }
        let prefix = "data:application/dash+xml;base64,"
        guard value.lowercased().hasPrefix(prefix) else { return (value, nil) }
        let encoded = String(value.dropFirst(prefix.count))
        guard encoded.utf8.count <= 350000, let data = Data(base64Encoded: encoded), data.count <= 256 * 1024,
              data.base64EncodedString() == encoded, var xml = String(data: data, encoding: .utf8), !xml.contains("<!") else { throw LocalHTMLHomeError("DASH 清单编码无效或超过 256 KiB。") }
        let collector = BaseURLs()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = collector
        guard parser.parse(), !collector.failed else { throw LocalHTMLHomeError("DASH 清单格式无效。") }
        var shared: [String: String]?
        for original in collector.values {
            let target: String, headers: [String: String]
            if original.hasPrefix("yingxia-home:") {
                let result = try resource(original, base: resourceBase)
                target = result.url; headers = result.headers
            } else { target = try LocalHTMLHomePolicy.address(original).absoluteString; headers = [:] }
            if let shared, canonical(shared) != canonical(headers) { throw LocalHTMLHomeError("该 DASH 清单的音视频使用不同请求头，暂不支持此播放方式。") }
            shared = headers
            // Replace decoded text only at BaseURL nodes, preserving the rest
            // of the XML for the strict parser to reject unexpected structure.
            xml = xml.replacingOccurrences(of: "<BaseURL>" + escape(original) + "</BaseURL>", with: "<BaseURL>" + escape(target) + "</BaseURL>")
        }
        let rewritten = prefix + Data(xml.utf8).base64EncodedString()
        _ = try HTMLHomePlayback.media(rewritten)
        return (rewritten, shared)
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private final class BaseURLs: NSObject, XMLParserDelegate {
        var values: [String] = [], failed = false
        private var reading = false, text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            if name == "BaseURL" { reading = true; text = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if reading { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if name == "BaseURL" { values.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); reading = false }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { failed = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { failed = true; parser.abortParsing(); return nil }
    }
}
