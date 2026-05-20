import CoreBluetooth
import Foundation

let meshProxyService = CBUUID(string: "1828")
let meshProvisioningService = CBUUID(string: "1827")
let meshProxyDataIn = CBUUID(string: "2ADD")
let meshProxyDataOut = CBUUID(string: "2ADE")
let meshProvisioningDataIn = CBUUID(string: "2ADB")
let meshProvisioningDataOut = CBUUID(string: "2ADC")
let publicSampleProxyPduHex = "006848cba437860e5673728a627fb938535508e21a6baf57"

func cbuuidString(_ uuid: CBUUID) -> String {
    uuid.uuidString.uppercased()
}

enum BluetoothProbeError: Error, CustomStringConvertible {
    case invalidHex(String)
    case invalidState(String)

    var description: String {
        switch self {
        case .invalidHex(let value):
            return "invalid hex: \(value)"
        case .invalidState(let value):
            return "invalid state: \(value)"
        }
    }
}

func bytes(hex: String) throws -> [UInt8] {
    let compact = hex.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
    guard compact.count % 2 == 0 else {
        throw BluetoothProbeError.invalidHex(hex)
    }

    var result: [UInt8] = []
    result.reserveCapacity(compact.count / 2)
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        guard let byte = UInt8(compact[index..<next], radix: 16) else {
            throw BluetoothProbeError.invalidHex(hex)
        }
        result.append(byte)
        index = next
    }
    return result
}

func defaultStatePath() -> String {
    "\(NSHomeDirectory())/Library/Application Support/amaran-cli/state.json"
}

func jsonInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String {
        return Int(string)
    }
    return nil
}

func jsonString(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty {
        return string
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return nil
}

func isoTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

func writeJSONPayload(_ payload: [String: Any], to outputPath: String) throws {
    let output = URL(fileURLWithPath: outputPath)
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: output, options: .atomic)
}

func writeSensitiveJSONPayload(_ payload: [String: Any], to outputPath: String) throws {
    let output = URL(fileURLWithPath: outputPath)
    let directory = output.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: output, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputPath)
}

struct NativePreparedProxyPdu {
    let proxyPdu: [UInt8]
    let requiredProxyNetworkId: [UInt8]
    let decodeMaterial: NativeDecodeMaterial
    let metadata: [String: Any]
}

struct NativePreparedProxyPduSequence {
    let proxyPdus: [[UInt8]]
    let requiredProxyNetworkId: [UInt8]
    let decodeMaterial: NativeDecodeMaterial
    let metadata: [String: Any]
    let expectedSegmentAckSeqZero: UInt16?
    let expectedSegmentAckSegN: UInt8?
}

func segmentProxyProtocolPdu(_ proxyPdu: [UInt8], maxWriteLength: Int) throws -> [[UInt8]] {
    guard maxWriteLength >= 2 else {
        throw BluetoothProbeError.invalidState("proxy write maximum length must leave room for a header and payload")
    }
    guard let header = proxyPdu.first else {
        throw BluetoothProbeError.invalidState("Proxy PDU must not be empty")
    }
    guard proxyPdu.count > maxWriteLength else {
        return [proxyPdu]
    }

    let messageType = header & NativeMeshProvisioning.proxyMessageTypeMask
    let payload = Array(proxyPdu.dropFirst())
    let payloadCapacity = maxWriteLength - 1
    var segments: [[UInt8]] = []
    var offset = 0
    while offset < payload.count {
        let next = min(offset + payloadCapacity, payload.count)
        let sar: UInt8
        if offset == 0 {
            sar = NativeMeshProvisioning.proxySarFirst
        } else if next == payload.count {
            sar = NativeMeshProvisioning.proxySarLast
        } else {
            sar = NativeMeshProvisioning.proxySarContinuation
        }
        segments.append([sar | messageType] + Array(payload[offset..<next]))
        offset = next
    }
    return segments
}

struct IncomingSegmentedAccessAccumulator {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segN: UInt8
    var segments: [UInt8: (sequence: UInt32, lowerTransportPdu: [UInt8])]

    init(decoded: LowerTransportSegmentedAccessDecoded, sequence: UInt32, lowerTransportPdu: [UInt8]) {
        self.akf = decoded.akf
        self.aid = decoded.aid
        self.szmic = decoded.szmic
        self.seqZero = decoded.seqZero
        self.segN = decoded.segN
        self.segments = [
            decoded.segO: (sequence: sequence, lowerTransportPdu: lowerTransportPdu),
        ]
    }

    mutating func add(decoded: LowerTransportSegmentedAccessDecoded, sequence: UInt32, lowerTransportPdu: [UInt8]) throws {
        guard decoded.akf == akf,
              decoded.aid == aid,
              decoded.szmic == szmic,
              decoded.seqZero == seqZero,
              decoded.segN == segN else {
            throw BluetoothProbeError.invalidState("segmented access PDU does not match pending reassembly")
        }
        segments[decoded.segO] = (sequence: sequence, lowerTransportPdu: lowerTransportPdu)
    }

    var isComplete: Bool {
        segments.count == Int(segN) + 1
    }

    var segmentZeroSequence: UInt32? {
        segments[0]?.sequence
    }

    var orderedLowerTransportPdus: [[UInt8]] {
        (UInt8(0)...segN).compactMap { segments[$0]?.lowerTransportPdu }
    }
}

struct NativeDecodeMaterial {
    let networkKeys: MeshKeyMaterial
    let appKey: [UInt8]
    let appAid: UInt8
    let deviceKey: [UInt8]?
    let ivIndex: UInt32
}

struct NativeProvisioningRun {
    let attentionDuration: Int
    let statePath: String
    let appendsToExistingState: Bool
    let meshUUID: String
    let netKey: [UInt8]
    let appKey: [UInt8]
    let keyIndex: Int
    let flags: Int
    let ivIndex: UInt32
    let unicastAddress: UInt16
    let sourceAddress: UInt16
    let provisionerKeyPair: NativeProvisioningKeyPair
    let provisionerRandom: [UInt8]
}

struct NativeJoinCaptureRun {
    let captureStatePath: String
    let localName: String
    let deviceUUID: [UInt8]
    let elementCount: Int
    let deviceKeyPair: NativeProvisioningKeyPair
    let deviceRandom: [UInt8]
}

func fixtureLabel(_ fixture: [String: Any]) -> String {
    if let name = jsonString(fixture["name"]) {
        return name
    }
    let address = jsonInt(fixture["node_address"]) ?? 0
    return "fixture-\(address)"
}

func fixtureMacSuffix(_ fixture: [String: Any]) -> String? {
    guard let value = jsonString(fixture["mac_address"]) else {
        return nil
    }
    let normalized = value.filter { $0.isHexDigit }.uppercased()
    guard !normalized.isEmpty else {
        return nil
    }
    return String(normalized.suffix(6))
}

func selectFixture(_ fixtures: [[String: Any]], nodeID: String?) throws -> [String: Any] {
    if let nodeID, !nodeID.isEmpty {
        if let fixture = fixtures.first(where: { fixture in
            jsonString(fixture["node_address"]) == nodeID || jsonString(fixture["name"]) == nodeID
        }) {
            return fixture
        }
        throw BluetoothProbeError.invalidState("fixture not found: \(nodeID)")
    }

    guard fixtures.count == 1 else {
        throw BluetoothProbeError.invalidState("multiple fixtures found; pass --node")
    }
    return fixtures[0]
}

func prepareNativeProxyStateProbe(
    statePath: String,
    nodeID: String?
) throws -> (requiredProxyNetworkId: [UInt8], metadata: [String: Any]) {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw BluetoothProbeError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]) else {
        throw BluetoothProbeError.invalidState("state mesh data missing NetKey")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw BluetoothProbeError.invalidState("fixture has invalid node address")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    var metadata: [String: Any] = [
        "address": destination,
        "fixture": fixtureLabel(fixture),
        "probe": "mesh_proxy_network_id",
    ]
    if let suffix = fixtureMacSuffix(fixture) {
        metadata["mac_suffix"] = suffix
    }
    return (try NativeMeshCrypto.k3(n: netKey), metadata)
}

func occupiedFixtureAddresses(_ fixtures: [[String: Any]]) -> Set<Int> {
    var occupied = Set<Int>()
    for fixture in fixtures {
        guard let primary = jsonInt(fixture["node_address"]), (1...0x7fff).contains(primary) else {
            continue
        }

        var elementCount = 1
        if let compositionHex = jsonString(fixture["composition_data"]),
           !compositionHex.isEmpty,
           let compositionBytes = try? NativeMeshCrypto.bytes(hex: compositionHex),
           let composition = try? NativeMeshConfig.compositionDataPage0(compositionBytes) {
            elementCount = max(1, composition.elements.count)
        } else if let storedElementCount = jsonInt(fixture["element_count"]),
                  (1...255).contains(storedElementCount) {
            elementCount = storedElementCount
        }

        for offset in 0..<elementCount {
            let address = primary + offset
            if (1...0x7fff).contains(address) {
                occupied.insert(address)
            }
        }
    }
    return occupied
}

func fixtureHasKnownElementExtent(_ fixture: [String: Any]) -> Bool {
    if let compositionHex = jsonString(fixture["composition_data"]),
       !compositionHex.isEmpty,
       let compositionBytes = try? NativeMeshCrypto.bytes(hex: compositionHex),
       (try? NativeMeshConfig.compositionDataPage0(compositionBytes)) != nil {
        return true
    }
    if let storedElementCount = jsonInt(fixture["element_count"]),
       (1...255).contains(storedElementCount) {
        return true
    }
    return false
}

func provisioningReservedFixtureAddresses(_ fixtures: [[String: Any]]) -> Set<Int> {
    var reserved = occupiedFixtureAddresses(fixtures)
    for fixture in fixtures {
        guard let primary = jsonInt(fixture["node_address"]), (1...0x7fff).contains(primary) else {
            continue
        }
        guard !fixtureHasKnownElementExtent(fixture) else {
            continue
        }
        for offset in 0..<16 {
            let address = primary + offset
            if (1...0x7fff).contains(address) {
                reserved.insert(address)
            }
        }
    }
    return reserved
}

func nextProvisioningUnicastAddress(
    fixtures: [[String: Any]],
    runtime: [String: Any]
) throws -> UInt16 {
    var reserved = provisioningReservedFixtureAddresses(fixtures)
    for key in ["source_address", "telink_source_address"] {
        if let address = jsonInt(runtime[key]), (1...0x7fff).contains(address) {
            reserved.insert(address)
        }
    }

    for candidate in 2...0x7fff {
        if !reserved.contains(candidate) {
            return UInt16(candidate)
        }
    }
    throw BluetoothProbeError.invalidState("could not choose an unused fixture node address")
}

func nativeRuntimeSourceAddress(
    runtime: [String: Any],
    fixtures: [[String: Any]],
    destination: Int
) throws -> Int {
    let occupied = occupiedFixtureAddresses(fixtures)
    let existing = jsonInt(runtime["source_address"])
    if let existing, !(1...0x7fff).contains(existing) {
        throw BluetoothProbeError.invalidState("runtime source_address must be a unicast address")
    }
    if let existing,
       existing != 1,
       existing != destination,
       !occupied.contains(existing) {
        return existing
    }

    if !occupied.contains(3), destination != 3 {
        return 3
    }
    for candidate in 4...0x7fff {
        if candidate != destination, !occupied.contains(candidate) {
            return candidate
        }
    }
    if !occupied.contains(2), destination != 2 {
        return 2
    }
    throw BluetoothProbeError.invalidState("could not choose an unused CLI source address")
}

func nativeTelinkSourceAddress(
    runtime: [String: Any],
    fixtures: [[String: Any]],
    destination: Int
) throws -> Int {
    let occupied = occupiedFixtureAddresses(fixtures)
    let existing = jsonInt(runtime["telink_source_address"])
    if let existing, !(1...0x7fff).contains(existing) {
        throw BluetoothProbeError.invalidState("runtime telink_source_address must be a unicast address")
    }
    if let existing,
       existing != destination,
       !occupied.contains(existing) {
        return existing
    }

    if destination != 1, !occupied.contains(1) {
        return 1
    }
    return try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: destination
    )
}

enum NativeSourceRole {
    case cliOwned
    case telinkRuntime
}

func reserveNativeAccessProxyPdu(
    statePath: String,
    nodeID: String?,
    accessMessage: [UInt8],
    metadata: [String: Any],
    lastReservedBy: String,
    sourceRole: NativeSourceRole = .cliOwned
) throws -> NativePreparedProxyPdu {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw BluetoothProbeError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]), let appKeyHex = jsonString(mesh["app_key"]) else {
        throw BluetoothProbeError.invalidState("state mesh data missing keys")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw BluetoothProbeError.invalidState("fixture has invalid node address")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let ivIndex = jsonInt(runtime["iv_index"]) ?? 0
    let sourceAddress: Int
    switch sourceRole {
    case .cliOwned:
        sourceAddress = try nativeRuntimeSourceAddress(
            runtime: runtime,
            fixtures: fixtures,
            destination: destination
        )
    case .telinkRuntime:
        sourceAddress = try nativeTelinkSourceAddress(
            runtime: runtime,
            fixtures: fixtures,
            destination: destination
        )
    }

    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw BluetoothProbeError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    let appKey = try NativeMeshCrypto.bytes(hex: appKeyHex)
    let networkKeys = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
    let appAid = try NativeMeshCrypto.k4(n: appKey)
    let sequence = UInt32(sequenceNext)
    let built = try NativeMeshCrypto.applicationAccessProxyPdu(
        ivIndex: UInt32(ivIndex),
        ttl: 10,
        sequence: sequence,
        source: UInt16(sourceAddress),
        destination: UInt16(destination),
        netKey: netKey,
        applicationKey: appKey,
        accessMessage: accessMessage
    )

    runtime["iv_index"] = ivIndex
    switch sourceRole {
    case .cliOwned:
        runtime["source_address"] = sourceAddress
    case .telinkRuntime:
        runtime["telink_source_address"] = sourceAddress
    }
    runtime["sequence_next"] = sequenceNext + 1
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = lastReservedBy
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    var sendMetadata = metadata
    sendMetadata["address"] = destination
    sendMetadata["fixture"] = fixtureLabel(fixture)
    sendMetadata["iv_index"] = ivIndex
    sendMetadata["sequence"] = sequenceNext
    sendMetadata["sequence_next"] = sequenceNext + 1
    sendMetadata["source"] = sourceAddress
    sendMetadata["ttl"] = 10

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: netKey),
        decodeMaterial: NativeDecodeMaterial(
            networkKeys: networkKeys,
            appKey: appKey,
            appAid: appAid,
            deviceKey: nil,
            ivIndex: UInt32(ivIndex)
        ),
        metadata: sendMetadata
    )
}

