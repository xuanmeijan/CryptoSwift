//
//  CryptoSwift
//
//  Copyright (C) 2014-2017 Marcin Krzyżanowski <marcin@krzyzanowskim.com>
//  This software is provided 'as-is', without any express or implied warranty.
//
//  In no event will the authors be held liable for any damages arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:
//
//  - The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation is required.
//  - Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
//  - This notice may not be removed or altered from any source or binary distribution.
//

//  Galois/Counter Mode (GCM)
//  https://csrc.nist.gov/publications/detail/sp/800-38d/final
//  ref: http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.694.695&rep=rep1&type=pdf
//

public final class GCM: BlockMode {
    public let options: BlockModeOptions = [.initializationVectorRequired, .useEncryptToDecrypt]

    public enum Error: Swift.Error {
        /// Invalid IV
        case invalidInitializationVector
        /// Special symbol FAIL that indicates that the inputs are not authentic.
        case fail
    }

    private let iv: Array<UInt8>
    private let additionalAuthenticatedData: Array<UInt8>?

    // `authenticationTag` nil for encryption, known tag for decryption
    /// For encryption, the value is set at the end of the encryption.
    /// For decryption, this is a known Tag to validate against.
    public var authenticationTag: Array<UInt8>?

    // encrypt
    public init(iv: Array<UInt8>, additionalAuthenticatedData: Array<UInt8>? = nil) {
        self.iv = iv
        self.additionalAuthenticatedData = additionalAuthenticatedData
    }

    // decrypt
    public convenience init(iv: Array<UInt8>, authenticationTag: Array<UInt8>, additionalAuthenticatedData: Array<UInt8>? = nil) {
        self.init(iv: iv, additionalAuthenticatedData: additionalAuthenticatedData)
        self.authenticationTag = authenticationTag
    }

    public func worker(blockSize: Int, cipherOperation: @escaping CipherOperationOnBlock) throws -> BlockModeWorker {
        if iv.isEmpty {
            throw Error.invalidInitializationVector
        }

        let worker = GCMModeWorker(iv: iv.slice, aad: additionalAuthenticatedData?.slice, expectedTag: authenticationTag, cipherOperation: cipherOperation)
        worker.didCalculateTag = { tag in
            self.authenticationTag = tag
        }
        return worker
    }
}


// MARK: - Worker

final class GCMModeWorker: BlockModeWorkerFinalizing {

    let cipherOperation: CipherOperationOnBlock

    // Callback called when authenticationTag is ready
    var didCalculateTag: ((Array<UInt8>) -> Void)? = nil

    // 128 bit tag. Other possible tags 4,8,12,13,14,15,16
    private static let tagSize = 16
    // GCM nonce is 96-bits by default. It's the most effective length for the IV
    private static let nonceSize = 12

    // GCM is designed for 128-bit ciphers like AES (but not really for Blowfish). 64-bit mode is not implemented.
    private let blockSize = 16 // 128 bit
    private let iv: ArraySlice<UInt8>
    private var counter: UInt128
    private let eky0: UInt128 // move to GF?
    private let h: UInt128

    // Additional authenticated data
    private let aad: ArraySlice<UInt8>?
    // Known Tag used to validate during decryption
    private let expectedTag: Array<UInt8>?

    // Note: need new worker to reset instance
    // Use empty aad if not specified. AAD is optional.
    private lazy var gf: GF = {
        if let aad = aad {
            return GF(aad: Array(aad), h: h, blockSize: blockSize)
        }
        return GF(aad: [UInt8](), h: h, blockSize: blockSize)
    }()

