import Foundation
import Darwin

/// How long a GGUF file must be, from its header alone: the header lists every tensor with its type, shape and
/// offset into the data section, so a truncated or half-copied file is caught without reading the weights.
/// Everything read comes from the file and is bounds-checked before any arithmetic.
enum GGUF {
    enum Check: Equatable {
        case whole
        case problem(String)   // truncated or damaged
        case unknown(String)   // couldn't tell (a version or tensor type this code doesn't know)
    }

    /// ggml tensor types: (elements per block, bytes per block), from ggml's type traits. Types ggml has retired
    /// (4, 5, 31–33, 36–38) and any newer than this table are "unknown".
    static let typeSizes: [UInt32: (Int64, Int64)] = [
        0: (1, 4), 1: (1, 2),                                   // F32, F16
        2: (32, 18), 3: (32, 20), 6: (32, 22), 7: (32, 24),    // Q4_0, Q4_1, Q5_0, Q5_1
        8: (32, 34), 9: (32, 36),                               // Q8_0, Q8_1
        10: (256, 84), 11: (256, 110), 12: (256, 144),         // Q2_K, Q3_K, Q4_K
        13: (256, 176), 14: (256, 210), 15: (256, 292),        // Q5_K, Q6_K, Q8_K
        16: (256, 66), 17: (256, 74), 18: (256, 98),           // IQ2_XXS, IQ2_XS, IQ3_XXS
        19: (256, 50), 20: (32, 18), 21: (256, 110),           // IQ1_S, IQ4_NL, IQ3_S
        22: (256, 82), 23: (256, 136),                          // IQ2_S, IQ4_XS
        24: (1, 1), 25: (1, 2), 26: (1, 4), 27: (1, 8), 28: (1, 8),   // I8, I16, I32, I64, F64
        29: (256, 56), 30: (1, 2),                              // IQ1_M, BF16
        34: (256, 54), 35: (256, 66),                           // TQ1_0, TQ2_0
        39: (32, 17),                                           // MXFP4
    ]

    /// Headers hold the tokenizer (vocab, merges), so tens of MB is normal; past this the file isn't checked.
    static let maxHeader: Int64 = 256 << 20

    private enum Stop: Error { case end, tooBig, damaged(String) }

    /// Reads the header front to back through a buffer, never past `maxHeader` or the end of the file.
    private struct Reader {
        let fd: Int32, size: Int64
        var pos: Int64 = 0
        var buf = [UInt8](), bufStart: Int64 = 0

