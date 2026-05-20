import CryptoKit
import Foundation
import Security

enum NativeMeshProvisioningError: Error, CustomStringConvertible {
    case invalidParameter(String)
    case invalidLength(String)
    case randomGenerationFailed(Int32)

    var description: String {
        switch self {
        case .invalidParameter(let value):
            return "invalid provisioning parameter: \(value)"
        case .invalidLength(let value):
            return "invalid provisioning length: \(value)"
        case .randomGenerationFailed(let status):
            return "provisioning random generation failed: \(status)"
        }
    }
}

struct NativeProvisioningSecrets: Equatable {
    let confirmationSalt: [UInt8]
    let confirmationKey: [UInt8]
    let provisioningSalt: [UInt8]
    let sessionKey: [UInt8]
    let sessionNonce: [UInt8]
    let deviceKey: [UInt8]
}

struct NativeProvisioningDataEncrypted: Equatable {
    let provisioningData: [UInt8]
    let encryptedProvisioningData: [UInt8]
    let provisioningDataMic: [UInt8]
    let provisioningDataPdu: [UInt8]
}

struct NativeProvisioningKeyPair {
    let privateKey: P256.KeyAgreement.PrivateKey
    let publicKey: [UInt8]
}

struct NativeNoOobProvisioningTranscript: Equatable {
    let invitePdu: [UInt8]
    let capabilitiesPdu: [UInt8]
    let startPdu: [UInt8]
    let provisionerPublicKey: [UInt8]
    let devicePublicKey: [UInt8]
    let provisionerPublicKeyPdu: [UInt8]
    let provisionerConfirmation: [UInt8]
    let provisionerConfirmationPdu: [UInt8]
    let expectedDeviceConfirmation: [UInt8]
    let expectedDeviceConfirmationPdu: [UInt8]
    let provisionerRandom: [UInt8]
    let deviceRandom: [UInt8]
    let provisionerRandomPdu: [UInt8]
    let confirmationInputs: [UInt8]
    let secrets: NativeProvisioningSecrets
    let encryptedProvisioningData: NativeProvisioningDataEncrypted
}

enum NativeNoOobProvisioningSessionState: String {
    case idle
    case awaitingCapabilities
    case awaitingDevicePublicKey
    case awaitingDeviceConfirmation
    case awaitingDeviceRandom
    case awaitingComplete
    case complete
    case failed
}

struct NativeNoOobProvisioningSessionResult: Equatable {
    let state: NativeNoOobProvisioningSessionState
    let outgoingPdus: [[UInt8]]
    let completed: Bool
    let failedErrorName: String?
}

struct NativeProvisioningDataPlaintext: Equatable {
    let networkKey: [UInt8]
    let keyIndex: Int
    let flags: Int
    let ivIndex: UInt32
    let unicastAddress: UInt16
}

struct NativeProvisioningProxyReassemblyResult: Equatable {
    let provisioningPdu: [UInt8]?
    let segmentCount: Int
    let pending: Bool
}

struct NativeProvisioningProxyPduReassembler {
    private(set) var segments: [[UInt8]] = []

    mutating func receive(_ proxyPdu: [UInt8]) throws -> NativeProvisioningProxyReassemblyResult {
        guard let header = proxyPdu.first else {
            throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment must not be empty")
        }
        guard (header & NativeMeshProvisioning.proxyMessageTypeMask) == NativeMeshProvisioning.proxyPduType else {
            throw NativeMeshProvisioningError.invalidParameter("Proxy PDU segment is not provisioning type")
        }

        let sar = header & NativeMeshProvisioning.proxySarMask
        switch sar {
        case NativeMeshProvisioning.proxySarComplete:
            segments = []
            return NativeProvisioningProxyReassemblyResult(
                provisioningPdu: Array(proxyPdu.dropFirst()),
                segmentCount: 1,
                pending: false
            )
        case NativeMeshProvisioning.proxySarFirst:
            guard segments.isEmpty else {
                throw NativeMeshProvisioningError.invalidParameter("received first segment while reassembly is pending")
            }
            segments = [proxyPdu]
            return NativeProvisioningProxyReassemblyResult(
                provisioningPdu: nil,
                segmentCount: segments.count,
                pending: true
            )
        case NativeMeshProvisioning.proxySarContinuation:
            guard !segments.isEmpty else {
                throw NativeMeshProvisioningError.invalidParameter("received continuation segment without first segment")
            }
            segments.append(proxyPdu)
            return NativeProvisioningProxyReassemblyResult(
                provisioningPdu: nil,
                segmentCount: segments.count,
                pending: true
            )
        case NativeMeshProvisioning.proxySarLast:
            guard !segments.isEmpty else {
                throw NativeMeshProvisioningError.invalidParameter("received last segment without first segment")
            }
            segments.append(proxyPdu)
            let completedSegments = segments
            segments = []
            return NativeProvisioningProxyReassemblyResult(
                provisioningPdu: try NativeMeshProvisioning.reassembleProxyPdus(completedSegments),
                segmentCount: completedSegments.count,
                pending: false
            )
        default:
            throw NativeMeshProvisioningError.invalidParameter("unknown Proxy PDU SAR")
        }
    }
}

struct NativeNoOobProvisioningSession {
    let provisionerKeyPair: NativeProvisioningKeyPair
    let provisionerRandom: [UInt8]
    let networkKey: [UInt8]
    let keyIndex: Int
    let flags: Int
    let ivIndex: UInt32
    let unicastAddress: UInt16

    private(set) var state: NativeNoOobProvisioningSessionState = .idle
    private(set) var transcript: NativeNoOobProvisioningTranscript?

    private var invitePdu: [UInt8]?
    private var capabilitiesPdu: [UInt8]?
    private var devicePublicKey: [UInt8]?
    private var deviceConfirmationPdu: [UInt8]?
    private var confirmationKey: [UInt8]?

    init(
        provisionerKeyPair: NativeProvisioningKeyPair,
        provisionerRandom: [UInt8],
        networkKey: [UInt8],
        keyIndex: Int,
        flags: Int,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws {
        guard provisionerRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("provisioner random must be 16 bytes")
        }
        self.provisionerKeyPair = provisionerKeyPair
        self.provisionerRandom = provisionerRandom
        self.networkKey = networkKey
        self.keyIndex = keyIndex
        self.flags = flags
        self.ivIndex = ivIndex
        self.unicastAddress = unicastAddress
        _ = try NativeMeshProvisioning.provisioningData(
            networkKey: networkKey,
            keyIndex: keyIndex,
            flags: flags,
            ivIndex: ivIndex,
            unicastAddress: unicastAddress
        )
    }

