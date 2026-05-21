import Foundation
import os.signpost

/// CL-P0-030 / CL-XS-007: signposts so Instruments → Points of Interest can
/// measure cold open / refresh / popover render cost. Keep the OSLog instance
/// stable so traces aggregate across runs.
enum TokenBarSignpost {
    static let log = OSLog(subsystem: "com.tokenbar.app", category: "performance")

    static func event(_ name: StaticString, _ message: String? = nil) {
        let id = OSSignpostID(log: log)
        if let message {
            os_signpost(.event, log: log, name: name, signpostID: id, "%{public}@", message)
        } else {
            os_signpost(.event, log: log, name: name, signpostID: id)
        }
    }

    static func interval(_ name: StaticString, _ block: () async -> Void) async {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        await block()
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
