import SwiftUI

/// 9-item, 3-section dropdown used by the prompt-template editor to insert
/// recognized substitutions at the caret. Acceptance §5 fixes the content
/// list — keep `Self.items` byte-stable for the unit test.
struct PromptVariablePicker: View {
    /// Called with the literal snippet to insert (e.g. "$ARGUMENTS").
    let onInsert: (String) -> Void

    static let items: [PickerSection] = [
        PickerSection(
            header: "User-typed arguments",
            entries: [
                .init(label: "$ARGUMENTS", sublabel: "All args (whole text after slash)", snippet: "$ARGUMENTS"),
                .init(label: "$0  $1  $2", sublabel: "Positional (whitespace-split)", snippet: "$0"),
                .init(label: "$ARGUMENTS[0]", sublabel: "Indexed (verbose form of $0)", snippet: "$ARGUMENTS[0]"),
            ]
        ),
        PickerSection(
            header: "Shell command",
            entries: [
                .init(label: "!`command`", sublabel: "Inline output, replaces with stdout", snippet: "!`command`"),
                .init(
                    label: "```!\\ncommand\\n```",
                    sublabel: "Multi-line block (≥ 2 lines)",
                    snippet: "\n```!\ncommand\n```\n"
                ),
            ]
        ),
        PickerSection(
            header: "Environment",
            entries: [
                .init(label: "${CLAUDE_SESSION_ID}", sublabel: "Current session id", snippet: "${CLAUDE_SESSION_ID}"),
                .init(label: "${CLAUDE_EFFORT}", sublabel: "Current effort level", snippet: "${CLAUDE_EFFORT}"),
                .init(label: "${CLAUDE_SKILL_DIR}", sublabel: "Skill directory path", snippet: "${CLAUDE_SKILL_DIR}"),
            ]
        ),
    ]

    /// Flat list used by unit tests (acceptance §5.1 asserts the order).
    static var allItems: [PickerEntry] {
        items.flatMap(\.entries)
    }

    var body: some View {
        Menu {
            ForEach(Self.items, id: \.header) { section in
                Section(section.header) {
                    ForEach(section.entries, id: \.label) { entry in
                        Button {
                            onInsert(entry.snippet)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.label)
                                    .font(.system(.body, design: .monospaced))
                                Text(entry.sublabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                Text("Insert")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .menuStyle(.button)
        .keyboardShortcut(".", modifiers: .command)
    }

    struct PickerSection: Hashable {
        let header: String
        let entries: [PickerEntry]
    }

    struct PickerEntry: Hashable {
        let label: String
        let sublabel: String
        let snippet: String
    }
}