    mutating func start(attentionDuration: Int) throws -> [UInt8] {
        guard state == .idle else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning session already started")
        }
        let invite = try NativeMeshProvisioning.provisioningInvite(attentionDuration: attentionDuration)
        invitePdu = invite
        state = .awaitingCapabilities
        return invite
    }

    mutating func receive(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard let pduType = pdu.first else {
            throw NativeMeshProvisioningError.invalidLength("incoming provisioning PDU is empty")
        }
        if pduType == NativeMeshProvisioning.provisioningFailedType {
            state = .failed
            let errorCode = pdu.dropFirst().first ?? 0
            return result(
                outgoingPdus: [],
                failedErrorName: NativeMeshProvisioning.provisioningFailedErrorName(errorCode)
            )
        }

        switch state {
        case .awaitingCapabilities:
            return try handleCapabilities(pdu)
        case .awaitingDevicePublicKey:
            return try handleDevicePublicKey(pdu)
        case .awaitingDeviceConfirmation:
            return try handleDeviceConfirmation(pdu)
        case .awaitingDeviceRandom:
            return try handleDeviceRandom(pdu)
        case .awaitingComplete:
            return try handleComplete(pdu)
        case .idle:
            throw NativeMeshProvisioningError.invalidParameter("provisioning session has not started")
        case .complete:
            throw NativeMeshProvisioningError.invalidParameter("provisioning session already completed")
        case .failed:
            throw NativeMeshProvisioningError.invalidParameter("provisioning session already failed")
        }
    }

    private mutating func handleCapabilities(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard invitePdu != nil else {
            throw NativeMeshProvisioningError.invalidParameter("Invite PDU is missing")
        }
        let startPdu = try NativeMeshProvisioning.noOobProvisioningStart(capabilitiesPdu: pdu)
        capabilitiesPdu = pdu
        state = .awaitingDevicePublicKey
        return result(
            outgoingPdus: [
                startPdu,
                try NativeMeshProvisioning.provisioningPublicKey(provisionerKeyPair.publicKey),
            ],
            failedErrorName: nil
        )
    }

    private mutating func handleDevicePublicKey(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard let invitePdu, let capabilitiesPdu else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning session is missing Capabilities")
        }
        let publicKey = try NativeMeshProvisioning.publicKeyValuePdu(pdu)
        let startPdu = try NativeMeshProvisioning.noOobProvisioningStart(capabilitiesPdu: capabilitiesPdu)
        let inputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: provisionerKeyPair.publicKey,
            devicePublicKey: publicKey
        )
        let ecdhSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: provisionerKeyPair.privateKey,
            peerPublicKey: publicKey
        )
        let confirmationSalt = try NativeMeshProvisioning.confirmationSalt(confirmationInputs: inputs)
        let key = try NativeMeshProvisioning.confirmationKey(
            ecdhSecret: ecdhSecret,
            confirmationSalt: confirmationSalt
        )
        let confirmation = try NativeMeshProvisioning.confirmationValue(
            confirmationKey: key,
            random: provisionerRandom,
            authValue: NativeMeshProvisioning.authValueNoOob()
        )
        devicePublicKey = publicKey
        confirmationKey = key
        state = .awaitingDeviceConfirmation
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningConfirmation(confirmation)],
            failedErrorName: nil
        )
    }

    private mutating func handleDeviceConfirmation(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        _ = try NativeMeshProvisioning.confirmationValuePdu(pdu)
        deviceConfirmationPdu = pdu
        state = .awaitingDeviceRandom
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningRandom(provisionerRandom)],
            failedErrorName: nil
        )
    }

    private mutating func handleDeviceRandom(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard let invitePdu, let capabilitiesPdu, let devicePublicKey, let deviceConfirmationPdu, let confirmationKey else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning session is missing confirmation state")
        }
        let deviceRandom = try NativeMeshProvisioning.randomValuePdu(pdu)
        let randomPdu = try NativeMeshProvisioning.provisioningRandom(deviceRandom)
        guard try NativeMeshProvisioning.verifyConfirmationPdu(
            confirmationPdu: deviceConfirmationPdu,
            randomPdu: randomPdu,
            confirmationKey: confirmationKey,
            authValue: NativeMeshProvisioning.authValueNoOob()
        ) else {
            throw NativeMeshProvisioningError.invalidParameter("device confirmation did not match device random")
        }

        let builtTranscript = try NativeMeshProvisioning.noOobProvisioningTranscript(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            provisionerKeyPair: provisionerKeyPair,
            devicePublicKey: devicePublicKey,
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom,
            networkKey: networkKey,
            keyIndex: keyIndex,
            flags: flags,
            ivIndex: ivIndex,
            unicastAddress: unicastAddress
        )
        transcript = builtTranscript
        state = .awaitingComplete
        return result(
            outgoingPdus: [builtTranscript.encryptedProvisioningData.provisioningDataPdu],
            failedErrorName: nil
        )
    }

    private mutating func handleComplete(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard pdu == [NativeMeshProvisioning.provisioningCompleteType] else {
            throw NativeMeshProvisioningError.invalidParameter("expected Provisioning Complete PDU")
        }
        state = .complete
        return result(outgoingPdus: [], failedErrorName: nil)
    }

    private func result(
        outgoingPdus: [[UInt8]],
        failedErrorName: String?
    ) -> NativeNoOobProvisioningSessionResult {
        NativeNoOobProvisioningSessionResult(
            state: state,
            outgoingPdus: outgoingPdus,
            completed: state == .complete,
            failedErrorName: failedErrorName
        )
    }
}

enum NativeProvisioneeCaptureSessionState: String {
    case awaitingInvite
    case awaitingStart
    case awaitingProvisionerPublicKey
    case awaitingProvisionerConfirmation
    case awaitingProvisionerRandom
    case awaitingProvisioningData
    case complete
    case failed
}

