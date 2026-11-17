import Foundation

public enum LocalAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    public static let key = "local.appearance"
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
}

