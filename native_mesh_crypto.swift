import CommonCrypto
import Foundation

enum NativeMeshCryptoError: Error, CustomStringConvertible {
    case invalidHex(String)
    case invalidLength(String)
    case invalidParameter(String)
    case authenticationFailed(String)
    case cryptorStatus(CCCryptorStatus)

    var description: String {
        switch self {
        case .invalidHex(let value):
            return "invalid hex: \(value)"
        case .invalidLength(let value):
            return "invalid length: \(value)"
        case .invalidParameter(let value):
            return "invalid parameter: \(value)"
        case .authenticationFailed(let value):
            return "authentication failed: \(value)"
        case .cryptorStatus(let status):
            return "CommonCrypto status \(status)"
        }
    }
}

struct MeshKeyMaterial: Equatable {
    let nid: UInt8
    let encryptionKey: [UInt8]
    let privacyKey: [UInt8]
}

struct AesCcmResult: Equatable {
    let ciphertext: [UInt8]
    let mic: [UInt8]
}

struct NetworkPduResult: Equatable {
    let nonce: [UInt8]
    let encryptedDstAndTransportPdu: [UInt8]
    let netMic: [UInt8]
    let privacyPlaintext: [UInt8]
    let pecb: [UInt8]
    let obfuscatedCtlTtlSeqSrc: [UInt8]
    let networkPdu: [UInt8]
    let proxyPdu: [UInt8]
}

struct UpperTransportAccessResult: Equatable {
    let nonce: [UInt8]
    let encAccessMessage: [UInt8]
    let transMic: [UInt8]
    let upperTransportPdu: [UInt8]
}

struct LowerTransportAccessResult: Equatable {
    let header: UInt8
    let lowerTransportPdu: [UInt8]
}

struct LowerTransportSegmentedAccessSegment: Equatable {
    let header: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segO: UInt8
    let segN: UInt8
    let segment: [UInt8]
    let lowerTransportPdu: [UInt8]
}

struct LowerTransportSegmentedAccessResult: Equatable {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segN: UInt8
    let segments: [LowerTransportSegmentedAccessSegment]

    var lowerTransportPdus: [[UInt8]] {
        segments.map(\.lowerTransportPdu)
    }
}

struct LowerTransportSegmentedAccessDecoded: Equatable {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segO: UInt8
    let segN: UInt8
    let segment: [UInt8]
}

struct LowerTransportSegmentedAccessReassembled: Equatable {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let upperTransportPdu: [UInt8]
}

struct LowerTransportSegmentAcknowledgmentDecoded: Equatable {
    let obo: Bool
    let seqZero: UInt16
    let ackedSegments: UInt32

    func acknowledges(segment: UInt8) -> Bool {
        guard segment < 32 else { return false }
        return (ackedSegments & (UInt32(1) << UInt32(segment))) != 0
    }

    func acknowledgesAll(segN: UInt8) -> Bool {
        guard segN < 32 else { return false }
        let expected = segN == 31 ? UInt32.max : (UInt32(1) << UInt32(segN + 1)) - 1
        return (ackedSegments & expected) == expected
    }
}

struct ApplicationAccessProxyPduResult: Equatable {
    let aid: UInt8
    let accessMessage: [UInt8]
    let upperTransport: UpperTransportAccessResult
    let lowerTransport: LowerTransportAccessResult
    let network: NetworkPduResult
}

struct DeviceAccessProxyPduResult: Equatable {
    let accessMessage: [UInt8]
    let upperTransport: UpperTransportAccessResult
    let lowerTransport: LowerTransportAccessResult
    let network: NetworkPduResult
}

struct SegmentedDeviceAccessProxyPduResult: Equatable {
    let accessMessage: [UInt8]
    let upperTransport: UpperTransportAccessResult
    let lowerTransport: LowerTransportSegmentedAccessResult
    let networks: [NetworkPduResult]

    var proxyPdus: [[UInt8]] {
        networks.map(\.proxyPdu)
    }
}

struct NetworkPduDecoded: Equatable {
    let ivi: UInt8
    let nid: UInt8
    let ctl: UInt8
    let ttl: UInt8
    let sequence: UInt32
    let source: UInt16
    let destination: UInt16
    let transportPdu: [UInt8]
    let netMic: [UInt8]
}

struct LowerTransportAccessDecoded: Equatable {
    let akf: Bool
    let aid: UInt8
    let upperTransportPdu: [UInt8]
}

struct UpperTransportAccessDecoded: Equatable {
    let nonce: [UInt8]
    let accessMessage: [UInt8]
    let transMic: [UInt8]
}

struct NativeMeshCrypto {
    static let zeroKey = [UInt8](repeating: 0, count: 16)

