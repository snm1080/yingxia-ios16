import Foundation

/// Native fallback and the bridge to the same play-result rules used by MacCat.
enum PlaybackNormalization {
    static func payload(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var value = input
        for _ in 0..<4 {
            var fields: [String: JSONValue]?
            for key in ["data", "result", "play"] {
                var nested = value[key]
                if let text = nested?.string, let data = text.data(using: .utf8) { nested = try? JSONDecoder().decode(JSONValue.self, from: data) }
                if let object = nested?.object { fields = object; break }
            }
            guard let fields else { break }
            for key in ["data", "result", "play"] { value.removeValue(forKey: key) }
            value.merge(fields) { _, new in new }
        }
        return value
    }

    static func choices(result: [String: JSONValue], request: [String: JSONValue], headers: [String: String], baseURL: URL, name: String) async throws -> [PlaybackChoice] {
        let fields = payload(result)
        var normalized: [String: JSONValue]?
        #if os(iOS) || os(tvOS)
        if EmbeddedNodeHost.available {
            normalized = try await MobileMediaServices.call("playback.normalize", ["result": .object(result), "request": .object(request),
                "baseURL": .string(baseURL.absoluteString), "episodeName": .string(name)]).object
            try Task.checkCancellation()
        }
        #endif
        let resultJSON = json(.object(result)), requestJSON = json(.object(request))
        let extra = fields["extra"]?.object ?? [:]
        let threadValues: [JSONValue?] = [normalized?["threadCount"], fields["threads"], fields["thread"], extra["threads"]]
        let threadCount: Int? = threadValues.lazy.compactMap { $0?.int }.first
        let sharedAudioValues: [JSONValue?] = [normalized?["audioUrl"], fields["audio"], fields["audioUrl"], fields["audio_url"], extra["audio"], extra["audio_url"]]
        let sharedAudio: String? = firstString(sharedAudioValues)
        let format: String = firstString([fields["format"], extra["format"]]) ?? ""
        let proxy: String? = firstString([normalized?["proxy"], fields["proxy"]])
        func resolve(_ text: String?) -> URL? {
            guard let text, !text.isEmpty else { return nil }
            return try? MediaAddress.resolve(text.replacingOccurrences(of: "js2p://_WEB_", with: baseURL.absoluteString), relativeTo: baseURL)
        }
        func choice(_ index: Int, _ title: String, _ address: String, _ item: [String: JSONValue] = [:]) -> PlaybackChoice {
            let sourceHeaders: [String: String] = Self.headers(item["headers"] ?? item["header"])
            let payloadHeaders = Self.headers(fields["headers"] ?? fields["header"])
            let itemHeaders: [String: String] = headers.merging(payloadHeaders) { _, new in new }.merging(sourceHeaders) { _, new in new }
            let audioAddress: String? = firstString([item["audioUrl"], item["audio"], item["audio_url"]]) ?? sharedAudio
            let audio: URL? = resolve(audioAddress)
            let sharedAudioHeaders: [String: String] = Self.headers(fields["audioHeaders"])
            let specificAudioHeaders: [String: String] = Self.headers(item["audioHeaders"])
            var audioHeaders: [String: String] = itemHeaders.merging(sharedAudioHeaders) { _, new in new }
            audioHeaders.merge(specificAudioHeaders) { _, new in new }
            let resolvedAddress: URL? = resolve(address)
            let pathExtension: String? = resolvedAddress.flatMap { $0.pathExtension.isEmpty ? nil : $0.pathExtension }
            let inferredFormat: String = item["format"]?.string ?? pathExtension ?? format
            let descriptor = PlaybackDescriptor(format: inferredFormat.lowercased(), audioURL: audio, audioHeaders: audioHeaders,
                proxyURL: resolve(proxy), threadCount: threadCount.flatMap { $0 > 0 ? $0 : nil }, discPlaylist: normalized?["discPlaylist"]?.int,
                requestJSON: requestJSON, resultJSON: resultJSON,
                isLive: normalized?["isLive"] == .bool(true) || PlaybackSourceContext.isLive(route: "", fields: fields)
                    || PlaybackSourceContext.isLive(route: request["siteAPI"]?.string ?? "", fields: request))
            return PlaybackChoice(id: index, name: title.isEmpty ? name : title, address: resolvedAddress?.absoluteString ?? address,
                headers: itemHeaders, playback: descriptor)
        }
        if let qualities = normalized?["qualities"]?.array {
            return qualities.enumerated().compactMap { index, entry in
                guard let item = entry.object, let address = item["url"]?.string, !address.isEmpty else { return nil }
                return choice(index, item["name"]?.string ?? name, address, item)
            }
        }
        let raw = ["url", "urls", "play_url", "link", "src", "m3u8"].compactMap { fields[$0] }.first {
            $0.string?.isEmpty == false || $0.array?.isEmpty == false || $0.object?.isEmpty == false
        }
        if let address = raw?.string { return [choice(0, name, address)] }
        if let object = raw?.object {
            if let address = object["url"]?.string ?? object["link"]?.string ?? object["src"]?.string {
                return [choice(0, object["name"]?.string ?? name, address, object)]
            }
            return object.keys.sorted().enumerated().compactMap { index, label in object[label]?.string.map { choice(index, label, $0) } }
        }
        guard let array = raw?.array else { return [] }
        if array.count == 1, let address = array[0].string { return [choice(0, name, address)] }
        if array.allSatisfy({ $0.string != nil }) {
            return stride(from: 0, to: array.count - array.count % 2, by: 2).compactMap { index in
                guard let title = array[index].string, let address = array[index + 1].string else { return nil }
                return choice(index / 2, title, address)
            }
        }
        return array.enumerated().compactMap { index, entry in
            guard let item = entry.object, let address = item["url"]?.string ?? item["link"]?.string ?? item["src"]?.string else { return nil }
            return choice(index, item["name"]?.string ?? item["label"]?.string ?? name, address, item)
        }
    }

    private static func firstString(_ values: [JSONValue?]) -> String? {
        for value in values {
            if let text = value?.string { return text }
        }
        return nil
    }

    static func headers(_ value: JSONValue?) -> [String: String] {
        var fields = value?.object
        if fields == nil, let text = value?.string, let data = text.data(using: .utf8) { fields = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object }
        return (fields ?? [:]).compactMapValues(\.string).filter { key, value in
            !["host", "connection", "content-length", "transfer-encoding"].contains(key.lowercased()) && !value.contains("\r") && !value.contains("\n")
        }
    }
    static func json(_ value: JSONValue) -> String? { (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } }
}
