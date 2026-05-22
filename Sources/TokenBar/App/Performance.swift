import Foundation
import os.log
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

/// Lightweight structured telemetry for local debugging. Values are emitted to
/// unified logging so `script/build_and_run.sh --telemetry` can show user
/// actions, duration, success/failure, and errors without adding a third-party
/// analytics dependency.
enum TokenBarTelemetry {
    private static let log = OSLog(subsystem: "com.javis.TokenBar", category: "telemetry")

    static func event(
        _ action: String,
        metadata: String = "",
        success: Bool? = nil,
        elapsed: TimeInterval? = nil,
        error: String? = nil
    ) {
        let successText = success.map { $0 ? "true" : "false" } ?? "n/a"
        let elapsedText = elapsed.map { String(format: "%.0f", $0 * 1000) } ?? "n/a"
        let errorText = error ?? ""
        let type: OSLogType = (success == false || error != nil) ? .error : .info
        os_log(
            "action=%{public}@ success=%{public}@ elapsed_ms=%{public}@ metadata=%{public}@ error=%{public}@",
            log: log,
            type: type,
            action,
            successText,
            elapsedText,
            metadata,
            errorText
        )
    }

    static func timing(
        _ action: String,
        startedAt started: Date,
        metadata: String = "",
        success: Bool? = true,
        error: String? = nil
    ) {
        event(
            action,
            metadata: enrich(metadata),
            success: success,
            elapsed: Date().timeIntervalSince(started),
            error: error
        )
    }

    static func mark(_ action: String, metadata: String = "", success: Bool? = true) {
        event(action, metadata: enrich(metadata), success: success)
    }

    private static func enrich(_ metadata: String) -> String {
        let thread = Thread.isMainThread ? "main" : "background"
        if metadata.isEmpty {
            return "thread=\(thread)"
        }
        return "\(metadata) thread=\(thread)"
    }
}
