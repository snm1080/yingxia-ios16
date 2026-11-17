import Foundation
import Network
import TVDisc

public struct DiscPlaybackChapter: Equatable, Sendable {
    public let title: String
    public let time: Double
}
public struct DiscPlaybackTitle: Equatable, Sendable {
    public let playlist: UInt32
    public let duration: Double
    public var chapterCount: Int? = nil
}

/// Main-title playback only. Disc recognition routes to a real UDF/MPLS reader;
/// open fails when the source lacks random reads or contains no usable title.
public enum DiscPlayback {
    public static func canHandle(url: URL, format: String? = nil) -> Bool {
        if ["iso", "udf", "bdmv", "mpls", "bluray"].contains(format?.lowercased() ?? "") { return true }
        if ["iso", "udf", "bdmv", "mpls"].contains(url.pathExtension.lowercased()) { return true }
        guard url.isFileURL else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("BDMV").path, isDirectory: &directory) && directory.boolValue
            || url.lastPathComponent.uppercased() == "BDMV" && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    public static func prepare(url: URL, headers: [String: String] = [:], playlist: UInt32? = nil) async throws -> DiscPlaybackResource {
        let cancellation = DiscCancellation()
        return try await withTaskCancellationHandler {
            let source = try await Task.detached(priority: .userInitiated) {
                try NativeDiscSource.open(url: url, headers: headers, playlist: playlist, cancellation: cancellation)
            }.value
            do {
                try cancellation.check()
                let server = DiscStreamServer(source: source)
                let address = try await server.start(cancellation: cancellation)
                try cancellation.check()
                return DiscPlaybackResource(playbackURL: address, source: source, server: server)
            } catch { source.close(); throw error }
        } onCancel: { cancellation.cancel() }
    }
}

/// The session retains this for as long as KSPlayer can request the local URL.
/// close interrupts outstanding upstream reads before destroying native state.
public final class DiscPlaybackResource: @unchecked Sendable {
    public let playbackURL: URL
    public let duration: Double
    public let playlist: UInt32
    public let chapters: [DiscPlaybackChapter]
    public let titles: [DiscPlaybackTitle]
    public var isAvailable: Bool { server.isAvailable }
    private let source: NativeDiscSource
    private let server: DiscStreamServer
    fileprivate init(playbackURL: URL, source: NativeDiscSource, server: DiscStreamServer) {
        self.playbackURL = playbackURL; self.source = source; self.server = server
        duration = source.duration; playlist = source.playlist; chapters = source.chapters; titles = source.titles
    }
    public func close() { server.close(); source.close() }
    deinit { close() }
}

private let readDiscBlocks: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32) -> Int32 = { context, buffer, lba, blocks in
    guard let context, let buffer else { return -1 }
    return Unmanaged<NativeDiscSource>.fromOpaque(context).takeUnretainedValue().readBlocks(buffer: buffer, lba: lba, count: blocks)
}

private final class NativeDiscSource: @unchecked Sendable {
    private let io = NSLock(), errors = NSLock()
    private var handle: OpaquePointer?
    private var remote: HttpRangeDiscSource?
    private let cancellation: DiscCancellation
    private var readCancellation: DiscCancellation
    private var observation: UUID?
    private var failure: DiscError?
    private(set) var size: Int64 = 0
    private(set) var playlist: UInt32 = 0
    private(set) var duration: Double = 0
    private(set) var chapters: [DiscPlaybackChapter] = []
    private(set) var titles: [DiscPlaybackTitle] = []
    private init(cancellation: DiscCancellation) { self.cancellation = cancellation; readCancellation = cancellation }

