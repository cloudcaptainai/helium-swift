import Foundation
import Compression

/// Compresses ctx bytes (post-JSON-serialization, pre-base64URL) so the
/// bundler URL doesn't blow Safari's URL budget when paywalls carry
/// multiple pre-fetched Paddle bootstraps.
///
/// **Wire pairing:** Swift `COMPRESSION_ZLIB` ↔ JS
/// `DecompressionStream('deflate-raw')`. Apple's `COMPRESSION_ZLIB`
/// emits raw DEFLATE (RFC 1951, no zlib/gzip wrapper) despite the name —
/// see Apple's docs for `compression.h`. `DecompressionStream('deflate-raw')`
/// in browsers (Safari 16.4+) consumes raw DEFLATE exactly. Both ends
/// are native, no third-party libraries on either side.
///
/// `CtxCompression.deflateRaw(...)` is intentionally a free function
/// rather than a class method — it has no state, no actor isolation
/// constraint, and the call site (`buildEnrichedCheckoutURL`) just
/// needs `Data → Data?`.
enum CtxCompression {

    /// Apple's `compression_encode_buffer` doesn't expose a quality/level
    /// parameter — the level is internal to the framework. For our use
    /// (small JSON ctx, run once per Subscribe-tap), the default level
    /// is fine; the size win comes from the algorithm, not the level.
    ///
    /// Returns nil when the framework reports a 0-byte output, which it
    /// does on encoder failure or when the destination buffer is too
    /// small. The bundler exclusively decodes compressed ctx, so
    /// callers must abort the checkout on nil rather than emit an
    /// uncompressed payload — the bundler would silently parse an
    /// uncompressed payload as empty defaults and the user would
    /// land on a paywall with no product data.
    static func deflateRaw(_ data: Data) -> Data? {
        // The encoder doesn't know the output size up-front, so we have
        // to allocate a destination buffer big enough for the worst case.
        // For DEFLATE, the worst-case overhead on incompressible data is
        // bounded by ~5 bytes per 16KB block + ~5 bytes header. We add
        // a generous fudge factor (input + 64 bytes + 10% margin) so even
        // pathological tiny inputs don't OOM the encoder.
        let dstCapacity = max(64, data.count + 64 + data.count / 10)

        var dst = [UInt8](repeating: 0, count: dstCapacity)
        let written = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let baseAddr = srcPtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                &dst, dstCapacity,
                baseAddr.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        // `compression_encode_buffer` returns 0 on failure (or when the
        // dst buffer is too small). For a non-empty input that's an
        // error; for an empty input it's legitimate (DEFLATE empty
        // streams are tiny but non-zero, but Apple may also return 0
        // for trivially-empty inputs).
        guard written > 0 else { return nil }
        return Data(dst.prefix(written))
    }
}
