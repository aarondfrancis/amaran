import Foundation

enum NativeMeshStateError: Error, CustomStringConvertible {
    case invalidLength(String)
    case invalidParameter(String)
    case invalidPayload(String)

    var description: String {
        switch self {
        case .invalidLength(let value):
            return "invalid local state length: \(value)"
        case .invalidParameter(let value):
            return "invalid local state parameter: \(value)"
        case .invalidPayload(let value):
            return "invalid local state payload: \(value)"
        }
    }
}

struct NativeProvisionedFixtureState {
    let uuid: String
    let macAddress: String?
    let code: String?
    let name: String?
    let nodeAddress: UInt16
    let deviceKey: [UInt8]
    let deviceUUID: [UInt8]
    let compositionData: [UInt8]?
    let elementCount: Int?
    let updateTime: String

    init(
        uuid: String,
        macAddress: String?,
        code: String?,
        name: String?,
        nodeAddress: UInt16,
        deviceKey: [UInt8],
        deviceUUID: [UInt8],
        compositionData: [UInt8]?,
        elementCount: Int? = nil,
        updateTime: String
    ) {
        self.uuid = uuid
        self.macAddress = macAddress
        self.code = code
        self.name = name
        self.nodeAddress = nodeAddress
        self.deviceKey = deviceKey
        self.deviceUUID = deviceUUID
        self.compositionData = compositionData
        self.elementCount = elementCount
        self.updateTime = updateTime
    }
}

struct NativeMeshState {
    static let schemaVersion = 1

    static func provisionedPayload(
        meshUUID: String,
        netKey: [UInt8],
        appKey: [UInt8],
        fixture: NativeProvisionedFixtureState,
        provisionedAt: String,
        ivIndex: UInt32,
        sequenceNext: Int = 1,
        sourceAddress: UInt16 = 3
    ) throws -> [String: Any] {
        try validateAesKey(netKey, label: "network key")
        try validateAesKey(appKey, label: "application key")
        guard !meshUUID.isEmpty else {
            throw NativeMeshStateError.invalidParameter("mesh UUID is required")
        }
        guard (0...0x00ff_fffe).contains(sequenceNext) else {
            throw NativeMeshStateError.invalidParameter("sequence_next must be between 0 and 0x00fffffe")
        }
        guard (1...0x7fff).contains(Int(sourceAddress)) else {
            throw NativeMeshStateError.invalidParameter("source address must be a non-zero unicast address")
        }

        let fixturePayload = try fixturePayload(fixture)
        let runtimeSourceAddress: UInt16
        if sourceAddress != 1 && sourceAddress != fixture.nodeAddress {
            runtimeSourceAddress = sourceAddress
        } else if fixture.nodeAddress != 3 {
            runtimeSourceAddress = 3
        } else {
            runtimeSourceAddress = 4
        }
        let telinkSourceAddress: UInt16 = fixture.nodeAddress == 1 ? runtimeSourceAddress : 1
        let deviceUUIDHex = NativeMeshCrypto.hex(fixture.deviceUUID)

        let mesh: [String: Any] = [
            "uuid": meshUUID,
            "net_key": NativeMeshCrypto.hex(netKey),
            "app_key": NativeMeshCrypto.hex(appKey),
            "fixtures_ordered_list": "[]",
            "scenes_ordered_list": "[]",
            "update_time": provisionedAt,
            "state": 0,
        ]
        let payload: [String: Any] = [
            "schema_version": schemaVersion,
            "synced_at": provisionedAt,
            "source": [
                "type": "native_provisioning",
                "provisioned_at": provisionedAt,
                "device_uuid": deviceUUIDHex,
            ],
            "mesh": mesh,
            "fixtures": [fixturePayload],
            "runtime": [
                "iv_index": Int(ivIndex),
                "source_address": Int(runtimeSourceAddress),
                "telink_source_address": Int(telinkSourceAddress),
                "sequence_next": sequenceNext,
                "updated_at": provisionedAt,
                "last_reserved_by": "provisioning",
            ],
        ]
        try validatePayload(payload)
        return payload
    }

