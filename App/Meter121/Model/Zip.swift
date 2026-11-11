// Raw deflate for the packed transfers (IMP-63) with Apple's Compression framework (COMPRESSION_ZLIB is raw DEFLATE,
// RFC 1951, without the zlib header).  The meter's inflater takes one final block with the dynamic code only;
// Transfer.packStream checks every piece and sends the raw bytes where the block is of another kind.

import Compression
import Foundation

enum Zip {
    static func deflate(_ raw: [UInt8]) -> [UInt8]? {
        guard !raw.isEmpty else { return nil }
        var dst = [UInt8](repeating: 0, count: raw.count + 64)
        let n = compression_encode_buffer(&dst, dst.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        return n == 0 ? nil : Array(dst[0..<n])
    }

    /// The raw deflate stream unpacked to exactly n bytes, else nil (the CRC-32 of the window is checked after).
    static func inflate(_ z: [UInt8], _ n: Int) -> [UInt8]? {
        guard n > 0, !z.isEmpty else { return nil }
        var dst = [UInt8](repeating: 0, count: n + 1)
        let got = compression_decode_buffer(&dst, dst.count, z, z.count, nil, COMPRESSION_ZLIB)
        return got == n ? Array(dst[0..<n]) : nil
    }
}
