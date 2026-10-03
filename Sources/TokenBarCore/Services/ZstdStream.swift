import Czstd
import Foundation

/// Thin Swift wrapper over the vendored decompress-only libzstd.
///
/// Used by the DSH (DeepSeek Harness) source to read the zstd-compressed
/// session JSONL files under the .dsh/sessions tree. DSH appends one small
/// zstd frame per event batch, so files are MULTI-frame and must be decoded
/// with the streaming API rather than ZSTD_decompress (single-frame only).
public enum ZstdStream {
    /// Upper bound we are willing to buffer for one session file.
    public static let maxOutputBytes = 256 * 1024 * 1024

    private static let chunkBytes = 512 * 1024

    /// Errors surfaced to callers.
    public enum DecompressError: Error, Sendable {
        case outputTooLarge(Int)
        case zstdFailure(String)
    }

    /// Streaming decode of every complete frame in the buffer.
    ///
    /// - Returns: the concatenated decompressed bytes plus truncated,
    ///   which is true when the buffer ends mid-frame (DSH writes the tail
    ///   frame incrementally while a session is live). Callers keep the
    ///   already-emitted bytes and re-read once the file grows.
    public static func decompressStreaming(_ compressed: Data) throws -> (data: Data, truncated: Bool) {
        var output = Data()
        var truncated = false

        let dctx: OpaquePointer? = ZSTD_createDCtx()
        defer { _ = ZSTD_freeDCtx(dctx) }

        var chunk = [UInt8](repeating: 0, count: chunkBytes)

        try compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Void in
            guard let srcBase = src.baseAddress, src.count > 0 else { return }
            var input = ZSTD_inBuffer(src: srcBase, size: src.count, pos: 0)

            while input.pos < input.size {
                var producedTotal = 0
                var frameOpen = true
                while frameOpen {
                    var out = ZSTD_outBuffer(dst: &chunk, size: chunkBytes, pos: 0)
                    let hint = ZSTD_decompressStream(dctx, &out, &input)
                    if ZSTD_isError(hint) != 0 {
                        throw DecompressError.zstdFailure(String(cString: ZSTD_getErrorName(hint)))
                    }
                    let produced = out.pos
                    if produced > 0 {
                        if output.count + produced > maxOutputBytes {
                            throw DecompressError.outputTooLarge(output.count + produced)
                        }
                        output.append(contentsOf: chunk[0..<produced])
                        producedTotal += produced
                    }
                    if hint == 0 {
                        // Current frame fully flushed; a new frame (if any)
                        // starts at input.pos.
                        frameOpen = false
                    } else if input.pos >= input.size {
                        // Mid-frame at end of buffer: live-session tail frame.
                        truncated = true
                        frameOpen = false
                    }
                }
                if producedTotal == 0 && input.pos < input.size && !truncated {
                    // No forward progress on a non-empty remainder: stop
                    // instead of looping forever on adversarial input.
                    truncated = true
                    break
                }
            }
        }

        return (output, truncated)
    }
}