    static func appendingProvisionedFixturePayload(
        existingPayload: [String: Any],
        fixture: NativeProvisionedFixtureState,
        provisionedAt: String
    ) throws -> [String: Any] {
        try validatePayload(existingPayload)

        guard var mesh = existingPayload["mesh"] as? [String: Any] else {
            throw NativeMeshStateError.invalidPayload("missing mesh")
        }
        guard var fixtures = existingPayload["fixtures"] as? [[String: Any]] else {
            throw NativeMeshStateError.invalidPayload("missing fixtures")
        }
        guard var runtime = existingPayload["runtime"] as? [String: Any] else {
            throw NativeMeshStateError.invalidPayload("missing runtime")
        }

        let newFixture = try fixturePayload(fixture)
        let deviceUUIDHex = NativeMeshCrypto.hex(fixture.deviceUUID)
        let nodeAddress = Int(fixture.nodeAddress)
        if fixtures.contains(where: { intValue($0["node_address"]) == nodeAddress }) {
            throw NativeMeshStateError.invalidPayload("fixture node_address already exists")
        }
        if fixtures.contains(where: { ($0["device_uuid"] as? String)?.caseInsensitiveCompare(deviceUUIDHex) == .orderedSame }) {
            throw NativeMeshStateError.invalidPayload("fixture device_uuid already exists")
        }

        fixtures.append(newFixture)
        mesh["update_time"] = provisionedAt
        runtime["updated_at"] = provisionedAt

        var payload = existingPayload
        payload["synced_at"] = provisionedAt
        payload["source"] = [
            "type": "native_provisioning_append",
            "provisioned_at": provisionedAt,
            "device_uuid": deviceUUIDHex,
            "node_address": nodeAddress,
        ]
        payload["mesh"] = mesh
        payload["fixtures"] = fixtures
        payload["runtime"] = runtime

        try validatePayload(payload)
        return payload
    }

    static func encodedPayload(_ payload: [String: Any]) throws -> Data {
        try validatePayload(payload)
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        return data
    }