func reserveNativeSigOnOffProxyPdu(
    statePath: String,
    nodeID: String?,
    turnOn: Bool
) throws -> NativePreparedProxyPdu {
    let sequenceNext = try peekNativeSequenceNext(statePath: statePath)
    let tid = UInt8(UInt32(sequenceNext) & 0xff)
    return try reserveNativeAccessProxyPdu(
        statePath: statePath,
        nodeID: nodeID,
        accessMessage: [0x82, 0x03, turnOn ? 0x01 : 0x00, tid],
        metadata: [
            "opcode": "Generic OnOff Set Unacknowledged",
            "onoff": turnOn,
        ],
        lastReservedBy: "sig-onoff-test"
    )
}

func reserveNativeControlProxyPdu(
    statePath: String,
    nodeID: String?,
    command: NativeTelinkControlCommand
) throws -> NativePreparedProxyPdu {
    try reserveNativeAccessProxyPdu(
        statePath: statePath,
        nodeID: nodeID,
        accessMessage: command.accessMessage(),
        metadata: command.metadata(),
        lastReservedBy: "control-test",
        sourceRole: .telinkRuntime
    )
}

func reserveNativeStatusProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    try reserveNativeAccessProxyPdu(
        statePath: statePath,
        nodeID: nodeID,
        accessMessage: NativeTelinkControlCommand.status.accessMessage(),
        metadata: NativeTelinkControlCommand.status.metadata(),
        lastReservedBy: "status-test",
        sourceRole: .telinkRuntime
    )
}

func reserveNativeConfigCompositionGetProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw BluetoothProbeError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]), let appKeyHex = jsonString(mesh["app_key"]) else {
        throw BluetoothProbeError.invalidState("state mesh data missing keys")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw BluetoothProbeError.invalidState("fixture has invalid node address")
    }
    guard let deviceKeyHex = jsonString(fixture["device_key"]) else {
        throw BluetoothProbeError.invalidState("fixture is missing device key")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let ivIndex = jsonInt(runtime["iv_index"]) ?? 0
    let sourceAddress = try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: destination
    )

    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw BluetoothProbeError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    let appKey = try NativeMeshCrypto.bytes(hex: appKeyHex)
    let deviceKey = try NativeMeshCrypto.bytes(hex: deviceKeyHex)
    let networkKeys = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
    let appAid = try NativeMeshCrypto.k4(n: appKey)
    let accessMessage = NativeMeshConfig.configCompositionDataGet()
    let built = try NativeMeshCrypto.deviceAccessProxyPdu(
        ivIndex: UInt32(ivIndex),
        ttl: 10,
        sequence: UInt32(sequenceNext),
        source: UInt16(sourceAddress),
        destination: UInt16(destination),
        netKey: netKey,
        deviceKey: deviceKey,
        accessMessage: accessMessage
    )

    runtime["iv_index"] = ivIndex
    runtime["source_address"] = sourceAddress
    runtime["sequence_next"] = sequenceNext + 1
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = "config-composition-get-test"
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    let sendMetadata: [String: Any] = [
        "address": destination,
        "fixture": fixtureLabel(fixture),
        "iv_index": ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_next": sequenceNext + 1,
        "opcode": "Config Composition Data Get",
        "config_command": "composition_data_get",
        "page": 0,
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count,
    ]

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: netKey),
        decodeMaterial: NativeDecodeMaterial(
            networkKeys: networkKeys,
            appKey: appKey,
            appAid: appAid,
            deviceKey: deviceKey,
            ivIndex: UInt32(ivIndex)
        ),
        metadata: sendMetadata
    )
}

func reserveNativeConfigAppKeyGetProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw BluetoothProbeError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]), let appKeyHex = jsonString(mesh["app_key"]) else {
        throw BluetoothProbeError.invalidState("state mesh data missing keys")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw BluetoothProbeError.invalidState("fixture has invalid node address")
    }
    guard let deviceKeyHex = jsonString(fixture["device_key"]) else {
        throw BluetoothProbeError.invalidState("fixture is missing device key")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let ivIndex = jsonInt(runtime["iv_index"]) ?? 0
    let sourceAddress = try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: destination
    )

    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw BluetoothProbeError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    let appKey = try NativeMeshCrypto.bytes(hex: appKeyHex)
    let deviceKey = try NativeMeshCrypto.bytes(hex: deviceKeyHex)
    let networkKeys = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
    let appAid = try NativeMeshCrypto.k4(n: appKey)
    let accessMessage = try NativeMeshConfig.configAppKeyGet(netKeyIndex: 0)
    let built = try NativeMeshCrypto.deviceAccessProxyPdu(
        ivIndex: UInt32(ivIndex),
        ttl: 10,
        sequence: UInt32(sequenceNext),
        source: UInt16(sourceAddress),
        destination: UInt16(destination),
        netKey: netKey,
        deviceKey: deviceKey,
        accessMessage: accessMessage
    )

    runtime["iv_index"] = ivIndex
    runtime["source_address"] = sourceAddress
    runtime["sequence_next"] = sequenceNext + 1
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = "config-appkey-get-test"
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    let sendMetadata: [String: Any] = [
        "address": destination,
        "fixture": fixtureLabel(fixture),
        "iv_index": ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_next": sequenceNext + 1,
        "opcode": "Config AppKey Get",
        "config_command": "appkey_get",
        "net_key_index": 0,
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count,
    ]

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: netKey),
        decodeMaterial: NativeDecodeMaterial(
            networkKeys: networkKeys,
            appKey: appKey,
            appAid: appAid,
            deviceKey: deviceKey,
            ivIndex: UInt32(ivIndex)
        ),
        metadata: sendMetadata
    )
}

func reserveNativeConfigAppKeyAddProxyPdus(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPduSequence {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw BluetoothProbeError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]), let appKeyHex = jsonString(mesh["app_key"]) else {
        throw BluetoothProbeError.invalidState("state mesh data missing keys")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw BluetoothProbeError.invalidState("fixture has invalid node address")
    }
    guard let deviceKeyHex = jsonString(fixture["device_key"]) else {
        throw BluetoothProbeError.invalidState("fixture is missing device key")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let ivIndex = jsonInt(runtime["iv_index"]) ?? 0
    let sourceAddress = try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: destination
    )

    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw BluetoothProbeError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    let appKey = try NativeMeshCrypto.bytes(hex: appKeyHex)
    let deviceKey = try NativeMeshCrypto.bytes(hex: deviceKeyHex)
    let networkKeys = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
    let appAid = try NativeMeshCrypto.k4(n: appKey)
    let accessMessage = try NativeMeshConfig.configAppKeyAdd(
        netKeyIndex: 0,
        appKeyIndex: 0,
        appKey: appKey
    )
    let built = try NativeMeshCrypto.segmentedDeviceAccessProxyPdus(
        ivIndex: UInt32(ivIndex),
        ttl: 10,
        sequence: UInt32(sequenceNext),
        source: UInt16(sourceAddress),
        destination: UInt16(destination),
        netKey: netKey,
        deviceKey: deviceKey,
        accessMessage: accessMessage
    )
    guard sequenceNext + built.proxyPdus.count <= 0x00ff_ffff else {
        throw BluetoothProbeError.invalidState("runtime sequence_next does not have room for segmented config send")
    }

    let nextSequence = sequenceNext + built.proxyPdus.count
    runtime["iv_index"] = ivIndex
    runtime["source_address"] = sourceAddress
    runtime["sequence_next"] = nextSequence
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = "config-appkey-add-test"
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    let segmentLengths = built.proxyPdus.map(\.count)
    let sendMetadata: [String: Any] = [
        "address": destination,
        "fixture": fixtureLabel(fixture),
        "iv_index": ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_last": sequenceNext + built.proxyPdus.count - 1,
        "sequence_next": nextSequence,
        "opcode": "Config AppKey Add",
        "config_command": "appkey_add",
        "net_key_index": 0,
        "app_key_index": 0,
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count,
        "segment_count": built.proxyPdus.count,
        "segment_lengths": segmentLengths,
        "seq_zero": Int(built.lowerTransport.seqZero),
        "seg_n": Int(built.lowerTransport.segN),
    ]

    return NativePreparedProxyPduSequence(
        proxyPdus: built.proxyPdus,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: netKey),
        decodeMaterial: NativeDecodeMaterial(
            networkKeys: networkKeys,
            appKey: appKey,
            appAid: appAid,
            deviceKey: deviceKey,
            ivIndex: UInt32(ivIndex)
        ),
        metadata: sendMetadata,
        expectedSegmentAckSeqZero: built.lowerTransport.seqZero,
        expectedSegmentAckSegN: built.lowerTransport.segN
    )
}

func reserveNativeConfigModelAppBindProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw BluetoothProbeError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]), let appKeyHex = jsonString(mesh["app_key"]) else {
        throw BluetoothProbeError.invalidState("state mesh data missing keys")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw BluetoothProbeError.invalidState("fixture has invalid node address")
    }
    guard let deviceKeyHex = jsonString(fixture["device_key"]) else {
        throw BluetoothProbeError.invalidState("fixture is missing device key")
    }
    guard let compositionHex = jsonString(fixture["composition_data"]) else {
        throw BluetoothProbeError.invalidState("fixture is missing composition data")
    }

    let composition = try NativeMeshConfig.compositionDataPage0(
        NativeMeshCrypto.bytes(hex: compositionHex)
    )
    guard let target = composition.firstVendorModelBindingTarget else {
        throw BluetoothProbeError.invalidState("fixture composition data has no vendor model to bind")
    }
    let elementAddress = destination + target.elementIndex
    guard (1...0x7fff).contains(elementAddress) else {
        throw BluetoothProbeError.invalidState("computed element address is not a unicast address")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let ivIndex = jsonInt(runtime["iv_index"]) ?? 0
    let sourceAddress = try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: destination
    )

    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw BluetoothProbeError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    let appKey = try NativeMeshCrypto.bytes(hex: appKeyHex)
    let deviceKey = try NativeMeshCrypto.bytes(hex: deviceKeyHex)
    let networkKeys = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
    let appAid = try NativeMeshCrypto.k4(n: appKey)
    let accessMessage = try NativeMeshConfig.configModelAppBind(
        elementAddress: UInt16(elementAddress),
        appKeyIndex: 0,
        modelIdentifier: .vendor(
            companyIdentifier: target.model.companyIdentifier,
            modelIdentifier: target.model.modelIdentifier
        )
    )
    let built = try NativeMeshCrypto.deviceAccessProxyPdu(
        ivIndex: UInt32(ivIndex),
        ttl: 10,
        sequence: UInt32(sequenceNext),
        source: UInt16(sourceAddress),
        destination: UInt16(destination),
        netKey: netKey,
        deviceKey: deviceKey,
        accessMessage: accessMessage
    )

    runtime["iv_index"] = ivIndex
    runtime["source_address"] = sourceAddress
    runtime["sequence_next"] = sequenceNext + 1
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = "config-model-app-bind-test"
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    let sendMetadata: [String: Any] = [
        "address": destination,
        "fixture": fixtureLabel(fixture),
        "iv_index": ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_next": sequenceNext + 1,
        "opcode": "Config Model App Bind",
        "config_command": "model_app_bind",
        "app_key_index": 0,
        "element_address": elementAddress,
        "element_index": target.elementIndex,
        "composition_cid": String(format: "%04x", composition.cid),
        "model_company_id": String(format: "%04x", target.model.companyIdentifier),
        "model_id": String(format: "%04x", target.model.modelIdentifier),
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count,
    ]

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: netKey),
        decodeMaterial: NativeDecodeMaterial(
            networkKeys: networkKeys,
            appKey: appKey,
            appAid: appAid,
            deviceKey: deviceKey,
            ivIndex: UInt32(ivIndex)
        ),
        metadata: sendMetadata
    )
}

func reserveNativeConfigNodeResetProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw BluetoothProbeError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]), let appKeyHex = jsonString(mesh["app_key"]) else {
        throw BluetoothProbeError.invalidState("state mesh data missing keys")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw BluetoothProbeError.invalidState("fixture has invalid node address")
    }
    guard let deviceKeyHex = jsonString(fixture["device_key"]) else {
        throw BluetoothProbeError.invalidState("fixture is missing device key")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let ivIndex = jsonInt(runtime["iv_index"]) ?? 0
    let sourceAddress = try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: destination
    )

    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw BluetoothProbeError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    let appKey = try NativeMeshCrypto.bytes(hex: appKeyHex)
    let deviceKey = try NativeMeshCrypto.bytes(hex: deviceKeyHex)
    let networkKeys = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
    let appAid = try NativeMeshCrypto.k4(n: appKey)
    let accessMessage = NativeMeshConfig.configNodeReset()
    let built = try NativeMeshCrypto.deviceAccessProxyPdu(
        ivIndex: UInt32(ivIndex),
        ttl: 10,
        sequence: UInt32(sequenceNext),
        source: UInt16(sourceAddress),
        destination: UInt16(destination),
        netKey: netKey,
        deviceKey: deviceKey,
        accessMessage: accessMessage
    )

    runtime["iv_index"] = ivIndex
    runtime["source_address"] = sourceAddress
    runtime["sequence_next"] = sequenceNext + 1
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = "config-node-reset-test"
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    let sendMetadata: [String: Any] = [
        "address": destination,
        "fixture": fixtureLabel(fixture),
        "iv_index": ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_next": sequenceNext + 1,
        "opcode": "Config Node Reset",
        "config_command": "node_reset",
        "destructive": true,
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count,
    ]

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: netKey),
        decodeMaterial: NativeDecodeMaterial(
            networkKeys: networkKeys,
            appKey: appKey,
            appAid: appAid,
            deviceKey: deviceKey,
            ivIndex: UInt32(ivIndex)
        ),
        metadata: sendMetadata
    )
}

func peekNativeSequenceNext(statePath: String) throws -> Int {
    let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    let runtime = payload["runtime"] as? [String: Any] ?? [:]
    return jsonInt(runtime["sequence_next"]) ?? 1
}

