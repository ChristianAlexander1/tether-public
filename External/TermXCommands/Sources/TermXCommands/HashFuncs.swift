import Foundation

/// Pure-Swift MD5 (RFC 1321) and SHA-1 (FIPS 180-1). No CryptoKit dependency so
/// these build on Linux and macOS with Foundation only.

func InsecureMD5(_ data: Data) -> [UInt8] {
    let bytes = [UInt8](data)
    let bitLenBits = UInt64(bytes.count) * 8

    // Padding: 0x80 then zeros until length ≡ 56 (mod 64), then 8-byte length.
    var m = bytes
    m.append(0x80)
    while m.count % 64 != 56 { m.append(0) }
    for i in stride(from: 0, to: 8, by: 1) {
        m.append(UInt8((bitLenBits >> UInt64(i * 8)) & 0xff))
    }

    var a0: UInt32 = 0x67452301
    var b0: UInt32 = 0xefcdab89
    var c0: UInt32 = 0x98badcfe
    var d0: UInt32 = 0x10325476

    let shifts: [UInt32] = [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
                            5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
                            4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
                            6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21]
    // MD5 round constants K[i] = floor(2^32 * abs(sin(i+1))), hardcoded so the
    // file needs no libm/`sin` symbol (portable across platforms with just
    // Foundation).
    let K: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    var offset = 0
    while offset < m.count {
        var w = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let base = offset + i * 4
            w[i] = UInt32(m[base]) | (UInt32(m[base+1]) << 8) | (UInt32(m[base+2]) << 16) | (UInt32(m[base+3]) << 24)
        }

        var A = a0, B = b0, C = c0, D = d0
        for i in 0..<64 {
            var F: UInt32
            var g: Int
            switch i {
            case 0..<16: F = (B & C) | (~B & D); g = i
            case 16..<32: F = (D & B) | (~D & C); g = (5 * i + 1) % 16
            case 32..<48: F = B ^ C ^ D; g = (3 * i + 5) % 16
            default: F = C ^ (B | ~D); g = (7 * i) % 16
            }
            F = F &+ A &+ K[i] &+ w[g]
            A = D; D = C; C = B
            B = B &+ rotateLeft(F, shifts[i])
        }
        a0 = a0 &+ A; b0 = b0 &+ B; c0 = c0 &+ C; d0 = d0 &+ D
        offset += 64
    }

    var out: [UInt8] = []
    for v in [a0, b0, c0, d0] {
        out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff))
        out.append(UInt8((v >> 16) & 0xff)); out.append(UInt8((v >> 24) & 0xff))
    }
    return out
}

func SHA1Compat(_ data: Data) -> [UInt8] {
    let bytes = [UInt8](data)
    let bitLenBits = UInt64(bytes.count) * 8
    var m = bytes
    m.append(0x80)
    while m.count % 64 != 56 { m.append(0) }
    for i in stride(from: 0, to: 8, by: 1) {
        m.append(UInt8((bitLenBits >> UInt64((7 - i) * 8)) & 0xff))
    }

    var h0: UInt32 = 0x67452301
    var h1: UInt32 = 0xefcdab89
    var h2: UInt32 = 0x98badcfe
    var h3: UInt32 = 0x10325476
    var h4: UInt32 = 0xc3d2e1f0

    var offset = 0
    while offset < m.count {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let base = offset + i * 4
            w[i] = UInt32(m[base]) << 24 | UInt32(m[base+1]) << 16 | UInt32(m[base+2]) << 8 | UInt32(m[base+3])
        }
        for i in 16..<80 {
            w[i] = rotateLeft(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1)
        }
        var a = h0, b = h1, c = h2, d = h3, e = h4
        for i in 0..<80 {
            var f: UInt32
            var k: UInt32
            if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999 }
            else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
            else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
            else { f = b ^ c ^ d; k = 0xCA62C1D6 }
            let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = rotateLeft(b, 30); b = a; a = temp
        }
        h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        offset += 64
    }

    var out: [UInt8] = []
    for v in [h0, h1, h2, h3, h4] {
        out.append(UInt8((v >> 24) & 0xff)); out.append(UInt8((v >> 16) & 0xff))
        out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8(v & 0xff))
    }
    return out
}

private func rotateLeft(_ x: UInt32, _ n: UInt32) -> UInt32 {
    return (x << n) | (x >> (32 - n))
}
