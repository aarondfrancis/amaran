import Foundation

enum NativeMeshConfigError: Error, CustomStringConvertible {
    case invalidLength(String)
    case invalidParameter(String)

    var description: String {
        switch self {
        case .invalidLength(let value):
            return "invalid native config length: \(value)"
        case .invalidParameter(let value):
            return "invalid native config parameter: \(value)"
        }
    }
}

enum NativeMeshModelIdentifier: Equatable {
    case sig(UInt16)
    case vendor(companyIdentifier: UInt16, modelIdentifier: UInt16)
}

struct NativeMeshVendorModel: Equatable {
    let companyIdentifier: UInt16
    let modelIdentifier: UInt16
}

struct NativeMeshCompositionElement: Equatable {
    let location: UInt16
    let sigModels: [UInt16]
    let vendorModels: [NativeMeshVendorModel]
}

struct NativeMeshCompositionDataPage0: Equatable {
    let cid: UInt16
    let pid: UInt16
    let vid: UInt16
    let crpl: UInt16
    let features: UInt16
    let elements: [NativeMeshCompositionElement]
    let includedPageByte: Bool

    var firstVendorModelBindingTarget: (elementIndex: Int, model: NativeMeshVendorModel)? {
        for (index, element) in elements.enumerated() {
            if let model = element.vendorModels.first {
                return (index, model)
            }
        }
        return nil
    }
}

struct NativeMeshConfigAppKeyStatus: Equatable {
    let status: UInt8
    let netKeyIndex: Int
    let appKeyIndex: Int
}

struct NativeMeshConfigAppKeyListStatus: Equatable {
    let status: UInt8
    let netKeyIndex: Int
    let appKeyIndexes: [Int]
}

struct NativeMeshConfigModelAppStatus: Equatable {
    let status: UInt8
    let elementAddress: UInt16
    let appKeyIndex: Int
    let modelIdentifier: NativeMeshModelIdentifier
}

struct NativeMeshConfig {
    static let configAppKeyAddOpcode = [UInt8(0x00)]
    static let configAppKeyGetOpcode = [UInt8(0x80), UInt8(0x01)]
    static let configAppKeyListOpcode = [UInt8(0x80), UInt8(0x02)]
    static let configAppKeyStatusOpcode = [UInt8(0x80), UInt8(0x03)]
    static let configCompositionDataStatusOpcode = [UInt8(0x02)]
    static let configCompositionDataGetOpcode = [UInt8(0x80), UInt8(0x08)]
    static let configModelAppBindOpcode = [UInt8(0x80), UInt8(0x3d)]
    static let configModelAppStatusOpcode = [UInt8(0x80), UInt8(0x3e)]
    static let configNodeResetOpcode = [UInt8(0x80), UInt8(0x49)]
    static let configNodeResetStatusOpcode = [UInt8(0x80), UInt8(0x4a)]

    static func configCompositionDataGet(page: UInt8 = 0) -> [UInt8] {
        configCompositionDataGetOpcode + [page]
    }

    static func configNodeReset() -> [UInt8] {
        configNodeResetOpcode
    }

    static func configAppKeyAdd(
        netKeyIndex: Int,
        appKeyIndex: Int,
        appKey: [UInt8]
    ) throws -> [UInt8] {
        guard appKey.count == 16 else {
            throw NativeMeshConfigError.invalidLength("AppKey must be 16 bytes")
        }
        return try configAppKeyAddOpcode + packedKeyIndexes(netKeyIndex, appKeyIndex) + appKey
    }

    static func configAppKeyGet(netKeyIndex: Int) throws -> [UInt8] {
        try validateKeyIndex(netKeyIndex, label: "NetKey Index")
        return configAppKeyGetOpcode + littleEndianBytes(UInt64(netKeyIndex), count: 2)
    }

    static func configModelAppBind(
        elementAddress: UInt16,
        appKeyIndex: Int,
        modelIdentifier: NativeMeshModelIdentifier
    ) throws -> [UInt8] {
        guard (1...0x7fff).contains(Int(elementAddress)) else {
            throw NativeMeshConfigError.invalidParameter("element address must be a non-zero unicast address")
        }
        try validateKeyIndex(appKeyIndex, label: "AppKey Index")

        let modelBytes: [UInt8]
        switch modelIdentifier {
        case .sig(let modelIdentifier):
            modelBytes = littleEndianBytes(UInt64(modelIdentifier), count: 2)
        case .vendor(let companyIdentifier, let modelIdentifier):
            modelBytes = littleEndianBytes(UInt64(companyIdentifier), count: 2)
                + littleEndianBytes(UInt64(modelIdentifier), count: 2)
        }

        return configModelAppBindOpcode
            + littleEndianBytes(UInt64(elementAddress), count: 2)
            + littleEndianBytes(UInt64(appKeyIndex), count: 2)
            + modelBytes
    }

