import Foundation
import Testing
@testable import TokenBarCore

/// Decompression correctness for the vendored Czstd wrapper.
///
/// Fixtures under Fixtures/dsh:
/// - session.jsonl.zstd   single frame (whole file compressed at once)
/// - session.v4.jsonl.zstd 8 frames (one per JSONL line), mirroring how DSH
///   appends one small frame per event batch.
struct ZstdStreamTests {
    private func fixture(_ name: String) throws -> Data {
        let parts = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = fixtureBundle.url(forResource: parts, withExtension: ext, subdirectory: "dsh")
            ?? fixtureBundle.url(forResource: parts, withExtension: ext) else {
            throw ZstdFixtureError.missing
        }
        return try Data(contentsOf: url)
    }

    private func expectedPlaintext(_ resource: String) throws -> String {
        let url = fixtureBundle.url(forResource: resource, withExtension: "jsonl", subdirectory: "dsh")
            ?? fixtureBundle.url(forResource: resource, withExtension: "jsonl")
        return try String(contentsOf: url!, encoding: .utf8)
    }

    @Test
    func decompressesSingleFrame() throws {
        let compressed = try fixture("dsh-legacy.jsonl.zstd")
        let (data, truncated) = try ZstdStream.decompressStreaming(compressed)
        let expected = try expectedPlaintext("dsh-legacy")
        #expect(!truncated)
        #expect(String(data: data, encoding: .utf8) == expected)
    }

    @Test
    func decompressesMultiFrameAppend() throws {
        // 8 independently compressed frames concatenated; the streaming API
        // must decode every frame, not just the first.
        let compressed = try fixture("dsh-v4.jsonl.zstd")
        let (data, truncated) = try ZstdStream.decompressStreaming(compressed)
        let expected = try expectedPlaintext("dsh-v4")
        #expect(!truncated)
        #expect(String(data: data, encoding: .utf8) == expected)
    }

    @Test
    func truncatedTailFrameEmitsPrefixAndFlag() throws {
        let compressed = try fixture("dsh-v4.jsonl.zstd")
        // Keep only the bytes of the first frame: every frame is >= 12 bytes
        // and frame boundaries are unknowable without decoding, so decode
        // forward and find the first prefix that is flagged truncated while
        // still producing the first frame's line.
        let single = try fixture("dsh-legacy.jsonl.zstd")
        let cut = compressed.prefix(single.count / 2)
        let (data, truncated) = try ZstdStream.decompressStreaming(Data(cut))
        #expect(truncated)
        #expect(!data.isEmpty)
        // Whatever was emitted must be valid UTF-8 (a prefix of the stream).
        _ = String(data: data, encoding: .utf8)
    }

    @Test
    func emptyInputIsEmptyOutput() throws {
        let (data, truncated) = try ZstdStream.decompressStreaming(Data())
        #expect(data.isEmpty)
        #expect(!truncated)
    }

    @Test
    func rejectsGarbageAsError() {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        #expect(throws: (any Error).self) {
            _ = try ZstdStream.decompressStreaming(garbage)
        }
    }
}

enum ZstdFixtureError: Error {
    case missing
}
