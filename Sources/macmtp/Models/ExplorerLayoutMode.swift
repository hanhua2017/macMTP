enum ExplorerLayoutMode: String, CaseIterable, Identifiable {
    case single = "Single Pane"
    case dual = "Dual Pane"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .single: return "rectangle"
        case .dual: return "rectangle.split.2x1"
        }
    }
}