    init(iv: ArraySlice<UInt8>, aad: ArraySlice<UInt8>? = nil, expectedTag: Array<UInt8>? = nil, cipherOperation: @escaping CipherOperationOnBlock) {
        self.cipherOperation = cipherOperation
        self.iv = iv
        self.aad = aad
        self.expectedTag = expectedTag
        self.h = UInt128(cipherOperation(Array<UInt8>(repeating: 0, count: blockSize).slice)!) // empty block
        
        // Assume nonce is 12 bytes long, otherwise initial counter would be calulated from GHASH
        // counter = GF.ghash(aad: [UInt8](), ciphertext: nonce)
        if iv.count == GCMModeWorker.nonceSize {
            counter = makeCounter(nonce: Array(self.iv))
        } else {
            counter = GF.ghash(h: h, aad: [UInt8](), ciphertext: Array(iv), blockSize: blockSize)
        }

        // Set constants
        eky0 = UInt128(cipherOperation(counter.bytes.slice)!)
    }

    func encrypt(_ plaintext: ArraySlice<UInt8>) -> Array<UInt8> {
        counter = incrementCounter(counter)

        guard let ekyN = cipherOperation(counter.bytes.slice) else {
            return Array(plaintext)
        }

        // plaintext block ^ ek1
        let ciphertext = xor(plaintext, ekyN) as Array<UInt8>

        // update ghash incrementally
        gf.ghashUpdate(block: ciphertext)

        return Array(ciphertext)
    }

    func decrypt(_ ciphertext: ArraySlice<UInt8>) -> Array<UInt8> {
        counter = incrementCounter(counter)

        // update ghash incrementally
        gf.ghashUpdate(block: Array(ciphertext))

        guard let ekN = cipherOperation(counter.bytes.slice) else {
            return Array(ciphertext)
        }

        // ciphertext block ^ ek1
        let plaintext = xor(ciphertext, ekN) as Array<UInt8>
        return plaintext
    }

    func finalize(encrypt ciphertext: ArraySlice<UInt8>) throws -> Array<UInt8> {
        // Calculate MAC tag.
        let ghash = gf.ghashFinish()
        let tag = Array((ghash ^ eky0).bytes.prefix(GCMModeWorker.tagSize))

        // Notify handler
        didCalculateTag?(tag)
        
        return Array(ciphertext)
    }

    // The authenticated decryption operation has five inputs: K, IV , C, A, and T. It has only a single
    // output, either the plaintext value P or a special symbol FAIL that indicates that the inputs are not
    // authentic.
    func finalize(decrypt plaintext: ArraySlice<UInt8>) throws -> Array<UInt8> {
        // Calculate MAC tag.
        let ghash = gf.ghashFinish()
        let computedTag = Array((ghash ^ eky0).bytes.prefix(GCMModeWorker.tagSize))

        // Validate tag
        if let expectedTag = self.expectedTag, computedTag == expectedTag {
            return Array(plaintext)
        }

        throw GCM.Error.fail
    }
}

// MARK: - Local utils

private func makeCounter(nonce: Array<UInt8>) -> UInt128 {
    return UInt128(nonce + [0, 0, 0, 1])
}

// Successive counter values are generated using the function incr(), which treats the rightmost 32
// bits of its argument as a nonnegative integer with the least significant bit on the right
private func incrementCounter(_ counter: UInt128) -> UInt128 {
    let b = counter.i.b + 1
    let a = (b == 0 ? counter.i.a + 1 : counter.i.a)
    return UInt128((a, b))
}

// If data is not a multiple of block size bytes long then the remainder is zero padded
// Note: It's similar to ZeroPadding, but it's not the same.
private func addPadding(_ bytes: Array<UInt8>, blockSize: Int) -> Array<UInt8> {
    if bytes.isEmpty {
        return Array<UInt8>(repeating: 0, count: blockSize)
    }

    let remainder = bytes.count % blockSize
    if remainder == 0 {
        return bytes
    }

    let paddingCount = blockSize - remainder
    if paddingCount > 0 {
        return bytes + Array<UInt8>(repeating: 0, count: paddingCount)
    }
    return bytes
}

// MARK: - GF

