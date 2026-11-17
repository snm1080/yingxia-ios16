import Foundation
import CryptoKit
import Compression
import zlib

public enum LocalSourceGroup: String, Codable, Sendable, CaseIterable {
    case subscription, python
    public var title: String { self == .python ? "Python" : "订阅" }
}

/// Portable identity addresses use a reserved host, never an app-container path.
public struct LocalSourceRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let group: LocalSourceGroup
    public let format: String
    public let version: String
    public let entry: String?
    public let input: [URL]
    /// Durable document-provider grants; nil for remote URLs and migrated records.
    public let bookmarks: [Data?]?
    public let name: String
    public let importedAt: Date
    public let updatedAt: Date
    public var address: URL { URL(string: "https://sources.yingxia.invalid/\(id)/subscription")! }
    public func directory(in root: URL) -> URL { root.appendingPathComponent("\(id)/versions/\(version)", isDirectory: true) }
    public func asset(_ name: String) -> URL {
        var value = URLComponents(); value.scheme = "https"; value.host = "sources.yingxia.invalid"
        value.path = "/\(id)/\(version)/\(name)"; return value.url!
    }
}

public struct PreparedLocalSources: Sendable {
    public let records: [LocalSourceRecord]
    fileprivate let directory: URL
    /// Calls the existing embedded Node bundle protocol, or publishes each validated Python entry.
    /// Commit only after all runtime configurations load, so failed refreshes retain their old copy.
    public func subscriptions(http: HTTPClient) async throws -> [Subscription] {
        try await records.asyncMap { record in
            if record.format == "bundle" {
                return try await CatPawOpen.subscription(bundle: record.asset("index.js"), origin: record.address, http: http)
            }
            if record.format == "python", let entry = record.entry {
                let api = record.asset(entry).absoluteString
                let raw: [String: JSONValue] = ["key": .string(record.id), "name": .string(record.name), "type": .number(3), "api": .string(api), "searchable": .number(1), "filterable": .number(1)]
                let site = Site(key: record.id, name: record.name, type: 3, api: api, raw: raw)
                return Subscription(origin: record.address, importedAt: record.updatedAt, sites: [site], lives: [], raw: ["sites": .array([.object(raw)])])
            }
            let bytes = try Data(contentsOf: record.directory(in: directory).appendingPathComponent("subscription.json"))
            return try await Subscription.parse(bytes, origin: record.asset("subscription.json")).sniffingScripts(http: http)
        }
    }
}

