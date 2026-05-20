import Foundation

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        fputs("FAIL \(label): \(actual) != \(expected)\n", stderr)
        Foundation.exit(1)
    }
}

func expectHex(_ actual: [UInt8], _ expected: String, _ label: String) throws {
    expectEqual(NativeMeshCrypto.hex(actual), expected, label)
}

func expectThrows(_ label: String, _ block: () throws -> Void) {
    do {
        try block()
        fputs("FAIL \(label): expected throw\n", stderr)
        Foundation.exit(1)
    } catch {
    }
}

@main
struct NativeMeshCryptoTests {
    static func main() {
        do {
            try run()
            print("native mesh crypto tests passed")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run() throws {
        let cmacKey = try NativeMeshCrypto.bytes(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let zero = [UInt8](repeating: 0, count: 16)
        try expectHex(
            try NativeMeshCrypto.aes128EncryptBlock(key: cmacKey, block: zero),
            "7df76b0c1ab899b33e42f047b91b546f",
            "RFC4493 AES-128(key, zero)"
        )

        try expectHex(
            try NativeMeshCrypto.aesCmac(key: cmacKey, message: []),
            "bb1d6929e95937287fa37d129b756746",
            "RFC4493 CMAC example 1"
        )
        try expectHex(
            try NativeMeshCrypto.aesCmac(
                key: cmacKey,
                message: NativeMeshCrypto.bytes(hex: "6bc1bee22e409f96e93d7e117393172a")
            ),
            "070a16b46b4d4144f79bdd9dd04a287c",
            "RFC4493 CMAC example 2"
        )
        try expectHex(
            try NativeMeshCrypto.aesCmac(
                key: cmacKey,
                message: NativeMeshCrypto.bytes(
                    hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411"
                )
            ),
            "dfa66747de9ae63030ca32611497c827",
            "RFC4493 CMAC example 3"
        )
        try expectHex(
            try NativeMeshCrypto.aesCmac(
                key: cmacKey,
                message: NativeMeshCrypto.bytes(
                    hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
                )
            ),
            "51f0bebf7e3b9d92fc49741779363cfe",
            "RFC4493 CMAC example 4"
        )

        let ccmResult = try NativeMeshCrypto.aesCcmEncrypt(
            key: NativeMeshCrypto.bytes(hex: "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"),
            nonce: NativeMeshCrypto.bytes(hex: "00000003020100a0a1a2a3a4a5"),
            plaintext: NativeMeshCrypto.bytes(hex: "08090a0b0c0d0e0f101112131415161718191a1b1c1d1e"),
            aad: NativeMeshCrypto.bytes(hex: "0001020304050607"),
            micLength: 8
        )
        try expectHex(
            ccmResult.ciphertext + ccmResult.mic,
            "588c979a61c663d2f066d0c2c0f989806d5f6b61dac38417e8d12cfdf926e0",
            "RFC3610 CCM packet vector 1"
        )
        try expectHex(
            try NativeMeshCrypto.aesCcmDecrypt(
                key: NativeMeshCrypto.bytes(hex: "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"),
                nonce: NativeMeshCrypto.bytes(hex: "00000003020100a0a1a2a3a4a5"),
                ciphertext: ccmResult.ciphertext,
                mic: ccmResult.mic,
                aad: NativeMeshCrypto.bytes(hex: "0001020304050607")
            ),
            "08090a0b0c0d0e0f101112131415161718191a1b1c1d1e",
            "RFC3610 CCM packet vector 1 decrypt"
        )

        try expectHex(try NativeMeshCrypto.s1("smk2"), "4f90480c1871bfbffd16971f4d8d10b1", "Mesh s1(smk2)")

        let netKey = try NativeMeshCrypto.bytes(hex: "7dd7364cd842ad18c17c2b820c84c3d6")
        let k2 = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
        expectEqual(k2.nid, 0x68, "Mesh k2 NID")
        try expectHex(k2.encryptionKey, "0953fa93e7caac9638f58820220a398e", "Mesh k2 EncryptionKey")
        try expectHex(k2.privacyKey, "8b84eedec100067d670971dd2aa700cf", "Mesh k2 PrivacyKey")
        try expectHex(try NativeMeshCrypto.k3(n: netKey), "3ecaff672f673370", "Mesh k3 Network ID")

        let appKey = try NativeMeshCrypto.bytes(hex: "63964771734fbd76e3b40519d1d94a48")
        expectEqual(try NativeMeshCrypto.k4(n: appKey), 0x26, "Mesh k4 AID")

        try expectHex(
            try NativeMeshCrypto.vendorAccessMessage(
                opcode: 0x23,
                companyIdentifier: 0x0136,
                parameters: NativeMeshCrypto.bytes(hex: "aabb")
            ),
            "e33601aabb",
            "Mesh vendor access opcode"
        )
        try expectHex(
            try NativeMeshConfig.packedKeyIndexes(0x0123, 0x0456),
            "236145",
            "Config packed key indexes"
        )
        try expectHex(
            NativeMeshConfig.configCompositionDataGet(),
            "800800",
            "Config Composition Data Get"
        )
        try expectHex(
            NativeMeshConfig.configNodeReset(),
            "8049",
            "Config Node Reset"
        )
        try expectHex(
            try NativeMeshConfig.configAppKeyGet(netKeyIndex: 0),
            "80010000",
            "Config AppKey Get"
        )
        let configAppKeyAdd = try NativeMeshConfig.configAppKeyAdd(
            netKeyIndex: 0x0123,
            appKeyIndex: 0x0456,
            appKey: appKey
        )
        try expectHex(
            configAppKeyAdd,
            "0023614563964771734fbd76e3b40519d1d94a48",
            "Config AppKey Add"
        )
        try expectHex(
            try NativeMeshConfig.configModelAppBind(
                elementAddress: 0x1201,
                appKeyIndex: 0x0123,
                modelIdentifier: .sig(0x1000)
            ),
            "803d011223010010",
            "Config SIG Model App Bind"
        )
        try expectHex(
            try NativeMeshConfig.configModelAppBind(
                elementAddress: 0x1201,
                appKeyIndex: 0x0123,
                modelIdentifier: .vendor(companyIdentifier: 0x0136, modelIdentifier: 0x0001)
            ),
            "803d0112230136010100",
            "Config Vendor Model App Bind"
        )
        expectEqual(
            NativeMeshConfig.requiresSegmentedLowerTransport(accessMessage: configAppKeyAdd),
            true,
            "Config AppKey Add requires segmentation"
        )
        expectEqual(
            NativeMeshConfig.requiresSegmentedLowerTransport(accessMessage: NativeMeshConfig.configCompositionDataGet()),
            false,
            "Config Composition Data Get is unsegmented"
        )
        let amaranComposition = try NativeMeshConfig.compositionDataPage0(
            NativeMeshCrypto.bytes(hex: "0011020102333369000A0000000A01000002000300001002100410061007100013011311020000")
        )
        expectEqual(amaranComposition.includedPageByte, true, "Composition Data Status page byte")
        expectEqual(amaranComposition.cid, 0x0211, "Composition CID")
        expectEqual(amaranComposition.pid, 0x0201, "Composition PID")
        expectEqual(amaranComposition.vid, 0x3333, "Composition VID")
        expectEqual(amaranComposition.crpl, 0x0069, "Composition CRPL")
        expectEqual(amaranComposition.features, 0x000a, "Composition features")
        expectEqual(amaranComposition.elements.count, 1, "Composition element count")
        expectEqual(amaranComposition.elements[0].location, 0x0000, "Composition primary element location")
        expectEqual(amaranComposition.elements[0].sigModels.count, 10, "Composition SIG model count")
        expectEqual(amaranComposition.elements[0].sigModels[0], 0x0000, "Composition Config Server model")
        expectEqual(amaranComposition.elements[0].sigModels[3], 0x1000, "Composition Generic OnOff Server model")
        expectEqual(amaranComposition.elements[0].vendorModels.count, 1, "Composition vendor model count")
        expectEqual(amaranComposition.elements[0].vendorModels[0].companyIdentifier, 0x0211, "Composition vendor company")
        expectEqual(amaranComposition.elements[0].vendorModels[0].modelIdentifier, 0x0000, "Composition vendor model")
        expectEqual(amaranComposition.firstVendorModelBindingTarget?.elementIndex, 0, "Composition bind element index")
        expectEqual(amaranComposition.firstVendorModelBindingTarget?.model.companyIdentifier, 0x0211, "Composition bind company")
        try expectHex(
            try NativeMeshConfig.configModelAppBind(
                elementAddress: 0x0002,
                appKeyIndex: 0,
                modelIdentifier: .vendor(companyIdentifier: 0x0211, modelIdentifier: 0x0000)
            ),
            "803d0200000011020000",
            "Config amaran Vendor Model App Bind"
        )
        let appKeyStatus = try NativeMeshConfig.configAppKeyStatus(
            NativeMeshCrypto.bytes(hex: "800300236145")
        )
        expectEqual(appKeyStatus.status, 0, "Config AppKey Status status")
        expectEqual(NativeMeshConfig.statusName(appKeyStatus.status), "success", "Config AppKey Status name")
        expectEqual(appKeyStatus.netKeyIndex, 0x0123, "Config AppKey Status NetKeyIndex")
        expectEqual(appKeyStatus.appKeyIndex, 0x0456, "Config AppKey Status AppKeyIndex")
        let appKeyList = try NativeMeshConfig.configAppKeyList(
            NativeMeshCrypto.bytes(hex: "8002000000001000")
        )
        expectEqual(appKeyList.status, 0, "Config AppKey List status")
        expectEqual(appKeyList.netKeyIndex, 0, "Config AppKey List NetKeyIndex")
        expectEqual(appKeyList.appKeyIndexes, [0, 1], "Config AppKey List indexes")
        let compositionStatus = try NativeMeshConfig.configCompositionDataStatus(
            NativeMeshCrypto.bytes(hex: "020011020102333369000A0000000A01000002000300001002100410061007100013011311020000")
        )
        expectEqual(compositionStatus.includedPageByte, true, "Config Composition Data Status page byte")
        expectEqual(compositionStatus.cid, 0x0211, "Config Composition Data Status CID")
        expectEqual(compositionStatus.elements.count, 1, "Config Composition Data Status elements")
        expectEqual(
            compositionStatus.firstVendorModelBindingTarget?.model.companyIdentifier,
            0x0211,
            "Config Composition Data Status vendor company"
        )
        let modelAppStatus = try NativeMeshConfig.configModelAppStatus(
            NativeMeshCrypto.bytes(hex: "803e000200000011020000")
        )
        expectEqual(modelAppStatus.status, 0, "Config Model App Status status")
        expectEqual(modelAppStatus.elementAddress, 0x0002, "Config Model App Status element")
        expectEqual(modelAppStatus.appKeyIndex, 0, "Config Model App Status AppKeyIndex")
        switch modelAppStatus.modelIdentifier {
        case .vendor(let companyIdentifier, let modelIdentifier):
            expectEqual(companyIdentifier, 0x0211, "Config Model App Status company")
            expectEqual(modelIdentifier, 0x0000, "Config Model App Status model")
        case .sig:
            fputs("FAIL Config Model App Status model: expected vendor model\n", stderr)
            Foundation.exit(1)
        }
        try expectHex(
            NativeTelinkControl.onOffPacket(turnOn: false),
            "8c00000000000000008c",
            "Telink 0x26 off packet"
        )
        try expectHex(
            NativeTelinkControl.onOffPacket(turnOn: true),
            "8d00000000000000018c",
            "Telink 0x26 on packet"
        )
        try expectHex(
            try NativeTelinkControl.brightnessPacket(telinkIntensity: 200),
            "c100000000000000328f",
            "Telink 0x26 brightness packet"
        )
        try expectHex(
            try NativeTelinkControl.brightnessPacket(telinkIntensity: 201),
            "0100000000000040328f",
            "Telink 0x26 brightness low-bit packet"
        )
        try expectHex(
            try NativeTelinkControl.cctPacket(telinkCct: 560, telinkIntensity: 200, gm: 10, gmFlag: 0),
            "f7000000002000233282",
            "Telink 0x26 CCT packet"
        )
        try expectHex(
            try NativeTelinkControlCommand.parse(spec: "cct:5600:20:10:0").accessMessage(),
            "26f7000000002000233282",
            "Telink 0x26 CCT access message"
        )
        try expectHex(
            NativeTelinkControl.statusRequestPacket(),
            "0e00000000000000000e",
            "Telink 0x26 status request packet"
        )
        try expectHex(
            try NativeTelinkControlCommand.parse(spec: "status").accessMessage(),
            "260e00000000000000000e",
            "Telink 0x26 status access message"
        )
        let decodedStatus = NativeTelinkControl.decodePacket(
            try NativeMeshCrypto.bytes(hex: "99010000004001233202")
        )
        let cctStatus = decodedStatus?["cct"] as? [String: Any]
        expectEqual(decodedStatus?["check_sum"] as? Int, 153, "Telink status checksum value")
        expectEqual(decodedStatus?["checksum_valid"] as? Bool, true, "Telink status checksum")
        expectEqual(decodedStatus?["command_type"] as? Int, 2, "Telink status command type")
        expectEqual(cctStatus?["intensity"] as? Int, 200, "Telink status intensity")
        expectEqual(cctStatus?["cct_decoded"] as? Int, 560, "Telink status CCT")
        expectEqual(cctStatus?["gm_decoded"] as? Int, 10, "Telink status green-magenta")
        expectEqual(cctStatus?["sleep_mode"] as? Int, 1, "Telink status sleep mode")
        let provisioning = NativeMeshProvisioning.provisioningServiceDataSummary(
            try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff000212345678")
        )
        expectEqual(provisioning["bytes"] as? Int, 22, "PB-GATT service data length")
        expectEqual(provisioning["device_uuid"] as? String, "00112233445566778899aabbccddeeff", "PB-GATT device UUID")
        expectEqual(provisioning["oob_info"] as? String, "0x0002", "PB-GATT OOB info")
        expectEqual(
            provisioning["oob_info_flags"] as? [String],
            ["electronic_or_uri"],
            "PB-GATT OOB info flags"
        )
        expectEqual(provisioning["uri_hash"] as? String, "12345678", "PB-GATT URI hash")
        try expectHex(
            try NativeMeshProvisioning.provisioningInvite(attentionDuration: 5),
            "0005",
            "PB-GATT Provisioning Invite PDU"
        )
        try expectHex(
            NativeMeshProvisioning.completeProxyPdu(provisioningPdu: [0x00, 0x05]),
            "030005",
            "PB-GATT complete Proxy PDU"
        )
        expectEqual(
            try NativeMeshProvisioning.segmentedProxyPdus(
                provisioningPdu: [0x00, 0x05],
                maxSegmentPayloadBytes: 20
            ),
            [[0x03, 0x00, 0x05]],
            "PB-GATT single-segment Proxy PDU"
        )
        expectEqual(
            NativeMeshProvisioning.provisioningPduSummary([0x00, 0x05])["pdu_type_name"] as? String,
            "provisioning_invite",
            "PB-GATT PDU type name"
        )
        let capabilities = NativeMeshProvisioning.provisioningCapabilitiesSummary(
            try NativeMeshCrypto.bytes(hex: "01020003010104000902000c")
        )
        expectEqual(capabilities?["number_of_elements"] as? Int, 2, "PB-GATT capabilities elements")
        expectEqual(
            capabilities?["algorithm_flags"] as? [String],
            ["fips_p256_elliptic_curve", "fips_p256_hmac_sha256_aes_ccm"],
            "PB-GATT capabilities algorithms"
        )
        expectEqual(capabilities?["public_key_oob"] as? Bool, true, "PB-GATT capabilities public key")
        expectEqual(capabilities?["static_oob_available"] as? Bool, true, "PB-GATT capabilities static OOB")
        expectEqual(capabilities?["output_oob_size"] as? Int, 4, "PB-GATT capabilities output size")
        expectEqual(
            capabilities?["output_oob_actions"] as? [String],
            ["blink", "output_numeric"],
            "PB-GATT capabilities output actions"
        )
        expectEqual(capabilities?["input_oob_size"] as? Int, 2, "PB-GATT capabilities input size")
        expectEqual(
            capabilities?["input_oob_actions"] as? [String],
            ["input_numeric", "input_alphanumeric"],
            "PB-GATT capabilities input actions"
        )
        let capabilitiesSummary = NativeMeshProvisioning.provisioningPduSummary(
            try NativeMeshCrypto.bytes(hex: "01020003010104000902000c")
        )
        let nestedCapabilities = capabilitiesSummary["capabilities"] as? [String: Any]
        expectEqual(
            nestedCapabilities?["pdu_type_name"] as? String,
            "provisioning_capabilities",
            "PB-GATT nested capabilities summary"
        )
        try expectHex(
            try NativeMeshProvisioning.provisioningStart(
                algorithm: 0,
                publicKey: 0,
                authenticationMethod: 0,
                authenticationAction: 0,
                authenticationSize: 0
            ),
            "020000000000",
            "PB-GATT no-OOB Provisioning Start PDU"
        )
        try expectHex(
            try NativeMeshProvisioning.noOobProvisioningStart(
                capabilitiesPdu: try NativeMeshCrypto.bytes(hex: "010100010000000000000000")
            ),
            "020000000000",
            "PB-GATT no-OOB Provisioning Start selection"
        )
        let startSummary = NativeMeshProvisioning.provisioningPduSummary(
            try NativeMeshCrypto.bytes(hex: "020000000000")
        )
        let nestedStart = startSummary["start"] as? [String: Any]
        expectEqual(nestedStart?["algorithm_name"] as? String, "fips_p256_elliptic_curve", "PB-GATT start algorithm")
        expectEqual(nestedStart?["public_key_name"] as? String, "in_band", "PB-GATT start public key")
        expectEqual(nestedStart?["authentication_method_name"] as? String, "no_oob", "PB-GATT start authentication")
        let samplePublicKey = Array(0..<64).map(UInt8.init)
        try expectHex(
            try NativeMeshProvisioning.provisioningPublicKey(samplePublicKey),
            "03000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
            "PB-GATT Provisioning Public Key PDU"
        )
        expectEqual(
            NativeMeshProvisioning.provisioningPduSummary([0x03] + samplePublicKey)["public_key_bytes"] as? Int,
            64,
            "PB-GATT public key summary"
        )
        let segmentedPublicKey = try NativeMeshProvisioning.segmentedProxyPdus(
            provisioningPdu: try NativeMeshProvisioning.provisioningPublicKey(samplePublicKey),
            maxSegmentPayloadBytes: 20
        )
        expectEqual(segmentedPublicKey.count, 4, "PB-GATT segmented Public Key segment count")
        expectEqual(segmentedPublicKey.map(\.count), [21, 21, 21, 6], "PB-GATT segmented Public Key sizes")
        expectEqual(segmentedPublicKey.map { $0[0] }, [0x43, 0x83, 0x83, 0xc3], "PB-GATT segmented Public Key SAR")
        try expectHex(
            try NativeMeshProvisioning.reassembleProxyPdus(segmentedPublicKey),
            "03000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
            "PB-GATT segmented Public Key reassembly"
        )
        var publicKeyReassembler = NativeProvisioningProxyPduReassembler()
        let firstPublicKeySegment = try publicKeyReassembler.receive(segmentedPublicKey[0])
        expectEqual(firstPublicKeySegment.pending, true, "PB-GATT Public Key reassembly pending")
        expectEqual(firstPublicKeySegment.segmentCount, 1, "PB-GATT Public Key first segment count")
        expectEqual(firstPublicKeySegment.provisioningPdu, nil, "PB-GATT Public Key first segment has no PDU")
        _ = try publicKeyReassembler.receive(segmentedPublicKey[1])
        _ = try publicKeyReassembler.receive(segmentedPublicKey[2])
        let completedPublicKeyReassembly = try publicKeyReassembler.receive(segmentedPublicKey[3])
        expectEqual(completedPublicKeyReassembly.pending, false, "PB-GATT Public Key reassembly complete")
        expectEqual(completedPublicKeyReassembly.segmentCount, 4, "PB-GATT Public Key complete segment count")
        expectEqual(
            completedPublicKeyReassembly.provisioningPdu,
            try NativeMeshProvisioning.provisioningPublicKey(samplePublicKey),
            "PB-GATT incremental Public Key reassembly"
        )
        let completedInviteReassembly = try publicKeyReassembler.receive([0x03, 0x00, 0x05])
        expectEqual(completedInviteReassembly.segmentCount, 1, "PB-GATT complete Invite segment count")
        expectEqual(completedInviteReassembly.provisioningPdu, [0x00, 0x05], "PB-GATT complete Invite reassembly")
        let provisionerKeyPair = try NativeMeshProvisioning.generateProvisionerKeyPair()
        let deviceKeyPair = try NativeMeshProvisioning.generateProvisionerKeyPair()
        expectEqual(provisionerKeyPair.publicKey.count, 64, "PB-GATT provisioner public key length")
        expectEqual(deviceKeyPair.publicKey.count, 64, "PB-GATT device public key length")
        try expectHex(
            try NativeMeshProvisioning.provisioningPublicKey(provisionerKeyPair.publicKey).prefix(1).map { $0 },
            "03",
            "PB-GATT generated public key PDU type"
        )
        let provisionerSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: provisionerKeyPair.privateKey,
            peerPublicKey: deviceKeyPair.publicKey
        )
        let deviceSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: deviceKeyPair.privateKey,
            peerPublicKey: provisionerKeyPair.publicKey
        )
        expectEqual(provisionerSecret.count, 32, "PB-GATT ECDH secret length")
        expectEqual(provisionerSecret, deviceSecret, "PB-GATT ECDH shared secret agreement")
        expectEqual(provisionerSecret == [UInt8](repeating: 0, count: 32), false, "PB-GATT ECDH secret is nonzero")
        let sampleInvite = try NativeMeshProvisioning.provisioningInvite(attentionDuration: 5)
        let sampleCapabilities = try NativeMeshCrypto.bytes(hex: "010100010000000000000000")
        expectEqual(
            try NativeMeshProvisioning.provisioningCapabilities(elementCount: 1),
            sampleCapabilities,
            "PB-GATT generated no-OOB capabilities"
        )
        let sampleStart = try NativeMeshProvisioning.noOobProvisioningStart(capabilitiesPdu: sampleCapabilities)
        let sampleDevicePublicKey = Array(64..<128).map(UInt8.init)
        let sampleEcdhSecret = try NativeMeshCrypto.bytes(
            hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )
        let sampleProvisionerRandom = try NativeMeshCrypto.bytes(hex: "202122232425262728292a2b2c2d2e2f")
        let sampleDeviceRandom = try NativeMeshCrypto.bytes(hex: "303132333435363738393a3b3c3d3e3f")
        let sampleConfirmationInputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: sampleInvite,
            capabilitiesPdu: sampleCapabilities,
            startPdu: sampleStart,
            provisionerPublicKey: samplePublicKey,
            devicePublicKey: sampleDevicePublicKey
        )
        try expectHex(
            sampleConfirmationInputs,
            "0501000100000000000000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f",
            "PB-GATT confirmation inputs"
        )
        let sampleConfirmationSalt = try NativeMeshProvisioning.confirmationSalt(
            confirmationInputs: sampleConfirmationInputs
        )
        try expectHex(sampleConfirmationSalt, "81c16d5e7d46f07e670f29f2185f5482", "PB-GATT confirmation salt")
        let sampleConfirmationKey = try NativeMeshProvisioning.confirmationKey(
            ecdhSecret: sampleEcdhSecret,
            confirmationSalt: sampleConfirmationSalt
        )
        try expectHex(sampleConfirmationKey, "d94e889c79b2ed38c11d5af37e9babc3", "PB-GATT confirmation key")
        try expectHex(
            try NativeMeshProvisioning.confirmationValue(
                confirmationKey: sampleConfirmationKey,
                random: sampleProvisionerRandom,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            "b61a5036306042842d3384a5ef32ac1c",
            "PB-GATT no-OOB confirmation value"
        )
        try expectHex(
            try NativeMeshProvisioning.provisioningConfirmation(
                try NativeMeshProvisioning.confirmationValue(
                    confirmationKey: sampleConfirmationKey,
                    random: sampleProvisionerRandom,
                    authValue: NativeMeshProvisioning.authValueNoOob()
                )
            ),
            "05b61a5036306042842d3384a5ef32ac1c",
            "PB-GATT Provisioning Confirmation PDU"
        )
        try expectHex(
            try NativeMeshProvisioning.provisioningRandom(sampleProvisionerRandom),
            "06202122232425262728292a2b2c2d2e2f",
            "PB-GATT Provisioning Random PDU"
        )
        let sampleSecrets = try NativeMeshProvisioning.provisioningSecrets(
            ecdhSecret: sampleEcdhSecret,
            confirmationSalt: sampleConfirmationSalt,
            provisionerRandom: sampleProvisionerRandom,
            deviceRandom: sampleDeviceRandom
        )
        try expectHex(sampleSecrets.provisioningSalt, "667dc0b6183dea931f3882a4f4f4b5c2", "PB-GATT provisioning salt")
        try expectHex(sampleSecrets.sessionKey, "bd0a2c3efdedeb3ca71ae352873b0293", "PB-GATT session key")
        try expectHex(sampleSecrets.sessionNonce, "cb44f0b3a500250e79fbd4c075", "PB-GATT session nonce")
        try expectHex(sampleSecrets.deviceKey, "0b9dc768a7a5debf33f536ccb83edefa", "PB-GATT device key")
        let sampleEncryptedProvisioningData = try NativeMeshProvisioning.encryptedProvisioningData(
            sessionKey: sampleSecrets.sessionKey,
            sessionNonce: sampleSecrets.sessionNonce,
            networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            keyIndex: 0x0123,
            flags: 0x00,
            ivIndex: 0x01020304,
            unicastAddress: 0x1201
        )
        try expectHex(
            sampleEncryptedProvisioningData.provisioningData,
            "00112233445566778899aabbccddeeff012300010203041201",
            "PB-GATT provisioning data plaintext"
        )
        try expectHex(
            sampleEncryptedProvisioningData.encryptedProvisioningData,
            "6ea5b884e4ef3a18531053a6820eedf7f0a287d34b020bda37",
            "PB-GATT encrypted provisioning data"
        )
        try expectHex(
            sampleEncryptedProvisioningData.provisioningDataMic,
            "679a315aadd64afa",
            "PB-GATT provisioning data MIC"
        )
        try expectHex(
            sampleEncryptedProvisioningData.provisioningDataPdu,
            "076ea5b884e4ef3a18531053a6820eedf7f0a287d34b020bda37679a315aadd64afa",
            "PB-GATT provisioning data PDU"
        )
        let sampleDecryptedProvisioningData = try NativeMeshProvisioning.decryptProvisioningData(
            sampleEncryptedProvisioningData.provisioningDataPdu,
            sessionKey: sampleSecrets.sessionKey,
            sessionNonce: sampleSecrets.sessionNonce
        )
        try expectHex(
            sampleDecryptedProvisioningData.networkKey,
            "00112233445566778899aabbccddeeff",
            "PB-GATT decrypt provisioning data NetKey"
        )
        expectEqual(sampleDecryptedProvisioningData.keyIndex, 0x0123, "PB-GATT decrypt provisioning data key index")
        expectEqual(sampleDecryptedProvisioningData.flags, 0x00, "PB-GATT decrypt provisioning data flags")
        expectEqual(sampleDecryptedProvisioningData.ivIndex, 0x01020304, "PB-GATT decrypt provisioning data IV index")
        expectEqual(sampleDecryptedProvisioningData.unicastAddress, 0x1201, "PB-GATT decrypt provisioning data unicast")
        let sampleTranscript = try NativeMeshProvisioning.noOobProvisioningTranscript(
            invitePdu: sampleInvite,
            capabilitiesPdu: sampleCapabilities,
            provisionerPublicKey: samplePublicKey,
            devicePublicKey: sampleDevicePublicKey,
            ecdhSecret: sampleEcdhSecret,
            provisionerRandom: sampleProvisionerRandom,
            deviceRandom: sampleDeviceRandom,
            networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            keyIndex: 0x0123,
            flags: 0x00,
            ivIndex: 0x01020304,
            unicastAddress: 0x1201
        )
        expectEqual(sampleTranscript.startPdu, sampleStart, "PB-GATT transcript Start PDU")
        expectEqual(sampleTranscript.confirmationInputs, sampleConfirmationInputs, "PB-GATT transcript inputs")
        expectEqual(sampleTranscript.secrets, sampleSecrets, "PB-GATT transcript secrets")
        try expectHex(
            sampleTranscript.provisionerConfirmationPdu,
            "05b61a5036306042842d3384a5ef32ac1c",
            "PB-GATT transcript confirmation PDU"
        )
        expectEqual(
            sampleTranscript.encryptedProvisioningData,
            sampleEncryptedProvisioningData,
            "PB-GATT transcript encrypted provisioning data"
        )
        let sampleDeviceRandomPdu = try NativeMeshProvisioning.provisioningRandom(sampleDeviceRandom)
        expectEqual(
            try NativeMeshProvisioning.verifyConfirmationPdu(
                confirmationPdu: sampleTranscript.expectedDeviceConfirmationPdu,
                randomPdu: sampleDeviceRandomPdu,
                confirmationKey: sampleTranscript.secrets.confirmationKey,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            true,
            "PB-GATT transcript device confirmation verification"
        )
        var wrongDeviceConfirmation = sampleTranscript.expectedDeviceConfirmationPdu
        wrongDeviceConfirmation[1] ^= 0x01
        expectEqual(
            try NativeMeshProvisioning.verifyConfirmationPdu(
                confirmationPdu: wrongDeviceConfirmation,
                randomPdu: sampleDeviceRandomPdu,
                confirmationKey: sampleTranscript.secrets.confirmationKey,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            false,
            "PB-GATT transcript rejects wrong device confirmation"
        )
        let liveStyleProvisioner = try NativeMeshProvisioning.generateProvisionerKeyPair()
        let liveStyleDevice = try NativeMeshProvisioning.generateProvisionerKeyPair()
        let liveStyleTranscript = try NativeMeshProvisioning.noOobProvisioningTranscript(
            invitePdu: sampleInvite,
            capabilitiesPdu: sampleCapabilities,
            provisionerKeyPair: liveStyleProvisioner,
            devicePublicKey: liveStyleDevice.publicKey,
            provisionerRandom: try NativeMeshProvisioning.generateProvisioningRandom(),
            deviceRandom: try NativeMeshProvisioning.generateProvisioningRandom(),
            networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            keyIndex: 0x0123,
            flags: 0x00,
            ivIndex: 0x01020304,
            unicastAddress: 0x1201
        )
        expectEqual(liveStyleTranscript.provisionerPublicKeyPdu.first, 0x03, "PB-GATT live transcript public key PDU")
        expectEqual(
            liveStyleTranscript.encryptedProvisioningData.provisioningDataPdu.first,
            0x07,
            "PB-GATT live transcript provisioning data PDU"
        )
        expectEqual(
            try NativeMeshProvisioning.verifyConfirmationPdu(
                confirmationPdu: liveStyleTranscript.expectedDeviceConfirmationPdu,
                randomPdu: try NativeMeshProvisioning.provisioningRandom(liveStyleTranscript.deviceRandom),
                confirmationKey: liveStyleTranscript.secrets.confirmationKey,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            true,
            "PB-GATT live transcript device confirmation verification"
        )
        var session = try NativeNoOobProvisioningSession(
            provisionerKeyPair: liveStyleProvisioner,
            provisionerRandom: liveStyleTranscript.provisionerRandom,
            networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            keyIndex: 0x0123,
            flags: 0x00,
            ivIndex: 0x01020304,
            unicastAddress: 0x1201
        )
        expectEqual(session.state, .idle, "PB-GATT session starts idle")
        expectEqual(try session.start(attentionDuration: 5), sampleInvite, "PB-GATT session Invite")
        expectEqual(session.state, .awaitingCapabilities, "PB-GATT session awaits Capabilities")
        let sessionStartResult = try session.receive(sampleCapabilities)
        expectEqual(sessionStartResult.state, .awaitingDevicePublicKey, "PB-GATT session awaits Public Key")
        expectEqual(
            sessionStartResult.outgoingPdus,
            [sampleStart, liveStyleTranscript.provisionerPublicKeyPdu],
            "PB-GATT session Start/Public Key output"
        )
        let liveStyleDevicePublicKeyPdu = try NativeMeshProvisioning.provisioningPublicKey(liveStyleDevice.publicKey)
        expectEqual(
            try NativeMeshProvisioning.publicKeyValuePdu(liveStyleDevicePublicKeyPdu),
            liveStyleDevice.publicKey,
            "PB-GATT public key PDU payload"
        )
        let sessionConfirmationResult = try session.receive(liveStyleDevicePublicKeyPdu)
        expectEqual(
            sessionConfirmationResult.outgoingPdus,
            [liveStyleTranscript.provisionerConfirmationPdu],
            "PB-GATT session Confirmation output"
        )
        expectEqual(
            sessionConfirmationResult.state,
            .awaitingDeviceConfirmation,
            "PB-GATT session awaits device Confirmation"
        )
        let sessionRandomResult = try session.receive(liveStyleTranscript.expectedDeviceConfirmationPdu)
        expectEqual(
            sessionRandomResult.outgoingPdus,
            [liveStyleTranscript.provisionerRandomPdu],
            "PB-GATT session Random output"
        )
        expectEqual(sessionRandomResult.state, .awaitingDeviceRandom, "PB-GATT session awaits device Random")
        let sessionDataResult = try session.receive(
            try NativeMeshProvisioning.provisioningRandom(liveStyleTranscript.deviceRandom)
        )
        expectEqual(
            sessionDataResult.outgoingPdus,
            [liveStyleTranscript.encryptedProvisioningData.provisioningDataPdu],
            "PB-GATT session Provisioning Data output"
        )
        expectEqual(sessionDataResult.state, .awaitingComplete, "PB-GATT session awaits Complete")
        expectEqual(session.transcript, liveStyleTranscript, "PB-GATT session transcript")
        let sessionCompleteResult = try session.receive([NativeMeshProvisioning.provisioningCompleteType])
        expectEqual(sessionCompleteResult.completed, true, "PB-GATT session completes")
        expectEqual(sessionCompleteResult.state, .complete, "PB-GATT session complete state")
        var captureSession = try NativeProvisioneeCaptureSession(
            deviceKeyPair: liveStyleDevice,
            deviceRandom: liveStyleTranscript.deviceRandom
        )
        expectEqual(captureSession.state, .awaitingInvite, "PB-GATT capture session starts awaiting Invite")
        let captureCapabilities = try captureSession.receive(sampleInvite)
        expectEqual(captureCapabilities.outgoingPdus, [sampleCapabilities], "PB-GATT capture Capabilities output")
        expectEqual(captureCapabilities.state, .awaitingStart, "PB-GATT capture session awaits Start")
        let captureStart = try captureSession.receive(sampleStart)
        expectEqual(captureStart.outgoingPdus, [], "PB-GATT capture Start output")
        expectEqual(captureStart.state, .awaitingProvisionerPublicKey, "PB-GATT capture session awaits Public Key")
        let capturePublicKey = try captureSession.receive(liveStyleTranscript.provisionerPublicKeyPdu)
        expectEqual(capturePublicKey.outgoingPdus, [liveStyleDevicePublicKeyPdu], "PB-GATT capture Public Key output")
        let captureConfirmation = try captureSession.receive(liveStyleTranscript.provisionerConfirmationPdu)
        expectEqual(
            captureConfirmation.outgoingPdus,
            [liveStyleTranscript.expectedDeviceConfirmationPdu],
            "PB-GATT capture Confirmation output"
        )
        let captureRandom = try captureSession.receive(liveStyleTranscript.provisionerRandomPdu)
        expectEqual(
            captureRandom.outgoingPdus,
            [try NativeMeshProvisioning.provisioningRandom(liveStyleTranscript.deviceRandom)],
            "PB-GATT capture Random output"
        )
        let captureData = try captureSession.receive(liveStyleTranscript.encryptedProvisioningData.provisioningDataPdu)
        expectEqual(captureData.completed, true, "PB-GATT capture completes")
        expectEqual(captureData.state, .complete, "PB-GATT capture complete state")
        expectEqual(
            captureData.outgoingPdus,
            [[NativeMeshProvisioning.provisioningCompleteType]],
            "PB-GATT capture Complete output"
        )
        expectEqual(
            captureData.capturedData?.networkKey ?? [],
            Array(liveStyleTranscript.encryptedProvisioningData.provisioningData.prefix(16)),
            "PB-GATT capture NetKey"
        )
        expectEqual(captureData.capturedData?.keyIndex, 0x0123, "PB-GATT capture key index")
        expectEqual(captureData.capturedData?.unicastAddress, 0x1201, "PB-GATT capture unicast")
        expectEqual(captureSession.deviceKey, liveStyleTranscript.secrets.deviceKey, "PB-GATT capture DeviceKey")
        var failedSession = try NativeNoOobProvisioningSession(
            provisionerKeyPair: liveStyleProvisioner,
            provisionerRandom: liveStyleTranscript.provisionerRandom,
            networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            keyIndex: 0x0123,
            flags: 0x00,
            ivIndex: 0x01020304,
            unicastAddress: 0x1201
        )
        _ = try failedSession.start(attentionDuration: 5)
        let failedSessionResult = try failedSession.receive([0x09, 0x04])
        expectEqual(failedSessionResult.state, .failed, "PB-GATT session failed state")
        expectEqual(
            failedSessionResult.failedErrorName,
            "confirmation_failed",
            "PB-GATT session failed reason"
        )
        let confirmationSummary = NativeMeshProvisioning.provisioningPduSummary(
            sampleTranscript.provisionerConfirmationPdu
        )
        let randomSummary = NativeMeshProvisioning.provisioningPduSummary(sampleTranscript.provisionerRandomPdu)
        let dataSummary = NativeMeshProvisioning.provisioningPduSummary(
            sampleTranscript.encryptedProvisioningData.provisioningDataPdu
        )
        expectEqual(confirmationSummary["confirmation_bytes"] as? Int, 16, "PB-GATT confirmation summary")
        expectEqual(randomSummary["random_bytes"] as? Int, 16, "PB-GATT random summary")
        expectEqual(dataSummary["mic_bytes"] as? Int, 8, "PB-GATT data summary")
        let failedSummary = NativeMeshProvisioning.provisioningPduSummary([0x09, 0x04])["failed"] as? [String: Any]
        expectEqual(failedSummary?["error_name"] as? String, "confirmation_failed", "PB-GATT failed summary")
        let nativeStateFixture = NativeProvisionedFixtureState(
            uuid: "fixture-001",
            macAddress: "a4c138123c21",
            code: "400M5",
            name: nil,
            nodeAddress: 0x1201,
            deviceKey: sampleSecrets.deviceKey,
            deviceUUID: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            compositionData: try NativeMeshCrypto.bytes(hex: "010203"),
            updateTime: "2026-05-18T00:00:00Z"
        )
        let nativeStatePayload = try NativeMeshState.provisionedPayload(
            meshUUID: "mesh-001",
            netKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            appKey: appKey,
            fixture: nativeStateFixture,
            provisionedAt: "2026-05-18T00:00:00Z",
            ivIndex: 0x01020304,
            sequenceNext: 1,
            sourceAddress: 1
        )
        try NativeMeshState.validatePayload(nativeStatePayload)
        expectEqual(nativeStatePayload["schema_version"] as? Int, 1, "Native state schema version")
        let nativeStateSource = nativeStatePayload["source"] as? [String: Any]
        expectEqual(nativeStateSource?["type"] as? String, "native_provisioning", "Native state source")
        let nativeStateMesh = nativeStatePayload["mesh"] as? [String: Any]
        expectEqual(nativeStateMesh?["uuid"] as? String, "mesh-001", "Native state mesh UUID")
        try expectHex(
            try NativeMeshCrypto.bytes(hex: nativeStateMesh?["net_key"] as? String ?? ""),
            "00112233445566778899aabbccddeeff",
            "Native state mesh net key"
        )
        let nativeStateFixtures = nativeStatePayload["fixtures"] as? [[String: Any]]
        let nativeStateFirstFixture = nativeStateFixtures?.first
        expectEqual(nativeStateFixtures?.count, 1, "Native state fixture count")
        expectEqual(nativeStateFirstFixture?["mac_address"] as? String, "A4:C1:38:12:3C:21", "Native state MAC")
        expectEqual(nativeStateFirstFixture?["name"] as? String, "400M5-123C21", "Native state generated name")
        expectEqual(nativeStateFirstFixture?["node_address"] as? Int, 0x1201, "Native state node address")
        expectEqual(
            nativeStateFirstFixture?["device_key"] as? String,
            NativeMeshCrypto.hex(sampleSecrets.deviceKey),
            "Native state device key field"
        )
        let nativeStateRuntime = nativeStatePayload["runtime"] as? [String: Any]
        expectEqual(nativeStateRuntime?["iv_index"] as? Int, 0x01020304, "Native state IV index")
        expectEqual(nativeStateRuntime?["source_address"] as? Int, 3, "Native state source address")
        expectEqual(nativeStateRuntime?["telink_source_address"] as? Int, 1, "Native state Telink source address")
        expectEqual(nativeStateRuntime?["sequence_next"] as? Int, 1, "Native state sequence")
        let nativeStateEncoded = try NativeMeshState.encodedPayload(nativeStatePayload)
        let nativeStateDecoded = try JSONSerialization.jsonObject(with: nativeStateEncoded) as? [String: Any]
        try NativeMeshState.validatePayload(nativeStateDecoded ?? [:])
        let nativeStatePath = "\(NSTemporaryDirectory())amaran-state-\(UUID().uuidString).json"
        defer {
            try? FileManager.default.removeItem(atPath: nativeStatePath)
        }
        try NativeMeshState.writePayload(nativeStatePayload, to: nativeStatePath)
        let nativeStateWritten = try Data(contentsOf: URL(fileURLWithPath: nativeStatePath))
        let nativeStateWrittenPayload = try JSONSerialization.jsonObject(with: nativeStateWritten) as? [String: Any]
        try NativeMeshState.validatePayload(nativeStateWrittenPayload ?? [:])
        let nativeStateAttributes = try FileManager.default.attributesOfItem(atPath: nativeStatePath)
        expectEqual(nativeStateAttributes[.posixPermissions] as? Int, 0o600, "Native state file permissions")

        let nativeStateNoMacFixture = NativeProvisionedFixtureState(
            uuid: "fixture-002",
            macAddress: nil,
            code: "400M5",
            name: nil,
            nodeAddress: 0x1202,
            deviceKey: sampleSecrets.deviceKey,
            deviceUUID: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            compositionData: nil,
            updateTime: "2026-05-18T00:00:00Z"
        )
        let nativeStateNoMacPayload = try NativeMeshState.provisionedPayload(
            meshUUID: "mesh-002",
            netKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            appKey: appKey,
            fixture: nativeStateNoMacFixture,
            provisionedAt: "2026-05-18T00:00:00Z",
            ivIndex: 0,
            sequenceNext: 1,
            sourceAddress: 1
        )
        try NativeMeshState.validatePayload(nativeStateNoMacPayload)
        let nativeStateNoMacFixtures = nativeStateNoMacPayload["fixtures"] as? [[String: Any]]
        let nativeStateNoMacFirstFixture = nativeStateNoMacFixtures?.first
        expectEqual(nativeStateNoMacFirstFixture?["mac_address"] as? String, "", "Native state no-MAC field")
        expectEqual(
            nativeStateNoMacFirstFixture?["mac_address_source"] as? String,
            "unavailable_corebluetooth",
            "Native state no-MAC source"
        )
        expectEqual(nativeStateNoMacFirstFixture?["name"] as? String, "400M5-DDEEFF", "Native state no-MAC name")

        let nativeStateAppendFixture = NativeProvisionedFixtureState(
            uuid: "fixture-append",
            macAddress: nil,
            code: "400M5",
            name: "append-test",
            nodeAddress: 0x1211,
            deviceKey: try NativeMeshCrypto.bytes(hex: "0102030405060708090a0b0c0d0e0f10"),
            deviceUUID: try NativeMeshCrypto.bytes(hex: "ffeeddccbbaa99887766554433221100"),
            compositionData: nil,
            elementCount: 2,
            updateTime: "2026-05-18T00:01:00Z"
        )
        let appendedNativeStatePayload = try NativeMeshState.appendingProvisionedFixturePayload(
            existingPayload: nativeStatePayload,
            fixture: nativeStateAppendFixture,
            provisionedAt: "2026-05-18T00:01:00Z"
        )
        try NativeMeshState.validatePayload(appendedNativeStatePayload)
        let appendedNativeStateSource = appendedNativeStatePayload["source"] as? [String: Any]
        expectEqual(
            appendedNativeStateSource?["type"] as? String,
            "native_provisioning_append",
            "Native state append source"
        )
        let appendedNativeStateMesh = appendedNativeStatePayload["mesh"] as? [String: Any]
        expectEqual(
            appendedNativeStateMesh?["net_key"] as? String,
            nativeStateMesh?["net_key"] as? String,
            "Native state append preserves NetKey"
        )
        let appendedNativeStateRuntime = appendedNativeStatePayload["runtime"] as? [String: Any]
        expectEqual(
            appendedNativeStateRuntime?["sequence_next"] as? Int,
            nativeStateRuntime?["sequence_next"] as? Int,
            "Native state append preserves sequence"
        )
        let appendedNativeStateFixtures = appendedNativeStatePayload["fixtures"] as? [[String: Any]]
        expectEqual(appendedNativeStateFixtures?.count, 2, "Native state append fixture count")
        expectEqual(appendedNativeStateFixtures?[1]["node_address"] as? Int, 0x1211, "Native state append node")
        expectEqual(appendedNativeStateFixtures?[1]["element_count"] as? Int, 2, "Native state append element count")
        expectThrows("Native state duplicate append address") {
            _ = try NativeMeshState.appendingProvisionedFixturePayload(
                existingPayload: nativeStatePayload,
                fixture: NativeProvisionedFixtureState(
                    uuid: "fixture-duplicate",
                    macAddress: nil,
                    code: nil,
                    name: nil,
                    nodeAddress: 0x1201,
                    deviceKey: try NativeMeshCrypto.bytes(hex: "11111111111111111111111111111111"),
                    deviceUUID: try NativeMeshCrypto.bytes(hex: "11111111111111111111111111111111"),
                    compositionData: nil,
                    updateTime: "2026-05-18T00:02:00Z"
                ),
                provisionedAt: "2026-05-18T00:02:00Z"
            )
        }
        var runtimeOnlyNativeStatePayload = nativeStatePayload
        runtimeOnlyNativeStatePayload["source"] = [
            "type": "mesh_join_import",
            "control_only": true,
        ]
        var runtimeOnlyFixtures = nativeStatePayload["fixtures"] as? [[String: Any]] ?? []
        runtimeOnlyFixtures[0].removeValue(forKey: "device_key")
        runtimeOnlyFixtures[0].removeValue(forKey: "device_uuid")
        runtimeOnlyFixtures[0]["control_only"] = true
        runtimeOnlyNativeStatePayload["fixtures"] = runtimeOnlyFixtures
        try NativeMeshState.validatePayload(runtimeOnlyNativeStatePayload)
        let appendedRuntimeOnlyPayload = try NativeMeshState.appendingProvisionedFixturePayload(
            existingPayload: runtimeOnlyNativeStatePayload,
            fixture: nativeStateAppendFixture,
            provisionedAt: "2026-05-18T00:03:00Z"
        )
        try NativeMeshState.validatePayload(appendedRuntimeOnlyPayload)
        let appendedRuntimeOnlyFixtures = appendedRuntimeOnlyPayload["fixtures"] as? [[String: Any]]
        expectEqual(appendedRuntimeOnlyFixtures?.count, 2, "Native runtime-only append fixture count")
        expectEqual(appendedRuntimeOnlyFixtures?.first?["control_only"] as? Bool, true, "Native runtime-only fixture marker")

        let applicationAccess = try NativeMeshCrypto.applicationAccessProxyPdu(
            ivIndex: 0x12345678,
            ttl: 0x03,
            sequence: 0x000007,
            source: 0x1201,
            destination: 0xffff,
            netKey: netKey,
            applicationKey: appKey,
            accessMessage: NativeMeshCrypto.bytes(hex: "0400000000")
        )
        expectEqual(applicationAccess.aid, 0x26, "Mesh access AID")
        try expectHex(applicationAccess.upperTransport.nonce, "01000000071201ffff12345678", "Mesh application nonce")
        try expectHex(applicationAccess.upperTransport.encAccessMessage, "5a8bde6d91", "Mesh EncAccessMessage")
        try expectHex(applicationAccess.upperTransport.transMic, "06ea078a", "Mesh TransMIC")
        try expectHex(applicationAccess.upperTransport.upperTransportPdu, "5a8bde6d9106ea078a", "Mesh UpperTransportPDU")
        expectEqual(applicationAccess.lowerTransport.header, 0x66, "Mesh lower transport access header")
        try expectHex(
            applicationAccess.lowerTransport.lowerTransportPdu,
            "665a8bde6d9106ea078a",
            "Mesh LowerTransportPDU"
        )
        try expectHex(applicationAccess.network.nonce, "00030000071201000012345678", "Mesh access Network nonce")
        try expectHex(
            applicationAccess.network.networkPdu,
            "6848cba437860e5673728a627fb938535508e21a6baf57",
            "Mesh access NetworkPDU"
        )
        try expectHex(
            applicationAccess.network.proxyPdu,
            "006848cba437860e5673728a627fb938535508e21a6baf57",
            "Mesh access ProxyPDU"
        )
        let decodedApplicationNetwork = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: applicationAccess.network.networkPdu,
            ivIndex: 0x12345678,
            nid: k2.nid,
            encryptionKey: k2.encryptionKey,
            privacyKey: k2.privacyKey
        )
        expectEqual(decodedApplicationNetwork.ctl, 0, "Mesh access decoded CTL")
        expectEqual(decodedApplicationNetwork.ttl, 0x03, "Mesh access decoded TTL")
        expectEqual(decodedApplicationNetwork.sequence, 0x000007, "Mesh access decoded SEQ")
        expectEqual(decodedApplicationNetwork.source, 0x1201, "Mesh access decoded SRC")
        expectEqual(decodedApplicationNetwork.destination, 0xffff, "Mesh access decoded DST")
        try expectHex(decodedApplicationNetwork.transportPdu, "665a8bde6d9106ea078a", "Mesh access decoded transport")
        let decodedLowerTransport = try NativeMeshCrypto.decodeLowerTransportUnsegmentedAccessPdu(
            lowerTransportPdu: decodedApplicationNetwork.transportPdu
        )
        expectEqual(decodedLowerTransport.akf, true, "Mesh lower transport decoded AKF")
        expectEqual(decodedLowerTransport.aid, 0x26, "Mesh lower transport decoded AID")
        let decodedUpperTransport = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
            applicationKey: appKey,
            sequence: decodedApplicationNetwork.sequence,
            source: decodedApplicationNetwork.source,
            destination: decodedApplicationNetwork.destination,
            ivIndex: 0x12345678,
            upperTransportPdu: decodedLowerTransport.upperTransportPdu
        )
        try expectHex(decodedUpperTransport.accessMessage, "0400000000", "Mesh decoded access message")

        let identitySalt = try NativeMeshCrypto.s1("nkik")
        let identityKey = try NativeMeshCrypto.k1(
            n: netKey,
            salt: identitySalt,
            p: NativeMeshCrypto.ascii("id128") + [0x01]
        )
        try expectHex(identityKey, "84396c435ac48560b5965385253e210c", "Mesh IdentityKey")

        let deviceUpperTransport = try NativeMeshCrypto.upperTransportAccessPdu(
            deviceKey: NativeMeshCrypto.bytes(hex: "9d6dd0e96eb25dc19a40ed9914f8f03f"),
            sequence: 0x3129ab,
            source: 0x0003,
            destination: 0x1201,
            ivIndex: 0x12345678,
            accessMessage: NativeMeshCrypto.bytes(hex: "0056341263964771734fbd76e3b40519d1d94a48")
        )
        try expectHex(deviceUpperTransport.nonce, "02003129ab0003120112345678", "Mesh device nonce")
        try expectHex(
            deviceUpperTransport.encAccessMessage,
            "ee9dddfd2169326d23f3afdfcfdc18c52fdef772",
            "Mesh device EncAccessMessage"
        )
        try expectHex(deviceUpperTransport.transMic, "e0e17308", "Mesh device TransMIC")
        try expectHex(
            deviceUpperTransport.upperTransportPdu,
            "ee9dddfd2169326d23f3afdfcfdc18c52fdef772e0e17308",
            "Mesh device UpperTransportPDU"
        )
        let configDeviceKey = try NativeMeshCrypto.bytes(hex: "9d6dd0e96eb25dc19a40ed9914f8f03f")
        let configAccess = try NativeMeshCrypto.deviceAccessProxyPdu(
            ivIndex: 0x12345678,
            ttl: 0x03,
            sequence: 0x00000a,
            source: 0x0001,
            destination: 0x1201,
            netKey: netKey,
            deviceKey: configDeviceKey,
            accessMessage: NativeMeshConfig.configCompositionDataGet()
        )
        expectEqual(configAccess.lowerTransport.header, 0x00, "Mesh device access lower header")
        let decodedConfigNetwork = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: configAccess.network.networkPdu,
            ivIndex: 0x12345678,
            nid: k2.nid,
            encryptionKey: k2.encryptionKey,
            privacyKey: k2.privacyKey
        )
        let decodedConfigLower = try NativeMeshCrypto.decodeLowerTransportUnsegmentedAccessPdu(
            lowerTransportPdu: decodedConfigNetwork.transportPdu
        )
        expectEqual(decodedConfigLower.akf, false, "Mesh device access decoded AKF")
        expectEqual(decodedConfigLower.aid, 0, "Mesh device access decoded AID")
        let decodedConfigUpper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
            deviceKey: configDeviceKey,
            sequence: decodedConfigNetwork.sequence,
            source: decodedConfigNetwork.source,
            destination: decodedConfigNetwork.destination,
            ivIndex: 0x12345678,
            upperTransportPdu: decodedConfigLower.upperTransportPdu
        )
        try expectHex(decodedConfigUpper.accessMessage, "800800", "Mesh device access decoded config message")
        expectThrows("Config AppKey Add needs segmented lower transport") {
            _ = try NativeMeshCrypto.deviceAccessProxyPdu(
                ivIndex: 0x12345678,
                ttl: 0x03,
                sequence: 0x00000b,
                source: 0x0001,
                destination: 0x1201,
                netKey: netKey,
                deviceKey: configDeviceKey,
                accessMessage: configAppKeyAdd
            )
        }
        let segmentedConfigAccess = try NativeMeshCrypto.segmentedDeviceAccessProxyPdus(
            ivIndex: 0x12345678,
            ttl: 0x03,
            sequence: 0x00000b,
            source: 0x0001,
            destination: 0x1201,
            netKey: netKey,
            deviceKey: configDeviceKey,
            accessMessage: configAppKeyAdd
        )
        expectEqual(segmentedConfigAccess.lowerTransport.seqZero, 0x000b, "Config segmented SeqZero")
        expectEqual(segmentedConfigAccess.lowerTransport.segN, 1, "Config segmented SegN")
        expectEqual(segmentedConfigAccess.lowerTransport.segments.count, 2, "Config segmented count")
        expectEqual(
            segmentedConfigAccess.lowerTransport.lowerTransportPdus.map(\.count),
            [16, 16],
            "Config segmented lower PDU lengths"
        )
        try expectHex(
            Array(segmentedConfigAccess.lowerTransport.segments[0].lowerTransportPdu.prefix(4)),
            "80002c01",
            "Config segmented first header"
        )
        try expectHex(
            Array(segmentedConfigAccess.lowerTransport.segments[1].lowerTransportPdu.prefix(4)),
            "80002c21",
            "Config segmented second header"
        )
        let decodedSegmentNetworks = try segmentedConfigAccess.networks.map {
            try NativeMeshCrypto.decodeNetworkPdu(
                networkPdu: $0.networkPdu,
                ivIndex: 0x12345678,
                nid: k2.nid,
                encryptionKey: k2.encryptionKey,
                privacyKey: k2.privacyKey
            )
        }
        expectEqual(decodedSegmentNetworks.map(\.sequence), [0x00000b, 0x00000c], "Config segmented network SEQs")
        let reassembledConfigLower = try NativeMeshCrypto.reassembleLowerTransportSegmentedAccessPdus(
            lowerTransportPdus: decodedSegmentNetworks.map(\.transportPdu)
        )
        expectEqual(reassembledConfigLower.akf, false, "Config segmented reassembled AKF")
        expectEqual(reassembledConfigLower.aid, 0, "Config segmented reassembled AID")
        expectEqual(reassembledConfigLower.seqZero, 0x000b, "Config segmented reassembled SeqZero")
        try expectHex(
            reassembledConfigLower.upperTransportPdu,
            NativeMeshCrypto.hex(segmentedConfigAccess.upperTransport.upperTransportPdu),
            "Config segmented reassembled UpperTransportPDU"
        )
        let decodedSegmentedConfigUpper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
            deviceKey: configDeviceKey,
            sequence: 0x00000b,
            source: 0x0001,
            destination: 0x1201,
            ivIndex: 0x12345678,
            upperTransportPdu: reassembledConfigLower.upperTransportPdu
        )
        try expectHex(
            decodedSegmentedConfigUpper.accessMessage,
            NativeMeshCrypto.hex(configAppKeyAdd),
            "Config segmented decoded access message"
        )
        let segmentAck = try NativeMeshCrypto.lowerTransportSegmentAcknowledgmentPdu(
            seqZero: 0x000b,
            ackedSegments: 0x00000003
        )
        try expectHex(segmentAck, "00002c00000003", "Config Segment Acknowledgment PDU")
        let decodedSegmentAck = try NativeMeshCrypto.decodeLowerTransportSegmentAcknowledgment(
            lowerTransportPdu: segmentAck
        )
        expectEqual(decodedSegmentAck.obo, false, "Config Segment Acknowledgment OBO")
        expectEqual(decodedSegmentAck.seqZero, 0x000b, "Config Segment Acknowledgment SeqZero")
        expectEqual(decodedSegmentAck.acknowledges(segment: 0), true, "Config Segment Acknowledgment segment 0")
        expectEqual(decodedSegmentAck.acknowledges(segment: 1), true, "Config Segment Acknowledgment segment 1")
        expectEqual(decodedSegmentAck.acknowledges(segment: 2), false, "Config Segment Acknowledgment segment 2")
        expectEqual(decodedSegmentAck.acknowledgesAll(segN: 1), true, "Config Segment Acknowledgment complete")
        expectEqual(decodedSegmentAck.acknowledgesAll(segN: 2), false, "Config Segment Acknowledgment incomplete")
        let segmentAckNetwork = try NativeMeshCrypto.networkPdu(
            ivIndex: 0x12345678,
            nid: k2.nid,
            encryptionKey: k2.encryptionKey,
            privacyKey: k2.privacyKey,
            ctl: 1,
            ttl: 0,
            sequence: 0x00000d,
            source: 0x0001,
            destination: 0x1201,
            transportPdu: segmentAck
        )
        let decodedSegmentAckNetwork = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: segmentAckNetwork.networkPdu,
            ivIndex: 0x12345678,
            nid: k2.nid,
            encryptionKey: k2.encryptionKey,
            privacyKey: k2.privacyKey
        )
        expectEqual(decodedSegmentAckNetwork.ctl, 1, "Config Segment Acknowledgment network CTL")
        expectEqual(decodedSegmentAckNetwork.ttl, 0, "Config Segment Acknowledgment network TTL")
        try expectHex(
            decodedSegmentAckNetwork.transportPdu,
            "00002c00000003",
            "Config Segment Acknowledgment network lower PDU"
        )

        let networkPdu = try NativeMeshCrypto.networkPdu(
            ivIndex: 0x12345677,
            nid: k2.nid,
            encryptionKey: k2.encryptionKey,
            privacyKey: k2.privacyKey,
            ctl: 0,
            ttl: 3,
            sequence: 0x07080c,
            source: 0x1234,
            destination: 0x9736,
            transportPdu: NativeMeshCrypto.bytes(hex: "662456db5e3100eef65daa7a38")
        )
        try expectHex(networkPdu.nonce, "000307080c1234000012345677", "Mesh network nonce")
        try expectHex(
            networkPdu.encryptedDstAndTransportPdu,
            "7a9d696d3dd16a75489696f0b70c71",
            "Mesh network encrypted payload"
        )
        try expectHex(networkPdu.netMic, "1b881385", "Mesh network NetMIC")
        try expectHex(
            networkPdu.privacyPlaintext,
            "0000000000123456777a9d696d3dd16a",
            "Mesh network privacy plaintext"
        )
        try expectHex(networkPdu.pecb, "74a385d9ec19", "Mesh network PECB")
        try expectHex(networkPdu.obfuscatedCtlTtlSeqSrc, "77a48dd5fe2d", "Mesh network obfuscated header")
        try expectHex(
            networkPdu.networkPdu,
            "e877a48dd5fe2d7a9d696d3dd16a75489696f0b70c711b881385",
            "Mesh network PDU"
        )
        try expectHex(
            networkPdu.proxyPdu,
            "00e877a48dd5fe2d7a9d696d3dd16a75489696f0b70c711b881385",
            "Mesh proxy PDU"
        )
        let decodedNetworkPdu = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: networkPdu.networkPdu,
            ivIndex: 0x12345677,
            nid: k2.nid,
            encryptionKey: k2.encryptionKey,
            privacyKey: k2.privacyKey
        )
        expectEqual(decodedNetworkPdu.ctl, 0, "Mesh network decoded CTL")
        expectEqual(decodedNetworkPdu.ttl, 3, "Mesh network decoded TTL")
        expectEqual(decodedNetworkPdu.sequence, 0x07080c, "Mesh network decoded SEQ")
        expectEqual(decodedNetworkPdu.source, 0x1234, "Mesh network decoded SRC")
        expectEqual(decodedNetworkPdu.destination, 0x9736, "Mesh network decoded DST")
        try expectHex(decodedNetworkPdu.transportPdu, "662456db5e3100eef65daa7a38", "Mesh network decoded transport")
    }
}
