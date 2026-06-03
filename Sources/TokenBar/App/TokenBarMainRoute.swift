enum TokenBarMainRoute: Equatable, Hashable {
    case today
    case library
    case diagnostics
    case settings
    case savedPrompts
    case project(String)
    case source(String)
    case model(String)
}

extension TokenBarMainRoute {
    var telemetryName: String {
        switch self {
        case .today:
            "overview"
        case .library:
            "library"
        case .diagnostics:
            "diagnostics"
        case .settings:
            "settings"
        case .savedPrompts:
            "saved_prompts"
        case .project(let name):
            "project:\(name)"
        case .source(let name):
            "source:\(name)"
        case .model(let name):
            "model:\(name)"
        }
    }
}
