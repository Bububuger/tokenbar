import CryptoKit
import Foundation

enum PromptExtraction {
    static func hash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isSystemReminder(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let header = trimmed.prefix(512)
        return header.range(of: "<system-reminder>", options: .caseInsensitive) != nil
            || header.range(of: "system reminder", options: .caseInsensitive) != nil
            || header.range(of: "important instruction reminders", options: .caseInsensitive) != nil
    }

    static func strings(fromContent value: Any?) -> [String] {
        if let string = value as? String {
            return [string]
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let type = part["type"] as? String, type == "tool_result" {
                    return nil
                }
                return part["text"] as? String
                    ?? part["content"] as? String
                    ?? part["input"] as? String
            }
        }
        return []
    }
}