public actor LocalSourceLibrary {
    public static let shared = LocalSourceLibrary(directory: storageRoot)
    public static var storageRoot: URL {
        #if os(tvOS)
        URL.cachesDirectory.appendingPathComponent("LocalSources", isDirectory: true)
        #else
        URL.applicationSupportDirectory.appendingPathComponent("LocalSources", isDirectory: true)
        #endif
    }
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func records() throws -> [LocalSourceRecord] {
        let file = directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([LocalSourceRecord].self, from: Data(contentsOf: file))
    }
    /// Back up only manifest-listed source files. Mutable runtime profiles,
    /// cookies, credentials and external file bookmarks do not travel.
    public func backupSources(portable: Bool = true) throws -> [LocalBackupSource] {
        try records().map { record in
            let root = record.directory(in: directory)
            let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            guard let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                  let hashes = object["sha256"] as? [String: String] else { throw LocalBackupArchive.Failure.invalid }
            var files = ["manifest.json": manifest]
            for (name, hash) in hashes {
                guard LocalBackupArchive.safePath(name) else { throw LocalBackupArchive.Failure.invalid }
                let file = root.appendingPathComponent(name)
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LocalBackupArchive.Failure.invalid }
                let data = try Data(contentsOf: file)
                guard PluginChecksum.sha256(data) == hash else { throw LocalBackupArchive.Failure.checksum }
                files[name] = data
            }
            let data: Data
            if portable {
                let clean = LocalSourceRecord(id: record.id, group: record.group, format: record.format, version: record.version,
                    entry: record.entry, input: record.input.filter { !$0.isFileURL }, bookmarks: nil, name: record.name,
                    importedAt: record.importedAt, updatedAt: record.updatedAt)
                data = try LocalBackupArchive.portable(JSONEncoder().encode(clean))
            } else { data = try JSONEncoder().encode(record) }
            return LocalBackupSource(record: data, files: files)
        }
    }
    public static func validateBackupSources(_ sources: [LocalBackupSource]) throws -> [LocalSourceRecord] {
        guard sources.count <= 200 else { throw LocalBackupArchive.Failure.invalid }
        var ids = Set<String>()
        return try sources.map { source in
            let record = try JSONDecoder().decode(LocalSourceRecord.self, from: source.record)
            guard record.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  record.version.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  ids.insert(record.id).inserted, ["bundle", "python", "tvbox"].contains(record.format),
                  source.files.count <= 1000, source.files.keys.allSatisfy(LocalBackupArchive.safePath),
                  source.files.values.reduce(0, { $0 + $1.count }) <= 90 * 1024 * 1024,
                  let manifest = source.files["manifest.json"],
                  let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                  object["version"] as? String == record.version, object["engine"] as? String == record.format,
                  let hashes = object["sha256"] as? [String: String], !hashes.isEmpty,
                  Set(source.files.keys) == Set(hashes.keys).union(["manifest.json"]),
                  hashes.allSatisfy({ name, expected in source.files[name].map { PluginChecksum.sha256($0) == expected } ?? false }) else { throw LocalBackupArchive.Failure.invalid }
            let signature = hashes.keys.sorted().map { $0 + "\0" + hashes[$0]! }.joined(separator: "\n")
            guard PluginChecksum.sha256(Data(signature.utf8)) == record.version,
                  record.entry == nil || source.files[record.entry!] != nil else { throw LocalBackupArchive.Failure.checksum }
            return record
        }
    }
    /// All archives are validated before any files are written. Versioned
    /// directories stay immutable; replacing the index keeps old files for undo.
    public func restoreBackupSources(_ sources: [LocalBackupSource], replacing: Bool) throws {
        let imported = try Self.validateBackupSources(sources)
        var next = replacing ? [] : try records()
        for (source, record) in zip(sources, imported) {
            if !replacing && next.contains(where: { $0.id == record.id }) { continue }
            let target = record.directory(in: directory)
            if FileManager.default.fileExists(atPath: target.path) {
                guard source.files.allSatisfy({ (try? Data(contentsOf: target.appendingPathComponent($0.key))) == $0.value }) else { throw LocalBackupArchive.Failure.checksum }
            } else {
                let staging = directory.appendingPathComponent(".restore-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                for (name, data) in source.files {
                    let file = staging.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: staging, to: target)
            }
            next.removeAll { $0.id == record.id }; next.append(record)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
    public func commit(_ prepared: PreparedLocalSources) throws {
        var saved = try records()
        for value in prepared.records {
            if let at = saved.firstIndex(where: { $0.id == value.id }) { saved[at] = value } else { saved.append(value) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
    public func remove(address: String) throws {
        var saved = try records()
        guard let value = saved.first(where: { $0.address.absoluteString == address }) else { return }
        saved.removeAll { $0.id == value.id }
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(value.id))
    }
    /// Rebuild derived source entries from the verified, app-owned version after an adapter update.
    /// Restoring a source does not require access to its original document provider or remote URL.
    public func storedSubscription(address: String, http: HTTPClient) async throws -> Subscription {
        guard let record = try records().first(where: { $0.address.absoluteString == address }) else { throw failure("此设备没有接口文件，请重新导入") }
        let values = try await PreparedLocalSources(records: [record], directory: directory).subscriptions(http: http)
        guard let value = values.first else { throw failure("接口没有可用来源") }
        return value
    }
    public func refresh(address: String, http: HTTPClient) async throws -> PreparedLocalSources {
        guard let record = try records().first(where: { $0.address.absoluteString == address }) else { throw failure("此设备没有接口原始文件，请重新导入") }
        // A copied file has no durable document-provider URL. Reload
        // its immutable owned version; replacing the source requires a new import.
        if record.input.isEmpty {
            return PreparedLocalSources(records: [record], directory: directory)
        }
        var inputs: [URL] = []
        var grants: [URL] = []
        defer { grants.forEach { $0.stopAccessingSecurityScopedResource() } }
        for (index,input) in record.input.enumerated() {
            guard input.isFileURL else { inputs.append(input); continue }
            guard let bookmark = record.bookmarks?.indices.contains(index) == true ? record.bookmarks?[index] : nil else {
                throw failure("原文件授权已失效，请在来源页重新选择同一文件或文件夹；保留原有版本")
            }
            var stale = false
            #if os(macOS)
            let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            if resolved.startAccessingSecurityScopedResource() { grants.append(resolved) }
            inputs.append(resolved)
        }
        return try await prepare(inputs, group: record.group, http: http, selectedEntry: record.entry, refreshingID: record.id)
    }
    /// Automatic checks may only follow remote origins. A local copy (including a
    /// restored portable copy) never regains access to its old provider implicitly.
    public func refreshIfChanged(address: String, http: HTTPClient, remoteOnly: Bool = true) async throws -> PreparedLocalSources? {
        guard let record = try records().first(where: { $0.address.absoluteString == address }) else {
            throw failure("此设备没有接口原始文件，请重新导入")
        }
        if remoteOnly, record.input.isEmpty || !record.input.allSatisfy({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) { return nil }
        let prepared = try await refresh(address: address, http: http)
        return prepared.records == [record] ? nil : prepared
    }
    public func prepare(_ selectedInputs: [URL], group: LocalSourceGroup, http: HTTPClient = HTTPClient(), selectedEntry: String? = nil, containingFolder: URL? = nil, refreshingID: String? = nil, name proposedName: String? = nil,
                        importingCopy: Bool = false) async throws -> PreparedLocalSources {
        var inputs = selectedInputs
        if importingCopy {
            guard containingFolder == nil, inputs.count == 1, let file = inputs.first, file.isFileURL,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw failure("请选择单个文件，不支持导入文件夹；多文件来源请压缩为 ZIP")
            }
        }
        if selectedInputs.count == 1, let file = selectedInputs.first, file.isFileURL,
           ["index.js", "index.js.md5", "index.config.js", "index.config.js.md5"].contains(file.lastPathComponent.lowercased()) {
            guard let folder = containingFolder,
                  folder.resolvingSymlinksInPath().standardizedFileURL == file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL,
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw failure("此接口需要多个文件，请将 index.js、index.config.js 和对应 MD5 一起压缩为 ZIP 后导入")
            }
            inputs = [folder]
        }
        guard !inputs.isEmpty, inputs.count <= 100 else { throw failure("每次可导入 1 至 100 个文件或地址") }
        let bundleMembers = ["index.js", "index.js.md5", "index.config.js", "index.config.js.md5"]
        let zipFiles: [String: Data]?
        if inputs.count == 1, let file = inputs.first, file.isFileURL, file.pathExtension.lowercased() == "zip" {
            zipFiles = try LocalSourceZIP.files(readLocal(file, max: 128 << 20)).filter { name, _ in
                // Finder/Files ZIP metadata is not an executable source file.
                !name.split(separator: "/").contains { $0 == "__MACOSX" || $0.hasPrefix("._") }
            }
        } else { zipFiles = nil }
        let pythonZip = group == .python && zipFiles != nil && !zipFiles!.keys.contains { $0 == "index.js" || $0.hasSuffix("/index.js") }
        let isBundleInput = !pythonZip && inputs.count == 1 && inputs.contains { input in
            ["zip", "md5"].contains(input.pathExtension.lowercased()) || bundleMembers.contains(input.lastPathComponent.lowercased())
                || (input.isFileURL && FileManager.default.fileExists(atPath: input.appendingPathComponent("index.js").path))
        }
        let isPythonFiles = group == .python && !isBundleInput
        let previous = try records()
        let identityInput = inputs.map { input -> String in
            if !isPythonFiles {
                if input.isFileURL, ["index.js", "index.js.md5"].contains(input.lastPathComponent) { return input.deletingLastPathComponent().standardizedFileURL.absoluteString }
                if !input.isFileURL, bundleMembers.contains(input.lastPathComponent.lowercased()) {
                    var base = URLComponents(url: input, resolvingAgainstBaseURL: false)!
                    base.path = input.deletingLastPathComponent().appendingPathComponent("index.js").path
                    return base.url!.absoluteString
                }
            }
            if importingCopy { return "imported-file:" + input.lastPathComponent.precomposedStringWithCanonicalMapping }
            return input.isFileURL ? input.standardizedFileURL.absoluteString : input.absoluteString
        }.sorted().joined(separator: "\n")
        var onlyEntry = selectedEntry
        var files: [String: Data] = [:], format = isPythonFiles ? "python" : "bundle"
        if isPythonFiles {
            if pythonZip, let zipFiles {
                files = zipFiles.filter { $0.key.lowercased().hasSuffix(".py") }
                // Files compresses a selected directory with its display name as
                // an outer wrapper. That name may contain spaces and is not a
                // Python module; the source root is the shared script directory.
                while let first = files.keys.first, let slash = first.firstIndex(of: "/") {
                    let prefix = String(first[...slash])
                    guard files.keys.allSatisfy({ $0.hasPrefix(prefix) }), files[prefix + "__init__.py"] == nil,
                          !Self.importsPackage(String(prefix.dropLast()), in: files.values) else { break }
                    files = Dictionary(uniqueKeysWithValues: files.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
                    if let entry = onlyEntry, entry.hasPrefix(prefix) { onlyEntry = String(entry.dropFirst(prefix.count)) }
                }
            } else {
                for input in inputs {
                    if input.isFileURL {
                        let isDirectory = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        if isDirectory {
                            try merge(try localFiles(input, python: true), into: &files)
                        } else {
                            try merge([input.lastPathComponent: try readLocal(input, max: 8 << 20)], into: &files)
                            if inputs.count == 1 { onlyEntry = input.lastPathComponent }
                        }
                    } else if input.pathExtension.lowercased() == "py" {
                        try merge([input.lastPathComponent: try await remote(input, http: http, max: 8 << 20)], into: &files)
                    } else {
                        let data = try await remote(input, http: http, max: 2 << 20)
                        let descriptor = try pythonManifest(data, origin: input)
                        for (name, address) in descriptor {
                            try merge([name: try await remote(address, http: http, max: 8 << 20)], into: &files)
                        }
                    }
                }
            }
            guard !files.isEmpty, files.count <= 100, files.keys.allSatisfy({ $0.lowercased().hasSuffix(".py") && safePath($0) }) else { throw failure("请选择 Python 文件、包含脚本的 ZIP 或远程脚本 JSON") }
        } else {
            guard inputs.count == 1, let input = inputs.first else { throw failure("每次请选择一个订阅包") }
            if input.isFileURL {
                if input.pathExtension.lowercased() == "zip" {
                    files = zipFiles ?? [:]
                    let roots = files.keys.filter { $0 == "index.js" || $0.hasSuffix("/index.js") }
                    guard roots.count == 1, let entry = roots.first else { throw failure("ZIP 必须包含一个完整 index.js 接口目录") }
                    let prefix = String(entry.dropLast("index.js".count))
                    files = Dictionary(uniqueKeysWithValues: files.filter { $0.key.hasPrefix(prefix) }.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
                } else if (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    files = try localFiles(input, python: false)
                } else if ["js", "md5"].contains(input.pathExtension.lowercased()) {
                    throw failure("本地接口包请导入包含 index.js、index.config.js 和对应 MD5 的 ZIP 文件")
                } else {
                    format = "tvbox"; files["subscription.json"] = try readLocal(input, max: 20_000_000)
                }
            } else if input.pathExtension.lowercased() == "md5" || bundleMembers.contains(input.lastPathComponent.lowercased()) || input.pathExtension.isEmpty {
                var base = input
                if bundleMembers.contains(base.lastPathComponent.lowercased()) {
                    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    components.path = base.deletingLastPathComponent().appendingPathComponent("index.js").path
                    base = components.url!
                } else {
                    if base.pathExtension.lowercased() == "md5" { base.deletePathExtension() }
                    if base.lastPathComponent != "index.js" { base.appendPathComponent("index.js") }
                }
                let baseline = refreshingID.flatMap { id in previous.first { $0.id == id && $0.format == "bundle" } }
                // Small checksums come first. Compare them against the actual saved
                // script bytes, so unchanged bundles do not download or execute again.
                for name in ["index.js.md5", "index.config.js.md5"] {
                    var sibling = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    sibling.path = base.deletingLastPathComponent().appendingPathComponent(name).path
                    files[name] = try await remote(sibling.url!, http: http, max: 4096)
                }
                var unchanged = baseline != nil
                for name in ["index.js", "index.config.js"] {
                    let expected = try Self.parseMD5(files[name + ".md5"]!, name: name)
                    if let baseline, let saved = try? Data(contentsOf: baseline.directory(in: directory).appendingPathComponent(name)),
                       Self.md5(saved) == expected {
                        files[name] = saved
                    } else {
                        unchanged = false
                        var sibling = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                        sibling.path = base.deletingLastPathComponent().appendingPathComponent(name).path
                        files[name] = try await remote(sibling.url!, http: http, max: 64 << 20)
                    }
                }
                if unchanged, let baseline, storedVersionIsIntact(baseline) {
                    return PreparedLocalSources(records: [baseline], directory: directory)
                }
            } else { format = "tvbox"; files["subscription.json"] = try await remote(input, http: http, max: 20_000_000) }
            if format == "bundle" {
                for name in ["index.js", "index.config.js"] {
                    guard let data = files[name], let checksum = files[name + ".md5"] else { throw failure("缺少 \(name) 或 \(name).md5，请重新选择完整接口 ZIP") }
                    let expected = try Self.parseMD5(checksum, name: name)
                    guard Self.md5(data) == expected else { throw failure("\(name) MD5 校验失败，保留原有版本") }
                }
                files["package.json"] = Data("{\"type\":\"commonjs\"}\n".utf8)
            } else { _ = try Subscription.parse(files["subscription.json"]!, origin: input) }
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= (format == "python" ? 32 << 20 : 128 << 20) else { throw failure("接口文件总大小超过限制") }
        let names = files.keys.sorted()
        let version = PluginChecksum.sha256(Data(names.map { $0 + "\0" + PluginChecksum.sha256(files[$0]!) }.joined(separator: "\n").utf8))
        if let refreshingID, let baseline = previous.first(where: { $0.id == refreshingID && $0.version == version }),
           storedVersionIsIntact(baseline),
           names.allSatisfy({ (try? Data(contentsOf: baseline.directory(in: directory).appendingPathComponent($0))) == files[$0] }) {
            return PreparedLocalSources(records: [baseline], directory: directory)
        }
        let staging = directory.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for name in names {
            guard safePath(name) else { throw failure("接口文件路径无效") }
            let file = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files[name]!.write(to: file)
        }
        let entries = format == "python" ? try await validatePython(files: names, staging: staging) : [""]
        guard onlyEntry == nil || entries.contains(onlyEntry!) else { throw failure("原 Python 入口不存在，保留原有版本") }
        let selected = onlyEntry.map { [$0] } ?? entries
        let manifest: [String: JSONValue] = ["format": .number(format == "python" ? 2 : 1), "engine": .string(format), "version": .string(version), "entries": .array(entries.map(JSONValue.string)), "sha256": .object(files.mapValues { .string(PluginChecksum.sha256($0)) })]
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        var prepared: [LocalSourceRecord] = []
        for entry in selected {
            // Picker copy paths change on every selection. Content identity makes
            // identical re-imports stable without replacing a different same-named source.
            let identity = importingCopy ? identityInput + "\n" + version : identityInput
            let id = refreshingID ?? PluginChecksum.sha256(Data((group.rawValue + "\n" + identity + "\n" + entry).utf8))
            let existing = previous.first { $0.id == id }
            let now = Date()
            let typedName = proposedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let input = inputs[0]
            let isDirectory = input.isFileURL && (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let automaticName = format == "python" && selected.count > 1
                ? URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent
                : LocalSourcePolicy.name(for: input, isDirectory: isDirectory)
            let name = typedName.isEmpty ? (existing?.name ?? automaticName)
                : (selected.count > 1 ? typedName + " · " + URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent : typedName)
            let persistentInputs = importingCopy ? [] : inputs
            let bookmarks: [Data?] = try persistentInputs.map { input in
                guard input.isFileURL else { return nil }
                #if os(macOS)
                return try input.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                #else
                return try input.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
                #endif
            }
            let record = LocalSourceRecord(id: id, group: group, format: format, version: version, entry: entry.isEmpty ? nil : entry,
                input: persistentInputs, bookmarks: importingCopy ? nil : bookmarks, name: name, importedAt: existing?.importedAt ?? now, updatedAt: now)
            let target = record.directory(in: directory)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A version path is immutable. Repair damaged files only after the complete replacement was verified.
            let copy = target.deletingLastPathComponent().appendingPathComponent(".copy-" + UUID().uuidString)
            try FileManager.default.copyItem(at: staging, to: copy)
            if FileManager.default.fileExists(atPath: target.path) {
                if storedVersionIsIntact(record), names.allSatisfy({ (try? Data(contentsOf: target.appendingPathComponent($0))) == files[$0] }) { try FileManager.default.removeItem(at: copy) }
                else { let old = target.appendingPathExtension("damaged"); try? FileManager.default.removeItem(at: old); try FileManager.default.moveItem(at: target, to: old); do { try FileManager.default.moveItem(at: copy, to: target); try? FileManager.default.removeItem(at: old) } catch { try? FileManager.default.moveItem(at: old, to: target); throw error } }
            } else { try FileManager.default.moveItem(at: copy, to: target) }
            prepared.append(record)
        }
        return PreparedLocalSources(records: prepared, directory: directory)
    }
    /// A matching remote MD5 proves only the script contents. Fast paths must also
    /// verify their companion files and the manifest, or a reported-success refresh
    /// can leave a bundle that still fails backup or runtime package resolution.
    private func storedVersionIsIntact(_ record: LocalSourceRecord) -> Bool {
        let root = record.directory(in: directory)
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode([String: JSONValue].self, from: bytes),
              manifest["engine"]?.string == record.format,
              manifest["format"]?.int == (record.format == "python" ? 2 : 1),
              manifest["version"]?.string == record.version,
              let hashValues = manifest["sha256"]?.object, !hashValues.isEmpty else { return false }
        let hashes = hashValues.compactMapValues(\.string)
        guard hashes.count == hashValues.count,
              record.entry == nil || hashes[record.entry!] != nil else { return false }
        if record.format == "bundle",
           !["index.js", "index.config.js", "index.js.md5", "index.config.js.md5", "package.json"].allSatisfy({ hashes[$0] != nil }) { return false }
        if record.format == "tvbox", hashes["subscription.json"] == nil { return false }
        let signature = hashes.keys.sorted().map { $0 + "\0" + hashes[$0]! }.joined(separator: "\n")
        guard PluginChecksum.sha256(Data(signature.utf8)) == record.version else { return false }
        for (name, expected) in hashes {
            guard safePath(name) else { return false }
            let file = root.appendingPathComponent(name)
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: file), PluginChecksum.sha256(data) == expected else { return false }
        }
        return true
    }
    private func localFiles(_ selectedRoot: URL, python: Bool) throws -> [String: Data] {
        try coordinatedRead(selectedRoot) { try localDirectoryFiles($0, python: python) }
    }

    /// Namespace packages need no __init__.py. Keep a shared root explicitly
    /// referenced by the source, including comma-separated absolute imports.
    private static func importsPackage(_ name: String, in files: Dictionary<String, Data>.Values) -> Bool {
        guard name.range(of: #"^\w+$"#, options: .regularExpression) != nil else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let expression = #"(?m)(?:^|[;\n])\s*(?:from\s+"# + escaped + #"(?:\.|\s+import\b)|import\s+(?:[\w.]+(?:\s+as\s+\w+)?\s*,\s*)*"# + escaped + #"(?:\.|\s|,|$))"#
        return files.contains { data in
            String(data: data, encoding: .utf8)?.range(of: expression, options: .regularExpression) != nil
        }
    }
    private func localDirectoryFiles(_ selectedRoot: URL, python: Bool) throws -> [String: Data] {
        guard (try selectedRoot.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw failure("接口目录不能为符号链接") }
        let root = selectedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw failure("无法读取接口目录") }
        var result: [String: Data] = [:]
        for case let url as URL in iterator {
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard resource.isSymbolicLink != true else { throw failure("接口目录不能包含符号链接") }
            guard resource.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let rootParts = root.pathComponents, fileParts = resolved.pathComponents
            guard fileParts.starts(with: rootParts) else { throw failure("接口文件不在所选目录") }
            let name = fileParts.dropFirst(rootParts.count).joined(separator: "/")
            if python && !name.lowercased().hasSuffix(".py") { continue }
            guard safePath(name), result.count < 1000 else { throw failure("接口文件路径或数量无效") }
            result[name] = try readLocal(url, max: python ? 8 << 20 : 64 << 20)
        }
        return result
    }
    private func readLocal(_ url: URL, max: Int) throws -> Data {
        try coordinatedRead(url) { coordinated in
            let values = try coordinated.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? max + 1) <= max else { throw failure("接口文件过大、不是普通文件或为符号链接") }
            let data = try Data(contentsOf: coordinated); guard data.count <= max else { throw failure("接口文件过大") }; return data
        }
    }
    /// Document-provider reads must coordinate with iCloud/Files before opening placeholders or moving items.
    /// The caller keeps its security-scope lease for this entire synchronous operation on the library actor.
    private func coordinatedRead<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try operation(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw failure("文件提供方未返回文件，请重新选择后重试") }
        return try result.get()
    }
    private func remote(_ url: URL, http: HTTPClient, max: Int) async throws -> Data {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw failure("在线接口只支持 HTTP/HTTPS") }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var headers = ["User-Agent": HTTPClient.subscriptionUserAgent]
        if let user = components.user {
            headers["Authorization"] = "Basic " + Data((user + ":" + (components.password ?? "")).utf8).base64EncodedString()
            components.user = nil; components.password = nil
        }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        for (key,value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let transfer = LocalSourceTransfer(limit: max, configuration: http.session.configuration)
        return try await transfer.load(request)
    }
    private func merge(_ addition: [String: Data], into files: inout [String: Data]) throws {
        for (name, data) in addition {
            guard safePath(name), !files.keys.contains(where: { $0.lowercased() == name.lowercased() }) else { throw failure("文件名重复或无效：\(name)") }
            files[name] = data
        }
    }
    private func pythonManifest(_ data: Data, origin: URL) throws -> [(String, URL)] {
        let object = try JSONSerialization.jsonObject(with: data)
        var result: [(String, URL)] = []
        func append(_ name: String?, _ address: String) throws {
            guard let url = URL(string: address, relativeTo: origin)?.absoluteURL, ["http", "https"].contains(url.scheme ?? "") else { throw failure("Python JSON 地址无效") }
            let filename = name ?? url.lastPathComponent
            guard safePath(filename), filename.lowercased().hasSuffix(".py") else { throw failure("Python JSON 文件名无效") }
            result.append((filename,url))
        }
        if let value = object as? [String: Any], let map = value["files"] as? [String: String] { for (name,address) in map.sorted(by: {$0.key < $1.key}) { try append(name,address) } }
        else {
            let dictionary = object as? [String: Any]
            guard let rows = (object as? [Any]) ?? (dictionary?["scripts"] as? [Any]) ?? (dictionary?["python"] as? [Any]) ?? (dictionary?["sites"] as? [Any]) else { throw failure("Python JSON 需要 files、scripts 或 sites 列表") }
            for row in rows {
                if let address = row as? String { try append(nil,address) }
                else if let fields = row as? [String: Any], let address = fields["url"] as? String ?? fields["api"] as? String { try append(fields["filename"] as? String,address) }
                else { throw failure("Python JSON 包含无效脚本项") }
            }
        }
        guard !result.isEmpty, result.count <= 100 else { throw failure("Python JSON 脚本数量无效") }; return result
    }
    private func validatePython(files: [String], staging: URL) async throws -> [String] {
        let paths = Dictionary(uniqueKeysWithValues: files.map { (staging.appendingPathComponent($0).path,$0) })
        #if os(iOS) || os(tvOS)
        return try await EmbeddedPythonHost.shared.validate(files: paths)
        #else
        let script = "import ast,json,sys,tokenize\nentries=[]\ntry:\n for path,name in json.loads(sys.argv[1]).items():\n  with tokenize.open(path) as f: tree=ast.parse(f.read(),filename=name)\n  if any((isinstance(n,ast.ClassDef) and n.name=='Spider') or (isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name=='createSpider') for n in tree.body): entries.append(name)\n print(json.dumps({'entries':entries}))\nexcept Exception as e: print(json.dumps({'error':str(e)}))"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", "-c", script, String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let result = try JSONDecoder().decode([String: JSONValue].self, from: output)
        if let message = result["error"]?.string { throw failure(message) }
        let entries = result["entries"]?.array?.compactMap(\.string).sorted() ?? []
        guard !entries.isEmpty else { throw failure("没有定义 Spider 或 createSpider() 的 Python 入口") }; return entries
        #endif
    }
    static func parseMD5(_ data: Data, name: String) throws -> String {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let hash = parts.first, hash.count == 32, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw failure("\(name).md5 无效") }
        if parts.count > 1 {
            let file = String(parts[1]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*")).replacingOccurrences(of: "\\", with: "/")
            guard !file.contains("\n"), URL(fileURLWithPath: file).lastPathComponent == name else { throw failure("MD5 文件名不匹配") }
        }
        return hash.lowercased()
    }
    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Profiles identify the record and entry; code/version addresses identify execution sessions only.
    public static func profileIdentity(at url: URL) -> String? {
        guard url.host()?.lowercased() == "sources.yingxia.invalid" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts.prefix(2).allSatisfy({ $0.count == 64 && $0.allSatisfy({ $0.isASCII && $0.isHexDigit }) }) else { return nil }
        return PluginChecksum.sha256(Data((parts[0] + "\n" + parts.dropFirst(2).joined(separator: "/")).utf8))
    }
    public static func localFile(at url: URL) throws -> URL? {
        guard url.host()?.lowercased() == "sources.yingxia.invalid" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[0].count == 64, parts[1].count == 64, parts.prefix(2).allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isHexDigit }) }), safePath(parts.dropFirst(2).joined(separator: "/")) else { throw failure("本地接口地址无效") }
        let path = storageRoot.appendingPathComponent("\(parts[0])/versions/\(parts[1])/" + parts.dropFirst(2).joined(separator: "/"))
        guard FileManager.default.fileExists(atPath: path.path) else { throw failure("接口文件已不存在，请重新导入") }; return path
    }
    static func data(at url: URL) throws -> Data? { try localFile(at: url).map { try Data(contentsOf: $0) } }
}