    static func packedKeyIndexes(_ first: Int, _ second: Int) throws -> [UInt8] {
        try validateKeyIndex(first, label: "first key index")
        try validateKeyIndex(second, label: "second key index")
        return [
            UInt8(first & 0xff),
            UInt8(((first >> 8) & 0x0f) | ((second & 0x0f) << 4)),
            UInt8((second >> 4) & 0xff),
        ]
    }

    static func requiresSegmentedLowerTransport(accessMessage: [UInt8], transMicLength: Int = 4) -> Bool {
        accessMessage.count + transMicLength > 15
    }

    static func compositionDataPage0(_ data: [UInt8]) throws -> NativeMeshCompositionDataPage0 {
        do {
            return try compositionDataPage0(data, includedPageByte: false)
        } catch {
            if data.first == 0x00 {
                return try compositionDataPage0(Array(data.dropFirst()), includedPageByte: true)
            }
            throw error
        }
    }

    static func configAppKeyStatus(_ accessMessage: [UInt8]) throws -> NativeMeshConfigAppKeyStatus {
        guard accessMessage.count == 6 else {
            throw NativeMeshConfigError.invalidLength("Config AppKey Status must be 6 bytes")
        }
        guard Array(accessMessage.prefix(2)) == configAppKeyStatusOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config AppKey Status")
        }
        let indexes = unpackedKeyIndexes(Array(accessMessage[3..<6]))
        return NativeMeshConfigAppKeyStatus(
            status: accessMessage[2],
            netKeyIndex: indexes.0,
            appKeyIndex: indexes.1
        )
    }

    static func configAppKeyList(_ accessMessage: [UInt8]) throws -> NativeMeshConfigAppKeyListStatus {
        guard accessMessage.count >= 5 else {
            throw NativeMeshConfigError.invalidLength("Config AppKey List must include opcode, status, and NetKeyIndex")
        }
        guard Array(accessMessage.prefix(2)) == configAppKeyListOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config AppKey List")
        }
        return try NativeMeshConfigAppKeyListStatus(
            status: accessMessage[2],
            netKeyIndex: unpackedSingleKeyIndex(Array(accessMessage[3..<5])),
            appKeyIndexes: unpackedKeyIndexList(Array(accessMessage.dropFirst(5)))
        )
    }

    static func configCompositionDataStatus(_ accessMessage: [UInt8]) throws -> NativeMeshCompositionDataPage0 {
        guard accessMessage.count >= 12 else {
            throw NativeMeshConfigError.invalidLength("Config Composition Data Status must include opcode, page, and header")
        }
        guard Array(accessMessage.prefix(1)) == configCompositionDataStatusOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config Composition Data Status")
        }
        guard accessMessage[1] == 0x00 else {
            throw NativeMeshConfigError.invalidParameter("only Composition Data Page 0 is supported")
        }
        return try compositionDataPage0(Array(accessMessage.dropFirst()))
    }

    static func configModelAppStatus(_ accessMessage: [UInt8]) throws -> NativeMeshConfigModelAppStatus {
        guard accessMessage.count == 9 || accessMessage.count == 11 else {
            throw NativeMeshConfigError.invalidLength("Config Model App Status must be 9 or 11 bytes")
        }
        guard Array(accessMessage.prefix(2)) == configModelAppStatusOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config Model App Status")
        }
        let modelIdentifier: NativeMeshModelIdentifier
        if accessMessage.count == 9 {
            modelIdentifier = .sig(littleEndianUInt16(accessMessage, 7))
        } else {
            modelIdentifier = .vendor(
                companyIdentifier: littleEndianUInt16(accessMessage, 7),
                modelIdentifier: littleEndianUInt16(accessMessage, 9)
            )
        }
        return NativeMeshConfigModelAppStatus(
            status: accessMessage[2],
            elementAddress: littleEndianUInt16(accessMessage, 3),
            appKeyIndex: Int(littleEndianUInt16(accessMessage, 5) & 0x0fff),
            modelIdentifier: modelIdentifier
        )
    }

    static func statusName(_ status: UInt8) -> String {
        switch status {
        case 0x00: return "success"
        case 0x01: return "invalid_address"
        case 0x02: return "invalid_model"
        case 0x03: return "invalid_appkey_index"
        case 0x04: return "invalid_netkey_index"
        case 0x05: return "insufficient_resources"
        case 0x06: return "key_index_already_stored"
        case 0x07: return "invalid_publish_parameters"
        case 0x08: return "not_a_subscribe_model"
        case 0x09: return "storage_failure"
        case 0x0a: return "feature_not_supported"
        case 0x0b: return "cannot_update"
        case 0x0c: return "cannot_remove"
        case 0x0d: return "cannot_bind"
        case 0x0e: return "temporarily_unable_to_change_state"
        case 0x0f: return "cannot_set"
        case 0x10: return "unspecified_error"
        case 0x11: return "invalid_binding"
        default: return "unknown"
        }
    }

    private static func validateKeyIndex(_ value: Int, label: String) throws {
        guard (0...0x0fff).contains(value) else {
            throw NativeMeshConfigError.invalidParameter("\(label) must be a 12-bit value")
        }
    }

    private static func unpackedKeyIndexes(_ packed: [UInt8]) -> (Int, Int) {
        let first = Int(packed[0]) | ((Int(packed[1]) & 0x0f) << 8)
        let second = ((Int(packed[1]) & 0xf0) >> 4) | (Int(packed[2]) << 4)
        return (first, second)
    }

    private static func unpackedSingleKeyIndex(_ packed: [UInt8]) throws -> Int {
        guard packed.count == 2 else {
            throw NativeMeshConfigError.invalidLength("single key index must be 2 bytes")
        }
        let index = Int(packed[0]) | ((Int(packed[1]) & 0x0f) << 8)
        try validateKeyIndex(index, label: "key index")
        return index
    }

    private static func unpackedKeyIndexList(_ packed: [UInt8]) throws -> [Int] {
        var result: [Int] = []
        var offset = 0
        while offset < packed.count {
            let remaining = packed.count - offset
            if remaining >= 3 {
                let indexes = unpackedKeyIndexes(Array(packed[offset..<(offset + 3)]))
                try validateKeyIndex(indexes.0, label: "key index")
                try validateKeyIndex(indexes.1, label: "key index")
                result.append(indexes.0)
                result.append(indexes.1)
                offset += 3
            } else if remaining == 2 {
                result.append(try unpackedSingleKeyIndex(Array(packed[offset..<(offset + 2)])))
                offset += 2
            } else {
                throw NativeMeshConfigError.invalidLength("packed key index list is truncated")
            }
        }
        return result
    }

    private static func compositionDataPage0(
        _ data: [UInt8],
        includedPageByte: Bool
    ) throws -> NativeMeshCompositionDataPage0 {
        guard data.count >= 10 else {
            throw NativeMeshConfigError.invalidLength("Composition Data Page 0 must include the 10-byte header")
        }

        var index = 0
        let cid = littleEndianUInt16(data, index)
        index += 2
        let pid = littleEndianUInt16(data, index)
        index += 2
        let vid = littleEndianUInt16(data, index)
        index += 2
        let crpl = littleEndianUInt16(data, index)
        index += 2
        let features = littleEndianUInt16(data, index)
        index += 2

        var elements: [NativeMeshCompositionElement] = []
        while index < data.count {
            guard index + 4 <= data.count else {
                throw NativeMeshConfigError.invalidLength("Composition element header is truncated")
            }
            let location = littleEndianUInt16(data, index)
            index += 2
            let sigModelCount = Int(data[index])
            index += 1
            let vendorModelCount = Int(data[index])
            index += 1

            guard index + sigModelCount * 2 + vendorModelCount * 4 <= data.count else {
                throw NativeMeshConfigError.invalidLength("Composition element model list is truncated")
            }

            var sigModels: [UInt16] = []
            for _ in 0..<sigModelCount {
                sigModels.append(littleEndianUInt16(data, index))
                index += 2
            }

            var vendorModels: [NativeMeshVendorModel] = []
            for _ in 0..<vendorModelCount {
                let companyIdentifier = littleEndianUInt16(data, index)
                let modelIdentifier = littleEndianUInt16(data, index + 2)
                vendorModels.append(
                    NativeMeshVendorModel(
                        companyIdentifier: companyIdentifier,
                        modelIdentifier: modelIdentifier
                    )
                )
                index += 4
            }

            elements.append(
                NativeMeshCompositionElement(
                    location: location,
                    sigModels: sigModels,
                    vendorModels: vendorModels
                )
            )
        }

        guard !elements.isEmpty else {
            throw NativeMeshConfigError.invalidLength("Composition Data Page 0 must include at least one element")
        }
        return NativeMeshCompositionDataPage0(
            cid: cid,
            pid: pid,
            vid: vid,
            crpl: crpl,
            features: features,
            elements: elements,
            includedPageByte: includedPageByte
        )
    }

    private static func littleEndianUInt16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private static func littleEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { index in
            UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }
}
