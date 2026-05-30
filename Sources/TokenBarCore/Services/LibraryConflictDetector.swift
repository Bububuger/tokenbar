import Foundation

public enum LibraryConflictDetector {
    public static func compute(skills: [ScannedSkill], pluginIds: [String]) -> [LibraryConflict] {
        var conflicts: [LibraryConflict] = []

        for skill in skills where skill.isBroken {
            conflicts.append(LibraryConflict(
                kind: .brokenSymlink,
                skillName: skill.name,
                scopes: [skill.scope],
                severity: .error
            ))
        }

        let pluginIdSet = Set(pluginIds)
        for skill in skills where pluginIdSet.contains(skill.name) {
            if !conflicts.contains(where: { $0.kind == .userPlugin && $0.skillName == skill.name }) {
                conflicts.append(LibraryConflict(
                    kind: .userPlugin,
                    skillName: skill.name,
                    scopes: [skill.scope],
                    severity: .warning
                ))
            }
        }

        let grouped = Dictionary(grouping: skills.filter { !$0.isBroken }, by: \.name)
        for (name, group) in grouped where group.count >= 2 {
            let scopes = Array(Set(group.map(\.scope)))
            guard scopes.count >= 2 else { continue }

            let hasSymlink = group.contains(where: \.isSymlink)
            let allReal = group.allSatisfy { !$0.isSymlink }

            if allReal {
                conflicts.append(LibraryConflict(
                    kind: .duplicateReal,
                    skillName: name,
                    scopes: scopes,
                    severity: .warning
                ))
            } else if hasSymlink {
                conflicts.append(LibraryConflict(
                    kind: .scopeOverlap,
                    skillName: name,
                    scopes: scopes,
                    severity: .warning
                ))
            }
        }

        return conflicts.sorted { $0.skillName < $1.skillName }
    }

    public static func winnerScope(for skillName: String, in skills: [ScannedSkill]) -> LibraryScope? {
        let matching = skills.filter { $0.name == skillName && !$0.isBroken }
        let priority: [LibraryScope] = [.project, .user, .shared]
        for scope in priority {
            if matching.contains(where: { $0.scope == scope }) {
                return scope
            }
        }
        return matching.first?.scope
    }
}
