import Foundation

public enum LocalHomeDestination: String, CaseIterable, Identifiable, Sendable {
    public static let key = "local.home.defaultDestination"
    /// Which kind of source was selected most recently ("sites", "python" or "html"),
    /// so the Home button can reopen it directly instead of the source panel.
    public static let lastKindKey = "local.home.lastKind"
    case home, lastSite, lastPython, lastHTML
    public var id: String { rawValue }
    public var title: String {
        switch self { case .home: "首页"; case .lastSite: "上次站点"; case .lastPython: "上次python"; case .lastHTML: "上次html" }
    }
}