func reserveNativeRuntimeSequence(
    statePath: String,
    lastReservedBy: String
) throws -> (sequence: Int, sequenceNext: Int) {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BluetoothProbeError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw BluetoothProbeError.invalidState("unsupported state schema version")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw BluetoothProbeError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    runtime["sequence_next"] = sequenceNext + 1
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = lastReservedBy
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    return (sequenceNext, sequenceNext + 1)
}

func makeNativeProvisioningRun(
    attentionDuration: Int,
    statePath: String,
    addToExistingState: Bool = false,
    unicastAddress: UInt16 = 2,
    sourceAddress: UInt16 = 3
) throws -> NativeProvisioningRun {
    guard (0...255).contains(attentionDuration) else {
        throw BluetoothProbeError.invalidState("attention duration must be 0..255")
    }
    if addToExistingState {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: statePath))
        } catch {
            throw BluetoothProbeError.invalidState("existing state file is required before adding a fixture")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BluetoothProbeError.invalidState("state file must contain a JSON object")
        }
        do {
            try NativeMeshState.validatePayload(payload)
        } catch {
            throw BluetoothProbeError.invalidState("existing state is not usable for fixture add: \(error)")
        }
        guard let mesh = payload["mesh"] as? [String: Any],
              let fixtures = payload["fixtures"] as? [[String: Any]],
              let runtime = payload["runtime"] as? [String: Any],
              let meshUUID = jsonString(mesh["uuid"]),
              let netKeyHex = jsonString(mesh["net_key"]),
              let appKeyHex = jsonString(mesh["app_key"]) else {
            throw BluetoothProbeError.invalidState("existing state is missing mesh data")
        }
        guard let ivIndex = jsonInt(runtime["iv_index"]), (0...0xffff_ffff).contains(ivIndex) else {
            throw BluetoothProbeError.invalidState("existing state runtime has invalid iv_index")
        }
        let nextAddress = try nextProvisioningUnicastAddress(fixtures: fixtures, runtime: runtime)
        let selectedSourceAddress = try nativeRuntimeSourceAddress(
            runtime: runtime,
            fixtures: fixtures,
            destination: Int(nextAddress)
        )

        return NativeProvisioningRun(
            attentionDuration: attentionDuration,
            statePath: statePath,
            appendsToExistingState: true,
            meshUUID: meshUUID,
            netKey: try NativeMeshCrypto.bytes(hex: netKeyHex),
            appKey: try NativeMeshCrypto.bytes(hex: appKeyHex),
            keyIndex: 0,
            flags: 0,
            ivIndex: UInt32(ivIndex),
            unicastAddress: nextAddress,
            sourceAddress: UInt16(selectedSourceAddress),
            provisionerKeyPair: try NativeMeshProvisioning.generateProvisionerKeyPair(),
            provisionerRandom: try NativeMeshProvisioning.generateProvisioningRandom()
        )
    }

    guard (1...0x7fff).contains(Int(unicastAddress)) else {
        throw BluetoothProbeError.invalidState("provisioned node address must be a unicast address")
    }
    guard (1...0x7fff).contains(Int(sourceAddress)), sourceAddress != unicastAddress else {
        throw BluetoothProbeError.invalidState("provisioner source address must be a different unicast address")
    }
    guard !FileManager.default.fileExists(atPath: statePath) else {
        throw BluetoothProbeError.invalidState(
            "state file already exists; use add mode or set AMARAN_CLI_STATE_PATH before provisioning"
        )
    }
    return NativeProvisioningRun(
        attentionDuration: attentionDuration,
        statePath: statePath,
        appendsToExistingState: false,
        meshUUID: UUID().uuidString,
        netKey: try NativeMeshProvisioning.generateProvisioningRandom(),
        appKey: try NativeMeshProvisioning.generateProvisioningRandom(),
        keyIndex: 0,
        flags: 0,
        ivIndex: 0,
        unicastAddress: unicastAddress,
        sourceAddress: sourceAddress,
        provisionerKeyPair: try NativeMeshProvisioning.generateProvisionerKeyPair(),
        provisionerRandom: try NativeMeshProvisioning.generateProvisioningRandom()
    )
}

func centralStateName(_ state: CBManagerState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .resetting: return "resetting"
    case .unsupported: return "unsupported"
    case .unauthorized: return "unauthorized"
    case .poweredOff: return "poweredOff"
    case .poweredOn: return "poweredOn"
    @unknown default: return "future"
    }
}

func characteristicProperties(_ properties: CBCharacteristicProperties) -> [String] {
    var names: [String] = []
    if properties.contains(.broadcast) { names.append("broadcast") }
    if properties.contains(.read) { names.append("read") }
    if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
    if properties.contains(.write) { names.append("write") }
    if properties.contains(.notify) { names.append("notify") }
    if properties.contains(.indicate) { names.append("indicate") }
    if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
    if properties.contains(.extendedProperties) { names.append("extendedProperties") }
    if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
    if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
    return names
}

func meshRole(serviceUUIDs: [String]) -> [String] {
    var roles: [String] = []
    if serviceUUIDs.contains("1828") { roles.append("proxy") }
    if serviceUUIDs.contains("1827") { roles.append("provisioning") }
    return roles
}

final class ProbeOptions {
    var outputPath = "/tmp/amaran-bluetooth-probe.json"
    var timeout: TimeInterval = 10
    var connect = true
    var scanServices = [meshProxyService, meshProvisioningService]
    var connectService: CBUUID?
    var proxyPdu: [UInt8]?
    var proxyPdus: [[UInt8]] = []
    var proxyPduLabel = "custom"
    var writeDataInUUID = meshProxyDataIn
    var writeDataOutUUID = meshProxyDataOut
    var requiredProxyNetworkId: [UInt8]?
    var decodeMaterial: NativeDecodeMaterial?
    var nativeSendMetadata: [String: Any]?
    var nativeProvisioningRun: NativeProvisioningRun?
    var nativeJoinCaptureRun: NativeJoinCaptureRun?
    var nodeID: String?
    var statePath = defaultStatePath()
    var settleAfterWrite: TimeInterval = 1.0
    var proxyWriteInterSegmentDelay: TimeInterval = 0.03
    var expectedSegmentAckSeqZero: UInt16?
    var expectedSegmentAckSegN: UInt8?
    var segmentAckMaxSendAttempts = 4
    var segmentAckRetryDelay: TimeInterval = 0.75
    var storeConfigCompositionData = false
    var confirmReset = false
    var configurationError: String?

    init(arguments: [String]) {
        confirmReset = arguments.contains("--confirm-reset")
        let addToExistingState = arguments.contains("--add-to-existing-state")
        var joinCaptureRequested = false
        var joinCapturePath: String?
        var joinCaptureName = "amaran 60x S"
        var joinCaptureDeviceUUID: [UInt8]?
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--output":
                if index + 1 < arguments.count {
                    outputPath = arguments[index + 1]
                    index += 2
                } else {
                    index += 1
                }
            case "--timeout":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    timeout = max(1, value)
                    index += 2
                } else {
                    index += 1
                }
            case "--scan-only":
                connect = false
                index += 1
            case "--provisioning-scan":
                scanServices = [meshProvisioningService]
                connectService = meshProvisioningService
                connect = true
                index += 1
            case "--provisioning-invite-test":
                if index + 1 < arguments.count, let attentionDuration = Int(arguments[index + 1]) {
                    do {
                        proxyPdu = NativeMeshProvisioning.completeProxyPdu(
                            provisioningPdu: try NativeMeshProvisioning.provisioningInvite(
                                attentionDuration: attentionDuration
                            )
                        )
                        proxyPduLabel = "provisioning-invite"
                        writeDataInUUID = meshProvisioningDataIn
                        writeDataOutUUID = meshProvisioningDataOut
                        scanServices = [meshProvisioningService]
                        connectService = meshProvisioningService
                        nativeSendMetadata = [
                            "attention_duration": attentionDuration,
                            "pdu_type": "provisioning_invite",
                        ]
                        settleAfterWrite = max(settleAfterWrite, 2.0)
                        connect = true
                    } catch {
                        configurationError = String(describing: error)
                    }
                    index += 2
                } else {
                    configurationError = "--provisioning-invite-test requires an attention duration from 0 to 255"
                    index += 1
                }
            case "--provision-test":
                if index + 1 < arguments.count, let attentionDuration = Int(arguments[index + 1]) {
                    do {
                        nativeProvisioningRun = try makeNativeProvisioningRun(
                            attentionDuration: attentionDuration,
                            statePath: statePath,
                            addToExistingState: addToExistingState
                        )
                        proxyPduLabel = "provision"
                        writeDataInUUID = meshProvisioningDataIn
                        writeDataOutUUID = meshProvisioningDataOut
                        scanServices = [meshProvisioningService]
                        connectService = meshProvisioningService
                        nativeSendMetadata = [
                            "attention_duration": attentionDuration,
                            "pdu_type": "provision",
                            "state_mode": addToExistingState ? "append" : "create",
                            "node_address": Int(nativeProvisioningRun?.unicastAddress ?? 0),
                        ]
                        connect = true
                    } catch {
                        configurationError = String(describing: error)
                    }
                    index += 2
                } else {
                    configurationError = "--provision-test requires an attention duration from 0 to 255"
                    index += 1
                }
            case "--join-capture":
                joinCaptureRequested = true
                connect = false
                scanServices = []
                index += 1
            case "--capture-state":
                if index + 1 < arguments.count {
                    joinCapturePath = (arguments[index + 1] as NSString).expandingTildeInPath
                    index += 2
                } else {
                    configurationError = "--capture-state requires a file path"
                    index += 1
                }
            case "--advertise-name":
                if index + 1 < arguments.count {
                    joinCaptureName = arguments[index + 1]
                    index += 2
                } else {
                    configurationError = "--advertise-name requires a value"
                    index += 1
                }
            case "--device-uuid":
                if index + 1 < arguments.count {
                    do {
                        let value = try bytes(hex: arguments[index + 1])
                        guard value.count == 16 else {
                            throw BluetoothProbeError.invalidState("device UUID must be 16 bytes")
                        }
                        joinCaptureDeviceUUID = value
                    } catch {
                        configurationError = String(describing: error)
                    }
                    index += 2
                } else {
                    configurationError = "--device-uuid requires a 16-byte hex value"
                    index += 1
                }
            case "--node":
                if index + 1 < arguments.count {
                    nodeID = arguments[index + 1]
                    index += 2
                } else {
                    index += 1
                }
            case "--state-path":
                if index + 1 < arguments.count {
                    statePath = (arguments[index + 1] as NSString).expandingTildeInPath
                    index += 2
                } else {
                    index += 1
                }
            case "--proxy-state-probe":
                do {
                    let prepared = try prepareNativeProxyStateProbe(
                        statePath: statePath,
                        nodeID: nodeID
                    )
                    requiredProxyNetworkId = prepared.requiredProxyNetworkId
                    nativeSendMetadata = prepared.metadata
                    scanServices = [meshProxyService]
                    connectService = meshProxyService
                    connect = true
                } catch {
                    configurationError = String(describing: error)
                }
                index += 1
            case "--proxy-test":
                do {
                    proxyPdu = try bytes(hex: publicSampleProxyPduHex)
                    proxyPduLabel = "public-sample-network-pdu"
                    connect = true
                } catch {
                    fputs("invalid built-in proxy test PDU: \(error)\n", stderr)
                }
                index += 1
            case "--proxy-pdu":
                if index + 1 < arguments.count {
                    do {
                        proxyPdu = try bytes(hex: arguments[index + 1])
                        proxyPduLabel = "custom"
                        connect = true
                    } catch {
                        fputs("\(error)\n", stderr)
                    }
                    index += 2
                } else {
                    index += 1
                }
            case "--sig-onoff-test":
                if index + 1 < arguments.count {
                    let value = arguments[index + 1].lowercased()
                    if value == "on" || value == "off" {
                        do {
                            let prepared = try reserveNativeSigOnOffProxyPdu(
                                statePath: statePath,
                                nodeID: nodeID,
                                turnOn: value == "on"
                            )
                            proxyPdu = prepared.proxyPdu
                            proxyPduLabel = "generic-onoff-set-unack"
                            requiredProxyNetworkId = prepared.requiredProxyNetworkId
                            decodeMaterial = prepared.decodeMaterial
                            nativeSendMetadata = prepared.metadata
                            connect = true
                        } catch {
                            configurationError = String(describing: error)
                        }
                    } else {
                        configurationError = "--sig-onoff-test must be on or off"
                    }
                    index += 2
                } else {
                    configurationError = "--sig-onoff-test requires on or off"
                    index += 1
                }
            case "--control-test":
                if index + 1 < arguments.count {
                    do {
                        let command = try NativeTelinkControlCommand.parse(spec: arguments[index + 1].lowercased())
                        let prepared = try reserveNativeControlProxyPdu(
                            statePath: statePath,
                            nodeID: nodeID,
                            command: command
                        )
                        proxyPdu = prepared.proxyPdu
                        proxyPduLabel = "telink-0x26-control"
                        requiredProxyNetworkId = prepared.requiredProxyNetworkId
                        decodeMaterial = prepared.decodeMaterial
                        nativeSendMetadata = prepared.metadata
                        connect = true
                    } catch {
                        configurationError = String(describing: error)
                    }
                    index += 2
                } else {
                    configurationError = "--control-test requires a command spec"
                    index += 1
                }
            case "--status-test":
                do {
                    let prepared = try reserveNativeStatusProxyPdu(
                        statePath: statePath,
                        nodeID: nodeID
                    )
                    proxyPdu = prepared.proxyPdu
                    proxyPduLabel = "telink-0x26-status"
                    requiredProxyNetworkId = prepared.requiredProxyNetworkId
                    decodeMaterial = prepared.decodeMaterial
                    nativeSendMetadata = prepared.metadata
                    settleAfterWrite = max(settleAfterWrite, 2.0)
                    connect = true
                } catch {
                    configurationError = String(describing: error)
                }
                index += 1
            case "--config-composition-get-test":
                do {
                    let prepared = try reserveNativeConfigCompositionGetProxyPdu(
                        statePath: statePath,
                        nodeID: nodeID
                    )
                    proxyPdu = prepared.proxyPdu
                    proxyPduLabel = "config-composition-data-get"
                    requiredProxyNetworkId = prepared.requiredProxyNetworkId
                    decodeMaterial = prepared.decodeMaterial
                    nativeSendMetadata = prepared.metadata
                    storeConfigCompositionData = true
                    settleAfterWrite = max(settleAfterWrite, 4.0)
                    connect = true
                } catch {
                    configurationError = String(describing: error)
                }
                index += 1
            case "--config-appkey-get-test":
                do {
                    let prepared = try reserveNativeConfigAppKeyGetProxyPdu(
                        statePath: statePath,
                        nodeID: nodeID
                    )
                    proxyPdu = prepared.proxyPdu
                    proxyPduLabel = "config-appkey-get"
                    requiredProxyNetworkId = prepared.requiredProxyNetworkId
                    decodeMaterial = prepared.decodeMaterial
                    nativeSendMetadata = prepared.metadata
                    settleAfterWrite = max(settleAfterWrite, 2.0)
                    connect = true
                } catch {
                    configurationError = String(describing: error)
                }
                index += 1
            case "--config-appkey-add-test":
                do {
                    let prepared = try reserveNativeConfigAppKeyAddProxyPdus(
                        statePath: statePath,
                        nodeID: nodeID
                    )
                    proxyPdus = prepared.proxyPdus
                    proxyPduLabel = "config-appkey-add"
                    requiredProxyNetworkId = prepared.requiredProxyNetworkId
                    decodeMaterial = prepared.decodeMaterial
                    nativeSendMetadata = prepared.metadata
                    expectedSegmentAckSeqZero = prepared.expectedSegmentAckSeqZero
                    expectedSegmentAckSegN = prepared.expectedSegmentAckSegN
                    proxyWriteInterSegmentDelay = max(proxyWriteInterSegmentDelay, 0.25)
                    settleAfterWrite = max(settleAfterWrite, 2.0)
                    connect = true
                } catch {
                    configurationError = String(describing: error)
                }
                index += 1
            case "--config-model-app-bind-test":
                do {
                    let prepared = try reserveNativeConfigModelAppBindProxyPdu(
                        statePath: statePath,
                        nodeID: nodeID
                    )
                    proxyPdu = prepared.proxyPdu
                    proxyPduLabel = "config-model-app-bind"
                    requiredProxyNetworkId = prepared.requiredProxyNetworkId
                    decodeMaterial = prepared.decodeMaterial
                    nativeSendMetadata = prepared.metadata
                    connect = true
                } catch {
                    configurationError = String(describing: error)
                }
                index += 1
            case "--config-node-reset-test":
                if !confirmReset {
                    configurationError = "--config-node-reset-test requires --confirm-reset"
                } else {
                    do {
                        let prepared = try reserveNativeConfigNodeResetProxyPdu(
                            statePath: statePath,
                            nodeID: nodeID
                        )
                        proxyPdu = prepared.proxyPdu
                        proxyPduLabel = "config-node-reset"
                        requiredProxyNetworkId = prepared.requiredProxyNetworkId
                        decodeMaterial = prepared.decodeMaterial
                        nativeSendMetadata = prepared.metadata
                        settleAfterWrite = max(settleAfterWrite, 4.0)
                        connect = true
                    } catch {
                        configurationError = String(describing: error)
                    }
                }
                index += 1
            case "--confirm-reset":
                index += 1
            case "--add-to-existing-state":
                index += 1
            case "--settle-after-write":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    settleAfterWrite = max(0.1, value)
                    index += 2
                } else {
                    index += 1
                }
            case "--expect-segment-ack":
                if index + 2 < arguments.count,
                   let seqZero = Int(arguments[index + 1]),
                   let segN = Int(arguments[index + 2]),
                   (0...0x1fff).contains(seqZero),
                   (0...0x1f).contains(segN) {
                    expectedSegmentAckSeqZero = UInt16(seqZero)
                    expectedSegmentAckSegN = UInt8(segN)
                    index += 3
                } else {
                    configurationError = "--expect-segment-ack requires SeqZero 0..8191 and SegN 0..31"
                    index += 1
                }
            default:
                index += 1
            }
        }

        if joinCaptureRequested, configurationError == nil {
            do {
                guard let joinCapturePath, !joinCapturePath.isEmpty else {
                    throw BluetoothProbeError.invalidState("--join-capture requires --capture-state <file>")
                }
                let deviceUUID: [UInt8]
                if let joinCaptureDeviceUUID {
                    deviceUUID = joinCaptureDeviceUUID
                } else {
                    deviceUUID = try NativeMeshProvisioning.generateProvisioningRandom()
                }
                nativeJoinCaptureRun = NativeJoinCaptureRun(
                    captureStatePath: joinCapturePath,
                    localName: joinCaptureName,
                    deviceUUID: deviceUUID,
                    elementCount: 1,
                    deviceKeyPair: try NativeMeshProvisioning.generateProvisionerKeyPair(),
                    deviceRandom: try NativeMeshProvisioning.generateProvisioningRandom()
                )
            } catch {
                configurationError = String(describing: error)
            }
        }
    }

    var hasProxyWrite: Bool {
        proxyPdu != nil || !proxyPdus.isEmpty
    }

    func configuredProxyPdus() -> [[UInt8]] {
        if !proxyPdus.isEmpty {
            return proxyPdus
        }
        if let proxyPdu {
            return [proxyPdu]
        }
        return []
    }
}