    static func bytes(hex: String) throws -> [UInt8] {
        let compact = hex.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard compact.count % 2 == 0 else {
            throw NativeMeshCryptoError.invalidHex(hex)
        }

        var result: [UInt8] = []
        result.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw NativeMeshCryptoError.invalidHex(hex)
            }
            result.append(byte)
            index = next
        }
        return result
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func ascii(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    static func aes128EncryptBlock(key: [UInt8], block: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("AES-128 key must be 16 bytes")
        }
        guard block.count == kCCBlockSizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("AES block must be 16 bytes")
        }

        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = key.withUnsafeBytes { keyPtr in
            block.withUnsafeBytes { blockPtr in
                output.withUnsafeMutableBytes { outputPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        key.count,
                        nil,
                        blockPtr.baseAddress,
                        block.count,
                        outputPtr.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NativeMeshCryptoError.cryptorStatus(status)
        }
        return Array(output.prefix(outputLength))
    }

    static func aesCmac(key: [UInt8], message: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("CMAC key must be 16 bytes")
        }

        let (subkey1, subkey2) = try cmacSubkeys(key: key)
        let blockCount = max(1, Int(ceil(Double(message.count) / Double(kCCBlockSizeAES128))))
        let lastBlockComplete = !message.isEmpty && message.count % kCCBlockSizeAES128 == 0
        let lastBlock: [UInt8]
        if lastBlockComplete {
            let start = (blockCount - 1) * kCCBlockSizeAES128
            lastBlock = xor(Array(message[start..<start + kCCBlockSizeAES128]), subkey1)
        } else {
            let start = (blockCount - 1) * kCCBlockSizeAES128
            let remainder = message.count - start
            var padded = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
            if remainder > 0 {
                padded.replaceSubrange(0..<remainder, with: message[start..<message.count])
            }
            padded[remainder] = 0x80
            lastBlock = xor(padded, subkey2)
        }

        var state = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        if blockCount > 1 {
            for blockIndex in 0..<(blockCount - 1) {
                let start = blockIndex * kCCBlockSizeAES128
                let block = Array(message[start..<start + kCCBlockSizeAES128])
                state = try aes128EncryptBlock(key: key, block: xor(state, block))
            }
        }
        return try aes128EncryptBlock(key: key, block: xor(state, lastBlock))
    }

    static func aesCcmEncrypt(
        key: [UInt8],
        nonce: [UInt8],
        plaintext: [UInt8],
        aad: [UInt8] = [],
        micLength: Int
    ) throws -> AesCcmResult {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("CCM key must be 16 bytes")
        }
        guard (7...13).contains(nonce.count) else {
            throw NativeMeshCryptoError.invalidLength("CCM nonce must be 7 to 13 bytes")
        }
        guard (4...16).contains(micLength) && micLength % 2 == 0 else {
            throw NativeMeshCryptoError.invalidLength("CCM MIC length must be even and 4 to 16 bytes")
        }

        let lengthFieldSize = 15 - nonce.count
        if lengthFieldSize < MemoryLayout<Int>.size {
            guard plaintext.count < (1 << (8 * lengthFieldSize)) else {
                throw NativeMeshCryptoError.invalidLength("CCM plaintext too long for nonce length")
            }
        }

        let authenticationBlocks = try ccmAuthenticationBlocks(
            nonce: nonce,
            plaintext: plaintext,
            aad: aad,
            micLength: micLength,
            lengthFieldSize: lengthFieldSize
        )
        var state = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        for block in authenticationBlocks {
            state = try aes128EncryptBlock(key: key, block: xor(state, block))
        }
        let authenticationValue = Array(state.prefix(micLength))

        let s0 = try aes128EncryptBlock(key: key, block: ccmCounterBlock(nonce: nonce, lengthFieldSize: lengthFieldSize, counter: 0))
        let mic = xor(authenticationValue, Array(s0.prefix(micLength)))

        var ciphertext: [UInt8] = []
        ciphertext.reserveCapacity(plaintext.count)
        var counter = 1
        var offset = 0
        while offset < plaintext.count {
            let stream = try aes128EncryptBlock(
                key: key,
                block: ccmCounterBlock(nonce: nonce, lengthFieldSize: lengthFieldSize, counter: counter)
            )
            let count = min(kCCBlockSizeAES128, plaintext.count - offset)
            ciphertext += xor(Array(plaintext[offset..<offset + count]), Array(stream.prefix(count)))
            offset += count
            counter += 1
        }

        return AesCcmResult(ciphertext: ciphertext, mic: mic)
    }

    static func aesCcmDecrypt(
        key: [UInt8],
        nonce: [UInt8],
        ciphertext: [UInt8],
        mic: [UInt8],
        aad: [UInt8] = []
    ) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("CCM key must be 16 bytes")
        }
        guard (7...13).contains(nonce.count) else {
            throw NativeMeshCryptoError.invalidLength("CCM nonce must be 7 to 13 bytes")
        }
        guard (4...16).contains(mic.count) && mic.count % 2 == 0 else {
            throw NativeMeshCryptoError.invalidLength("CCM MIC length must be even and 4 to 16 bytes")
        }

        let lengthFieldSize = 15 - nonce.count
        var plaintext: [UInt8] = []
        plaintext.reserveCapacity(ciphertext.count)
        var counter = 1
        var offset = 0
        while offset < ciphertext.count {
            let stream = try aes128EncryptBlock(
                key: key,
                block: ccmCounterBlock(nonce: nonce, lengthFieldSize: lengthFieldSize, counter: counter)
            )
            let count = min(kCCBlockSizeAES128, ciphertext.count - offset)
            plaintext += xor(Array(ciphertext[offset..<offset + count]), Array(stream.prefix(count)))
            offset += count
            counter += 1
        }

        let verification = try aesCcmEncrypt(
            key: key,
            nonce: nonce,
            plaintext: plaintext,
            aad: aad,
            micLength: mic.count
        )
        guard verification.mic == mic else {
            throw NativeMeshCryptoError.authenticationFailed("CCM MIC mismatch")
        }
        return plaintext
    }

    static func s1(_ value: String) throws -> [UInt8] {
        try aesCmac(key: zeroKey, message: ascii(value))
    }

    static func k1(n: [UInt8], salt: [UInt8], p: [UInt8]) throws -> [UInt8] {
        let t = try aesCmac(key: salt, message: n)
        return try aesCmac(key: t, message: p)
    }

    static func k2(n: [UInt8], p: [UInt8]) throws -> MeshKeyMaterial {
        let salt = try s1("smk2")
        let t = try aesCmac(key: salt, message: n)
        let t1 = try aesCmac(key: t, message: p + [0x01])
        let t2 = try aesCmac(key: t, message: t1 + p + [0x02])
        let t3 = try aesCmac(key: t, message: t2 + p + [0x03])
        return MeshKeyMaterial(nid: t1[15] & 0x7f, encryptionKey: t2, privacyKey: t3)
    }

    static func k3(n: [UInt8]) throws -> [UInt8] {
        let salt = try s1("smk3")
        let t = try aesCmac(key: salt, message: n)
        let result = try aesCmac(key: t, message: ascii("id64") + [0x01])
        return Array(result.suffix(8))
    }

    static func k4(n: [UInt8]) throws -> UInt8 {
        let salt = try s1("smk4")
        let t = try aesCmac(key: salt, message: n)
        let result = try aesCmac(key: t, message: ascii("id6") + [0x01])
        return result[15] & 0x3f
    }

    static func networkNonce(ctl: UInt8, ttl: UInt8, sequence: UInt32, source: UInt16, ivIndex: UInt32) -> [UInt8] {
        [0x00, ((ctl & 0x01) << 7) | (ttl & 0x7f)]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
            + [0x00, 0x00]
            + uintBytes(UInt64(ivIndex), count: 4)
    }

    static func applicationNonce(
        aszmic: Bool = false,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32
    ) -> [UInt8] {
        [0x01, aszmic ? 0x80 : 0x00]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
            + uintBytes(UInt64(destination), count: 2)
            + uintBytes(UInt64(ivIndex), count: 4)
    }

    static func deviceNonce(
        aszmic: Bool = false,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32
    ) -> [UInt8] {
        [0x02, aszmic ? 0x80 : 0x00]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
            + uintBytes(UInt64(destination), count: 2)
            + uintBytes(UInt64(ivIndex), count: 4)
    }

    static func upperTransportAccessPdu(
        applicationKey: [UInt8],
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32,
        accessMessage: [UInt8],
        transMicLength: Int = 4,
        labelUuid: [UInt8] = []
    ) throws -> UpperTransportAccessResult {
        guard sequence <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("sequence number must be a 24-bit value")
        }
        let nonce = applicationNonce(
            aszmic: transMicLength == 8,
            sequence: sequence,
            source: source,
            destination: destination,
            ivIndex: ivIndex
        )
        return try upperTransportAccessPdu(
            key: applicationKey,
            nonce: nonce,
            accessMessage: accessMessage,
            transMicLength: transMicLength,
            aad: labelUuid
        )
    }

    static func upperTransportAccessPdu(
        deviceKey: [UInt8],
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32,
        accessMessage: [UInt8],
        transMicLength: Int = 4
    ) throws -> UpperTransportAccessResult {
        guard sequence <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("sequence number must be a 24-bit value")
        }
        let nonce = deviceNonce(
            aszmic: transMicLength == 8,
            sequence: sequence,
            source: source,
            destination: destination,
            ivIndex: ivIndex
        )
        return try upperTransportAccessPdu(
            key: deviceKey,
            nonce: nonce,
            accessMessage: accessMessage,
            transMicLength: transMicLength
        )
    }

    static func lowerTransportUnsegmentedAccessPdu(
        akf: Bool,
        aid: UInt8,
        upperTransportPdu: [UInt8]
    ) throws -> LowerTransportAccessResult {
        guard aid <= 0x3f else {
            throw NativeMeshCryptoError.invalidParameter("AID must be a 6-bit value")
        }
        guard (5...15).contains(upperTransportPdu.count) else {
            throw NativeMeshCryptoError.invalidLength("unsegmented Upper Transport Access PDU must be 5 to 15 bytes")
        }

        let header = (akf ? UInt8(0x40) : UInt8(0x00)) | aid
        return LowerTransportAccessResult(header: header, lowerTransportPdu: [header] + upperTransportPdu)
    }

    static func lowerTransportSegmentedAccessPdus(
        akf: Bool,
        aid: UInt8,
        szmic: Bool,
        seqZero: UInt16,
        upperTransportPdu: [UInt8]
    ) throws -> LowerTransportSegmentedAccessResult {
        guard aid <= 0x3f else {
            throw NativeMeshCryptoError.invalidParameter("AID must be a 6-bit value")
        }
        guard seqZero <= 0x1fff else {
            throw NativeMeshCryptoError.invalidParameter("SeqZero must be a 13-bit value")
        }
        guard !upperTransportPdu.isEmpty else {
            throw NativeMeshCryptoError.invalidLength("segmented Upper Transport Access PDU must not be empty")
        }
        guard upperTransportPdu.count <= 384 else {
            throw NativeMeshCryptoError.invalidLength("segmented Upper Transport Access PDU must be at most 384 bytes")
        }

        let segmentPayloadSize = 12
        let segmentCount = (upperTransportPdu.count + segmentPayloadSize - 1) / segmentPayloadSize
        guard (1...32).contains(segmentCount) else {
            throw NativeMeshCryptoError.invalidLength("segmented Upper Transport Access PDU must fit in 32 segments")
        }

        let header = UInt8(0x80) | (akf ? UInt8(0x40) : UInt8(0x00)) | aid
        let segN = UInt8(segmentCount - 1)
        let segments = try (0..<segmentCount).map { index -> LowerTransportSegmentedAccessSegment in
            let start = index * segmentPayloadSize
            let end = min(start + segmentPayloadSize, upperTransportPdu.count)
            let segment = Array(upperTransportPdu[start..<end])
            let segO = UInt8(index)
            let lowerTransportHeader = try segmentedAccessHeader(
                header: header,
                szmic: szmic,
                seqZero: seqZero,
                segO: segO,
                segN: segN
            )
            return LowerTransportSegmentedAccessSegment(
                header: header,
                szmic: szmic,
                seqZero: seqZero,
                segO: segO,
                segN: segN,
                segment: segment,
                lowerTransportPdu: lowerTransportHeader + segment
            )
        }

        return LowerTransportSegmentedAccessResult(
            akf: akf,
            aid: aid,
            szmic: szmic,
            seqZero: seqZero,
            segN: segN,
            segments: segments
        )
    }

    static func lowerTransportSegmentAcknowledgmentPdu(
        obo: Bool = false,
        seqZero: UInt16,
        ackedSegments: UInt32
    ) throws -> [UInt8] {
        guard seqZero <= 0x1fff else {
            throw NativeMeshCryptoError.invalidParameter("SeqZero must be a 13-bit value")
        }
        return [
            0x00,
            (obo ? UInt8(0x80) : UInt8(0x00)) | UInt8((seqZero >> 6) & 0x7f),
            UInt8((seqZero & 0x3f) << 2),
        ] + uintBytes(ackedSegments, count: 4)
    }

    static func vendorAccessMessage(opcode: UInt8, companyIdentifier: UInt16, parameters: [UInt8] = []) throws -> [UInt8] {
        guard opcode <= 0x3f else {
            throw NativeMeshCryptoError.invalidParameter("vendor opcode must be a 6-bit value")
        }
        return [0xc0 | opcode] + littleEndianBytes(UInt64(companyIdentifier), count: 2) + parameters
    }

    static func applicationAccessProxyPdu(
        ivIndex: UInt32,
        ttl: UInt8,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        netKey: [UInt8],
        applicationKey: [UInt8],
        accessMessage: [UInt8]
    ) throws -> ApplicationAccessProxyPduResult {
        let networkKeys = try k2(n: netKey, p: [0x00])
        let aid = try k4(n: applicationKey)
        let upperTransport = try upperTransportAccessPdu(
            applicationKey: applicationKey,
            sequence: sequence,
            source: source,
            destination: destination,
            ivIndex: ivIndex,
            accessMessage: accessMessage
        )
        let lowerTransport = try lowerTransportUnsegmentedAccessPdu(
            akf: true,
            aid: aid,
            upperTransportPdu: upperTransport.upperTransportPdu
        )
        let network = try networkPdu(
            ivIndex: ivIndex,
            nid: networkKeys.nid,
            encryptionKey: networkKeys.encryptionKey,
            privacyKey: networkKeys.privacyKey,
            ctl: 0,
            ttl: ttl,
            sequence: sequence,
            source: source,
            destination: destination,
            transportPdu: lowerTransport.lowerTransportPdu
        )
        return ApplicationAccessProxyPduResult(
            aid: aid,
            accessMessage: accessMessage,
            upperTransport: upperTransport,
            lowerTransport: lowerTransport,
            network: network
        )
    }

    static func deviceAccessProxyPdu(
        ivIndex: UInt32,
        ttl: UInt8,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        netKey: [UInt8],
        deviceKey: [UInt8],
        accessMessage: [UInt8]
    ) throws -> DeviceAccessProxyPduResult {
        let networkKeys = try k2(n: netKey, p: [0x00])
        let upperTransport = try upperTransportAccessPdu(
            deviceKey: deviceKey,
            sequence: sequence,
            source: source,
            destination: destination,
            ivIndex: ivIndex,
            accessMessage: accessMessage
        )
        let lowerTransport = try lowerTransportUnsegmentedAccessPdu(
            akf: false,
            aid: 0,
            upperTransportPdu: upperTransport.upperTransportPdu
        )
        let network = try networkPdu(
            ivIndex: ivIndex,
            nid: networkKeys.nid,
            encryptionKey: networkKeys.encryptionKey,
            privacyKey: networkKeys.privacyKey,
            ctl: 0,
            ttl: ttl,
            sequence: sequence,
            source: source,
            destination: destination,
            transportPdu: lowerTransport.lowerTransportPdu
        )
        return DeviceAccessProxyPduResult(
            accessMessage: accessMessage,
            upperTransport: upperTransport,
            lowerTransport: lowerTransport,
            network: network
        )
    }

    static func segmentedDeviceAccessProxyPdus(
        ivIndex: UInt32,
        ttl: UInt8,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        netKey: [UInt8],
        deviceKey: [UInt8],
        accessMessage: [UInt8],
        transMicLength: Int = 4
    ) throws -> SegmentedDeviceAccessProxyPduResult {
        let networkKeys = try k2(n: netKey, p: [0x00])
        let upperTransport = try upperTransportAccessPdu(
            deviceKey: deviceKey,
            sequence: sequence,
            source: source,
            destination: destination,
            ivIndex: ivIndex,
            accessMessage: accessMessage,
            transMicLength: transMicLength
        )
        let lowerTransport = try lowerTransportSegmentedAccessPdus(
            akf: false,
            aid: 0,
            szmic: transMicLength == 8,
            seqZero: UInt16(sequence & 0x1fff),
            upperTransportPdu: upperTransport.upperTransportPdu
        )
        guard sequence + UInt32(lowerTransport.segments.count - 1) <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("segmented sequence range exceeds 24-bit sequence space")
        }

        let networks = try lowerTransport.segments.enumerated().map { index, segment in
            try networkPdu(
                ivIndex: ivIndex,
                nid: networkKeys.nid,
                encryptionKey: networkKeys.encryptionKey,
                privacyKey: networkKeys.privacyKey,
                ctl: 0,
                ttl: ttl,
                sequence: sequence + UInt32(index),
                source: source,
                destination: destination,
                transportPdu: segment.lowerTransportPdu
            )
        }

        return SegmentedDeviceAccessProxyPduResult(
            accessMessage: accessMessage,
            upperTransport: upperTransport,
            lowerTransport: lowerTransport,
            networks: networks
        )
    }

    static func networkPdu(
        ivIndex: UInt32,
        nid: UInt8,
        encryptionKey: [UInt8],
        privacyKey: [UInt8],
        ctl: UInt8,
        ttl: UInt8,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        transportPdu: [UInt8]
    ) throws -> NetworkPduResult {
        guard nid <= 0x7f else {
            throw NativeMeshCryptoError.invalidParameter("NID must be a 7-bit value")
        }
        guard ctl <= 0x01 else {
            throw NativeMeshCryptoError.invalidParameter("CTL must be 0 or 1")
        }
        guard ttl <= 0x7f else {
            throw NativeMeshCryptoError.invalidParameter("TTL must be a 7-bit value")
        }
        guard sequence <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("sequence number must be a 24-bit value")
        }
        guard !transportPdu.isEmpty else {
            throw NativeMeshCryptoError.invalidParameter("transport PDU must not be empty")
        }

        let nonce = networkNonce(ctl: ctl, ttl: ttl, sequence: sequence, source: source, ivIndex: ivIndex)
        let plaintext = uintBytes(UInt64(destination), count: 2) + transportPdu
        let micLength = ctl == 0 ? 4 : 8
        let networkEncryption = try aesCcmEncrypt(
            key: encryptionKey,
            nonce: nonce,
            plaintext: plaintext,
            micLength: micLength
        )

        let privacyPlaintext = [UInt8](repeating: 0, count: 5)
            + uintBytes(UInt64(ivIndex), count: 4)
            + Array((networkEncryption.ciphertext + networkEncryption.mic).prefix(7))
        let pecb = Array(try aes128EncryptBlock(key: privacyKey, block: privacyPlaintext).prefix(6))
        let ctlTtlSeqSrc = [((ctl & 0x01) << 7) | (ttl & 0x7f)]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
        let obfuscated = xor(ctlTtlSeqSrc, pecb)
        let iviNid = UInt8((ivIndex & 0x01) == 0 ? 0 : 0x80) | (nid & 0x7f)
        let networkPdu = [iviNid] + obfuscated + networkEncryption.ciphertext + networkEncryption.mic
        let proxyPdu = [0x00] + networkPdu

        return NetworkPduResult(
            nonce: nonce,
            encryptedDstAndTransportPdu: networkEncryption.ciphertext,
            netMic: networkEncryption.mic,
            privacyPlaintext: privacyPlaintext,
            pecb: pecb,
            obfuscatedCtlTtlSeqSrc: obfuscated,
            networkPdu: networkPdu,
            proxyPdu: proxyPdu
        )
    }

    static func decodeNetworkPdu(
        networkPdu: [UInt8],
        ivIndex: UInt32,
        nid: UInt8,
        encryptionKey: [UInt8],
        privacyKey: [UInt8]
    ) throws -> NetworkPduDecoded {
        guard networkPdu.count >= 14 else {
            throw NativeMeshCryptoError.invalidLength("Network PDU is too short")
        }
        guard nid <= 0x7f else {
            throw NativeMeshCryptoError.invalidParameter("NID must be a 7-bit value")
        }

        let iviNid = networkPdu[0]
        let pduIvi = (iviNid & 0x80) >> 7
        let pduNid = iviNid & 0x7f
        guard pduNid == nid else {
            throw NativeMeshCryptoError.authenticationFailed("NID does not match")
        }

        let obfuscated = Array(networkPdu[1..<7])
        let encryptedAndMic = Array(networkPdu[7...])
        guard encryptedAndMic.count >= 8 else {
            throw NativeMeshCryptoError.invalidLength("encrypted network payload is too short")
        }

        let privacyPlaintext = [UInt8](repeating: 0, count: 5)
            + uintBytes(UInt64(ivIndex), count: 4)
            + Array(encryptedAndMic.prefix(7))
        let pecb = Array(try aes128EncryptBlock(key: privacyKey, block: privacyPlaintext).prefix(6))
        let ctlTtlSeqSrc = xor(obfuscated, pecb)
        let ctl = (ctlTtlSeqSrc[0] & 0x80) >> 7
        let ttl = ctlTtlSeqSrc[0] & 0x7f
        let sequence = uint32(bytes: Array(ctlTtlSeqSrc[1..<4]))
        let source = uint16(bytes: Array(ctlTtlSeqSrc[4..<6]))
        let micLength = ctl == 0 ? 4 : 8
        guard encryptedAndMic.count > micLength + 2 else {
            throw NativeMeshCryptoError.invalidLength("encrypted network payload is too short for NetMIC")
        }

        let ciphertext = Array(encryptedAndMic.dropLast(micLength))
        let netMic = Array(encryptedAndMic.suffix(micLength))
        let nonce = networkNonce(ctl: ctl, ttl: ttl, sequence: sequence, source: source, ivIndex: ivIndex)
        let plaintext = try aesCcmDecrypt(
            key: encryptionKey,
            nonce: nonce,
            ciphertext: ciphertext,
            mic: netMic
        )
        guard plaintext.count >= 3 else {
            throw NativeMeshCryptoError.invalidLength("decrypted network payload is too short")
        }

        return NetworkPduDecoded(
            ivi: pduIvi,
            nid: pduNid,
            ctl: ctl,
            ttl: ttl,
            sequence: sequence,
            source: source,
            destination: uint16(bytes: Array(plaintext[0..<2])),
            transportPdu: Array(plaintext[2...]),
            netMic: netMic
        )
    }

    static func decodeLowerTransportUnsegmentedAccessPdu(
        lowerTransportPdu: [UInt8]
    ) throws -> LowerTransportAccessDecoded {
        guard lowerTransportPdu.count >= 6 else {
            throw NativeMeshCryptoError.invalidLength("Lower Transport Access PDU is too short")
        }
        let header = lowerTransportPdu[0]
        guard (header & 0x80) == 0 else {
            throw NativeMeshCryptoError.invalidParameter("segmented access messages are not supported")
        }
        return LowerTransportAccessDecoded(
            akf: (header & 0x40) != 0,
            aid: header & 0x3f,
            upperTransportPdu: Array(lowerTransportPdu.dropFirst())
        )
    }

    static func decodeLowerTransportSegmentedAccessPdu(
        lowerTransportPdu: [UInt8]
    ) throws -> LowerTransportSegmentedAccessDecoded {
        guard (5...16).contains(lowerTransportPdu.count) else {
            throw NativeMeshCryptoError.invalidLength("Segmented Lower Transport Access PDU must be 5 to 16 bytes")
        }
        let header = lowerTransportPdu[0]
        guard (header & 0x80) != 0 else {
            throw NativeMeshCryptoError.invalidParameter("Lower Transport Access PDU is not segmented")
        }

        let seqZero = UInt16(lowerTransportPdu[1] & 0x7f) << 6
            | UInt16((lowerTransportPdu[2] & 0xfc) >> 2)
        let segO = ((lowerTransportPdu[2] & 0x03) << 3) | ((lowerTransportPdu[3] & 0xe0) >> 5)
        let segN = lowerTransportPdu[3] & 0x1f
        guard segO <= segN else {
            throw NativeMeshCryptoError.invalidParameter("SegO must not exceed SegN")
        }
        let segment = Array(lowerTransportPdu.dropFirst(4))
        if segO < segN && segment.count != 12 {
            throw NativeMeshCryptoError.invalidLength("non-final segmented Access PDU segments must carry 12 bytes")
        }
        guard !segment.isEmpty && segment.count <= 12 else {
            throw NativeMeshCryptoError.invalidLength("segmented Access PDU segment must be 1 to 12 bytes")
        }

        return LowerTransportSegmentedAccessDecoded(
            akf: (header & 0x40) != 0,
            aid: header & 0x3f,
            szmic: (lowerTransportPdu[1] & 0x80) != 0,
            seqZero: seqZero,
            segO: segO,
            segN: segN,
            segment: segment
        )
    }

    static func reassembleLowerTransportSegmentedAccessPdus(
        lowerTransportPdus: [[UInt8]]
    ) throws -> LowerTransportSegmentedAccessReassembled {
        guard !lowerTransportPdus.isEmpty else {
            throw NativeMeshCryptoError.invalidLength("segmented Lower Transport PDU list must not be empty")
        }
        let decoded = try lowerTransportPdus.map { try decodeLowerTransportSegmentedAccessPdu(lowerTransportPdu: $0) }
        guard let first = decoded.first else {
            throw NativeMeshCryptoError.invalidLength("segmented Lower Transport PDU list must not be empty")
        }

        var bySegmentOffset: [UInt8: LowerTransportSegmentedAccessDecoded] = [:]
        for segment in decoded {
            guard segment.akf == first.akf,
                  segment.aid == first.aid,
                  segment.szmic == first.szmic,
                  segment.seqZero == first.seqZero,
                  segment.segN == first.segN else {
                throw NativeMeshCryptoError.invalidParameter("segmented Access PDUs do not belong to the same message")
            }
            guard bySegmentOffset[segment.segO] == nil else {
                throw NativeMeshCryptoError.invalidParameter("duplicate segmented Access PDU segment")
            }
            bySegmentOffset[segment.segO] = segment
        }

        let expectedCount = Int(first.segN) + 1
        guard bySegmentOffset.count == expectedCount else {
            throw NativeMeshCryptoError.invalidLength("segmented Access PDU set is incomplete")
        }

        var upperTransportPdu: [UInt8] = []
        for index in 0...first.segN {
            guard let segment = bySegmentOffset[index] else {
                throw NativeMeshCryptoError.invalidLength("segmented Access PDU set is incomplete")
            }
            upperTransportPdu += segment.segment
        }

        return LowerTransportSegmentedAccessReassembled(
            akf: first.akf,
            aid: first.aid,
            szmic: first.szmic,
            seqZero: first.seqZero,
            upperTransportPdu: upperTransportPdu
        )
    }

    static func decodeLowerTransportSegmentAcknowledgment(
        lowerTransportPdu: [UInt8]
    ) throws -> LowerTransportSegmentAcknowledgmentDecoded {
        guard lowerTransportPdu.count == 7 else {
            throw NativeMeshCryptoError.invalidLength("Segment Acknowledgment PDU must be 7 bytes")
        }
        guard lowerTransportPdu[0] == 0x00 else {
            throw NativeMeshCryptoError.invalidParameter("Lower Transport PDU is not a Segment Acknowledgment")
        }
        guard (lowerTransportPdu[2] & 0x03) == 0 else {
            throw NativeMeshCryptoError.invalidParameter("Segment Acknowledgment RFU bits must be zero")
        }

        let seqZero = UInt16(lowerTransportPdu[1] & 0x7f) << 6
            | UInt16((lowerTransportPdu[2] & 0xfc) >> 2)
        return LowerTransportSegmentAcknowledgmentDecoded(
            obo: (lowerTransportPdu[1] & 0x80) != 0,
            seqZero: seqZero,
            ackedSegments: uint32(bytes: Array(lowerTransportPdu[3..<7]))
        )
    }

    static func decodeUpperTransportAccessPdu(
        applicationKey: [UInt8],
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32,
        upperTransportPdu: [UInt8],
        transMicLength: Int = 4,
        labelUuid: [UInt8] = []
    ) throws -> UpperTransportAccessDecoded {
        let nonce = applicationNonce(
            aszmic: transMicLength == 8,
            sequence: sequence,
            source: source,
            destination: destination,
            ivIndex: ivIndex
        )
        return try decodeUpperTransportAccessPdu(
            key: applicationKey,
            nonce: nonce,
            upperTransportPdu: upperTransportPdu,
            transMicLength: transMicLength,
            aad: labelUuid
        )
    }

    static func decodeUpperTransportAccessPdu(
        deviceKey: [UInt8],
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32,
        upperTransportPdu: [UInt8],
        transMicLength: Int = 4
    ) throws -> UpperTransportAccessDecoded {
        let nonce = deviceNonce(
            aszmic: transMicLength == 8,
            sequence: sequence,
            source: source,
            destination: destination,
            ivIndex: ivIndex
        )
        return try decodeUpperTransportAccessPdu(
            key: deviceKey,
            nonce: nonce,
            upperTransportPdu: upperTransportPdu,
            transMicLength: transMicLength
        )
    }

    private static func decodeUpperTransportAccessPdu(
        key: [UInt8],
        nonce: [UInt8],
        upperTransportPdu: [UInt8],
        transMicLength: Int,
        aad: [UInt8] = []
    ) throws -> UpperTransportAccessDecoded {
        guard upperTransportPdu.count > transMicLength else {
            throw NativeMeshCryptoError.invalidLength("Upper Transport Access PDU is too short")
        }
        let encryptedAccessMessage = Array(upperTransportPdu.dropLast(transMicLength))
        let transMic = Array(upperTransportPdu.suffix(transMicLength))
        let accessMessage = try aesCcmDecrypt(
            key: key,
            nonce: nonce,
            ciphertext: encryptedAccessMessage,
            mic: transMic,
            aad: aad
        )
        return UpperTransportAccessDecoded(nonce: nonce, accessMessage: accessMessage, transMic: transMic)
    }

    private static func upperTransportAccessPdu(
        key: [UInt8],
        nonce: [UInt8],
        accessMessage: [UInt8],
        transMicLength: Int,
        aad: [UInt8] = []
    ) throws -> UpperTransportAccessResult {
        guard !accessMessage.isEmpty else {
            throw NativeMeshCryptoError.invalidParameter("access message must not be empty")
        }
        guard transMicLength == 4 || transMicLength == 8 else {
            throw NativeMeshCryptoError.invalidLength("TransMIC must be 4 or 8 bytes")
        }
        let maxAccessLength = transMicLength == 4 ? 380 : 376
        guard accessMessage.count <= maxAccessLength else {
            throw NativeMeshCryptoError.invalidLength("access message is too large for TransMIC size")
        }
        if !aad.isEmpty && aad.count != 16 {
            throw NativeMeshCryptoError.invalidLength("Label UUID AAD must be 16 bytes")
        }

        let encrypted = try aesCcmEncrypt(
            key: key,
            nonce: nonce,
            plaintext: accessMessage,
            aad: aad,
            micLength: transMicLength
        )
        return UpperTransportAccessResult(
            nonce: nonce,
            encAccessMessage: encrypted.ciphertext,
            transMic: encrypted.mic,
            upperTransportPdu: encrypted.ciphertext + encrypted.mic
        )
    }

    private static func segmentedAccessHeader(
        header: UInt8,
        szmic: Bool,
        seqZero: UInt16,
        segO: UInt8,
        segN: UInt8
    ) throws -> [UInt8] {
        guard (header & 0x80) != 0 else {
            throw NativeMeshCryptoError.invalidParameter("segmented Access header must set SEG")
        }
        guard seqZero <= 0x1fff else {
            throw NativeMeshCryptoError.invalidParameter("SeqZero must be a 13-bit value")
        }
        guard segO <= 0x1f && segN <= 0x1f else {
            throw NativeMeshCryptoError.invalidParameter("SegO and SegN must be 5-bit values")
        }
        guard segO <= segN else {
            throw NativeMeshCryptoError.invalidParameter("SegO must not exceed SegN")
        }
        return [
            header,
            (szmic ? UInt8(0x80) : UInt8(0x00)) | UInt8((seqZero >> 6) & 0x7f),
            UInt8((seqZero & 0x3f) << 2) | UInt8((segO >> 3) & 0x03),
            UInt8((segO & 0x07) << 5) | segN,
        ]
    }

    private static func cmacSubkeys(key: [UInt8]) throws -> ([UInt8], [UInt8]) {
        let l = try aes128EncryptBlock(key: key, block: [UInt8](repeating: 0, count: 16))
        let k1 = dbl(l)
        let k2 = dbl(k1)
        return (k1, k2)
    }

    private static func ccmAuthenticationBlocks(
        nonce: [UInt8],
        plaintext: [UInt8],
        aad: [UInt8],
        micLength: Int,
        lengthFieldSize: Int
    ) throws -> [[UInt8]] {
        let flags = (aad.isEmpty ? UInt8(0) : UInt8(0x40))
            | UInt8(((micLength - 2) / 2) << 3)
            | UInt8(lengthFieldSize - 1)
        var data = [flags] + nonce + uintBytes(UInt64(plaintext.count), count: lengthFieldSize)

        if !aad.isEmpty {
            data += try ccmEncodedAad(aad)
            appendZeroPadding(&data)
        }

        if !plaintext.isEmpty {
            data += plaintext
            appendZeroPadding(&data)
        }

        return stride(from: 0, to: data.count, by: kCCBlockSizeAES128).map {
            Array(data[$0..<$0 + kCCBlockSizeAES128])
        }
    }

    private static func ccmEncodedAad(_ aad: [UInt8]) throws -> [UInt8] {
        if aad.count < 0xff00 {
            return uintBytes(UInt64(aad.count), count: 2) + aad
        }
        if aad.count <= UInt32.max {
            return [0xff, 0xfe] + uintBytes(UInt64(aad.count), count: 4) + aad
        }
        throw NativeMeshCryptoError.invalidLength("CCM AAD is too large")
    }

    private static func ccmCounterBlock(nonce: [UInt8], lengthFieldSize: Int, counter: Int) -> [UInt8] {
        [UInt8(lengthFieldSize - 1)] + nonce + uintBytes(UInt64(counter), count: lengthFieldSize)
    }

    private static func uintBytes(_ value: UInt32, count: Int) -> [UInt8] {
        uintBytes(UInt64(value), count: count)
    }

    private static func uintBytes(_ value: UInt64, count: Int) -> [UInt8] {
        stride(from: count - 1, through: 0, by: -1).map { UInt8((value >> UInt64($0 * 8)) & 0xff) }
    }

    private static func uint16(bytes: [UInt8]) -> UInt16 {
        bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    private static func uint32(bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func littleEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> UInt64($0 * 8)) & 0xff) }
    }

    private static func appendZeroPadding(_ data: inout [UInt8]) {
        let remainder = data.count % kCCBlockSizeAES128
        if remainder != 0 {
            data += [UInt8](repeating: 0, count: kCCBlockSizeAES128 - remainder)
        }
    }

    private static func dbl(_ block: [UInt8]) -> [UInt8] {
        let carry = (block[0] & 0x80) != 0
        var result = leftShiftOneBit(block)
        if carry {
            result[15] ^= 0x87
        }
        return result
    }

    private static func leftShiftOneBit(_ block: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: block.count)
        var carry: UInt8 = 0
        for index in stride(from: block.count - 1, through: 0, by: -1) {
            let nextCarry = (block[index] & 0x80) != 0 ? UInt8(1) : UInt8(0)
            result[index] = (block[index] << 1) | carry
            carry = nextCarry
        }
        return result
    }

    private static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        zip(lhs, rhs).map { $0 ^ $1 }
    }
}
