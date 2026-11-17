import Foundation

public enum LocalHomeDestination: String, CaseIterable, Identifiable, Sendable {
    public static let key = "local.home.defaultDestination"
    case home, lastSite, lastPython, lastHTML
    public var id: String { rawValue }
    public var title: String {
        switch self { case .home: "首页"; case .lastSite: "上次站点"; case .lastPython: "上次python"; case .lastHTML: "上次html" }
    }
}