final class MeshJoinCapturePeripheral: NSObject, CBPeripheralManagerDelegate {
    private let options: ProbeOptions
    private let run: NativeJoinCaptureRun
    private var manager: CBPeripheralManager?
    private var dataOutCharacteristic: CBMutableCharacteristic?
    private var session: NativeProvisioneeCaptureSession
    private var reassembler = NativeProvisioningProxyPduReassembler()
    private var startedAt = Date()
    private var finished = false
    private var centralState = "unknown"
    private var advertisingStarted = false
    private var serviceDataAdvertisingRequested = false
    private var serviceDataAdvertisingActive = false
    private var subscribedCentralCount = 0
    private var receiveSegmentCount = 0
    private var receivePduCount = 0
    private var sentProxySegmentCount = 0
    private var sentPduCount = 0
    private var stateWritten = false
    private var outgoingQueue: [[UInt8]] = []
    private var completionPending = false
    private var errorMessage: String?
    private var events: [[String: Any]] = []

    init(options: ProbeOptions, run: NativeJoinCaptureRun) throws {
        self.options = options
        self.run = run
        self.session = try NativeProvisioneeCaptureSession(
            deviceKeyPair: run.deviceKeyPair,
            deviceRandom: run.deviceRandom,
            elementCount: run.elementCount
        )
        super.init()
        self.manager = CBPeripheralManager(delegate: self, queue: DispatchQueue.main)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout) { [weak self] in
            self?.handleTimeout()
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        centralState = centralStateName(peripheral.state)
        guard peripheral.state == .poweredOn else {
            if peripheral.state == .unauthorized || peripheral.state == .unsupported || peripheral.state == .poweredOff {
                finish(ok: false, error: "Bluetooth peripheral is \(centralState)")
            }
            return
        }

        startedAt = Date()
        let dataIn = CBMutableCharacteristic(
            type: meshProvisioningDataIn,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let dataOut = CBMutableCharacteristic(
            type: meshProvisioningDataOut,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        dataOutCharacteristic = dataOut
        let service = CBMutableService(type: meshProvisioningService, primary: true)
        service.characteristics = [dataIn, dataOut]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            finish(ok: false, error: "Mesh Provisioning service add failed: \(error.localizedDescription)")
            return
        }
        startAdvertising(includeServiceData: false)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            if serviceDataAdvertisingRequested {
                events.append([
                    "event": "advertising_service_data_rejected",
                    "fallback": "service_uuid_and_name",
                ])
                peripheral.stopAdvertising()
                startAdvertising(includeServiceData: false)
                return
            }
            finish(ok: false, error: "Mesh Provisioning advertising failed: \(error.localizedDescription)")
            return
        }
        advertisingStarted = true
        serviceDataAdvertisingActive = serviceDataAdvertisingRequested
        events.append([
            "event": "advertising_started",
            "service_data": serviceDataAdvertisingActive,
            "name": run.localName,
        ])
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == meshProvisioningDataOut else {
            return
        }
        subscribedCentralCount += 1
        events.append([
            "event": "subscribed",
            "central": central.identifier.uuidString,
        ])
        sendNextQueuedProxySegment()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == meshProvisioningDataOut else {
            return
        }
        subscribedCentralCount = max(0, subscribedCentralCount - 1)
        events.append([
            "event": "unsubscribed",
            "central": central.identifier.uuidString,
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == meshProvisioningDataIn else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            guard request.offset == 0 else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                continue
            }
            guard let value = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            do {
                try handleIncomingProxyPdu(Array(value))
                peripheral.respond(to: request, withResult: .success)
            } catch {
                let message = String(describing: error)
                errorMessage = message
                events.append([
                    "event": "receive_error",
                    "error": message,
                ])
                peripheral.respond(to: request, withResult: .unlikelyError)
                finish(ok: false, error: message)
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        sendNextQueuedProxySegment()
    }

    private func startAdvertising(includeServiceData: Bool) {
        guard let manager else {
            return
        }
        serviceDataAdvertisingRequested = includeServiceData
        var advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [meshProvisioningService],
            CBAdvertisementDataLocalNameKey: run.localName,
        ]
        if includeServiceData {
            advertisement[CBAdvertisementDataServiceDataKey] = [
                meshProvisioningService: Data(run.deviceUUID + [0x00, 0x00]),
            ]
        }
        manager.startAdvertising(advertisement)
    }

    private func handleIncomingProxyPdu(_ proxyPdu: [UInt8]) throws {
        receiveSegmentCount += 1
        let reassembly = try reassembler.receive(proxyPdu)
        events.append([
            "event": "proxy_segment_in",
            "pending": reassembly.pending,
            "segments": reassembly.segmentCount,
            "bytes": proxyPdu.count,
        ])
        guard let provisioningPdu = reassembly.provisioningPdu else {
            return
        }

        receivePduCount += 1
        let result = try session.receive(provisioningPdu)
        events.append([
            "event": "provisioning_pdu_in",
            "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(provisioningPdu[0]),
            "state": result.state.rawValue,
            "outgoing_pdu_count": result.outgoingPdus.count,
            "completed": result.completed,
        ])

        if let failedErrorName = result.failedErrorName {
            throw BluetoothProbeError.invalidState("provisioning failed: \(failedErrorName)")
        }
        if !result.outgoingPdus.isEmpty {
            try enqueueOutgoingProvisioningPdus(result.outgoingPdus)
        }
        if result.completed {
            completionPending = true
            completeIfReady()
        }
    }

    private func enqueueOutgoingProvisioningPdus(_ provisioningPdus: [[UInt8]]) throws {
        for pdu in provisioningPdus {
            sentPduCount += 1
            let segments = try NativeMeshProvisioning.segmentedProxyPdus(
                provisioningPdu: pdu,
                maxSegmentPayloadBytes: 19
            )
            outgoingQueue.append(contentsOf: segments)
            events.append([
                "event": "provisioning_pdu_out",
                "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(pdu[0]),
                "bytes": pdu.count,
                "proxy_segments": segments.count,
            ])
        }
        sendNextQueuedProxySegment()
    }

    private func sendNextQueuedProxySegment() {
        guard !finished,
              subscribedCentralCount > 0,
              let manager,
              let dataOutCharacteristic else {
            return
        }

        while !outgoingQueue.isEmpty {
            let segment = outgoingQueue[0]
            if manager.updateValue(Data(segment), for: dataOutCharacteristic, onSubscribedCentrals: nil) {
                outgoingQueue.removeFirst()
                sentProxySegmentCount += 1
            } else {
                return
            }
        }
        completeIfReady()
    }

    private func completeIfReady() {
        guard completionPending, outgoingQueue.isEmpty, !stateWritten else {
            return
        }
        do {
            try writeCaptureState()
            stateWritten = true
            events.append([
                "event": "capture_state_written",
                "path": run.captureStatePath,
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.finish(ok: true, error: nil)
            }
        } catch {
            let message = String(describing: error)
            errorMessage = message
            finish(ok: false, error: message)
        }
    }

    private func writeCaptureState() throws {
        guard !FileManager.default.fileExists(atPath: run.captureStatePath) else {
            throw BluetoothProbeError.invalidState("capture state file already exists at \(run.captureStatePath)")
        }
        guard let capturedData = session.capturedData, let deviceKey = session.deviceKey else {
            throw BluetoothProbeError.invalidState("provisioning capture is incomplete")
        }
        let now = isoTimestamp()
        let payload: [String: Any] = [
            "schema_version": 1,
            "captured_at": now,
            "source": [
                "type": "sidus_join_capture",
                "phase": "provisioning",
                "app_key_captured": false,
            ],
            "mesh": [
                "net_key": NativeMeshCrypto.hex(capturedData.networkKey),
                "key_index": capturedData.keyIndex,
                "flags": capturedData.flags,
                "iv_index": Int(capturedData.ivIndex),
            ],
            "captured_node": [
                "device_uuid": NativeMeshCrypto.hex(run.deviceUUID),
                "device_key": NativeMeshCrypto.hex(deviceKey),
                "unicast_address": Int(capturedData.unicastAddress),
                "element_count": run.elementCount,
            ],
            "app_key": NSNull(),
            "app_key_captured": false,
            "next_step": "Provisioning capture has NetKey and the fake node DeviceKey. AppKey is still required before runtime fixture control can join this mesh.",
        ]
        try writeSensitiveJSONPayload(payload, to: run.captureStatePath)
    }

    private func handleTimeout() {
        if finished {
            return
        }
        if centralState != "poweredOn" {
            finish(ok: false, error: "Bluetooth peripheral did not become available (state \(centralState))")
            return
        }
        if !advertisingStarted {
            finish(ok: false, error: "join capture did not start advertising")
        } else if receivePduCount == 0 {
            finish(ok: false, error: "join capture timed out waiting for Sidus Link provisioning")
        } else {
            finish(ok: false, error: errorMessage ?? "join capture timed out before provisioning completed")
        }
    }

    private func finish(ok: Bool, error: String?) {
        guard !finished else {
            return
        }
        finished = true
        manager?.stopAdvertising()
        let elapsed = Date().timeIntervalSince(startedAt)
        var capture: [String: Any] = [
            "started": centralState == "poweredOn",
            "advertising_started": advertisingStarted,
            "service_data_advertised": serviceDataAdvertisingActive,
            "subscribed_central_count": subscribedCentralCount,
            "received_proxy_segments": receiveSegmentCount,
            "received_provisioning_pdus": receivePduCount,
            "sent_proxy_segments": sentProxySegmentCount,
            "sent_provisioning_pdus": sentPduCount,
            "completed": session.state == .complete,
            "state_written": stateWritten,
            "capture_state_path": run.captureStatePath,
            "app_key_captured": false,
            "device_uuid_suffix": NativeMeshCrypto.hex(Array(run.deviceUUID.suffix(3))),
            "session_state": session.state.rawValue,
        ]
        if let capturedData = session.capturedData {
            capture["node_address"] = Int(capturedData.unicastAddress)
            capture["key_index"] = capturedData.keyIndex
            capture["flags"] = capturedData.flags
            capture["iv_index"] = Int(capturedData.ivIndex)
        }
        if let error = error ?? errorMessage {
            capture["error"] = error
        }
        if !events.isEmpty {
            capture["events"] = events
        }

        var payload: [String: Any] = [
            "ok": ok,
            "data": [
                "central_state": centralState,
                "elapsed_seconds": Double(round(elapsed * 1000) / 1000),
                "join_capture": capture,
            ],
        ]
        if let error {
            payload["error"] = error
        }
        writePayload(payload)

        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    private func writePayload(_ payload: [String: Any]) {
        do {
            try writeJSONPayload(payload, to: options.outputPath)
        } catch {
            fputs("failed to write join capture output: \(error.localizedDescription)\n", stderr)
        }
    }
}

final class MeshGattProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let options: ProbeOptions
    private var manager: CBCentralManager?
    private var selectedPeripheral: CBPeripheral?
    private var pendingCharacteristicServices = Set<String>()
    private var discoveries: [String: [String: Any]] = [:]
    private var centralState = "unknown"
    private var startedAt = Date()
    private var finished = false
    private var proxyDataInCharacteristic: CBCharacteristic?
    private var proxyDataOutCharacteristic: CBCharacteristic?
    private var proxyWriteStarted = false
    private var proxyWriteCompleted = false
    private var proxyWriteType = "none"
    private var proxyWriteIndex = 0
    private var proxyWritePdus: [[UInt8]] = []
    private var proxyWriteMaxLength = 0
    private var proxyWriteLogicalPduCount = 0
    private var proxyWriteLogicalBytes = 0
    private var proxyWriteSegmentsWrittenTotal = 0
    private var proxyWriteSegmentLengths: [Int] = []
    private var outboundSegmentAckSummaries: [[String: Any]] = []
    private var notificationLengths: [Int] = []
    private var decodedNotifications: [[String: Any]] = []
    private var segmentedAccessReassemblies: [String: IncomingSegmentedAccessAccumulator] = [:]
    private var completedSegmentedAccessKeys = Set<String>()
    private var storedCompositionDataSummary: [String: Any]?
    private var segmentAckComplete = false
    private var segmentAckedSegments: UInt32 = 0
    private var segmentAckNotificationCount = 0
    private var segmentAckLastSeqZero: UInt16?
    private var segmentAckSendAttempts = 0
    private var segmentAckRetryScheduled = false
    private var provisioningNotificationReassembler = NativeProvisioningProxyPduReassembler()
    private var liveProvisioningSession: NativeNoOobProvisioningSession?
    private var liveProvisioningStarted = false
    private var liveProvisioningCompleted = false
    private var liveProvisioningStateWritten = false
    private var liveProvisioningError: String?
    private var liveProvisioningDeviceUUID: [UInt8]?
    private var liveProvisioningEvents: [[String: Any]] = []
    private var liveProvisioningQueue: [[UInt8]] = []
    private var liveProvisioningWriting = false
    private var liveProvisioningPendingWriteResponse = false
    private var liveProvisioningWriteType = "none"
    private var liveProvisioningProxySegmentsWritten = 0
    private var liveProvisioningProxySegmentLengths: [Int] = []

    init(options: ProbeOptions) {
        self.options = options
        super.init()
        self.manager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout + 1.0) { [weak self] in
            self?.handleTimeout()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = centralStateName(central.state)
        guard central.state == .poweredOn else {
            finish(ok: central.state != .unauthorized && central.state != .unsupported, error: nil)
            return
        }

        startedAt = Date()
        central.scanForPeripherals(
            withServices: options.scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout) { [weak self] in
            self?.handleTimeout()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let networkMatches = proxyNetworkMatches(advertisementData: advertisementData)
        record(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI, proxyNetworkMatches: networkMatches)

        guard options.connect, selectedPeripheral == nil else {
            return
        }
        if let connectService = options.connectService, !advertisementIncludesService(advertisementData, uuid: connectService) {
            return
        }
        guard networkMatches else {
            return
        }
        if options.nativeProvisioningRun != nil {
            liveProvisioningDeviceUUID = provisioningDeviceUUID(advertisementData: advertisementData)
        }

        selectedPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        updateDiscovery(peripheral) { entry in
            entry["connected"] = true
        }
        peripheral.discoverServices([meshProxyService, meshProvisioningService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        updateDiscovery(peripheral) { entry in
            entry["connect_error"] = error?.localizedDescription ?? "connect failed"
        }
        finish(ok: true, error: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        updateDiscovery(peripheral) { entry in
            entry["connected"] = false
            if let error {
                entry["disconnect_error"] = error.localizedDescription
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            updateDiscovery(peripheral) { entry in
                entry["service_error"] = error.localizedDescription
            }
            finish(ok: true, error: nil)
            return
        }

        let services = peripheral.services ?? []
        if services.isEmpty {
            finish(ok: true, error: nil)
            return
        }

        pendingCharacteristicServices = Set(services.map { cbuuidString($0.uuid) })
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let serviceID = cbuuidString(service.uuid)
        updateDiscovery(peripheral) { entry in
            var services = entry["services"] as? [[String: Any]] ?? []
            var serviceEntry: [String: Any] = [
                "uuid": serviceID,
                "role": meshRole(serviceUUIDs: [serviceID]),
            ]
            if let error {
                serviceEntry["error"] = error.localizedDescription
            } else {
                serviceEntry["characteristics"] = (service.characteristics ?? []).map { characteristic in
                    if characteristic.uuid == options.writeDataInUUID {
                        proxyDataInCharacteristic = characteristic
                    } else if characteristic.uuid == options.writeDataOutUUID {
                        proxyDataOutCharacteristic = characteristic
                    }
                    return [
                        "uuid": cbuuidString(characteristic.uuid),
                        "properties": characteristicProperties(characteristic.properties),
                        "role": characteristicRole(characteristic.uuid),
                    ]
                }
            }
            services.removeAll { ($0["uuid"] as? String) == serviceID }
            services.append(serviceEntry)
            entry["services"] = services.sorted { lhs, rhs in
                (lhs["uuid"] as? String ?? "") < (rhs["uuid"] as? String ?? "")
            }
        }

        pendingCharacteristicServices.remove(serviceID)
        if pendingCharacteristicServices.isEmpty {
            if options.nativeProvisioningRun != nil {
                startLiveProvisioningIfReady(peripheral)
            } else if options.hasProxyWrite {
                startProxyWriteIfReady(peripheral)
            } else {
                finish(ok: true, error: nil)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == options.writeDataOutUUID else {
            return
        }
        if let error {
            finish(ok: false, error: "\(writeDataOutLabel()) notification subscribe failed: \(error.localizedDescription)")
            return
        }
        if options.nativeProvisioningRun != nil {
            startLiveProvisioning(peripheral)
        } else {
            writeProxyPdus(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == options.writeDataInUUID else {
            return
        }
        if options.nativeProvisioningRun != nil {
            handleLiveProvisioningWriteResponse(peripheral, error: error)
            return
        }
        if let error {
            finish(ok: false, error: "\(writeDataInLabel()) write failed: \(error.localizedDescription)")
            return
        }
        proxyWriteIndex += 1
        proxyWriteSegmentsWrittenTotal += 1
        if proxyWriteIndex >= proxyWritePdus.count {
            completeProxyWriteOrWaitForAck()
        } else {
            writeNextProxyPdu(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == options.writeDataOutUUID else {
            return
        }
        if error == nil, let value = characteristic.value {
            notificationLengths.append(value.count)
            let proxyPdu = Array(value)
            let decoded = options.nativeProvisioningRun != nil
                ? handleLiveProvisioningNotification(proxyPdu, peripheral: peripheral)
                : decodeProxyNotification(proxyPdu, peripheral: peripheral)
            decodedNotifications.append(decoded)
            handleSegmentAcknowledgment(decoded)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if options.nativeProvisioningRun != nil && liveProvisioningWriting {
            writeNextLiveProvisioningProxyPdu(peripheral)
            return
        }
        if options.hasProxyWrite && proxyWriteStarted && !proxyWriteCompleted {
            writeNextProxyPdu(peripheral)
        }
    }

    private func characteristicRole(_ uuid: CBUUID) -> String {
        switch cbuuidString(uuid) {
        case cbuuidString(meshProxyDataIn): return "proxyDataIn"
        case cbuuidString(meshProxyDataOut): return "proxyDataOut"
        case cbuuidString(meshProvisioningDataIn): return "provisioningDataIn"
        case cbuuidString(meshProvisioningDataOut): return "provisioningDataOut"
        default: return "unknown"
        }
    }

    private func proxyNetworkMatches(advertisementData: [String: Any]) -> Bool {
        guard let requiredNetworkId = options.requiredProxyNetworkId else {
            return true
        }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        guard let proxyData = serviceData[meshProxyService] else {
            return false
        }
        let bytes = Array(proxyData)
        return bytes.count == 9 && bytes[0] == 0x00 && Array(bytes[1...]) == requiredNetworkId
    }

    private func advertisementIncludesService(_ advertisementData: [String: Any], uuid: CBUUID) -> Bool {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertisedServices.contains(uuid) {
            return true
        }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return serviceData[uuid] != nil
    }

    private func provisioningDeviceUUID(advertisementData: [String: Any]) -> [UInt8]? {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        guard let provisioningData = serviceData[meshProvisioningService] else {
            return nil
        }
        let bytes = Array(provisioningData)
        guard bytes.count >= 18 else {
            return nil
        }
        return Array(bytes[0..<16])
    }

    private func record(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber,
        proxyNetworkMatches: Bool
    ) {
        updateDiscovery(peripheral) { entry in
            let advertisedServices = Set(
                (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(cbuuidString)
                    + (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]).keys.map(cbuuidString)
            ).sorted()
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
            let serviceDataLengths = serviceData.reduce(into: [String: Int]()) { result, item in
                result[cbuuidString(item.key)] = item.value.count
            }

            entry["id"] = peripheral.identifier.uuidString
            entry["name"] = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? NSNull()
            entry["rssi"] = rssi.intValue
            entry["advertised_services"] = advertisedServices
            entry["mesh_roles"] = meshRole(serviceUUIDs: advertisedServices)
            entry["connectable"] = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? NSNull()
            entry["manufacturer_data_length"] = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.count ?? 0
            entry["service_data_lengths"] = serviceDataLengths
            if let provisioningData = serviceData[meshProvisioningService] {
                entry["provisioning"] = NativeMeshProvisioning.provisioningServiceDataSummary(Array(provisioningData))
            }
            if options.requiredProxyNetworkId != nil {
                entry["proxy_network_match"] = proxyNetworkMatches
            }
        }
    }

    private func startProxyWriteIfReady(_ peripheral: CBPeripheral) {
        guard !proxyWriteStarted else {
            return
        }
        guard proxyDataInCharacteristic != nil else {
            finish(ok: false, error: "\(writeDataInLabel()) characteristic \(cbuuidString(options.writeDataInUUID)) not found")
            return
        }
        guard let out = proxyDataOutCharacteristic else {
            writeProxyPdus(peripheral)
            return
        }

        if out.properties.contains(.notify) || out.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: out)
        } else {
            writeProxyPdus(peripheral)
        }
    }

    private func startLiveProvisioningIfReady(_ peripheral: CBPeripheral) {
        guard !liveProvisioningStarted else {
            return
        }
        guard proxyDataInCharacteristic != nil else {
            finish(ok: false, error: "\(writeDataInLabel()) characteristic \(cbuuidString(options.writeDataInUUID)) not found")
            return
        }
        guard let out = proxyDataOutCharacteristic else {
            finish(ok: false, error: "\(writeDataOutLabel()) characteristic \(cbuuidString(options.writeDataOutUUID)) not found")
            return
        }

        if out.properties.contains(.notify) || out.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: out)
        } else {
            finish(ok: false, error: "\(writeDataOutLabel()) characteristic \(cbuuidString(options.writeDataOutUUID)) is not notifiable")
        }
    }

    private func startLiveProvisioning(_ peripheral: CBPeripheral) {
        guard !liveProvisioningStarted else {
            return
        }
        guard let run = options.nativeProvisioningRun else {
            finish(ok: false, error: "provisioning run is not configured")
            return
        }
        guard let deviceUUID = liveProvisioningDeviceUUID else {
            finish(ok: false, error: "unprovisioned advertisement did not include a device UUID")
            return
        }

        do {
            var session = try NativeNoOobProvisioningSession(
                provisionerKeyPair: run.provisionerKeyPair,
                provisionerRandom: run.provisionerRandom,
                networkKey: run.netKey,
                keyIndex: run.keyIndex,
                flags: run.flags,
                ivIndex: run.ivIndex,
                unicastAddress: run.unicastAddress
            )
            let invite = try session.start(attentionDuration: run.attentionDuration)
            liveProvisioningSession = session
            liveProvisioningStarted = true
            liveProvisioningEvents.append([
                "direction": "out",
                "pdu_type": "provisioning_invite",
                "state": session.state.rawValue,
                "device_uuid_suffix": NativeMeshCrypto.hex(Array(deviceUUID.suffix(3))),
            ])
            try enqueueLiveProvisioningPdus([invite], peripheral: peripheral)
        } catch {
            let message = String(describing: error)
            liveProvisioningError = message
            finish(ok: false, error: message)
        }
    }

    private func enqueueLiveProvisioningPdus(_ provisioningPdus: [[UInt8]], peripheral: CBPeripheral) throws {
        for pdu in provisioningPdus {
            let proxyPdus = try NativeMeshProvisioning.segmentedProxyPdus(
                provisioningPdu: pdu,
                maxSegmentPayloadBytes: 20
            )
            liveProvisioningQueue.append(contentsOf: proxyPdus)
            liveProvisioningEvents.append([
                "direction": "out",
                "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(pdu[0]),
                "bytes": pdu.count,
                "proxy_segments": proxyPdus.count,
            ])
        }
        writeNextLiveProvisioningProxyPdu(peripheral)
    }

    private func writeNextLiveProvisioningProxyPdu(_ peripheral: CBPeripheral) {
        guard options.nativeProvisioningRun != nil, !liveProvisioningCompleted else {
            return
        }
        guard !liveProvisioningPendingWriteResponse else {
            return
        }
        guard !liveProvisioningQueue.isEmpty else {
            liveProvisioningWriting = false
            return
        }
        guard let input = proxyDataInCharacteristic else {
            finish(ok: false, error: "\(writeDataInLabel()) characteristic \(cbuuidString(options.writeDataInUUID)) not found")
            return
        }

        liveProvisioningWriting = true
        let data = Data(liveProvisioningQueue[0])
        if input.properties.contains(.writeWithoutResponse) {
            liveProvisioningWriteType = "withoutResponse"
            peripheral.writeValue(data, for: input, type: .withoutResponse)
            liveProvisioningQueue.removeFirst()
            liveProvisioningProxySegmentsWritten += 1
            liveProvisioningProxySegmentLengths.append(data.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak peripheral] in
                guard let self, let peripheral else {
                    return
                }
                self.writeNextLiveProvisioningProxyPdu(peripheral)
            }
        } else if input.properties.contains(.write) {
            liveProvisioningWriteType = "withResponse"
            liveProvisioningPendingWriteResponse = true
            peripheral.writeValue(data, for: input, type: .withResponse)
        } else {
            finish(ok: false, error: "\(writeDataInLabel()) characteristic \(cbuuidString(options.writeDataInUUID)) is not writable")
        }
    }

    private func handleLiveProvisioningWriteResponse(_ peripheral: CBPeripheral, error: Error?) {
        if let error {
            let message = "\(writeDataInLabel()) write failed: \(error.localizedDescription)"
            liveProvisioningError = message
            finish(ok: false, error: message)
            return
        }
        guard liveProvisioningPendingWriteResponse else {
            return
        }
        liveProvisioningPendingWriteResponse = false
        if !liveProvisioningQueue.isEmpty {
            let count = liveProvisioningQueue.removeFirst().count
            liveProvisioningProxySegmentsWritten += 1
            liveProvisioningProxySegmentLengths.append(count)
        }
        writeNextLiveProvisioningProxyPdu(peripheral)
    }

    private func writeProxyPdus(_ peripheral: CBPeripheral) {
        guard !proxyWriteStarted else {
            return
        }
        guard !options.configuredProxyPdus().isEmpty else {
            finish(ok: false, error: "no proxy PDU configured")
            return
        }
        guard let input = proxyDataInCharacteristic else {
            finish(ok: false, error: "\(writeDataInLabel()) characteristic \(cbuuidString(options.writeDataInUUID)) not found")
            return
        }

        proxyWriteStarted = true
        proxyWriteIndex = 0
        proxyWriteSegmentsWrittenTotal = 0
        proxyWriteLogicalPduCount = options.configuredProxyPdus().count
        proxyWriteLogicalBytes = options.configuredProxyPdus().reduce(0) { $0 + $1.count }
        if options.expectedSegmentAckSeqZero != nil {
            segmentAckSendAttempts = 1
        }
        do {
            let writeType: CBCharacteristicWriteType = input.properties.contains(.writeWithoutResponse)
                ? .withoutResponse
                : .withResponse
            proxyWriteMaxLength = peripheral.maximumWriteValueLength(for: writeType)
            proxyWritePdus = try options.configuredProxyPdus().flatMap {
                try segmentProxyProtocolPdu($0, maxWriteLength: proxyWriteMaxLength)
            }
            proxyWriteSegmentLengths = proxyWritePdus.map(\.count)
            writeNextProxyPdu(peripheral, input: input)
        } catch {
            finish(ok: false, error: String(describing: error))
        }
    }

    private func writeNextProxyPdu(_ peripheral: CBPeripheral, input: CBCharacteristic? = nil) {
        guard !proxyWriteCompleted else {
            return
        }
        let pdus = proxyWritePdus
        guard proxyWriteIndex < pdus.count else {
            completeProxyWriteOrWaitForAck()
            return
        }
        guard let input = input ?? proxyDataInCharacteristic else {
            finish(ok: false, error: "\(writeDataInLabel()) characteristic \(cbuuidString(options.writeDataInUUID)) not found")
            return
        }

        let data = Data(pdus[proxyWriteIndex])
        if input.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else {
                return
            }
            proxyWriteType = "withoutResponse"
            peripheral.writeValue(data, for: input, type: .withoutResponse)
            proxyWriteIndex += 1
            proxyWriteSegmentsWrittenTotal += 1
            if proxyWriteIndex >= pdus.count {
                completeProxyWriteOrWaitForAck()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + options.proxyWriteInterSegmentDelay) { [weak self, weak peripheral] in
                    guard let self, let peripheral else {
                        return
                    }
                    self.writeNextProxyPdu(peripheral)
                }
            }
        } else if input.properties.contains(.write) {
            proxyWriteType = "withResponse"
            peripheral.writeValue(data, for: input, type: .withResponse)
        } else {
            finish(ok: false, error: "\(writeDataInLabel()) characteristic \(cbuuidString(options.writeDataInUUID)) is not writable")
        }
    }

    private func handleLiveProvisioningNotification(_ proxyPdu: [UInt8], peripheral: CBPeripheral) -> [String: Any] {
        guard !proxyPdu.isEmpty else {
            return ["length": 0, "decode_error": "empty Proxy PDU"]
        }

        let sar = (proxyPdu[0] & 0xc0) >> 6
        let messageType = proxyPdu[0] & 0x3f
        var decoded: [String: Any] = [
            "length": proxyPdu.count,
            "sar": sar,
            "type": proxyPduTypeName(messageType),
        ]
        guard messageType == NativeMeshProvisioning.proxyPduType else {
            decoded["decode_error"] = "provisioning expected a provisioning Proxy PDU"
            return decoded
        }

        do {
            let reassembly = try provisioningNotificationReassembler.receive(proxyPdu)
            var reassemblySummary: [String: Any] = [
                "pending": reassembly.pending,
                "payload_bytes": max(0, proxyPdu.count - 1),
                "segment_count": reassembly.segmentCount,
            ]
            if let provisioningPdu = reassembly.provisioningPdu {
                reassemblySummary["completed"] = true
                reassemblySummary["bytes"] = provisioningPdu.count
                decoded["provisioning"] = NativeMeshProvisioning.provisioningPduSummary(provisioningPdu)
                liveProvisioningEvents.append([
                    "direction": "in",
                    "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(provisioningPdu[0]),
                    "bytes": provisioningPdu.count,
                ])
                try advanceLiveProvisioningSession(with: provisioningPdu, peripheral: peripheral, decoded: &decoded)
            } else {
                reassemblySummary["completed"] = false
            }
            decoded["provisioning_reassembly"] = reassemblySummary
        } catch {
            let message = String(describing: error)
            liveProvisioningError = message
            decoded["decode_error"] = message
            finish(ok: false, error: message)
        }
        return decoded
    }

    private func advanceLiveProvisioningSession(
        with provisioningPdu: [UInt8],
        peripheral: CBPeripheral,
        decoded: inout [String: Any]
    ) throws {
        guard var session = liveProvisioningSession else {
            throw BluetoothProbeError.invalidState("provisioning session is not started")
        }

        let result = try session.receive(provisioningPdu)
        liveProvisioningSession = session
        decoded["provisioning_session"] = [
            "state": result.state.rawValue,
            "outgoing_pdu_count": result.outgoingPdus.count,
            "completed": result.completed,
            "failed_error": result.failedErrorName ?? NSNull(),
        ]
        liveProvisioningEvents.append([
            "direction": "state",
            "state": result.state.rawValue,
            "outgoing_pdu_count": result.outgoingPdus.count,
            "completed": result.completed,
        ])

        if let failedErrorName = result.failedErrorName {
            liveProvisioningError = failedErrorName
            finish(ok: false, error: "provisioning failed: \(failedErrorName)")
            return
        }

        if !result.outgoingPdus.isEmpty {
            try enqueueLiveProvisioningPdus(result.outgoingPdus, peripheral: peripheral)
        }

        if result.completed {
            try writeLiveProvisioningState()
            liveProvisioningCompleted = true
            decoded["state_written"] = liveProvisioningStateWritten
            finish(ok: true, error: nil)
        }
    }

    private func writeLiveProvisioningState() throws {
        guard let run = options.nativeProvisioningRun else {
            throw BluetoothProbeError.invalidState("provisioning run is not configured")
        }
        guard let deviceUUID = liveProvisioningDeviceUUID else {
            throw BluetoothProbeError.invalidState("provisioning device UUID is missing")
        }
        guard let transcript = liveProvisioningSession?.transcript else {
            throw BluetoothProbeError.invalidState("provisioning transcript is missing")
        }
        guard run.appendsToExistingState || !FileManager.default.fileExists(atPath: run.statePath) else {
            throw BluetoothProbeError.invalidState("state file already exists; use add mode or set AMARAN_CLI_STATE_PATH before provisioning")
        }

        let now = isoTimestamp()
        let elementCount = transcript.capabilitiesPdu.count > 1 ? max(1, Int(transcript.capabilitiesPdu[1])) : 1
        let fixture = NativeProvisionedFixtureState(
            uuid: NativeMeshCrypto.hex(deviceUUID),
            macAddress: nil,
            code: nil,
            name: nil,
            nodeAddress: run.unicastAddress,
            deviceKey: transcript.secrets.deviceKey,
            deviceUUID: deviceUUID,
            compositionData: nil,
            elementCount: elementCount,
            updateTime: now
        )
        let payload: [String: Any]
        if run.appendsToExistingState {
            let data = try Data(contentsOf: URL(fileURLWithPath: run.statePath))
            guard let existingPayload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BluetoothProbeError.invalidState("state file must contain a JSON object")
            }
            payload = try NativeMeshState.appendingProvisionedFixturePayload(
                existingPayload: existingPayload,
                fixture: fixture,
                provisionedAt: now
            )
        } else {
            payload = try NativeMeshState.provisionedPayload(
                meshUUID: run.meshUUID,
                netKey: run.netKey,
                appKey: run.appKey,
                fixture: fixture,
                provisionedAt: now,
                ivIndex: run.ivIndex,
                sequenceNext: 1,
                sourceAddress: run.sourceAddress
            )
        }
        try NativeMeshState.writePayload(payload, to: run.statePath)
        liveProvisioningStateWritten = true
        liveProvisioningEvents.append([
            "direction": "state",
            "state": run.appendsToExistingState ? "appended" : "written",
            "node_address": Int(run.unicastAddress),
            "element_count": elementCount,
        ])
    }

    private func decodeProxyNotification(_ proxyPdu: [UInt8], peripheral: CBPeripheral?) -> [String: Any] {
        guard !proxyPdu.isEmpty else {
            return ["length": 0, "decode_error": "empty Proxy PDU"]
        }

        let sar = (proxyPdu[0] & 0xc0) >> 6
        let messageType = proxyPdu[0] & 0x3f
        var result: [String: Any] = [
            "length": proxyPdu.count,
            "sar": sar,
            "type": proxyPduTypeName(messageType),
        ]
        guard messageType == 0x00 else {
            if messageType == 0x01 {
                result["beacon"] = meshBeaconSummary(Array(proxyPdu.dropFirst()))
            } else if messageType == 0x03 {
                result.merge(provisioningProxyNotificationSummary(proxyPdu)) { _, new in new }
            }
            return result
        }
        guard let material = options.decodeMaterial else {
            result["decode_error"] = "no local decode material"
            return result
        }

        do {
            let decodedNetwork = try NativeMeshCrypto.decodeNetworkPdu(
                networkPdu: Array(proxyPdu.dropFirst()),
                ivIndex: material.ivIndex,
                nid: material.networkKeys.nid,
                encryptionKey: material.networkKeys.encryptionKey,
                privacyKey: material.networkKeys.privacyKey
            )
            result["network"] = [
                "ctl": decodedNetwork.ctl,
                "ttl": decodedNetwork.ttl,
                "sequence": decodedNetwork.sequence,
                "source": decodedNetwork.source,
                "destination": decodedNetwork.destination,
                "transport_bytes": decodedNetwork.transportPdu.count,
            ]

            if decodedNetwork.ctl == 0 {
                if let first = decodedNetwork.transportPdu.first, (first & 0x80) != 0 {
                    let lower = try NativeMeshCrypto.decodeLowerTransportSegmentedAccessPdu(
                        lowerTransportPdu: decodedNetwork.transportPdu
                    )
                    result["lower_transport"] = [
                        "segmented": true,
                        "akf": lower.akf,
                        "aid": lower.aid,
                        "szmic": lower.szmic,
                        "seq_zero": Int(lower.seqZero),
                        "seg_o": Int(lower.segO),
                        "seg_n": Int(lower.segN),
                        "segment_bytes": lower.segment.count,
                    ]
                    let accessKey = segmentedAccessKey(lower, decodedNetwork: decodedNetwork)
                    if completedSegmentedAccessKeys.contains(accessKey) {
                        result["segmented_access"] = [
                            "pending": false,
                            "completed": true,
                            "duplicate": true,
                            "seq_zero": Int(lower.seqZero),
                            "seg_o": Int(lower.segO),
                            "seg_n": Int(lower.segN),
                        ]
                        result["outbound_segment_ack"] = sendSegmentAcknowledgment(
                            lower: lower,
                            decodedNetwork: decodedNetwork,
                            material: material,
                            peripheral: peripheral,
                            duplicate: true
                        )
                    } else if let completed = try receiveSegmentedAccess(
                        lower,
                        decodedNetwork: decodedNetwork
                    ) {
                        result["segmented_access"] = completed.summary
                        result["outbound_segment_ack"] = sendSegmentAcknowledgment(
                            lower: lower,
                            decodedNetwork: decodedNetwork,
                            material: material,
                            peripheral: peripheral,
                            duplicate: false
                        )
                        if let access = try decodedAccessSummary(
                            akf: completed.reassembled.akf,
                            aid: completed.reassembled.aid,
                            szmic: completed.reassembled.szmic,
                            sequence: completed.sequence,
                            source: decodedNetwork.source,
                            destination: decodedNetwork.destination,
                            upperTransportPdu: completed.reassembled.upperTransportPdu,
                            material: material
                        ) {
                            result["access"] = access
                        }
                    } else {
                        result["segmented_access"] = segmentedAccessPendingSummary(lower)
                    }
                } else {
                    let lower = try NativeMeshCrypto.decodeLowerTransportUnsegmentedAccessPdu(
                        lowerTransportPdu: decodedNetwork.transportPdu
                    )
                    result["lower_transport"] = [
                        "segmented": false,
                        "akf": lower.akf,
                        "aid": lower.aid,
                        "upper_transport_bytes": lower.upperTransportPdu.count,
                    ]
                    if let access = try decodedAccessSummary(
                        akf: lower.akf,
                        aid: lower.aid,
                        szmic: false,
                        sequence: decodedNetwork.sequence,
                        source: decodedNetwork.source,
                        destination: decodedNetwork.destination,
                        upperTransportPdu: lower.upperTransportPdu,
                        material: material
                    ) {
                        result["access"] = access
                    }
                }
            } else {
                result["control"] = controlMessageSummary(decodedNetwork.transportPdu)
            }
        } catch {
            result["decode_error"] = String(describing: error)
        }
        return result
    }

    private struct CompletedSegmentedAccess {
        let reassembled: LowerTransportSegmentedAccessReassembled
        let sequence: UInt32
        let summary: [String: Any]
    }

    private func receiveSegmentedAccess(
        _ lower: LowerTransportSegmentedAccessDecoded,
        decodedNetwork: NetworkPduDecoded
    ) throws -> CompletedSegmentedAccess? {
        let key = segmentedAccessKey(lower, decodedNetwork: decodedNetwork)
        if var pending = segmentedAccessReassemblies[key] {
            try pending.add(
                decoded: lower,
                sequence: decodedNetwork.sequence,
                lowerTransportPdu: decodedNetwork.transportPdu
            )
            segmentedAccessReassemblies[key] = pending
        } else {
            segmentedAccessReassemblies[key] = IncomingSegmentedAccessAccumulator(
                decoded: lower,
                sequence: decodedNetwork.sequence,
                lowerTransportPdu: decodedNetwork.transportPdu
            )
        }

        guard let pending = segmentedAccessReassemblies[key] else {
            return nil
        }
        guard pending.isComplete else {
            return nil
        }
        guard let sequence = pending.segmentZeroSequence else {
            throw BluetoothProbeError.invalidState("segmented access reassembly is missing segment zero")
        }
        let reassembled = try NativeMeshCrypto.reassembleLowerTransportSegmentedAccessPdus(
            lowerTransportPdus: pending.orderedLowerTransportPdus
        )
        segmentedAccessReassemblies.removeValue(forKey: key)
        completedSegmentedAccessKeys.insert(key)
        return CompletedSegmentedAccess(
            reassembled: reassembled,
            sequence: sequence,
            summary: [
                "pending": false,
                "completed": true,
                "seq_zero": Int(reassembled.seqZero),
                "segment_count": Int(pending.segN) + 1,
                "upper_transport_bytes": reassembled.upperTransportPdu.count,
            ]
        )
    }

    private func segmentedAccessPendingSummary(_ lower: LowerTransportSegmentedAccessDecoded) -> [String: Any] {
        [
            "pending": true,
            "completed": false,
            "seq_zero": Int(lower.seqZero),
            "seg_o": Int(lower.segO),
            "seg_n": Int(lower.segN),
        ]
    }

    private func segmentedAccessKey(
        _ lower: LowerTransportSegmentedAccessDecoded,
        decodedNetwork: NetworkPduDecoded
    ) -> String {
        [
            String(decodedNetwork.source),
            String(decodedNetwork.destination),
            String(lower.akf ? 1 : 0),
            String(lower.aid),
            String(lower.szmic ? 1 : 0),
            String(lower.seqZero),
            String(lower.segN),
        ].joined(separator: ":")
    }

    private func sendSegmentAcknowledgment(
        lower: LowerTransportSegmentedAccessDecoded,
        decodedNetwork: NetworkPduDecoded,
        material: NativeDecodeMaterial,
        peripheral: CBPeripheral?,
        duplicate: Bool
    ) -> [String: Any] {
        let ackedSegments = lower.segN == 31 ? UInt32.max : (UInt32(1) << UInt32(lower.segN + 1)) - 1
        var summary: [String: Any] = [
            "seq_zero": Int(lower.seqZero),
            "seg_n": Int(lower.segN),
            "acked_segments": Int(ackedSegments),
            "acked_segments_hex": String(format: "%08x", ackedSegments),
            "source": Int(decodedNetwork.destination),
            "destination": Int(decodedNetwork.source),
            "duplicate": duplicate,
        ]

        guard let peripheral, let input = proxyDataInCharacteristic else {
            summary["written"] = false
            summary["write_error"] = "proxy Data In characteristic not ready"
            outboundSegmentAckSummaries.append(summary)
            return summary
        }
        guard input.properties.contains(.writeWithoutResponse) else {
            summary["written"] = false
            summary["write_error"] = "proxy Data In characteristic does not support writeWithoutResponse"
            outboundSegmentAckSummaries.append(summary)
            return summary
        }
        guard peripheral.canSendWriteWithoutResponse else {
            summary["written"] = false
            summary["write_error"] = "peripheral is not ready for writeWithoutResponse"
            outboundSegmentAckSummaries.append(summary)
            return summary
        }

        do {
            let reserved = try reserveNativeRuntimeSequence(
                statePath: options.statePath,
                lastReservedBy: "segment-ack"
            )
            let transportPdu = try NativeMeshCrypto.lowerTransportSegmentAcknowledgmentPdu(
                seqZero: lower.seqZero,
                ackedSegments: ackedSegments
            )
            let network = try NativeMeshCrypto.networkPdu(
                ivIndex: material.ivIndex,
                nid: material.networkKeys.nid,
                encryptionKey: material.networkKeys.encryptionKey,
                privacyKey: material.networkKeys.privacyKey,
                ctl: 1,
                ttl: 0,
                sequence: UInt32(reserved.sequence),
                source: decodedNetwork.destination,
                destination: decodedNetwork.source,
                transportPdu: transportPdu
            )
            summary["sequence"] = reserved.sequence
            summary["sequence_next"] = reserved.sequenceNext
            summary["ttl"] = 0
            summary["bytes"] = network.proxyPdu.count

            peripheral.writeValue(Data(network.proxyPdu), for: input, type: .withoutResponse)
            summary["written"] = true
            summary["write_type"] = "withoutResponse"
            outboundSegmentAckSummaries.append(summary)
            return summary
        } catch {
            summary["written"] = false
            summary["write_error"] = String(describing: error)
            outboundSegmentAckSummaries.append(summary)
            return summary
        }
    }

    private func decodedAccessSummary(
        akf: Bool,
        aid: UInt8,
        szmic: Bool,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        upperTransportPdu: [UInt8],
        material: NativeDecodeMaterial
    ) throws -> [String: Any]? {
        if akf && aid == material.appAid {
            let upper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
                applicationKey: material.appKey,
                sequence: sequence,
                source: source,
                destination: destination,
                ivIndex: material.ivIndex,
                upperTransportPdu: upperTransportPdu,
                transMicLength: szmic ? 8 : 4
            )
            return accessMessageSummaryWithState(upper.accessMessage)
        }
        if !akf, let deviceKey = material.deviceKey {
            let upper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
                deviceKey: deviceKey,
                sequence: sequence,
                source: source,
                destination: destination,
                ivIndex: material.ivIndex,
                upperTransportPdu: upperTransportPdu,
                transMicLength: szmic ? 8 : 4
            )
            var access = accessMessageSummaryWithState(upper.accessMessage)
            access["key"] = "device"
            return access
        }
        return nil
    }

    private func accessMessageSummaryWithState(_ accessMessage: [UInt8]) -> [String: Any] {
        var access = accessMessageSummary(accessMessage)
        if options.storeConfigCompositionData {
            storeCompositionDataIfPresent(accessMessage, accessSummary: &access)
        }
        return access
    }

    private func storeCompositionDataIfPresent(_ accessMessage: [UInt8], accessSummary: inout [String: Any]) {
        guard Array(accessMessage.prefix(1)) == NativeMeshConfig.configCompositionDataStatusOpcode else {
            return
        }
        do {
            let composition = try NativeMeshConfig.configCompositionDataStatus(accessMessage)
            let compositionPayload = Array(accessMessage.dropFirst())
            let data = try Data(contentsOf: URL(fileURLWithPath: options.statePath))
            guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BluetoothProbeError.invalidState("state file must contain a JSON object")
            }
            guard var fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
                throw BluetoothProbeError.invalidState("state file is missing fixtures")
            }
            let targetAddress = options.nativeSendMetadata?["address"].flatMap(jsonInt)
            let fixtureIndex: Int
            if let targetAddress,
               let matched = fixtures.firstIndex(where: { jsonInt($0["node_address"]) == targetAddress }) {
                fixtureIndex = matched
            } else if fixtures.count == 1 {
                fixtureIndex = 0
            } else {
                throw BluetoothProbeError.invalidState("multiple fixtures found; cannot store composition data")
            }

            let now = isoTimestamp()
            fixtures[fixtureIndex]["composition_data"] = NativeMeshCrypto.hex(compositionPayload)
            fixtures[fixtureIndex]["update_time"] = now
            payload["fixtures"] = fixtures

            var runtime = payload["runtime"] as? [String: Any] ?? [:]
            runtime["updated_at"] = now
            payload["runtime"] = runtime

            let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: URL(fileURLWithPath: options.statePath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: options.statePath)

            var summary = compositionDataSummary(composition)
            summary["stored"] = true
            summary["state_path"] = options.statePath
            storedCompositionDataSummary = summary
            accessSummary["state_update"] = summary
        } catch {
            accessSummary["state_update"] = [
                "stored": false,
                "error": String(describing: error),
            ]
        }
    }

    private func provisioningProxyNotificationSummary(_ proxyPdu: [UInt8]) -> [String: Any] {
        do {
            let reassembly = try provisioningNotificationReassembler.receive(proxyPdu)
            var summary: [String: Any] = [
                "pending": reassembly.pending,
                "payload_bytes": max(0, proxyPdu.count - 1),
                "segment_count": reassembly.segmentCount,
            ]
            if let provisioningPdu = reassembly.provisioningPdu {
                summary["completed"] = true
                summary["bytes"] = provisioningPdu.count
                return [
                    "provisioning": NativeMeshProvisioning.provisioningPduSummary(provisioningPdu),
                    "provisioning_reassembly": summary,
                ]
            }
            summary["completed"] = false
            return [
                "provisioning_reassembly": summary,
            ]
        } catch {
            return [
                "decode_error": String(describing: error),
            ]
        }
    }

    private func proxyPduTypeName(_ value: UInt8) -> String {
        switch value {
        case 0x00: return "network"
        case 0x01: return "meshBeacon"
        case 0x02: return "proxyConfiguration"
        case 0x03: return "provisioning"
        default: return "unknown"
        }
    }

    private func meshBeaconSummary(_ beacon: [UInt8]) -> [String: Any] {
        guard beacon.count == 22, beacon[0] == 0x01 else {
            return ["bytes": beacon.count]
        }
        var result: [String: Any] = [
            "type": "secureNetwork",
            "flags": beacon[1],
            "key_refresh": (beacon[1] & 0x01) != 0,
            "iv_update": (beacon[1] & 0x02) != 0,
            "iv_index": UInt32(beacon[10]) << 24 | UInt32(beacon[11]) << 16 | UInt32(beacon[12]) << 8 | UInt32(beacon[13]),
            "auth_value_bytes": 8,
        ]
        if let requiredNetworkId = options.requiredProxyNetworkId {
            result["network_id_match"] = Array(beacon[2..<10]) == requiredNetworkId
        }
        return result
    }

    private func controlMessageSummary(_ transportPdu: [UInt8]) -> [String: Any] {
        guard let first = transportPdu.first else {
            return ["decode_error": "empty lower transport control PDU"]
        }

        var result: [String: Any] = [
            "bytes": transportPdu.count,
            "segmented": (first & 0x80) != 0,
        ]
        if (first & 0x80) == 0 {
            result["opcode"] = first & 0x7f
            if first == 0x00 {
                do {
                    let ack = try NativeMeshCrypto.decodeLowerTransportSegmentAcknowledgment(
                        lowerTransportPdu: transportPdu
                    )
                    result["opcode_name"] = "segment_acknowledgment"
                    result["obo"] = ack.obo
                    result["seq_zero"] = ack.seqZero
                    result["acked_segments"] = ack.ackedSegments
                    result["acked_segments_hex"] = String(format: "%08x", ack.ackedSegments)
                } catch {
                    result["decode_error"] = String(describing: error)
                }
            }
        } else {
            result["opcode"] = first & 0x7f
        }
        return result
    }

    private func handleSegmentAcknowledgment(_ decodedNotification: [String: Any]) {
        guard let expectedSeqZero = options.expectedSegmentAckSeqZero,
              let expectedSegN = options.expectedSegmentAckSegN,
              let control = decodedNotification["control"] as? [String: Any],
              (control["opcode_name"] as? String) == "segment_acknowledgment" else {
            return
        }
        let seqZero: UInt16?
        if let value = control["seq_zero"] as? UInt16 {
            seqZero = value
        } else if let value = jsonInt(control["seq_zero"]) {
            seqZero = UInt16(exactly: value)
        } else {
            seqZero = nil
        }
        guard let seqZero, seqZero == expectedSeqZero else {
            return
        }

        let ackedSegments: UInt32
        if let number = control["acked_segments"] as? NSNumber {
            ackedSegments = number.uint32Value
        } else if let value = control["acked_segments"] as? UInt32 {
            ackedSegments = value
        } else if let value = control["acked_segments"] as? Int {
            ackedSegments = UInt32(value)
        } else {
            return
        }

        segmentAckNotificationCount += 1
        segmentAckLastSeqZero = seqZero
        segmentAckedSegments |= ackedSegments
        let expectedMask = expectedSegN == 31 ? UInt32.max : (UInt32(1) << UInt32(expectedSegN + 1)) - 1
        if (segmentAckedSegments & expectedMask) == expectedMask {
            segmentAckComplete = true
            proxyWriteCompleted = true
            finishAfterProxySettle()
        }
    }

    private func accessMessageSummary(_ accessMessage: [UInt8]) -> [String: Any] {
        guard let opcodeLength = accessOpcodeLength(accessMessage) else {
            return ["decode_error": "invalid access opcode", "bytes": accessMessage.count]
        }
        let opcode = Array(accessMessage.prefix(opcodeLength))
        var result: [String: Any] = [
            "opcode": NativeMeshCrypto.hex(opcode),
            "opcode_type": opcodeLength == 3 ? "vendor" : "sig",
            "parameters_bytes": max(0, accessMessage.count - opcodeLength),
        ]
        if let config = configMessageSummary(accessMessage) {
            result["config"] = config
        }
        if opcodeLength == 3 {
            result["vendor_opcode"] = opcode[0] & 0x3f
            result["company_id"] = String(format: "%04x", UInt16(opcode[1]) | (UInt16(opcode[2]) << 8))
        } else if opcodeLength == 1 && opcode[0] == NativeTelinkControl.accessOpcode {
            let parameters = Array(accessMessage.dropFirst())
            if let telink = NativeTelinkControl.decodePacket(parameters) {
                result["telink"] = telink
            }
        }
        return result
    }

    private func configMessageSummary(_ accessMessage: [UInt8]) -> [String: Any]? {
        if Array(accessMessage.prefix(1)) == NativeMeshConfig.configCompositionDataStatusOpcode {
            do {
                let composition = try NativeMeshConfig.configCompositionDataStatus(accessMessage)
                var result = compositionDataSummary(composition)
                result["message"] = "composition_data_status"
                result["page"] = 0
                result["composition_data_bytes"] = max(0, accessMessage.count - 1)
                return result
            } catch {
                return [
                    "message": "composition_data_status",
                    "decode_error": String(describing: error),
                ]
            }
        }

        if Array(accessMessage.prefix(2)) == NativeMeshConfig.configAppKeyListOpcode {
            do {
                let status = try NativeMeshConfig.configAppKeyList(accessMessage)
                return [
                    "message": "appkey_list",
                    "status": status.status,
                    "status_name": NativeMeshConfig.statusName(status.status),
                    "net_key_index": status.netKeyIndex,
                    "app_key_indexes": status.appKeyIndexes,
                    "app_key_count": status.appKeyIndexes.count,
                ]
            } catch {
                return [
                    "message": "appkey_list",
                    "decode_error": String(describing: error),
                ]
            }
        }

        if Array(accessMessage.prefix(2)) == NativeMeshConfig.configAppKeyStatusOpcode {
            do {
                let status = try NativeMeshConfig.configAppKeyStatus(accessMessage)
                return [
                    "message": "appkey_status",
                    "status": Int(status.status),
                    "status_name": NativeMeshConfig.statusName(status.status),
                    "net_key_index": status.netKeyIndex,
                    "app_key_index": status.appKeyIndex,
                ]
            } catch {
                return [
                    "message": "appkey_status",
                    "decode_error": String(describing: error),
                ]
            }
        }

        if Array(accessMessage.prefix(2)) == NativeMeshConfig.configModelAppStatusOpcode {
            do {
                let status = try NativeMeshConfig.configModelAppStatus(accessMessage)
                var result: [String: Any] = [
                    "message": "model_app_status",
                    "status": Int(status.status),
                    "status_name": NativeMeshConfig.statusName(status.status),
                    "element_address": Int(status.elementAddress),
                    "app_key_index": status.appKeyIndex,
                ]
                switch status.modelIdentifier {
                case .sig(let modelIdentifier):
                    result["model_type"] = "sig"
                    result["model_id"] = String(format: "%04x", modelIdentifier)
                case .vendor(let companyIdentifier, let modelIdentifier):
                    result["model_type"] = "vendor"
                    result["model_company_id"] = String(format: "%04x", companyIdentifier)
                    result["model_id"] = String(format: "%04x", modelIdentifier)
                }
                return result
            } catch {
                return [
                    "message": "model_app_status",
                    "decode_error": String(describing: error),
                ]
            }
        }

        if accessMessage == NativeMeshConfig.configNodeResetStatusOpcode {
            return [
                "message": "node_reset_status",
                "destructive": true,
            ]
        }

        return nil
    }

    private func compositionDataSummary(_ composition: NativeMeshCompositionDataPage0) -> [String: Any] {
        let sigModelCount = composition.elements.reduce(0) { $0 + $1.sigModels.count }
        let vendorModelCount = composition.elements.reduce(0) { $0 + $1.vendorModels.count }
        var result: [String: Any] = [
            "cid": String(format: "%04x", composition.cid),
            "pid": String(format: "%04x", composition.pid),
            "vid": String(format: "%04x", composition.vid),
            "crpl": Int(composition.crpl),
            "features": Int(composition.features),
            "element_count": composition.elements.count,
            "sig_model_count": sigModelCount,
            "vendor_model_count": vendorModelCount,
        ]
        if let target = composition.firstVendorModelBindingTarget {
            result["first_vendor_element_index"] = target.elementIndex
            result["first_vendor_company_id"] = String(format: "%04x", target.model.companyIdentifier)
            result["first_vendor_model_id"] = String(format: "%04x", target.model.modelIdentifier)
        }
        return result
    }

    private func accessOpcodeLength(_ accessMessage: [UInt8]) -> Int? {
        guard let first = accessMessage.first else {
            return nil
        }
        let length: Int
        if (first & 0x80) == 0 {
            length = 1
        } else if (first & 0xc0) == 0x80 {
            length = 2
        } else {
            length = 3
        }
        return accessMessage.count >= length ? length : nil
    }

    private func completeProxyWriteOrWaitForAck() {
        if options.expectedSegmentAckSeqZero != nil {
            if segmentAckComplete {
                proxyWriteCompleted = true
                finishAfterProxySettle()
            } else {
                scheduleSegmentAckRetryIfNeeded()
            }
            return
        }

        proxyWriteCompleted = true
        finishAfterProxySettle()
    }

    private func scheduleSegmentAckRetryIfNeeded() {
        guard !finished,
              !segmentAckRetryScheduled,
              segmentAckSendAttempts < options.segmentAckMaxSendAttempts,
              let peripheral = selectedPeripheral else {
            return
        }

        segmentAckRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + options.segmentAckRetryDelay) { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  !self.finished,
                  !self.segmentAckComplete,
                  !self.proxyWriteCompleted else {
                return
            }
            self.segmentAckRetryScheduled = false
            self.segmentAckSendAttempts += 1
            self.proxyWriteIndex = 0
            self.writeNextProxyPdu(peripheral)
        }
    }

    private func finishAfterProxySettle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + options.settleAfterWrite) { [weak self] in
            self?.finish(ok: true, error: nil)
        }
    }

    private func handleTimeout() {
        if centralState != "poweredOn" && discoveries.isEmpty {
            finish(ok: false, error: "Bluetooth did not become available (central_state \(centralState))")
            return
        }
        if options.nativeProvisioningRun != nil && !liveProvisioningCompleted {
            if selectedPeripheral == nil {
                finish(ok: false, error: "no Mesh Provisioning service device found")
            } else {
                finish(ok: false, error: liveProvisioningError ?? "provisioning timed out")
            }
        } else if options.hasProxyWrite && !proxyWriteCompleted {
            if selectedPeripheral == nil && options.connectService == meshProvisioningService {
                finish(ok: false, error: "no Mesh Provisioning service device found")
            } else if options.requiredProxyNetworkId != nil && selectedPeripheral == nil {
                finish(ok: false, error: "no matching Mesh Proxy Network ID found")
            } else if options.expectedSegmentAckSeqZero != nil && proxyWriteIndex >= proxyWritePdus.count {
                finish(ok: false, error: "segment acknowledgment timed out")
            } else {
                finish(ok: false, error: "proxy write timed out")
            }
        } else {
            finish(ok: true, error: nil)
        }
    }

    private func updateDiscovery(_ peripheral: CBPeripheral, mutate: (inout [String: Any]) -> Void) {
        let key = peripheral.identifier.uuidString
        var entry = discoveries[key] ?? [
            "id": key,
            "name": peripheral.name ?? NSNull(),
            "connected": false,
        ]
        mutate(&entry)
        discoveries[key] = entry
    }

    private func finish(ok: Bool, error: String?) {
        guard !finished else {
            return
        }
        finished = true
        manager?.stopScan()
        if let peripheral = selectedPeripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        var data: [String: Any] = [
            "central_state": centralState,
            "elapsed_seconds": Double(round(elapsed * 1000) / 1000),
            "scanned_services": options.scanServices.map(cbuuidString).sorted(),
            "connected": discoveries.values.contains { ($0["connected"] as? Bool) == true },
            "discoveries": discoveries.values.sorted {
                ($0["rssi"] as? Int ?? -999) > ($1["rssi"] as? Int ?? -999)
            },
        ]
        if let selectedPeripheral {
            data["selected_peripheral_id"] = selectedPeripheral.identifier.uuidString
        }
        if options.hasProxyWrite {
            let logicalProxyPdus = options.configuredProxyPdus()
            let writtenProxyPdus = proxyWritePdus.isEmpty ? logicalProxyPdus : proxyWritePdus
            data["proxy_write"] = [
                "attempted": proxyWriteStarted,
                "completed": proxyWriteCompleted,
                "pdu_label": options.proxyPduLabel,
                "bytes": writtenProxyPdus.reduce(0) { $0 + $1.count },
                "logical_pdu_count": proxyWriteLogicalPduCount == 0 ? logicalProxyPdus.count : proxyWriteLogicalPduCount,
                "logical_bytes": proxyWriteLogicalBytes == 0 ? logicalProxyPdus.reduce(0) { $0 + $1.count } : proxyWriteLogicalBytes,
                "characteristic": cbuuidString(options.writeDataInUUID),
                "max_write_length": proxyWriteMaxLength,
                "proxy_sar_segmented": writtenProxyPdus.count != logicalProxyPdus.count,
                "segment_count": writtenProxyPdus.count,
                "segment_lengths": proxyWriteSegmentLengths.isEmpty ? writtenProxyPdus.map(\.count) : proxyWriteSegmentLengths,
                "segments_written": proxyWriteSegmentsWrittenTotal,
                "write_type": proxyWriteType,
                "notification_count": notificationLengths.count,
                "notification_lengths": notificationLengths,
            ]
            if let expectedSeqZero = options.expectedSegmentAckSeqZero,
               let expectedSegN = options.expectedSegmentAckSegN {
                data["segment_ack"] = [
                    "expected_seq_zero": Int(expectedSeqZero),
                    "expected_seg_n": Int(expectedSegN),
                    "last_seq_zero": segmentAckLastSeqZero.map { Int($0) } ?? NSNull(),
                    "acked_segments": Int(segmentAckedSegments),
                    "acked_segments_hex": String(format: "%08x", segmentAckedSegments),
                    "complete": segmentAckComplete,
                    "notification_count": segmentAckNotificationCount,
                    "send_attempts": segmentAckSendAttempts,
                    "max_send_attempts": options.segmentAckMaxSendAttempts,
                ]
            }
            if !decodedNotifications.isEmpty {
                data["proxy_notifications"] = decodedNotifications
            }
        }
        if !outboundSegmentAckSummaries.isEmpty {
            data["outbound_segment_acks"] = outboundSegmentAckSummaries
        }
        if let nativeSendMetadata = options.nativeSendMetadata {
            data["native_send"] = nativeSendMetadata
        }
        if let storedCompositionDataSummary {
            data["composition_data"] = storedCompositionDataSummary
        }
        if let run = options.nativeProvisioningRun {
            var provisioning: [String: Any] = [
                "started": liveProvisioningStarted,
                "completed": liveProvisioningCompleted,
                "state_written": liveProvisioningStateWritten,
                "state_mode": run.appendsToExistingState ? "append" : "create",
                "state_path": run.statePath,
                "node_address": Int(run.unicastAddress),
                "source_address": Int(run.sourceAddress),
                "iv_index": Int(run.ivIndex),
                "proxy_segments_written": liveProvisioningProxySegmentsWritten,
                "proxy_segment_lengths": liveProvisioningProxySegmentLengths,
                "write_type": liveProvisioningWriteType,
                "notification_count": notificationLengths.count,
            ]
            if let deviceUUID = liveProvisioningDeviceUUID {
                provisioning["device_uuid_suffix"] = NativeMeshCrypto.hex(Array(deviceUUID.suffix(3)))
            }
            if let state = liveProvisioningSession?.state.rawValue {
                provisioning["session_state"] = state
            }
            if let liveProvisioningError {
                provisioning["error"] = liveProvisioningError
            }
            if !liveProvisioningEvents.isEmpty {
                provisioning["events"] = liveProvisioningEvents
            }
            data["native_provisioning"] = provisioning
        }

        var payload: [String: Any] = ["ok": ok, "data": data]
        if let error {
            payload["error"] = error
        }
        writePayload(payload)

        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    private func writePayload(_ payload: [String: Any]) {
        do {
            try writeJSONPayload(payload, to: options.outputPath)
        } catch {
            fputs("failed to write probe output: \(error.localizedDescription)\n", stderr)
        }
    }

    private func writeDataInLabel() -> String {
        options.writeDataInUUID == meshProvisioningDataIn ? "Mesh Provisioning Data In" : "Mesh Proxy Data In"
    }

    private func writeDataOutLabel() -> String {
        options.writeDataOutUUID == meshProvisioningDataOut ? "Mesh Provisioning Data Out" : "Mesh Proxy Data Out"
    }
}

