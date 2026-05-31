import Foundation

/// In-flight state for the popover-driven update download. UI binds to this
/// via the runtime model's `@Published` mirror.
public enum AppUpdateDownloadState: Sendable, Equatable {
    case idle
    case downloading(progress: Double)
    case completed(localURL: URL)
    case failed(message: String)
}

/// Human-facing download detail derived from the `0…1` progress stream plus
/// the known DMG size: absolute bytes, smoothed speed, and an ETA. Drives the
/// popover's "26.5 / 42.8 MB · 9.4 MB/s · 2s remaining" line.
public struct DownloadMetrics: Sendable, Equatable {
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let bytesPerSec: Double
    public let secondsRemaining: Double?

    public init(bytesDone: Int64, bytesTotal: Int64, bytesPerSec: Double, secondsRemaining: Double?) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSec = bytesPerSec
        self.secondsRemaining = secondsRemaining
    }
}

/// Lightweight non-Sparkle updater. The chosen design (see refactor notes):
/// click → URLSession download with progress → save to ~/Downloads → caller
/// `NSWorkspace.open` the DMG. The user then drags TokenBar.app to
/// /Applications/ themselves and relaunches. No code-signing dance.
///
/// What this intentionally does NOT do:
/// - SHA256 verification (relies on TLS to github.com)
/// - in-place replace + relaunch (would need Developer ID + notarization)
/// - background unattended install
public actor AppUpdateDownloader {
    public typealias ProgressHandler = @Sendable (Double) -> Void

    public init() {}

    /// Download `dmgURL` to `~/Downloads/TokenBar-<version>.dmg`. Reports
    /// progress via `onProgress` (called on a background URLSession queue,
    /// caller is responsible for hopping to MainActor for UI updates).
    public func download(
        from dmgURL: URL,
        version: String,
        onProgress: @escaping ProgressHandler
    ) async throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        let destination = downloads.appendingPathComponent("TokenBar-\(version).dmg")

        let delegate = ProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: dmgURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}

/// URLSessionDownloadDelegate that funnels `didWriteData` byte counts back
/// to the caller as `0…1` progress. Sendable-safe because every closure call
/// crosses the actor boundary; the receiver hops to `MainActor` for UI.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(1.0, max(0.0, progress)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `session.download(from:)` API handles destination
        // staging itself; this delegate just streams progress.
        _ = location
    }
}