    static func open(url: URL, headers: [String: String], playlist: UInt32?, cancellation: DiscCancellation) throws -> NativeDiscSource {
        try cancellation.check()
        if let playlist, playlist > 99999 { throw DiscError.playlistNotFound(Int(playlist)) }
        let disc = NativeDiscSource(cancellation: cancellation)
        guard let handle = tvd_create() else { throw DiscError.libraryUnavailable }
        disc.handle = handle
        var requested = playlist
        let opened: Int32
        if url.isFileURL {
            var local = url.standardizedFileURL
            let ext = local.pathExtension.lowercased()
            if ext == "mpls" {
                requested = requested ?? UInt32(local.deletingPathExtension().lastPathComponent)
                local.deleteLastPathComponent(); local.deleteLastPathComponent()
            } else if ext == "bdmv" { local.deleteLastPathComponent() }
            if local.lastPathComponent.uppercased() == "BDMV" { local.deleteLastPathComponent() }
            opened = local.path.withCString { tvd_open_path(handle, $0) }
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            guard !["bdmv", "mpls"].contains(url.pathExtension.lowercased()) else { throw DiscError.remoteDirectory }
            let source = try HttpRangeDiscSource(url: url, headers: headers)
            disc.remote = source
            disc.observation = cancellation.observe { [weak source] in source?.cancel() }
            opened = tvd_open_stream(handle, Unmanaged.passUnretained(disc).toOpaque(), readDiscBlocks)
        } else { throw DiscError.invalidURL }
        try cancellation.check()
        if tvd_is_encrypted(handle) != 0 { throw DiscError.encryptedDisc }
        guard opened != 0 else { throw disc.readError ?? .invalidDisc }
        let count = tvd_title_count(handle)
        guard count <= 10000 else { throw DiscError.invalidDisc }
        var choices: [(title: DiscPlaybackTitle, looped: Bool)] = []
        var seen = Set<UInt32>()
        for index in 0..<count {
            try cancellation.check()
            var info = tvd_title_info()
            if tvd_title(handle, index, &info) != 0, info.valid != 0, seen.insert(info.playlist).inserted {
                choices.append((DiscPlaybackTitle(playlist: info.playlist, duration: Double(info.duration) / 90000,
                                                  chapterCount: Int(info.chapters)), info.looped != 0))
            }
        }
        if let failure = disc.readError { throw failure }
        // Match MacCat: non-looping films first, duration descending, stable MPLS tie break.
        choices.sort {
            if $0.looped != $1.looped { return !$0.looped }
            return $0.title.duration == $1.title.duration ? $0.title.playlist < $1.title.playlist : $0.title.duration > $1.title.duration
        }
        disc.titles = choices.map(\.title)
        guard let longest = disc.titles.first else { throw DiscError.noTitles }
        let selected = requested ?? longest.playlist
        guard let title = disc.titles.first(where: { $0.playlist == selected }), tvd_select(handle, selected) != 0 else { throw DiscError.playlistNotFound(Int(selected)) }
        let length = tvd_size(handle)
        guard length > 0, length <= UInt64(Int64.max) else { throw DiscError.invalidDisc }
        disc.playlist = selected; disc.duration = title.duration; disc.size = Int64(length)
        var index: UInt32 = 0, start: UInt64 = 0
        while index < 100000, tvd_chapter(handle, index, &start) != 0 {
            let time = Double(start) / 90000
            if time < title.duration { disc.chapters.append(DiscPlaybackChapter(title: "章节 \(index + 1)", time: time)) }
            index += 1
        }
        try cancellation.check()
        return disc
    }

    private var readError: DiscError? { errors.lock(); defer { errors.unlock() }; return failure }
    func readBlocks(buffer: UnsafeMutableRawPointer, lba: Int32, count: Int32) -> Int32 {
        guard readError == nil, lba >= 0, count >= 0, let remote else { return -1 }
        do {
            try cancellation.check(); try readCancellation.check()
            let total = Int(count) * 2048
            var copied = 0
            while copied < total {
                let bytes = try remote.read(offset: Int64(lba) * 2048 + Int64(copied), count: min(total - copied, HttpRangeDiscSource.pageSize), cancellation: readCancellation)
                guard !bytes.isEmpty else { break }
                bytes.copyBytes(to: buffer.advanced(by: copied).assumingMemoryBound(to: UInt8.self), count: bytes.count)
                copied += bytes.count
            }
            return Int32(copied / 2048)
        } catch {
            if error as? DiscError != .cancelled { errors.lock(); failure = error as? DiscError ?? .network; errors.unlock() }
            return -1
        }
    }
    func read(offset: Int64, count: Int, cancellation request: DiscCancellation) throws -> Data {
        io.lock(); defer { readCancellation = cancellation; io.unlock() }
        try cancellation.check(); try request.check()
        guard let handle, offset >= 0, count > 0, count <= 256 * 1024 else { throw DiscError.closed }
        if let failure = readError { throw failure }
        readCancellation = request
        var bytes = Data(count: count)
        let n = bytes.withUnsafeMutableBytes { tvd_read_at(handle, UInt64(offset), $0.bindMemory(to: UInt8.self).baseAddress, Int32(count)) }
        try cancellation.check(); try request.check()
        if let failure = readError { throw failure }
        guard n >= 0 else { throw DiscError.invalidDisc }
        bytes.count = Int(n)
        return bytes
    }
    func close() {
        cancellation.cancel(); remote?.cancel()
        io.lock(); defer { io.unlock() }
        if let handle { tvd_close(handle); self.handle = nil }
        if let observation { cancellation.remove(observation); self.observation = nil }
    }
    deinit { close() }
}