@main
struct BluetoothProbeMain {
    static func main() {
        let options = ProbeOptions(arguments: CommandLine.arguments)
        if let configurationError = options.configurationError {
            let payload: [String: Any] = [
                "ok": false,
                "error": configurationError,
                "data": [
                    "central_state": "notStarted",
                    "discoveries": [],
                    "scanned_services": options.scanServices.map(cbuuidString).sorted(),
                ],
            ]
            do {
                try writeJSONPayload(payload, to: options.outputPath)
            } catch {
                fputs("failed to write probe output: \(error.localizedDescription)\n", stderr)
            }
            return
        }
        if let run = options.nativeJoinCaptureRun {
            do {
                let capture = try MeshJoinCapturePeripheral(options: options, run: run)
                withExtendedLifetime(capture) {
                    CFRunLoopRun()
                }
            } catch {
                let payload: [String: Any] = [
                    "ok": false,
                    "error": String(describing: error),
                    "data": [
                        "central_state": "notStarted",
                        "join_capture": [
                            "started": false,
                            "completed": false,
                            "state_written": false,
                        ],
                    ],
                ]
                do {
                    try writeJSONPayload(payload, to: options.outputPath)
                } catch {
                    fputs("failed to write join capture output: \(error.localizedDescription)\n", stderr)
                }
            }
        } else {
            let probe = MeshGattProbe(options: options)
            withExtendedLifetime(probe) {
                CFRunLoopRun()
            }
        }
    }
}
