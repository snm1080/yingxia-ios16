#if os(iOS) || os(tvOS)
import CFNetwork
import Foundation

/// CatPawOpen (猫源) sources on iPhone, iPad and Apple TV. The app embeds nodejs-mobile (`Scripts/fetch-node-mobile.sh`)
/// and starts it once, the first time such a source is used: Node can't start twice in a process. It runs
/// `NodeHost/main.mjs`, the iOS twin of the Mac host's CatPawOpen mode, which starts each bundle once and
/// answers on a loopback port with a per-launch token.
public actor EmbeddedNodeHost {
    public static let shared = EmbeddedNodeHost()
    /// Only builds that embedded `Scripts/fetch-node-mobile.sh`'s output have Node.
    public static let available: Bool = {
        guard let frameworks = Bundle.main.privateFrameworksURL,
              Bundle.main.url(forResource: "main", withExtension: "mjs", subdirectory: "NodeHost") != nil else { return false }
        return FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("NodeMobile.framework/NodeMobile").path)
    }()
    private struct Control: Decodable { var port: Int?; var token: String?; var error: String? }
    private var control: Task<Control, Error>?
    private var relistening: Task<Control, Error>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 150
        configuration.connectionProxyDictionary = [:]
        // Eight shared-worker searches need eight loopback connections; retain
        // additional room for playback/services instead of URLSession's default six.
        configuration.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: configuration)
    }()
    private let sourceControlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 150
        configuration.connectionProxyDictionary = [:]
        // Completion/cancel long polls must not occupy the data connections whose
        // actual handlers they are waiting for. At most eight sources own permits.
        configuration.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: configuration)
    }()

    /// Portable MacCat services share the existing in-process Node and authenticated loopback channel.
    public func mediaService(_ method: String, params: [String: JSONValue] = [:], operationID: String = UUID().uuidString) async throws -> JSONValue {
        guard Self.available else { throw TVError.unsupported("此安装包缺少媒体服务运行库") }
        let input: [String: JSONValue] = ["service": .string(method), "params": .object(params), "operationId": .string(operationID)]
        let body = try JSONEncoder().encode(input)
        let control = try await start()
        let serviceTimeout: TimeInterval = method == "playback.prepare" ? 8 : method == "playback.release" ? 3 : 150
        return try await withTaskCancellationHandler {
            let answer: Data
            do { answer = try await send(body, to: control, timeout: serviceTimeout) }
            catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                answer = try await send(body, to: try await relisten(after: control), timeout: serviceTimeout)
            }
            try Task.checkCancellation()
            let envelope = try JSONDecoder().decode([String: JSONValue].self, from: answer)
            if let message = envelope["error"]?.string { throw TVError.unsupported(message) }
            return envelope["serviceResult"] ?? .null
        } onCancel: {
            Task { await self.cancelMediaOperation(operationID) }
        }
    }

    private func cancelMediaOperation(_ id: String) async {
        guard let control = try? await start(), let body = try? JSONEncoder().encode([
            "service": JSONValue.string("operation.cancel"), "params": .object(["id": .string(id)])
        ]) else { return }
        _ = try? await send(body, to: control)
    }

    public func request(site: Site, bundleURL: URL, params: [String: String], http: HTTPClient, origin: URL) async throws -> [String: JSONValue] {
        guard Self.available else {
            throw TVError.unsupported(L10n.text("This device can't run CatPawOpen sources."))
        }
        let data = try await PluginDownloads.shared.data(at: bundleURL, http: http)
        try Task.checkCancellation()
        // Each address keeps its own settings. The host reuses a small pool of idle bundles;
        // evicted workers restart with the same persisted profile on the next request.
        let key = LocalSourceLibrary.profileIdentity(at: bundleURL) ?? PluginChecksum.sha256(Data((bundleURL.absoluteString + "\n" + origin.absoluteString).utf8))
        let root = Self.storageRoot
        let bundle = try LocalSourceLibrary.localFile(at: bundleURL) ?? root.appendingPathComponent("Bundles/" + key + "-" + PluginChecksum.sha256(data) + ".js")
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: bundle.path) { try data.write(to: bundle, options: .atomic) }
        var params = params
        if let path = site.raw["catPawOpen"]?.string { params["catPawOpen"] = path }
        // Search, play and detail resolves run under a source operation, so
        // cancelling the caller's task fires cancelAndWait into Node and the
        // bundle's handler is told to stop instead of running to completion
        // for an episode the viewer has already left.
        let operationID = params["wd"] != nil || params["play"] != nil || params["ids"] != nil ? UUID().uuidString : nil
        var input: [String: JSONValue] = [
            "bundle": .string(bundle.path), "api": .string(bundleURL.absoluteString),
            "profile": .string(root.appendingPathComponent("Profiles/" + key).path),
            // Saved Quark/UC/Baidu sign-ins, which bundles with a config center take as their own.
            "cloudAccounts": .string(CloudDriveAccounts.fileURL.path),
            "proxy": Self.systemProxy(), "params": .object(params.mapValues(JSONValue.string)),
        ]
        if let operationID { input["operationId"] = .string(operationID) }
        let body = try JSONEncoder().encode(input)
        let kind = EmbeddedJarHost.kind(params)
        let started = ContinuousClock.now
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) node \(kind) begin")
        let control = try await self.start()
        let envelope: [String: JSONValue]
        do {
            let answer: Data
            do {
                if let operationID { answer = try await sendSource(body, to: control, operationID: operationID) }
                else { answer = try await send(body, to: control) }
            }
            catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                // iOS takes back a suspended app's listening sockets; Node then listens again on new ports.
                let fresh = try await relisten(after: control)
                if operationID != nil { answer = try await sendSource(body, to: fresh, operationID: UUID().uuidString) }
                else { answer = try await send(body, to: fresh) }
            }
            envelope = try JSONDecoder().decode([String: JSONValue].self, from: answer)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            Diagnostics.shared.record(.error, "jar.request", "source=\(site.key) node \(kind) failed duration=\(started.duration(to: .now)) error=\(error.localizedDescription)")
            throw error
        }
        if let message = PluginFailure.message(envelope) {
            Diagnostics.shared.record(.error, "jar.request", "source=\(site.key) node \(kind) failed duration=\(started.duration(to: .now)) error=\(message)")
            throw TVError.unsupported(message)
        }
        guard let text = envelope["result"]?.string, !text.isEmpty else {
            throw TVError.unsupported(L10n.text("The plugin returned no content. Try another source."))
        }
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) node \(kind) complete duration=\(started.duration(to: .now)) bytes=\(text.utf8.count)")
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }

    /// A bundle's media proxy address at the port the bundle listens on now. iOS takes back a suspended app's listening
    /// sockets and Node then listens again on new ports, so an episode that was playing when the screen went off can't
    /// reach its address any more (#485). Nil when the address is still current, or Node can't say.
    public func relocate(_ url: URL) async -> URL? {
        guard Self.available, let control = try? await start(),
              let body = try? JSONEncoder().encode(["relocate": url.absoluteString]) else { return nil }
        let answer: Data
        do { answer = try await send(body, to: control) }
        catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            guard let fresh = try? await relisten(after: control), let data = try? await send(body, to: fresh) else { return nil }
            answer = data
        } catch { return nil }
        guard let envelope = try? JSONDecoder().decode([String: JSONValue].self, from: answer),
              let address = envelope["result"]?.string, let moved = URL(string: address), moved.port != url.port else { return nil }
        Diagnostics.shared.record(.info, "node.start", "media proxy moved from port \(url.port ?? 0) to \(moved.port ?? 0)")
        return moved
    }

    /// The selected player's local proxy stays owned while paused; stop or replacement
    /// releases this lease. Old and rebound source ports resolve to the same worker.
    public func setPlaybackPinned(_ url: URL, pinned: Bool) async -> Bool {
        guard Self.available, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? ""),
              let control = try? await start(),
              let body = try? JSONEncoder().encode(["sourcePlayback": JSONValue.string(url.absoluteString), "pinned": .bool(pinned)]) else { return false }
        let answer: Data
        do { answer = try await send(body, to: control) }
        catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            guard let fresh = try? await relisten(after: control), let data = try? await send(body, to: fresh) else { return false }
            answer = data
        } catch { return false }
        let response = try? JSONDecoder().decode([String: JSONValue].self, from: answer)
        return response?["applied"] == .bool(true)
    }

    private func send(_ body: Data, to control: Control, timeout: TimeInterval = 150, controlOnly: Bool = false) async throws -> Data {
        guard let port = control.port, let token = control.token else {
            throw TVError.unsupported(control.error ?? L10n.text("The CatPawOpen runtime stopped. Quit and reopen the app to use these sources."))
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/call")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-yingxia-token")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        let transport = controlOnly ? sourceControlSession : session
        return try await transport.data(for: request).0
    }

    /// A cancelled URLSession request closes its socket before Node's source handler
    /// necessarily exits. Keep the caller's real admission slot until Node acknowledges
    /// that handler/HTTP cleanup finished. Detached cleanup does not inherit cancellation.
    private func sendSource(_ body: Data, to control: Control, operationID: String) async throws -> Data {
        try Task.checkCancellation()
        var input = try JSONDecoder().decode([String: JSONValue].self, from: body)
        input["operationId"] = .string(operationID)
        let tagged = try JSONEncoder().encode(input)
        return try await withTaskCancellationHandler {
            do {
                let answer = try await send(tagged, to: control)
                try await Task.detached { try await self.waitForSourceCompletion(operationID, control: control, cancel: false) }.value
                try Task.checkCancellation()
                return answer
            } catch {
                await cancelSource(operationID, control: control)
                throw error
            }
        } onCancel: {
            Task.detached { await self.cancelSource(operationID, control: control) }
        }
    }

    private func cancelSource(_ id: String, control: Control) async {
        _ = try? await Task.detached { try await self.waitForSourceCompletion(id, control: control, cancel: true) }.value
    }

    private func waitForSourceCompletion(_ id: String, control: Control, cancel: Bool) async throws {
        let input: [String: JSONValue] = ["sourceOperation": .string(cancel ? "cancelAndWait" : "wait"), "operationId": .string(id)]
        let body = try JSONEncoder().encode(input)
        var current = control
        while true {
            do {
                let answer = try await send(body, to: current, controlOnly: true)
                let envelope = try JSONDecoder().decode([String: JSONValue].self, from: answer)
                if envelope["completed"] == .bool(true) { return }
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                if let fresh = try? await relisten(after: current) { current = fresh }
            } catch {
                // A long-poll transport deadline says nothing about the actual source
                // worker. Retry this single waiter while retaining its admission slot.
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Starts Node at most once; a failed start stays failed until the app relaunches.
    private func start() async throws -> Control {
        if let control { return try await control.value }
        let task = Task.detached { try await Self.launch() }
        control = task
        return try await task.value
    }

    /// The control port found refusing: requests that fail together share one relisten.
    private func relisten(after stale: Control) async throws -> Control {
        if let current = try await control?.value, current.port != stale.port { return current }
        let task = relistening ?? Task.detached { try await Self.relisten(from: stale) }
        relistening = task
        defer { relistening = nil }
        let fresh = try await task.value
        control = Task { fresh }
        return fresh
    }

    private static func relisten(from stale: Control) async throws -> Control {
        let file = storageRoot.appendingPathComponent("control.json")
        func current() -> Control? {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Control.self, from: $0) }
        }
        if let control = current(), control.port != stale.port { return control }
        Diagnostics.shared.record(.warning, "node.start", "port \(stale.port ?? 0) refused; asking Node to listen again")
        let handle = try FileHandle(forWritingTo: relistenFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if let control = current(), control.port != stale.port {
                Diagnostics.shared.record(.info, "node.start", "listening again on port \(control.port ?? 0)")
                return control
            }
        }
        Diagnostics.shared.record(.error, "node.start", "Node did not listen again within 5 s")
        return Control(error: L10n.text("The CatPawOpen runtime stopped. Quit and reopen the app to use these sources."))
    }

    /// The HTTP proxy set in Settings > Wi-Fi, which Node's own sockets would bypass. A proxy set by a PAC file
    /// isn't followed; a VPN-style proxy app needs nothing, since iOS routes Node's sockets through it.
    private static func systemProxy() -> JSONValue {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return .null }
        for scheme in ["HTTPS", "HTTP"] {
            guard settings[scheme + "Enable"] as? Int == 1, let host = settings[scheme + "Proxy"] as? String, !host.isEmpty,
                  let port = settings[scheme + "Port"] as? Int else { continue }
            let exceptions = (settings["ExceptionsList"] as? [String] ?? []).map(JSONValue.string)
            return .object(["host": .string(host), "port": .number(Double(port)), "exceptions": .array(exceptions)])
        }
        return .null
    }

    private static func launch() async throws -> Control {
        typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        guard let main = Bundle.main.url(forResource: "main", withExtension: "mjs", subdirectory: "NodeHost"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("NodeMobile.framework/NodeMobile"),
              let handle = dlopen(library.path, RTLD_NOW), let symbol = dlsym(handle, "node_start") else {
            let reason = dlerror().map { String(cString: $0) } ?? "missing files"
            Diagnostics.shared.record(.error, "node.start", reason)
            return Control(error: L10n.text("This device can't run CatPawOpen sources."))
        }
        let nodeStart = unsafeBitCast(symbol, to: NodeStart.self)
        let file = storageRoot.appendingPathComponent("control.json")
        try? FileManager.default.removeItem(at: file)
        // Node watches this file; it has to exist first.
        FileManager.default.createFile(atPath: relistenFile.path, contents: nil)
        // Node 26 decrypts RSA PKCS#1 v1.5 (瓜子 signs in with it) through OpenSSL's implicit rejection, so it
        // needs no --security-revert, which it would refuse as an unknown CVE.
        let arguments = ["node", main.path, file.path, relistenFile.path]
        let thread = Thread {
            // node_start expects its arguments in one contiguous block that lives as long as Node.
            let strings = arguments.map { Array($0.utf8CString) }
            let block = UnsafeMutablePointer<CChar>.allocate(capacity: strings.reduce(0) { $0 + $1.count })
            var argv: [UnsafeMutablePointer<CChar>?] = []
            var offset = 0
            for string in strings {
                (block + offset).initialize(from: string, count: string.count)
                argv.append(block + offset)
                offset += string.count
            }
            argv.append(nil)
            let status = argv.withUnsafeMutableBufferPointer { nodeStart(Int32(arguments.count), $0.baseAddress) }
            Diagnostics.shared.record(.error, "node.start", "Node exited with status \(status)")
            let stopped = ["error": L10n.text("The CatPawOpen runtime stopped. Quit and reopen the app to use these sources.")]
            try? JSONEncoder().encode(stopped).write(to: file, options: .atomic)
        }
        thread.name = "nodejs"
        thread.stackSize = 2 << 20
        thread.start()
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: file), let control = try? JSONDecoder().decode(Control.self, from: data) {
                Diagnostics.shared.record(.info, "node.start", control.error == nil ? "ready" : "stopped")
                return control
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Diagnostics.shared.record(.error, "node.start", "Node did not start within 30 s")
        return Control(error: L10n.text("The CatPawOpen runtime stopped. Quit and reopen the app to use these sources."))
    }

    private static let relistenFile = storageRoot.appendingPathComponent("relisten")

    /// Bundles download again on demand, but profiles hold their settings (sign-ins among them), so they stay
    /// out of purgeable Caches. Apple TV apps can only write to Caches.
    static let storageRoot: URL = {
        let manager = FileManager.default
        #if os(tvOS)
        let directory = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let directory = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif
        let root = manager.urls(for: directory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/EmbeddedNode", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return root
    }()
}
#endif
