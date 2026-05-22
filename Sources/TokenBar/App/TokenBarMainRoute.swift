enum TokenBarMainRoute: Equatable {
    case today
    case diagnostics
    case settings
    case project(String)
}

extension TokenBarMainRoute {
    var telemetryName: String {
        switch self {
        case .today:
            "overview"
        case .diagnostics:
            "diagnostics"
        case .settings:
            "settings"
        case .project(let name):
            "project:\(name)"
        }
    }
}
