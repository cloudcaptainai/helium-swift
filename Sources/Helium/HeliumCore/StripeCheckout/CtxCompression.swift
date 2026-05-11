import Foundation
import Compression

enum CtxCompression {

    /// Returns nil on encoder failure. Note that `COMPRESSION_ZLIB` emits
    /// raw DEFLATE (RFC 1951, no zlib/gzip wrapper) despite the name.
    /// Callers must abort on nil — never emit an uncompressed payload.
    static func deflateRaw(_ data: Data) -> Data? {
        // DEFLATE worst-case bound + margin for pathological tiny inputs.
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

        guard written > 0 else { return nil }
        return Data(dst.prefix(written))
    }
}