struct NativeProvisioneeCaptureResult: Equatable {
    let state: NativeProvisioneeCaptureSessionState
    let outgoingPdus: [[UInt8]]
    let completed: Bool
    let failedErrorName: String?
    let capturedData: NativeProvisioningDataPlaintext?
}

struct NativeProvisioneeCaptureSession {
    let deviceKeyPair: NativeProvisioningKeyPair
    let deviceRandom: [UInt8]
    let capabilitiesPdu: [UInt8]

    private(set) var state: NativeProvisioneeCaptureSessionState = .awaitingInvite
    private(set) var capturedData: NativeProvisioningDataPlaintext?
    private(set) var deviceKey: [UInt8]?

    private var invitePdu: [UInt8]?
    private var startPdu: [UInt8]?
    private var provisionerPublicKey: [UInt8]?
    private var provisionerConfirmationPdu: [UInt8]?
    private var confirmationKey: [UInt8]?
    private var provisioningSecrets: NativeProvisioningSecrets?

    init(
        deviceKeyPair: NativeProvisioningKeyPair,
        deviceRandom: [UInt8],
        elementCount: Int = 1
    ) throws {
        guard deviceRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("device random must be 16 bytes")
        }
        self.deviceKeyPair = deviceKeyPair
        self.deviceRandom = deviceRandom
        self.capabilitiesPdu = try NativeMeshProvisioning.provisioningCapabilities(elementCount: elementCount)
    }

    mutating func receive(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let pduType = pdu.first else {
            throw NativeMeshProvisioningError.invalidLength("incoming provisioning PDU is empty")
        }
        if pduType == NativeMeshProvisioning.provisioningFailedType {
            state = .failed
            let errorCode = pdu.dropFirst().first ?? 0
            return result(
                outgoingPdus: [],
                failedErrorName: NativeMeshProvisioning.provisioningFailedErrorName(errorCode)
            )
        }

        switch state {
        case .awaitingInvite:
            return try handleInvite(pdu)
        case .awaitingStart:
            return try handleStart(pdu)
        case .awaitingProvisionerPublicKey:
            return try handleProvisionerPublicKey(pdu)
        case .awaitingProvisionerConfirmation:
            return try handleProvisionerConfirmation(pdu)
        case .awaitingProvisionerRandom:
            return try handleProvisionerRandom(pdu)
        case .awaitingProvisioningData:
            return try handleProvisioningData(pdu)
        case .complete:
            throw NativeMeshProvisioningError.invalidParameter("provisionee session already completed")
        case .failed:
            throw NativeMeshProvisioningError.invalidParameter("provisionee session already failed")
        }
    }

    private mutating func handleInvite(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard pdu.count == 2, pdu[0] == NativeMeshProvisioning.provisioningInviteType else {
            throw NativeMeshProvisioningError.invalidParameter("expected Provisioning Invite PDU")
        }
        invitePdu = pdu
        state = .awaitingStart
        return result(outgoingPdus: [capabilitiesPdu], failedErrorName: nil)
    }

    private mutating func handleStart(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let start = NativeMeshProvisioning.provisioningStartSummary(pdu) else {
            throw NativeMeshProvisioningError.invalidParameter("expected Provisioning Start PDU")
        }
        guard start["algorithm_name"] as? String == "fips_p256_elliptic_curve" else {
            throw NativeMeshProvisioningError.invalidParameter("unsupported provisioning algorithm")
        }
        guard start["public_key_name"] as? String == "in_band" else {
            throw NativeMeshProvisioningError.invalidParameter("out-of-band public key is not supported")
        }
        guard start["authentication_method_name"] as? String == "no_oob" else {
            throw NativeMeshProvisioningError.invalidParameter("only no-OOB provisioning capture is supported")
        }
        startPdu = pdu
        state = .awaitingProvisionerPublicKey
        return result(outgoingPdus: [], failedErrorName: nil)
    }

    private mutating func handleProvisionerPublicKey(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let invitePdu, let startPdu else {
            throw NativeMeshProvisioningError.invalidParameter("provisionee session is missing invite/start state")
        }
        let publicKey = try NativeMeshProvisioning.publicKeyValuePdu(pdu)
        let inputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: publicKey,
            devicePublicKey: deviceKeyPair.publicKey
        )
        let ecdhSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: deviceKeyPair.privateKey,
            peerPublicKey: publicKey
        )
        let salt = try NativeMeshProvisioning.confirmationSalt(confirmationInputs: inputs)
        let key = try NativeMeshProvisioning.confirmationKey(ecdhSecret: ecdhSecret, confirmationSalt: salt)
        provisionerPublicKey = publicKey
        confirmationKey = key
        state = .awaitingProvisionerConfirmation
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningPublicKey(deviceKeyPair.publicKey)],
            failedErrorName: nil
        )
    }

    private mutating func handleProvisionerConfirmation(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        _ = try NativeMeshProvisioning.confirmationValuePdu(pdu)
        provisionerConfirmationPdu = pdu
        guard let confirmationKey else {
            throw NativeMeshProvisioningError.invalidParameter("confirmation key is missing")
        }
        let confirmation = try NativeMeshProvisioning.confirmationValue(
            confirmationKey: confirmationKey,
            random: deviceRandom,
            authValue: NativeMeshProvisioning.authValueNoOob()
        )
        state = .awaitingProvisionerRandom
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningConfirmation(confirmation)],
            failedErrorName: nil
        )
    }

    private mutating func handleProvisionerRandom(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let provisionerConfirmationPdu, let confirmationKey, let invitePdu, let startPdu, let provisionerPublicKey else {
            throw NativeMeshProvisioningError.invalidParameter("provisionee session is missing confirmation state")
        }
        let provisionerRandom = try NativeMeshProvisioning.randomValuePdu(pdu)
        let provisionerRandomPdu = try NativeMeshProvisioning.provisioningRandom(provisionerRandom)
        guard try NativeMeshProvisioning.verifyConfirmationPdu(
            confirmationPdu: provisionerConfirmationPdu,
            randomPdu: provisionerRandomPdu,
            confirmationKey: confirmationKey,
            authValue: NativeMeshProvisioning.authValueNoOob()
        ) else {
            throw NativeMeshProvisioningError.invalidParameter("provisioner confirmation did not match provisioner random")
        }
        let inputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: provisionerPublicKey,
            devicePublicKey: deviceKeyPair.publicKey
        )
        let confirmationSalt = try NativeMeshProvisioning.confirmationSalt(confirmationInputs: inputs)
        let ecdhSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: deviceKeyPair.privateKey,
            peerPublicKey: provisionerPublicKey
        )
        let secrets = try NativeMeshProvisioning.provisioningSecrets(
            ecdhSecret: ecdhSecret,
            confirmationSalt: confirmationSalt,
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom
        )
        provisioningSecrets = secrets
        deviceKey = secrets.deviceKey
        state = .awaitingProvisioningData
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningRandom(deviceRandom)],
            failedErrorName: nil
        )
    }

    private mutating func handleProvisioningData(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let provisioningSecrets else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning secrets are missing")
        }
        let plaintext = try NativeMeshProvisioning.decryptProvisioningData(
            pdu,
            sessionKey: provisioningSecrets.sessionKey,
            sessionNonce: provisioningSecrets.sessionNonce
        )
        capturedData = plaintext
        state = .complete
        return result(
            outgoingPdus: [[NativeMeshProvisioning.provisioningCompleteType]],
            failedErrorName: nil
        )
    }

    private func result(
        outgoingPdus: [[UInt8]],
        failedErrorName: String?
    ) -> NativeProvisioneeCaptureResult {
        NativeProvisioneeCaptureResult(
            state: state,
            outgoingPdus: outgoingPdus,
            completed: state == .complete,
            failedErrorName: failedErrorName,
            capturedData: capturedData
        )
    }
}

