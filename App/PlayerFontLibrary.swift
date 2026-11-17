#if os(iOS)
import Foundation
import CoreText
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import TVCore

/// Imported TTF/OTF files stay in the app's documents and register again before a selected font renders.
enum PlayerFontLibrary {
    struct FontFile: Identifiable { let url: URL, family: String; var id: String { url.lastPathComponent } }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false
    private static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PlayerFonts", isDirectory: true) }
    static func ensureRegistered() {
        lock.withLock {
            guard !registered else { return }; registered = true
            for file in files { CTFontManagerRegisterFontsForURL(file.url as CFURL, .process, nil) }
        }
    }
    static var files: [FontFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { return nil }
            return FontFile(url: url, family: family)
        }.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }
    static var families: [String] { ensureRegistered(); return Array(Set(UIFont.familyNames)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    static func add(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { location in
            result = Result {
                let size = try location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, size.fileSize.map({ $0 <= 20 * 1024 * 1024 }) ?? true else {
                    throw NSError(domain: "PlayerFonts", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择小于 20 MB 的字体文件。"])
                }
                return try Data(contentsOf: location)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw NSError(domain: "PlayerFonts", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件提供方未返回字体，请重新选择。"]) }
        return try add(data: result.get(), filename: url.lastPathComponent)
    }
    static func add(data: Data, filename: String) throws -> String {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard data.count <= 20 * 1024 * 1024, ["ttf", "otf"].contains(fileExtension),
              let provider = CGDataProvider(data: data as CFData), CGFont(provider) != nil,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else {
            throw NSError(domain: "PlayerFonts", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择有效的 TTF / OTF 字体，文件须小于 20 MB。"])
        }
        ensureRegistered()
        if files.contains(where: { $0.family == family }) { return family }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: target, options: .atomic)
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(target as CFURL, .process, &error), !UIFont.familyNames.contains(family) {
            try? FileManager.default.removeItem(at: target)
            let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "无法载入所选字体。"
            throw NSError(domain: "PlayerFonts", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return family
    }
    static func remove(_ file: FontFile) throws {
        try FileManager.default.removeItem(at: file.url)
        CTFontManagerUnregisterFontsForURL(file.url as CFURL, .process, nil)
        var subtitle = SubtitleStyle.load()
        if subtitle.font == file.family { subtitle.font = nil; subtitle.save() }
        if UserDefaults.standard.string(forKey: "danmakuFontFamily") == file.family { UserDefaults.standard.set("", forKey: "danmakuFontFamily") }
    }
}

struct PlayerFontPicker: View {
    @Binding var family: String
    @State private var importing = false
    @State private var managing = false
    @State private var revision = 0
    @State private var issue: String?
    @State private var readingFile = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalGlassChoicePicker(title: "字体", selection: $family,
                                   options: [.init("", "默认")] + PlayerFontLibrary.families.map { .init($0, $0) })
                .id(revision)
            HStack {
                Button { issue = nil; importing = true } label: { Image(systemName: "square.and.arrow.up") }.disabled(readingFile).accessibilityLabel("上传 TTF / OTF 字体")
                if readingFile { ProgressView().controlSize(.small) }
                if !PlayerFontLibrary.files.isEmpty { Button { managing.toggle() } label: { Image(systemName: "folder") }.accessibilityLabel("管理已导入字体") }
            }
            if managing {
                ForEach(PlayerFontLibrary.files) { file in
                    HStack {
                        Text(file.family).font(.caption); Spacer()
                        Button(role: .destructive) {
                            do { try PlayerFontLibrary.remove(file); if family == file.family { family = "" }; revision += 1 }
                            catch { issue = error.localizedDescription }
                        } label: { Image(systemName: "trash") }.accessibilityLabel("删除字体 " + file.family)
                    }
                }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }
        .localDocumentImporter(isPresented: $importing, kind: .fontFile) { result in
            switch result {
            case .failure(let error): issue = error.localizedDescription
            case .success(let selection):
                readingFile = true
                Task {
                    defer { selection.release(); readingFile = false }
                    do {
                        let data = try await selection.readData(maxBytes: 20 * 1024 * 1024)
                        family = try PlayerFontLibrary.add(data: data, filename: selection.urls[0].lastPathComponent)
                        revision += 1; issue = nil
                    } catch { if !(error is CancellationError) { issue = error.localizedDescription } }
                }
            }
        } cancelled: { issue = "已取消文件选择" }
    }
}
#endif