/// A bounded loopback stream: each send waits for its preceding 256 KiB chunk.
/// Multiple seeks share a serialized native reader and use independent cancel tokens.
private final class DiscStreamServer: @unchecked Sendable {
    private let source: NativeDiscSource
    private let token = UUID().uuidString.lowercased()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "yingxia.disc.http", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    init(source: NativeDiscSource) { self.source = source }
    var isAvailable: Bool { lock.withLock { !stopped && listener?.state == .ready } }

    func start(cancellation: DiscCancellation) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) ?? connection.cancel() }
        let ready = OneShot<URL>()
        let observation = cancellation.observe { [weak self] in self?.close(); ready.resume(.failure(DiscError.cancelled)) }
        defer { cancellation.remove(observation) }
        return try await withCheckedThrowingContinuation { continuation in
            ready.set(continuation)
            if cancellation.isCancelled { ready.resume(.failure(DiscError.cancelled)); return }
            listener.stateUpdateHandler = { [weak listener, token] state in
                switch state {
                case .ready:
                    guard let port = listener?.port else { return }
                    ready.resume(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/title.m2ts")!))
                case .failed(let error): ready.resume(.failure(error))
                case .cancelled: ready.resume(.failure(DiscError.cancelled))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection), request = DiscCancellation()
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }; clients[id] = connection; return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state { request.cancel(); self?.removeClient(id) }
            else if case .failed = state { request.cancel(); self?.removeClient(id); connection?.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, bytes: Data(), cancellation: request)
    }
    private func removeClient(_ id: ObjectIdentifier) { _ = lock.withLock { clients.removeValue(forKey: id) } }
    private func receive(_ connection: NWConnection, bytes: Data, cancellation: DiscCancellation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = bytes
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { serve(connection, bytes: buffer, cancellation: cancellation) }
            else if complete || error != nil || buffer.count >= 16384 { connection.cancel() }
            else { receive(connection, bytes: buffer, cancellation: cancellation) }
        }
    }
    private func serve(_ connection: NWConnection, bytes: Data, cancellation: DiscCancellation) {
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" || fields[0] == "HEAD" else { respond(connection, status: 405); return }
        guard fields[1] == "/\(token)/title.m2ts" else { respond(connection, status: 404); return }
        let size = source.size
        var start: Int64 = 0, end = size - 1, status = 200
        if let header = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bytes="), !value.contains(",") else { respond(connection, status: 416, extra: "Content-Range: bytes */\(size)\r\n"); return }
            let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2 else { respond(connection, status: 416); return }
            if parts[0].isEmpty {
                guard let suffix = Int64(parts[1]), suffix > 0 else { respond(connection, status: 416); return }
                start = max(0, size - suffix)
            } else {
                guard let low = Int64(parts[0]), low >= 0 else { respond(connection, status: 416); return }
                start = low
                if !parts[1].isEmpty {
                    guard let high = Int64(parts[1]) else { respond(connection, status: 416); return }
                    end = min(end, high)
                }
            }
            guard start <= end, start < size else { respond(connection, status: 416, extra: "Content-Range: bytes */\(size)\r\n"); return }
            status = 206
        }
        let extra = status == 206 ? "Content-Range: bytes \(start)-\(end)/\(size)\r\n" : ""
        let header = Self.header(status: status, length: end - start + 1, extra: extra)
        let lower = start, upper = end
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, fields[0] != "HEAD", let self else { connection.cancel(); return }
            pump(connection, offset: lower, end: upper, cancellation: cancellation)
        })
    }
    private func pump(_ connection: NWConnection, offset: Int64, end: Int64, cancellation: DiscCancellation) {
        guard offset <= end, !cancellation.isCancelled else { connection.cancel(); return }
        do {
            let data = try source.read(offset: offset, count: Int(min(256 * 1024, end - offset + 1)), cancellation: cancellation)
            guard !data.isEmpty else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { connection.cancel(); return }
                pump(connection, offset: offset + Int64(data.count), end: end, cancellation: cancellation)
            })
        } catch { cancellation.cancel(); connection.cancel() }
    }
    private static func header(status: Int, length: Int64, extra: String = "") -> String {
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable"][status] ?? "Error"
        return "HTTP/1.1 \(status) \(reason)\r\nContent-Type: video/mp2t\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
    }
    private func respond(_ connection: NWConnection, status: Int, extra: String = "") {
        connection.send(content: Data(Self.header(status: status, length: 0, extra: extra).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    func close() {
        let snapshot = lock.withLock { () -> (NWListener?, [NWConnection]) in
            stopped = true
            let snapshot = (listener, Array(clients.values)); listener = nil; clients.removeAll()
            return snapshot
        }
        snapshot.0?.cancel(); snapshot.1.forEach { $0.cancel() }
    }
    deinit { close() }
}