struct NativeMeshProvisioning {
    static let proxyPduType = UInt8(0x03)
    static let proxySarComplete = UInt8(0x00)
    static let proxySarFirst = UInt8(0x40)
    static let proxySarContinuation = UInt8(0x80)
    static let proxySarLast = UInt8(0xc0)
    static let proxyMessageTypeMask = UInt8(0x3f)
    static let proxySarMask = UInt8(0xc0)
    static let provisioningInviteType = UInt8(0x00)
    static let provisioningCapabilitiesType = UInt8(0x01)
    static let provisioningStartType = UInt8(0x02)
    static let provisioningPublicKeyType = UInt8(0x03)
    static let provisioningConfirmationType = UInt8(0x05)
    static let provisioningRandomType = UInt8(0x06)
    static let provisioningDataType = UInt8(0x07)
    static let provisioningCompleteType = UInt8(0x08)
    static let provisioningFailedType = UInt8(0x09)
    static let algorithmFipsP256EllipticCurve = UInt8(0x00)
    static let publicKeyInBand = UInt8(0x00)
    static let publicKeyOob = UInt8(0x01)
    static let authenticationNoOob = UInt8(0x00)
    static let authenticationStaticOob = UInt8(0x01)
    static let authenticationOutputOob = UInt8(0x02)
    static let authenticationInputOob = UInt8(0x03)