        mutating func need(_ n: Int64) throws {
            guard n >= 0, n <= GGUF.maxHeader, pos <= GGUF.maxHeader - n else { throw Stop.tooBig }
            guard n <= size - pos else { throw Stop.end }
            if pos >= bufStart && pos + n <= bufStart + Int64(buf.count) { return }
            let count = Int(min(max(n, 4 << 20), size - pos))
            var b = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let r = b.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress! + got, count - got, off_t(pos) + off_t(got)) }
                if r <= 0 { throw Stop.end }
                got += r
            }
            buf = b; bufStart = pos
        }
        mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
            try need(Int64(n))
            let s = Int(pos - bufStart)
            pos += Int64(n)
            return buf[s..<(s + n)]
        }
        mutating func skip(_ n: Int64) throws {
            guard n >= 0, n <= GGUF.maxHeader, pos <= GGUF.maxHeader - n else { throw Stop.tooBig }
            guard n <= size - pos else { throw Stop.end }
            pos += n
        }
        /// Little-endian integers straight from the buffer (no slices: this runs once per vocab entry).
        mutating func u32() throws -> UInt32 {
            try need(4)
            let s = Int(pos - bufStart)
            pos += 4
            return buf.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: s, as: UInt32.self)) }
        }
        mutating func u64() throws -> UInt64 {
            try need(8)
            let s = Int(pos - bufStart)
            pos += 8
            return buf.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: s, as: UInt64.self)) }
        }
        /// A length that must fit in what's left of the header.
        mutating func length() throws -> Int64 {
            let n = try u64()
            guard n <= UInt64(GGUF.maxHeader) else { throw Stop.tooBig }
            return Int64(n)
        }
    }

    /// Fixed-size metadata value types: u8 i8 u16 i16 u32 i32 f32 bool u64 i64 f64.
    private static let valueSizes: [UInt32: Int64] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]

    private static func skipValue(_ r: inout Reader, type: UInt32, depth: Int) throws {
        if let n = valueSizes[type] { try r.skip(n); return }
        switch type {
        case 8: try r.skip(try r.length())                     // string
        case 9:                                                // array: item type, count, items
            guard depth < 4 else { throw Stop.damaged("metadata nested too deep") }
            let item = try r.u32()
            let count = try r.length()
            if let n = valueSizes[item] {
                let (total, over) = count.multipliedReportingOverflow(by: n)
                if over { throw Stop.tooBig }
                try r.skip(total)
            } else if item == 8 {
                for _ in 0..<count { try r.skip(try r.length()) }   // vocab and merges: the common, big case
            } else {
                for _ in 0..<count { try skipValue(&r, type: item, depth: depth + 1) }
            }
        default: throw Stop.damaged("unknown metadata type \(type)")
        }
    }

    /// The check, on an open file of `size` bytes.
    static func check(fd: Int32, size: Int64) -> Check {
        var r = Reader(fd: fd, size: size)
        do {
            guard Array(try r.bytes(4)) == Array("GGUF".utf8) else { return .problem("not a GGUF file (bad header)") }
            let version = try r.u32()
            // Big-endian files show a byte-swapped version here; version 1 had 32-bit counts.
            guard version == 2 || version == 3 else { return .unknown("GGUF version \(version) isn't one this checks, length not checked") }
            let tensors = try r.u64(), kvs = try r.u64()
            guard tensors <= 1 << 24, kvs <= 1 << 24 else { return .problem("damaged header (implausible counts)") }
            var alignment: Int64 = 32
            for _ in 0..<kvs {
                let klen = try r.length()
                guard klen <= 1 << 16 else { return .problem("damaged header (key too long)") }
                let key = String(decoding: try r.bytes(Int(klen)), as: UTF8.self)
                let type = try r.u32()
                if key == "general.alignment" && type == 4 {
                    let a = try r.u32()
                    guard a > 0, a & (a - 1) == 0, a <= 1 << 20 else { return .problem("damaged header (bad alignment)") }
                    alignment = Int64(a)
                } else {
                    try skipValue(&r, type: type, depth: 0)
                }
            }
            var end: Int64 = 0, unknownType: UInt32?   // any tensor of a type not in the table
            for _ in 0..<tensors {
                let nlen = try r.length()
                guard nlen <= 1 << 16 else { return .problem("damaged header (tensor name too long)") }
                try r.skip(nlen)
                let dims = try r.u32()
                guard dims <= 8 else { return .problem("damaged header (tensor with \(dims) dimensions)") }
                var elements: Int64 = 1
                for _ in 0..<dims {
                    let d = try r.u64()
                    guard d <= UInt64(Int64.max) else { return .problem("damaged header (bad tensor shape)") }
                    let (e, over) = elements.multipliedReportingOverflow(by: Int64(d))
                    guard !over else { return .problem("damaged header (bad tensor shape)") }
                    elements = e
                }
                let type = try r.u32()
                let off = try r.u64()
                guard off <= UInt64(Int64.max / 2) else { return .problem("damaged header (bad tensor offset)") }
                let offset = Int64(off)
                var tensorEnd = offset + 1   // an unknown type: at least its first byte must be there
                if let (block, bytes) = typeSizes[type] {
                    guard elements % block == 0 else { return .problem("damaged header (tensor shape doesn't fit its type)") }
                    let (n, over) = (elements / block).multipliedReportingOverflow(by: bytes)
                    guard !over, n <= Int64.max / 2 else { return .problem("damaged header (tensor too large)") }
                    tensorEnd = offset + n
                }
                end = max(end, tensorEnd)
                if typeSizes[type] == nil { unknownType = unknownType ?? type }
            }
            // No tensors (a vocab-only file): nothing follows the header, not even alignment padding (review L2).
            let dataStart = tensors == 0 ? r.pos : (r.pos + alignment - 1) / alignment * alignment   // pos ≤ maxHeader
            let (needed, over) = dataStart.addingReportingOverflow(end)
            if over || needed > size { return .problem("truncated (header needs \(needed) bytes, file has \(size))") }
            // A tensor of unknown size can't be ruled out as the last one, whatever the offsets say (review L4).
            if let t = unknownType { return .unknown("a tensor has a type this doesn't know (ggml type \(t)), so the length is only partly checked") }
            return .whole
        } catch Stop.end {
            return .problem("truncated (the file ends inside its header)")
        } catch Stop.tooBig {
            return .unknown("header larger than \(maxHeader >> 20) MB, length not checked")
        } catch Stop.damaged(let why) {
            return .problem("damaged header (\(why))")
        } catch {
            return .problem("damaged header")
        }
    }
}
