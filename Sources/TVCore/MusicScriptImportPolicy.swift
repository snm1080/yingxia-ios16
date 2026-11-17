import Foundation

/// Files providers do not consistently advertise JavaScript UTIs. The picker accepts
/// regular items, then this policy validates the selected document before evaluation.
public enum MusicScriptImportPolicy {
    public enum Kind: Sendable {
        case lx, musicExtension
        public var maximumBytes: Int { self == .lx ? 9_000_000 : 5_000_000 }
    }
    public enum Failure: LocalizedError, Equatable {
        case filename, empty, tooLarge(Int), encoding
        public var errorDescription: String? {
            switch self {
            case .filename: "请选择 JavaScript 脚本文件（.js、.mjs、.cjs 或 .txt）。"
            case .empty: "所选脚本文件为空，请重新选择。"
            case .tooLarge(let bytes): "脚本文件不能超过 \(bytes / 1_000_000) MB。"
            case .encoding: "无法读取脚本文字，请使用 UTF-8 编码的 JavaScript 文件。"
            }
        }
    }
    public static func validateFilename(_ filename: String) throws {
        let suffix = (filename as NSString).pathExtension.lowercased()
        guard ["js", "mjs", "cjs", "txt"].contains(suffix) else { throw Failure.filename }
    }
    public static func script(_ data: Data, filename: String, kind: Kind) throws -> String {
        try validateFilename(filename)
        guard data.count <= kind.maximumBytes else { throw Failure.tooLarge(kind.maximumBytes) }
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Failure.encoding }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        return text
    }
}
