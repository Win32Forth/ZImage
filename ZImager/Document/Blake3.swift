import Foundation

/// Unkeyed BLAKE3, 32-byte output. Port of the reference hasher's regular hash.
/// The empty digest is `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`.
nonisolated enum Blake3 {
    static func hash(_ data: Data) -> Data {
        var hasher = Hasher()
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                hasher.update(UnsafeRawBufferPointer(start: base, count: data.count))
            } else {
                hasher.update(UnsafeRawBufferPointer(start: nil, count: 0))
            }
        }
        return hasher.finalize()
    }

    static func hex(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    private static let blockLength = 64
    private static let chunkLength = 1024
    private static let chunkStart: UInt32 = 1
    private static let chunkEnd: UInt32 = 2
    private static let parentFlag: UInt32 = 4
    private static let rootFlag: UInt32 = 8
    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    private static let messagePermutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

    private struct Output {
        var chainingValue: [UInt32]
        var blockWords: [UInt32]
        var counter: UInt64
        var blockLength: UInt32
        var flags: UInt32

        func compressedChainingValue() -> [UInt32] {
            Array(compress(
                chainingValue: chainingValue,
                blockWords: blockWords,
                counter: counter,
                blockLength: blockLength,
                flags: flags
            ).prefix(8))
        }

        func rootBytes() -> Data {
            let words = compress(
                chainingValue: chainingValue,
                blockWords: blockWords,
                counter: 0,
                blockLength: blockLength,
                flags: flags | Blake3.rootFlag
            )
            var bytes = Data(count: 32)
            for index in 0..<8 {
                let value = words[index].littleEndian
                bytes[index * 4] = UInt8(truncatingIfNeeded: value)
                bytes[index * 4 + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[index * 4 + 2] = UInt8(truncatingIfNeeded: value >> 16)
                bytes[index * 4 + 3] = UInt8(truncatingIfNeeded: value >> 24)
            }
            return bytes
        }
    }

    private struct ChunkState {
        var chainingValue: [UInt32]
        var chunkCounter: UInt64
        var block = [UInt8](repeating: 0, count: Blake3.blockLength)
        var blockLength = 0
        var blocksCompressed = 0

        var count: Int { Blake3.blockLength * blocksCompressed + blockLength }

        mutating func update(_ input: ArraySlice<UInt8>) {
            var remaining = input
            while !remaining.isEmpty {
                if blockLength == Blake3.blockLength {
                    chainingValue = Array(compress(
                        chainingValue: chainingValue,
                        blockWords: words(from: block),
                        counter: chunkCounter,
                        blockLength: UInt32(Blake3.blockLength),
                        flags: blocksCompressed == 0 ? Blake3.chunkStart : 0
                    ).prefix(8))
                    blocksCompressed += 1
                    block = [UInt8](repeating: 0, count: Blake3.blockLength)
                    blockLength = 0
                }
                let take = min(Blake3.blockLength - blockLength, remaining.count)
                for offset in 0..<take {
                    block[blockLength + offset] = remaining[remaining.startIndex + offset]
                }
                blockLength += take
                remaining = remaining.dropFirst(take)
            }
        }

        func output() -> Output {
            var flags: UInt32 = Blake3.chunkEnd
            if blocksCompressed == 0 { flags |= Blake3.chunkStart }
            return Output(
                chainingValue: chainingValue,
                blockWords: words(from: block),
                counter: chunkCounter,
                blockLength: UInt32(blockLength),
                flags: flags
            )
        }
    }

    private struct Hasher {
        var chunk = ChunkState(chainingValue: Blake3.iv, chunkCounter: 0)
        var stack: [[UInt32]] = []

        mutating func update(_ buffer: UnsafeRawBufferPointer) {
            let bytes = [UInt8](buffer)
            var offset = 0
            while offset < bytes.count {
                if chunk.count == Blake3.chunkLength {
                    let total = chunk.chunkCounter + 1
                    addChunk(chunk.output().compressedChainingValue(), totalChunks: total)
                    chunk = ChunkState(chainingValue: Blake3.iv, chunkCounter: total)
                }
                let take = min(Blake3.chunkLength - chunk.count, bytes.count - offset)
                chunk.update(bytes[offset..<(offset + take)])
                offset += take
            }
        }

        mutating func addChunk(_ newValue: [UInt32], totalChunks: UInt64) {
            var value = newValue
            var total = totalChunks
            while total & 1 == 0 {
                let left = stack.removeLast()
                value = parentOutput(left: left, right: value).compressedChainingValue()
                total >>= 1
            }
            stack.append(value)
        }

        func finalize() -> Data {
            var output = chunk.output()
            var remaining = stack.count
            while remaining > 0 {
                remaining -= 1
                output = parentOutput(left: stack[remaining], right: output.compressedChainingValue())
            }
            return output.rootBytes()
        }
    }

    private static func parentOutput(left: [UInt32], right: [UInt32]) -> Output {
        Output(
            chainingValue: iv,
            blockWords: left + right,
            counter: 0,
            blockLength: UInt32(blockLength),
            flags: parentFlag
        )
    }

    private static func words(from bytes: [UInt8]) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            let offset = index * 4
            guard offset + 3 < bytes.count else { break }
            words[index] = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        return words
    }

    private static func compress(
        chainingValue: [UInt32],
        blockWords: [UInt32],
        counter: UInt64,
        blockLength: UInt32,
        flags: UInt32
    ) -> [UInt32] {
        var state: [UInt32] = [
            chainingValue[0], chainingValue[1], chainingValue[2], chainingValue[3],
            chainingValue[4], chainingValue[5], chainingValue[6], chainingValue[7],
            iv[0], iv[1], iv[2], iv[3],
            UInt32(truncatingIfNeeded: counter),
            UInt32(truncatingIfNeeded: counter >> 32),
            blockLength,
            flags,
        ]
        var message = blockWords
        for _ in 0..<7 {
            round(&state, message)
            message = permute(message)
        }
        for index in 0..<8 {
            state[index] ^= state[index + 8]
            state[index + 8] ^= chainingValue[index]
        }
        return state
    }

    private static func round(_ state: inout [UInt32], _ message: [UInt32]) {
        mix(&state, 0, 4, 8, 12, message[0], message[1])
        mix(&state, 1, 5, 9, 13, message[2], message[3])
        mix(&state, 2, 6, 10, 14, message[4], message[5])
        mix(&state, 3, 7, 11, 15, message[6], message[7])
        mix(&state, 0, 5, 10, 15, message[8], message[9])
        mix(&state, 1, 6, 11, 12, message[10], message[11])
        mix(&state, 2, 7, 8, 13, message[12], message[13])
        mix(&state, 3, 4, 9, 14, message[14], message[15])
    }

    private static func mix(
        _ state: inout [UInt32],
        _ a: Int, _ b: Int, _ c: Int, _ d: Int,
        _ mx: UInt32, _ my: UInt32
    ) {
        state[a] = state[a] &+ state[b] &+ mx
        state[d] = (state[d] ^ state[a]).rotated(right: 16)
        state[c] = state[c] &+ state[d]
        state[b] = (state[b] ^ state[c]).rotated(right: 12)
        state[a] = state[a] &+ state[b] &+ my
        state[d] = (state[d] ^ state[a]).rotated(right: 8)
        state[c] = state[c] &+ state[d]
        state[b] = (state[b] ^ state[c]).rotated(right: 7)
    }

    private static func permute(_ message: [UInt32]) -> [UInt32] {
        messagePermutation.map { message[$0] }
    }
}

private extension UInt32 {
    func rotated(right count: UInt32) -> UInt32 {
        (self >> count) | (self << (32 - count))
    }
}