private func failure(_ message: String) -> TVError { .unsupported(message) }
private func safePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !path.contains(":") else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] { var values: [T] = []; for value in self { values.append(try await transform(value)) }; return values }
}

/// Validate every ZIP entry before importing any: traversal, symlink, duplicate names, encryption,
/// unsupported methods, CRC and both compressed and expanded sizes are checked independently.
enum LocalSourceZIP {
    static func files(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { at >= 0 && at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at+1]) << 8 : -1 }
        func u32(_ at: Int) -> Int { at >= 0 && at + 4 <= bytes.count ? u16(at) | u16(at+2) << 16 : -1 }
        var end = bytes.count - 22
        while end >= max(0,bytes.count - 65_557), u32(end) != 0x06054b50 { end -= 1 }
        guard end >= 0, u32(end) == 0x06054b50, u16(end+4) == 0, u16(end+6) == 0, u16(end+8) == u16(end+10), u16(end+10) > 0, u16(end+10) <= 1000, end+22+u16(end+20) == bytes.count else { throw failure("ZIP 目录无效") }
        let centralEnd = u32(end+16)+u32(end+12)
        guard centralEnd == end else { throw failure("ZIP 目录偏移无效") }
        var cursor = u32(end+16), total = 0, result: [String: Data] = [:], seen: Set<String> = []
        for _ in 0..<u16(end+10) {
            guard cursor >= 0, cursor+46 <= end, u32(cursor) == 0x02014b50 else { throw failure("ZIP 条目无效") }
            let flags=u16(cursor+8), method=u16(cursor+10), crc=u32(cursor+16), compressed=u32(cursor+20), size=u32(cursor+24), nameLength=u16(cursor+28), extra=u16(cursor+30), comment=u16(cursor+32), local=u32(cursor+42)
            guard flags & 1 == 0, [0,8].contains(method), cursor+46+nameLength+extra+comment <= end, let name=String(bytes:bytes[(cursor+46)..<(cursor+46+nameLength)],encoding:.utf8) else { throw failure("ZIP 加密或压缩格式不受支持") }
            let isFolder=name.hasSuffix("/"), cleaned=isFolder ? String(name.dropLast()) : name
            let mode=(u32(cursor+38) >> 16) & 0xf000
            guard safePath(cleaned), mode != 0xa000, seen.insert(cleaned.lowercased()).inserted else { throw failure("ZIP 包含路径穿越、链接或重复文件") }
            cursor += 46+nameLength+extra+comment
            guard size >= 0, size <= 64 << 20, compressed >= 0, compressed <= 128 << 20, total+size <= 128 << 20, local >= 0, local+30 <= end, u32(local)==0x04034b50, u16(local+8)==method, u16(local+6)==flags else { throw failure("ZIP 文件大小或头部无效") }
            let start=local+30+u16(local+26)+u16(local+28)
            guard start >= local+30, start+compressed <= u32(end+16), u16(local+26)==nameLength, Data(bytes[(local+30)..<(local+30+nameLength)]) == Data(name.utf8) else { throw failure("ZIP 本地条目无效") }
            if isFolder { continue }
            var output = Data(count:size)
            if method == 0 { guard compressed==size else { throw failure("ZIP 长度不符") }; output=Data(bytes[start..<(start+compressed)]) }
            else if size > 0 {
                let written=output.withUnsafeMutableBytes { destination in bytes[start..<(start+compressed)].withUnsafeBufferPointer { source in compression_decode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,size,source.baseAddress!,compressed,nil,COMPRESSION_ZLIB) } }
                guard written==size else { throw failure("ZIP 解压失败") }
            }
            let actual=output.withUnsafeBytes { crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt(output.count)) }
            guard actual==crc else { throw failure("ZIP CRC 校验失败") }
            total += size; result[name]=output
        }
        guard cursor==centralEnd else { throw failure("ZIP 目录长度不符") }; return result
    }
}

private final class LocalSourceTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var bytes = Data()
    private var failure: Error?
    private var cancelled = false
    init(limit: Int, configuration: URLSessionConfiguration) { self.limit = limit; self.configuration = configuration }
    func load(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task; task.resume(); lock.unlock()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock(); task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if let http = response as? HTTPURLResponse {
            if !(200..<300).contains(http.statusCode) { failure = TVError.http(http.statusCode) }
            else if response.expectedContentLength > limit { failure = TVError.unsupported("接口文件过大") }
        } else { failure = TVError.invalidConfiguration }
        let rejected = failure != nil; lock.unlock(); completionHandler(rejected ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if bytes.count + data.count > limit { failure = TVError.unsupported("接口文件过大"); lock.unlock(); dataTask.cancel(); return }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil
        let result: Result<Data, Error> = (failure ?? error).map(Result.failure) ?? .success(bytes)
        self.session = nil; self.task = nil; lock.unlock()
        session.finishTasksAndInvalidate(); continuation?.resume(with: result)
    }
}