/// The Field GF(2^128)
private final class GF {
    static let r = UInt128(a: 0xE100000000000000, b: 0)

    let blockSize: Int
    let h: UInt128

    // AAD won't change
    let aadLength: Int

    // Updated for every consumed block
    var ciphertextLength: Int

    // Start with 0
    var x: UInt128

    init(aad: [UInt8], h: UInt128, blockSize: Int) {
        self.blockSize = blockSize
        self.aadLength = aad.count
        self.ciphertextLength = 0
        self.h = h
        self.x = 0

        // Calculate for AAD at the begining
        x = GF.calculateX(aad: aad, x: x, h: h, blockSize: blockSize)
    }

    @discardableResult
    func ghashUpdate(block ciphertextBlock: Array<UInt8>) -> UInt128 {
        ciphertextLength += ciphertextBlock.count
        x = GF.calculateX(block: addPadding(ciphertextBlock, blockSize: blockSize), x: x, h: h, blockSize: blockSize)
        return x
    }

    func ghashFinish() -> UInt128 {
        // len(A) || len(C)
        let len = UInt128(a: UInt64(aadLength * 8), b: UInt64(ciphertextLength * 8))
        x = GF.multiply((x ^ len), h)
        return x
    }

    // GHASH. One-time calculation
    static func ghash(x startx: UInt128 = 0, h: UInt128, aad: Array<UInt8>, ciphertext: Array<UInt8>, blockSize: Int) -> UInt128 {
        var x = calculateX(aad: aad, x: startx, h: h, blockSize: blockSize)
            x = calculateX(ciphertext: ciphertext, x: x, h: h, blockSize: blockSize)

        // len(aad) || len(ciphertext)
        let len = UInt128(a: UInt64(aad.count * 8), b: UInt64(ciphertext.count * 8))
        x = multiply((x ^ len), h)

        return x
    }

    // Calculate Ciphertext part, for all blocks
    // Not used with incremental calculation.
    private static func calculateX(ciphertext: [UInt8], x startx: UInt128, h: UInt128, blockSize: Int) -> UInt128 {
        let pciphertext = addPadding(ciphertext, blockSize: blockSize)
        let blocksCount = pciphertext.count / blockSize

        var x = startx
        for i in 0..<blocksCount {
            let cpos = i * blockSize
            let block = pciphertext[pciphertext.startIndex.advanced(by: cpos)..<pciphertext.startIndex.advanced(by: cpos + blockSize)]
            x = calculateX(block: Array(block), x: x, h: h, blockSize: blockSize)
        }
        return x
    }

    // block is expected to be padded with addPadding
    private static func calculateX(block ciphertextBlock: Array<UInt8>, x: UInt128, h: UInt128, blockSize: Int) -> UInt128 {
        let k = x ^ UInt128(ciphertextBlock)
        return multiply(k, h)
    }

    // Calculate AAD part, for all blocks
    private static func calculateX(aad: [UInt8], x startx: UInt128, h: UInt128, blockSize: Int) -> UInt128 {
        let paad = addPadding(aad, blockSize: blockSize)
        let blocksCount = paad.count / blockSize

        var x = startx
        for i in 0..<blocksCount {
            let apos = i * blockSize
            let k = x ^ UInt128(paad[paad.startIndex.advanced(by: apos)..<paad.startIndex.advanced(by: apos + blockSize)])
            x = multiply(k, h)
        }

        return x
    }

    // Multiplication GF(2^128).
    private static func multiply(_ x: UInt128, _ y: UInt128) -> UInt128 {
        var z: UInt128 = 0
        var v = x
        var k = UInt128(a: 1 << 63, b: 0)

        for _ in 0..<128 {
            if y & k == k {
                z = z ^ v
            }

            if v & 1 != 1 {
                v = v >> 1
            } else {
                v = (v >> 1) ^ r
            }

            k = k >> 1
        }

        return z
    }
}