    static func writePayload(_ payload: [String: Any], to statePath: String) throws {
        let url = URL(fileURLWithPath: statePath)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encodedPayload(payload).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)
    }

    static func validatePayload(_ payload: [String: Any]) throws {
        guard payload["schema_version"] as? Int == schemaVersion else {
            throw NativeMeshStateError.invalidPayload("unsupported schema_version")
        }
        guard let mesh = payload["mesh"] as? [String: Any] else {
            throw NativeMeshStateError.invalidPayload("missing mesh")
        }
        for field in ["uuid", "net_key", "app_key"] {
            guard let value = mesh[field] as? String, !value.isEmpty else {
                throw NativeMeshStateError.invalidPayload("mesh missing \(field)")
            }
        }
        try validateHexString(mesh["net_key"] as? String, bytes: 16, label: "mesh net_key")
        try validateHexString(mesh["app_key"] as? String, bytes: 16, label: "mesh app_key")

        guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
            throw NativeMeshStateError.invalidPayload("missing fixtures")
        }
        var occupied = Set<Int>()
        for (index, fixture) in fixtures.enumerated() {
            guard fixture["node_address"] != nil else {
                throw NativeMeshStateError.invalidPayload("fixture \(index + 1) missing node_address")
            }
            guard let nodeAddress = intValue(fixture["node_address"]), (1...0x7fff).contains(nodeAddress) else {
                throw NativeMeshStateError.invalidPayload("fixture \(index + 1) has invalid node_address")
            }
            if let macValue = fixture["mac_address"] {
                guard let macAddress = macValue as? String else {
                    throw NativeMeshStateError.invalidPayload("fixture \(index + 1) has invalid mac_address")
                }
                if !macAddress.isEmpty {
                    _ = try normalizedMacAddress(macAddress)
                }
            }
            try validateOptionalHexString(fixture["device_key"] as? String, bytes: 16, label: "fixture device_key")
            try validateOptionalHexString(fixture["device_uuid"] as? String, bytes: 16, label: "fixture device_uuid")
            try validateOptionalHexString(fixture["composition_data"] as? String, label: "fixture composition_data")
            let elementCount = try fixtureElementCount(fixture)
            for offset in 0..<elementCount {
                let address = nodeAddress + offset
                guard address <= 0x7fff else {
                    throw NativeMeshStateError.invalidPayload("fixture \(index + 1) element address exceeds unicast range")
                }
                guard !occupied.contains(address) else {
                    throw NativeMeshStateError.invalidPayload("duplicate fixture element address \(address)")
                }
                occupied.insert(address)
            }
        }

        guard let runtime = payload["runtime"] as? [String: Any] else {
            throw NativeMeshStateError.invalidPayload("missing runtime")
        }
        guard let ivIndex = intValue(runtime["iv_index"]), (0...0xffff_ffff).contains(ivIndex) else {
            throw NativeMeshStateError.invalidPayload("runtime has invalid iv_index")
        }
        guard let sourceAddress = intValue(runtime["source_address"]), (1...0x7fff).contains(sourceAddress) else {
            throw NativeMeshStateError.invalidPayload("runtime has invalid source_address")
        }
        guard let telinkSourceAddress = intValue(runtime["telink_source_address"]), (1...0x7fff).contains(telinkSourceAddress) else {
            throw NativeMeshStateError.invalidPayload("runtime has invalid telink_source_address")
        }
        guard let sequenceNext = intValue(runtime["sequence_next"]), (0...0x00ff_fffe).contains(sequenceNext) else {
            throw NativeMeshStateError.invalidPayload("runtime has invalid sequence_next")
        }
    }

    static func normalizedOptionalMacAddress(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return try normalizedMacAddress(value)
    }

    static func normalizedMacAddress(_ value: String) throws -> String {
        let compact = value.filter { $0 != ":" && $0 != "-" }.uppercased()
        guard compact.count == 12, compact.allSatisfy({ $0.isHexDigit }) else {
            throw NativeMeshStateError.invalidParameter("MAC address must contain 12 hex digits")
        }
        var parts: [String] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            parts.append(String(compact[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }

    private static func fixtureName(
        code: String?,
        macAddress: String?,
        deviceUUIDHex: String,
        nodeAddress: UInt16
    ) -> String {
        let suffix = macAddress?.filter { $0 != ":" }.suffix(6) ?? deviceUUIDHex.uppercased().suffix(6)
        if let code, !code.isEmpty {
            return "\(code)-\(suffix)"
        }
        return suffix.isEmpty ? "fixture-\(nodeAddress)" : String(suffix)
    }

    private static func fixturePayload(_ fixture: NativeProvisionedFixtureState) throws -> [String: Any] {
        try validateAesKey(fixture.deviceKey, label: "device key")
        guard fixture.deviceUUID.count == 16 else {
            throw NativeMeshStateError.invalidLength("device UUID must be 16 bytes")
        }
        guard !fixture.uuid.isEmpty else {
            throw NativeMeshStateError.invalidParameter("fixture UUID is required")
        }
        guard (1...0x7fff).contains(Int(fixture.nodeAddress)) else {
            throw NativeMeshStateError.invalidParameter("fixture node address must be a non-zero unicast address")
        }
        if let elementCount = fixture.elementCount, !(1...255).contains(elementCount) {
            throw NativeMeshStateError.invalidParameter("fixture element_count must be 1..255")
        }

        let macAddress = try normalizedOptionalMacAddress(fixture.macAddress)
        let deviceUUIDHex = NativeMeshCrypto.hex(fixture.deviceUUID)
        var payload: [String: Any] = [
            "uuid": fixture.uuid,
            "mac_address": macAddress ?? "",
            "code": fixture.code ?? "",
            "device_key": NativeMeshCrypto.hex(fixture.deviceKey),
            "device_uuid": deviceUUIDHex,
            "composition_data": NativeMeshCrypto.hex(fixture.compositionData ?? []),
            "fast_provision_supported": 0,
            "control_hw_version": "",
            "name": fixture.name ?? fixtureName(
                code: fixture.code,
                macAddress: macAddress,
                deviceUUIDHex: deviceUUIDHex,
                nodeAddress: fixture.nodeAddress
            ),
            "node_address": Int(fixture.nodeAddress),
            "update_time": fixture.updateTime,
            "state": 0,
            "control_software_version": "",
            "driver_software_version": "",
            "driver_hardware_version": "",
            "ble_software_version": "",
            "ble_hardware_version": "",
        ]
        if let elementCount = fixture.elementCount {
            payload["element_count"] = elementCount
        }
        if macAddress == nil {
            payload["mac_address_source"] = "unavailable_corebluetooth"
        }
        return payload
    }

    private static func validateAesKey(_ key: [UInt8], label: String) throws {
        guard key.count == 16 else {
            throw NativeMeshStateError.invalidLength("\(label) must be 16 bytes")
        }
    }

    private static func validateHexString(_ value: String?, bytes: Int, label: String) throws {
        guard let value, value.count == bytes * 2, value.allSatisfy({ $0.isHexDigit }) else {
            throw NativeMeshStateError.invalidPayload("\(label) must be \(bytes) bytes of hex")
        }
    }

    private static func validateOptionalHexString(_ value: String?, label: String) throws {
        guard let value, !value.isEmpty else {
            return
        }
        guard value.count % 2 == 0, value.allSatisfy({ $0.isHexDigit }) else {
            throw NativeMeshStateError.invalidPayload("\(label) must be hex")
        }
    }

    private static func validateOptionalHexString(_ value: String?, bytes: Int, label: String) throws {
        guard let value, !value.isEmpty else {
            return
        }
        try validateHexString(value, bytes: bytes, label: label)
    }

    private static func fixtureElementCount(_ fixture: [String: Any]) throws -> Int {
        if let compositionHex = fixture["composition_data"] as? String, !compositionHex.isEmpty {
            let compositionBytes = try NativeMeshCrypto.bytes(hex: compositionHex)
            if let composition = try? NativeMeshConfig.compositionDataPage0(compositionBytes) {
                return max(1, composition.elements.count)
            }
        }
        if let elementCount = intValue(fixture["element_count"]) {
            guard (1...255).contains(elementCount) else {
                throw NativeMeshStateError.invalidPayload("fixture element_count must be 1..255")
            }
            return elementCount
        }
        return 1
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}