    static func oobInfoFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "other"),
            (0x0002, "electronic_or_uri"),
            (0x0004, "machine_readable_2d_code"),
            (0x0008, "bar_code"),
            (0x0010, "nfc"),
            (0x0020, "number"),
            (0x0040, "string"),
            (0x0800, "on_box"),
            (0x1000, "inside_box"),
            (0x2000, "on_piece_of_paper"),
            (0x4000, "inside_manual"),
            (0x8000, "on_device"),
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func provisioningServiceDataSummary(_ bytes: [UInt8]) -> [String: Any] {
        var result: [String: Any] = [
            "bytes": bytes.count,
        ]

        guard bytes.count >= 16 else {
            result["format"] = "short"
            return result
        }

        result["device_uuid"] = NativeMeshCrypto.hex(Array(bytes[0..<16]))

        if bytes.count >= 18 {
            let oobInfo = (UInt16(bytes[16]) << 8) | UInt16(bytes[17])
            result["oob_info"] = String(format: "0x%04x", oobInfo)
            result["oob_info_value"] = Int(oobInfo)
            result["oob_info_flags"] = oobInfoFlags(oobInfo)
        }

        if bytes.count >= 22 {
            result["uri_hash"] = NativeMeshCrypto.hex(Array(bytes[18..<22]))
        }

        if bytes.count != 18 && bytes.count != 22 {
            result["format"] = "unexpected"
        }
        return result
    }

    static func provisioningInvite(attentionDuration: Int) throws -> [UInt8] {
        guard (0...255).contains(attentionDuration) else {
            throw NativeMeshProvisioningError.invalidParameter("attention duration must be between 0 and 255")
        }
        return [provisioningInviteType, UInt8(attentionDuration)]
    }

    static func provisioningCapabilities(elementCount: Int = 1) throws -> [UInt8] {
        guard (1...255).contains(elementCount) else {
            throw NativeMeshProvisioningError.invalidParameter("element count must be 1..255")
        }
        return [
            provisioningCapabilitiesType,
            UInt8(elementCount),
            0x00, 0x01,
            publicKeyInBand,
            0x00,
            0x00,
            0x00, 0x00,
            0x00,
            0x00, 0x00,
        ]
    }

    static func completeProxyPdu(provisioningPdu: [UInt8]) -> [UInt8] {
        [proxyPduType] + provisioningPdu
    }

    static func segmentedProxyPdus(
        provisioningPdu: [UInt8],
        maxSegmentPayloadBytes: Int
    ) throws -> [[UInt8]] {
        guard maxSegmentPayloadBytes > 0 else {
            throw NativeMeshProvisioningError.invalidParameter("max segment payload bytes must be positive")
        }
        guard !provisioningPdu.isEmpty else {
            throw NativeMeshProvisioningError.invalidLength("Provisioning PDU must not be empty")
        }
        guard provisioningPdu.count > maxSegmentPayloadBytes else {
            return [completeProxyPdu(provisioningPdu: provisioningPdu)]
        }

        var segments: [[UInt8]] = []
        var offset = 0
        while offset < provisioningPdu.count {
            let next = min(offset + maxSegmentPayloadBytes, provisioningPdu.count)
            let payload = Array(provisioningPdu[offset..<next])
            let sar: UInt8
            if offset == 0 {
                sar = proxySarFirst
            } else if next == provisioningPdu.count {
                sar = proxySarLast
            } else {
                sar = proxySarContinuation
            }
            segments.append([sar | proxyPduType] + payload)
            offset = next
        }
        return segments
    }

    static func reassembleProxyPdus(_ proxyPdus: [[UInt8]]) throws -> [UInt8] {
        guard !proxyPdus.isEmpty else {
            throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment list must not be empty")
        }
        if proxyPdus.count == 1 {
            guard let header = proxyPdus[0].first else {
                throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment must not be empty")
            }
            guard (header & proxySarMask) == proxySarComplete, (header & proxyMessageTypeMask) == proxyPduType else {
                throw NativeMeshProvisioningError.invalidParameter("single Proxy PDU must be complete provisioning type")
            }
            return Array(proxyPdus[0].dropFirst())
        }

        var result: [UInt8] = []
        for (index, segment) in proxyPdus.enumerated() {
            guard let header = segment.first else {
                throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment must not be empty")
            }
            guard (header & proxyMessageTypeMask) == proxyPduType else {
                throw NativeMeshProvisioningError.invalidParameter("Proxy PDU segment is not provisioning type")
            }
            let sar = header & proxySarMask
            if index == 0 {
                guard sar == proxySarFirst else {
                    throw NativeMeshProvisioningError.invalidParameter("first Proxy PDU segment has invalid SAR")
                }
            } else if index == proxyPdus.count - 1 {
                guard sar == proxySarLast else {
                    throw NativeMeshProvisioningError.invalidParameter("last Proxy PDU segment has invalid SAR")
                }
            } else {
                guard sar == proxySarContinuation else {
                    throw NativeMeshProvisioningError.invalidParameter("continuation Proxy PDU segment has invalid SAR")
                }
            }
            result += Array(segment.dropFirst())
        }
        return result
    }

    static func provisioningStart(
        algorithm: Int,
        publicKey: Int,
        authenticationMethod: Int,
        authenticationAction: Int,
        authenticationSize: Int
    ) throws -> [UInt8] {
        guard (0...255).contains(algorithm) else {
            throw NativeMeshProvisioningError.invalidParameter("algorithm must be between 0 and 255")
        }
        guard publicKey == Int(publicKeyInBand) || publicKey == Int(publicKeyOob) else {
            throw NativeMeshProvisioningError.invalidParameter("public key must be 0 or 1")
        }
        guard (Int(authenticationNoOob)...Int(authenticationInputOob)).contains(authenticationMethod) else {
            throw NativeMeshProvisioningError.invalidParameter("authentication method must be between 0 and 3")
        }
        guard (0...255).contains(authenticationAction) else {
            throw NativeMeshProvisioningError.invalidParameter("authentication action must be between 0 and 255")
        }
        guard (0...255).contains(authenticationSize) else {
            throw NativeMeshProvisioningError.invalidParameter("authentication size must be between 0 and 255")
        }

        return [
            provisioningStartType,
            UInt8(algorithm),
            UInt8(publicKey),
            UInt8(authenticationMethod),
            UInt8(authenticationAction),
            UInt8(authenticationSize),
        ]
    }

    static func noOobProvisioningStart(capabilitiesPdu: [UInt8]) throws -> [UInt8] {
        guard capabilitiesPdu.count == 12, capabilitiesPdu[0] == provisioningCapabilitiesType else {
            throw NativeMeshProvisioningError.invalidParameter("capabilities PDU must be 12 bytes and type 0x01")
        }
        let algorithms = bigEndianUInt16(capabilitiesPdu, offset: 2)
        guard (algorithms & 0x0001) != 0 else {
            throw NativeMeshProvisioningError.invalidParameter("capabilities do not support FIPS P-256 Elliptic Curve")
        }
        return try provisioningStart(
            algorithm: Int(algorithmFipsP256EllipticCurve),
            publicKey: Int(publicKeyInBand),
            authenticationMethod: Int(authenticationNoOob),
            authenticationAction: 0,
            authenticationSize: 0
        )
    }

    static func generateProvisioningRandom() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NativeMeshProvisioningError.randomGenerationFailed(status)
        }
        return bytes
    }

    static func provisioningPublicKey(_ publicKeyXY: [UInt8]) throws -> [UInt8] {
        guard publicKeyXY.count == 64 else {
            throw NativeMeshProvisioningError.invalidParameter("public key must be 64 bytes of X and Y coordinates")
        }
        return [provisioningPublicKeyType] + publicKeyXY
    }

    static func generateProvisionerKeyPair() throws -> NativeProvisioningKeyPair {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return NativeProvisioningKeyPair(
            privateKey: privateKey,
            publicKey: try publicKeyCoordinates(privateKey.publicKey)
        )
    }

    static func ecdhSecret(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: [UInt8]
    ) throws -> [UInt8] {
        try validatePublicKey(peerPublicKey, label: "peer public key")
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: [0x04] + peerPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return sharedSecret.withUnsafeBytes { buffer in
            Array(buffer)
        }
    }

    static func provisioningConfirmation(_ confirmation: [UInt8]) throws -> [UInt8] {
        try validateAesKey(confirmation, label: "confirmation value")
        return [provisioningConfirmationType] + confirmation
    }

    static func provisioningRandom(_ random: [UInt8]) throws -> [UInt8] {
        guard random.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("random value must be 16 bytes")
        }
        return [provisioningRandomType] + random
    }

    static func confirmationValuePdu(_ pdu: [UInt8]) throws -> [UInt8] {
        try provisioningPayload(
            pdu,
            expectedType: provisioningConfirmationType,
            payloadLength: 16,
            label: "Confirmation PDU"
        )
    }

    static func randomValuePdu(_ pdu: [UInt8]) throws -> [UInt8] {
        try provisioningPayload(
            pdu,
            expectedType: provisioningRandomType,
            payloadLength: 16,
            label: "Random PDU"
        )
    }

    static func publicKeyValuePdu(_ pdu: [UInt8]) throws -> [UInt8] {
        try provisioningPayload(
            pdu,
            expectedType: provisioningPublicKeyType,
            payloadLength: 64,
            label: "Public Key PDU"
        )
    }

    static func verifyConfirmationPdu(
        confirmationPdu: [UInt8],
        randomPdu: [UInt8],
        confirmationKey: [UInt8],
        authValue: [UInt8]
    ) throws -> Bool {
        let provided = try confirmationValuePdu(confirmationPdu)
        let random = try randomValuePdu(randomPdu)
        let expected = try confirmationValue(
            confirmationKey: confirmationKey,
            random: random,
            authValue: authValue
        )
        return provided == expected
    }

    static func confirmationInputs(
        invitePdu: [UInt8],
        capabilitiesPdu: [UInt8],
        startPdu: [UInt8],
        provisionerPublicKey: [UInt8],
        devicePublicKey: [UInt8]
    ) throws -> [UInt8] {
        guard invitePdu.count == 2, invitePdu[0] == provisioningInviteType else {
            throw NativeMeshProvisioningError.invalidLength("Invite PDU must be 2 bytes and type 0x00")
        }
        guard capabilitiesPdu.count == 12, capabilitiesPdu[0] == provisioningCapabilitiesType else {
            throw NativeMeshProvisioningError.invalidLength("Capabilities PDU must be 12 bytes and type 0x01")
        }
        guard startPdu.count == 6, startPdu[0] == provisioningStartType else {
            throw NativeMeshProvisioningError.invalidLength("Start PDU must be 6 bytes and type 0x02")
        }
        try validatePublicKey(provisionerPublicKey, label: "provisioner public key")
        try validatePublicKey(devicePublicKey, label: "device public key")

        return Array(invitePdu.dropFirst())
            + Array(capabilitiesPdu.dropFirst())
            + Array(startPdu.dropFirst())
            + provisionerPublicKey
            + devicePublicKey
    }

    static func authValueNoOob() -> [UInt8] {
        [UInt8](repeating: 0, count: 16)
    }

    static func confirmationSalt(confirmationInputs: [UInt8]) throws -> [UInt8] {
        try NativeMeshCrypto.aesCmac(key: NativeMeshCrypto.zeroKey, message: confirmationInputs)
    }

    static func confirmationKey(ecdhSecret: [UInt8], confirmationSalt: [UInt8]) throws -> [UInt8] {
        try validateEcdhSecret(ecdhSecret)
        try validateAesKey(confirmationSalt, label: "confirmation salt")
        return try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: confirmationSalt,
            p: NativeMeshCrypto.ascii("prck")
        )
    }

    static func confirmationValue(confirmationKey: [UInt8], random: [UInt8], authValue: [UInt8]) throws -> [UInt8] {
        try validateAesKey(confirmationKey, label: "confirmation key")
        guard random.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("random value must be 16 bytes")
        }
        guard authValue.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("auth value must be 16 bytes")
        }
        return try NativeMeshCrypto.aesCmac(key: confirmationKey, message: random + authValue)
    }

    static func provisioningSalt(
        confirmationSalt: [UInt8],
        provisionerRandom: [UInt8],
        deviceRandom: [UInt8]
    ) throws -> [UInt8] {
        try validateAesKey(confirmationSalt, label: "confirmation salt")
        guard provisionerRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("provisioner random must be 16 bytes")
        }
        guard deviceRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("device random must be 16 bytes")
        }
        return try NativeMeshCrypto.aesCmac(
            key: NativeMeshCrypto.zeroKey,
            message: confirmationSalt + provisionerRandom + deviceRandom
        )
    }

    static func provisioningSecrets(
        ecdhSecret: [UInt8],
        confirmationSalt: [UInt8],
        provisionerRandom: [UInt8],
        deviceRandom: [UInt8]
    ) throws -> NativeProvisioningSecrets {
        try validateEcdhSecret(ecdhSecret)
        try validateAesKey(confirmationSalt, label: "confirmation salt")
        let salt = try provisioningSalt(
            confirmationSalt: confirmationSalt,
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom
        )
        let sessionKey = try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: salt,
            p: NativeMeshCrypto.ascii("prsk")
        )
        let sessionNonceFull = try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: salt,
            p: NativeMeshCrypto.ascii("prsn")
        )
        let deviceKey = try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: salt,
            p: NativeMeshCrypto.ascii("prdk")
        )
        return NativeProvisioningSecrets(
            confirmationSalt: confirmationSalt,
            confirmationKey: try confirmationKey(ecdhSecret: ecdhSecret, confirmationSalt: confirmationSalt),
            provisioningSalt: salt,
            sessionKey: sessionKey,
            sessionNonce: Array(sessionNonceFull.suffix(13)),
            deviceKey: deviceKey
        )
    }

    static func provisioningData(
        networkKey: [UInt8],
        keyIndex: Int,
        flags: Int,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws -> [UInt8] {
        try validateAesKey(networkKey, label: "network key")
        guard (0...0x0fff).contains(keyIndex) else {
            throw NativeMeshProvisioningError.invalidParameter("key index must be a 12-bit value")
        }
        guard (0...0xff).contains(flags) else {
            throw NativeMeshProvisioningError.invalidParameter("flags must be between 0 and 255")
        }
        guard (1...0x7fff).contains(Int(unicastAddress)) else {
            throw NativeMeshProvisioningError.invalidParameter("unicast address must be a non-zero unicast address")
        }

        return networkKey
            + bigEndianBytes(UInt64(keyIndex), count: 2)
            + [UInt8(flags)]
            + bigEndianBytes(UInt64(ivIndex), count: 4)
            + bigEndianBytes(UInt64(unicastAddress), count: 2)
    }

    static func encryptedProvisioningData(
        sessionKey: [UInt8],
        sessionNonce: [UInt8],
        networkKey: [UInt8],
        keyIndex: Int,
        flags: Int,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws -> NativeProvisioningDataEncrypted {
        try validateAesKey(sessionKey, label: "session key")
        guard sessionNonce.count == 13 else {
            throw NativeMeshProvisioningError.invalidLength("session nonce must be 13 bytes")
        }
        let data = try provisioningData(
            networkKey: networkKey,
            keyIndex: keyIndex,
            flags: flags,
            ivIndex: ivIndex,
            unicastAddress: unicastAddress
        )
        let encrypted = try NativeMeshCrypto.aesCcmEncrypt(
            key: sessionKey,
            nonce: sessionNonce,
            plaintext: data,
            micLength: 8
        )
        let pdu = [UInt8(0x07)] + encrypted.ciphertext + encrypted.mic
        return NativeProvisioningDataEncrypted(
            provisioningData: data,
            encryptedProvisioningData: encrypted.ciphertext,
            provisioningDataMic: encrypted.mic,
            provisioningDataPdu: pdu
        )
    }

    static func decryptProvisioningData(
        _ pdu: [UInt8],
        sessionKey: [UInt8],
        sessionNonce: [UInt8]
    ) throws -> NativeProvisioningDataPlaintext {
        try validateAesKey(sessionKey, label: "session key")
        guard sessionNonce.count == 13 else {
            throw NativeMeshProvisioningError.invalidLength("session nonce must be 13 bytes")
        }
        guard pdu.count == 34, pdu[0] == provisioningDataType else {
            throw NativeMeshProvisioningError.invalidLength("Provisioning Data PDU must be 34 bytes and type 0x07")
        }
        let encrypted = Array(pdu[1..<26])
        let mic = Array(pdu[26..<34])
        let plaintext = try NativeMeshCrypto.aesCcmDecrypt(
            key: sessionKey,
            nonce: sessionNonce,
            ciphertext: encrypted,
            mic: mic
        )
        guard plaintext.count == 25 else {
            throw NativeMeshProvisioningError.invalidLength("Provisioning Data plaintext must be 25 bytes")
        }
        return NativeProvisioningDataPlaintext(
            networkKey: Array(plaintext[0..<16]),
            keyIndex: Int(bigEndianUInt16(plaintext, offset: 16)),
            flags: Int(plaintext[18]),
            ivIndex: UInt32(plaintext[19]) << 24
                | UInt32(plaintext[20]) << 16
                | UInt32(plaintext[21]) << 8
                | UInt32(plaintext[22]),
            unicastAddress: bigEndianUInt16(plaintext, offset: 23)
        )
    }

    static func noOobProvisioningTranscript(
        invitePdu: [UInt8],
        capabilitiesPdu: [UInt8],
        provisionerPublicKey: [UInt8],
        devicePublicKey: [UInt8],
        ecdhSecret: [UInt8],
        provisionerRandom: [UInt8],
        deviceRandom: [UInt8],
        networkKey: [UInt8],
        keyIndex: Int,
        flags: Int,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws -> NativeNoOobProvisioningTranscript {
        let startPdu = try noOobProvisioningStart(capabilitiesPdu: capabilitiesPdu)
        let publicKeyPdu = try provisioningPublicKey(provisionerPublicKey)
        let inputs = try confirmationInputs(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: provisionerPublicKey,
            devicePublicKey: devicePublicKey
        )
        let salt = try confirmationSalt(confirmationInputs: inputs)
        let key = try confirmationKey(ecdhSecret: ecdhSecret, confirmationSalt: salt)
        let authValue = authValueNoOob()
        let provisionerConfirmation = try confirmationValue(
            confirmationKey: key,
            random: provisionerRandom,
            authValue: authValue
        )
        let deviceConfirmation = try confirmationValue(
            confirmationKey: key,
            random: deviceRandom,
            authValue: authValue
        )
        let secrets = try provisioningSecrets(
            ecdhSecret: ecdhSecret,
            confirmationSalt: salt,
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom
        )
        let encryptedData = try encryptedProvisioningData(
            sessionKey: secrets.sessionKey,
            sessionNonce: secrets.sessionNonce,
            networkKey: networkKey,
            keyIndex: keyIndex,
            flags: flags,
            ivIndex: ivIndex,
            unicastAddress: unicastAddress
        )

        return NativeNoOobProvisioningTranscript(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: provisionerPublicKey,
            devicePublicKey: devicePublicKey,
            provisionerPublicKeyPdu: publicKeyPdu,
            provisionerConfirmation: provisionerConfirmation,
            provisionerConfirmationPdu: try provisioningConfirmation(provisionerConfirmation),
            expectedDeviceConfirmation: deviceConfirmation,
            expectedDeviceConfirmationPdu: try provisioningConfirmation(deviceConfirmation),
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom,
            provisionerRandomPdu: try provisioningRandom(provisionerRandom),
            confirmationInputs: inputs,
            secrets: secrets,
            encryptedProvisioningData: encryptedData
        )
    }

    static func noOobProvisioningTranscript(
        invitePdu: [UInt8],
        capabilitiesPdu: [UInt8],
        provisionerKeyPair: NativeProvisioningKeyPair,
        devicePublicKey: [UInt8],
        provisionerRandom: [UInt8],
        deviceRandom: [UInt8],
        networkKey: [UInt8],
        keyIndex: Int,
        flags: Int,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws -> NativeNoOobProvisioningTranscript {
        try noOobProvisioningTranscript(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            provisionerPublicKey: provisionerKeyPair.publicKey,
            devicePublicKey: devicePublicKey,
            ecdhSecret: try ecdhSecret(
                privateKey: provisionerKeyPair.privateKey,
                peerPublicKey: devicePublicKey
            ),
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom,
            networkKey: networkKey,
            keyIndex: keyIndex,
            flags: flags,
            ivIndex: ivIndex,
            unicastAddress: unicastAddress
        )
    }

    static func provisioningPduSummary(_ pdu: [UInt8]) -> [String: Any] {
        guard let pduType = pdu.first else {
            return [
                "bytes": 0,
                "decode_error": "empty provisioning PDU",
            ]
        }

        var result: [String: Any] = [
            "bytes": pdu.count,
            "pdu_type": Int(pduType),
            "pdu_type_name": provisioningPduTypeName(pduType),
        ]
        if let capabilities = provisioningCapabilitiesSummary(pdu) {
            result["capabilities"] = capabilities
        } else if let start = provisioningStartSummary(pdu) {
            result["start"] = start
        } else if pduType == provisioningPublicKeyType {
            result["public_key_bytes"] = max(0, pdu.count - 1)
        } else if pduType == provisioningConfirmationType {
            result["confirmation_bytes"] = max(0, pdu.count - 1)
        } else if pduType == provisioningRandomType {
            result["random_bytes"] = max(0, pdu.count - 1)
        } else if pduType == provisioningDataType {
            result["encrypted_data_bytes"] = max(0, pdu.count - 9)
            result["mic_bytes"] = pdu.count >= 9 ? 8 : 0
        } else if pduType == provisioningCompleteType {
            result["complete"] = pdu.count == 1
        } else if pduType == provisioningFailedType {
            result["failed"] = provisioningFailedSummary(pdu)
        }
        return result
    }

    static func provisioningStartSummary(_ pdu: [UInt8]) -> [String: Any]? {
        guard pdu.count == 6, pdu[0] == provisioningStartType else {
            return nil
        }
        return [
            "pdu_type": Int(pdu[0]),
            "pdu_type_name": "provisioning_start",
            "algorithm": Int(pdu[1]),
            "algorithm_name": provisioningAlgorithmName(pdu[1]),
            "public_key": Int(pdu[2]),
            "public_key_name": pdu[2] == publicKeyOob ? "oob" : "in_band",
            "authentication_method": Int(pdu[3]),
            "authentication_method_name": authenticationMethodName(pdu[3]),
            "authentication_action": Int(pdu[4]),
            "authentication_size": Int(pdu[5]),
        ]
    }

    static func provisioningCapabilitiesSummary(_ pdu: [UInt8]) -> [String: Any]? {
        guard pdu.count == 12, pdu[0] == provisioningCapabilitiesType else {
            return nil
        }

        let algorithms = bigEndianUInt16(pdu, offset: 2)
        let publicKeyType = pdu[4]
        let staticOobType = pdu[5]
        let outputOobAction = bigEndianUInt16(pdu, offset: 7)
        let inputOobAction = bigEndianUInt16(pdu, offset: 10)

        return [
            "pdu_type": Int(pdu[0]),
            "pdu_type_name": "provisioning_capabilities",
            "number_of_elements": Int(pdu[1]),
            "algorithms": String(format: "0x%04x", algorithms),
            "algorithm_flags": algorithmFlags(algorithms),
            "public_key_type": Int(publicKeyType),
            "public_key_oob": (publicKeyType & 0x01) != 0,
            "static_oob_type": Int(staticOobType),
            "static_oob_available": (staticOobType & 0x01) != 0,
            "output_oob_size": Int(pdu[6]),
            "output_oob_action": String(format: "0x%04x", outputOobAction),
            "output_oob_actions": outputOobActionFlags(outputOobAction),
            "input_oob_size": Int(pdu[9]),
            "input_oob_action": String(format: "0x%04x", inputOobAction),
            "input_oob_actions": inputOobActionFlags(inputOobAction),
        ]
    }

    static func algorithmFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "fips_p256_elliptic_curve"),
            (0x0002, "fips_p256_hmac_sha256_aes_ccm"),
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func outputOobActionFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "blink"),
            (0x0002, "beep"),
            (0x0004, "vibrate"),
            (0x0008, "output_numeric"),
            (0x0010, "output_alphanumeric"),
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func inputOobActionFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "push"),
            (0x0002, "twist"),
            (0x0004, "input_numeric"),
            (0x0008, "input_alphanumeric"),
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func provisioningPduTypeName(_ value: UInt8) -> String {
        switch value {
        case 0x00: return "provisioning_invite"
        case 0x01: return "provisioning_capabilities"
        case 0x02: return "provisioning_start"
        case 0x03: return "provisioning_public_key"
        case 0x04: return "provisioning_input_complete"
        case 0x05: return "provisioning_confirmation"
        case 0x06: return "provisioning_random"
        case 0x07: return "provisioning_data"
        case 0x08: return "provisioning_complete"
        case 0x09: return "provisioning_failed"
        default: return "unknown"
        }
    }

    static func provisioningFailedSummary(_ pdu: [UInt8]) -> [String: Any] {
        guard pdu.count == 2, pdu[0] == provisioningFailedType else {
            return ["bytes": pdu.count]
        }
        return [
            "error_code": Int(pdu[1]),
            "error_name": provisioningFailedErrorName(pdu[1]),
        ]
    }

    static func provisioningFailedErrorName(_ value: UInt8) -> String {
        switch value {
        case 0x01: return "invalid_pdu"
        case 0x02: return "invalid_format"
        case 0x03: return "unexpected_pdu"
        case 0x04: return "confirmation_failed"
        case 0x05: return "out_of_resources"
        case 0x06: return "decryption_failed"
        case 0x07: return "unexpected_error"
        case 0x08: return "cannot_assign_addresses"
        default: return "unknown"
        }
    }

    static func provisioningAlgorithmName(_ value: UInt8) -> String {
        switch value {
        case algorithmFipsP256EllipticCurve: return "fips_p256_elliptic_curve"
        case 0x01: return "fips_p256_hmac_sha256_aes_ccm"
        default: return "unknown"
        }
    }

    static func authenticationMethodName(_ value: UInt8) -> String {
        switch value {
        case authenticationNoOob: return "no_oob"
        case authenticationStaticOob: return "static_oob"
        case authenticationOutputOob: return "output_oob"
        case authenticationInputOob: return "input_oob"
        default: return "unknown"
        }
    }

    private static func bigEndianUInt16(_ bytes: [UInt8], offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { index in
            UInt8((value >> UInt64((count - index - 1) * 8)) & 0xff)
        }
    }

    private static func validateAesKey(_ key: [UInt8], label: String) throws {
        guard key.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("\(label) must be 16 bytes")
        }
    }

    private static func validateEcdhSecret(_ secret: [UInt8]) throws {
        guard secret.count == 32 else {
            throw NativeMeshProvisioningError.invalidLength("ECDH secret must be 32 bytes")
        }
    }

    private static func validatePublicKey(_ publicKey: [UInt8], label: String) throws {
        guard publicKey.count == 64 else {
            throw NativeMeshProvisioningError.invalidLength("\(label) must be 64 bytes")
        }
    }

    private static func provisioningPayload(
        _ pdu: [UInt8],
        expectedType: UInt8,
        payloadLength: Int,
        label: String
    ) throws -> [UInt8] {
        guard pdu.count == payloadLength + 1, pdu.first == expectedType else {
            throw NativeMeshProvisioningError.invalidLength(
                "\(label) must be \(payloadLength + 1) bytes and type 0x\(String(format: "%02x", expectedType))"
            )
        }
        return Array(pdu.dropFirst())
    }

    private static func publicKeyCoordinates(_ publicKey: P256.KeyAgreement.PublicKey) throws -> [UInt8] {
        let x963 = Array(publicKey.x963Representation)
        guard x963.count == 65, x963.first == 0x04 else {
            throw NativeMeshProvisioningError.invalidLength("P-256 public key must be 65-byte uncompressed X9.63")
        }
        return Array(x963.dropFirst())
    }
}
