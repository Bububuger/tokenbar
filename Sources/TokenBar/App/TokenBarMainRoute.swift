struct TokenBarProjectRoute: Equatable, Hashable {
    let name: String
    let projectPath: String?

    init(name: String, projectPath: String? = nil) {
        self.name = name
        self.projectPath = projectPath?.isEmpty == false ? projectPath : nil
    }

    var identity: String { projectPath ?? name }
}

enum TokenBarMainRoute: Equatable, Hashable {
    case today
    case library
    case diagnostics
    case settings
    case savedPrompts
    case project(TokenBarProjectRoute)
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
        case .project(let project):
            "project:\(project.identity)"
        case .source(let name):
            "source:\(name)"
        case .model(let name):
            "model:\(name)"
        }
    }
}
