import Foundation
import Testing
@testable import TokenBarCLI

struct CommandRegistryTests {
    @Test
    func registryListsAllExpectedCommands() throws {
        let names = Set(CommandRegistry.all.map(\.name))
        let expected: Set<String> = [
            "events", "prompts", "projects", "sessions", "models", "agents",
            "summary", "timeline", "sources", "checkpoints", "warnings",
            "schema", "rebuild", "prompt",
        ]
        #expect(names == expected)
    }

    @Test
    func descriptorLookupByName() throws {
        let descriptor = CommandRegistry.descriptor(named: "events")
        #expect(descriptor != nil)
        #expect(descriptor?.sortFields.contains("timestamp") == true)
    }

    @Test
    func descriptorLookupUnknownReturnsNil() throws {
        #expect(CommandRegistry.descriptor(named: "bogus") == nil)
    }

    @Test
    func helpSummaryContainsProgramAndAllCommands() throws {
        let summary = CommandRegistry.helpSummary(programName: "tbar")
        #expect(summary.contains("tbar"))
        for descriptor in CommandRegistry.all {
            #expect(summary.contains(descriptor.name))
        }
    }
}
