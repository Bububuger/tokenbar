import Foundation

struct ArgumentCursor {
    private let values: [String]
    private(set) var index = 0

    init(_ values: [String]) {
        self.values = values
    }

    mutating func next() -> String? {
        guard index < values.count else { return nil }
        defer { index += 1 }
        return values[index]
    }

    mutating func peek() -> String? {
        guard index < values.count else { return nil }
        return values[index]
    }

    mutating func nextValue(for optionName: String) throws -> String {
        guard let value = next() else {
            throw CLIError.invalidArgument("Missing value for \(optionName)")
        }
        return value
    }
}

enum CLIError: LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let reason):
            return reason
        }
    }
}
