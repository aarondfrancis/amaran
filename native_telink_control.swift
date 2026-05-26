import Foundation

enum NativeTelinkControlError: Error, CustomStringConvertible {
    case invalidCommand(String)
    case invalidParameter(String)

    var description: String {
        switch self {
        case .invalidCommand(let value):
            return "invalid native control command: \(value)"
        case .invalidParameter(let value):
            return "invalid native control parameter: \(value)"
        }
    }
}

enum NativeTelinkControlCommand {
    case onOff(Bool)
    case brightness(percent: String)
    case cct(kelvin: String, intensityPercent: String, gm: Int, gmFlag: Int)
    case raw(packetHex: String, packet: [UInt8])
    case status

    static func parse(spec: String) throws -> NativeTelinkControlCommand {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first else {
            throw NativeTelinkControlError.invalidCommand(spec)
        }

        switch name {
        case "on":
            guard parts.count == 1 else {
                throw NativeTelinkControlError.invalidCommand(spec)
            }
            return .onOff(true)
        case "off":
            guard parts.count == 1 else {
                throw NativeTelinkControlError.invalidCommand(spec)
            }
            return .onOff(false)
        case "intensity":
            guard parts.count == 2 else {
                throw NativeTelinkControlError.invalidCommand(spec)
            }
            return .brightness(percent: parts[1])
        case "cct":
            guard parts.count == 5, let gm = Int(parts[3]), let gmFlag = Int(parts[4]) else {
                throw NativeTelinkControlError.invalidCommand(spec)
            }
            return .cct(kelvin: parts[1], intensityPercent: parts[2], gm: gm, gmFlag: gmFlag)
        case "raw":
            guard parts.count == 2 else {
                throw NativeTelinkControlError.invalidCommand(spec)
            }
            return .raw(
                packetHex: parts[1],
                packet: try NativeTelinkControl.rawPacket(hex: parts[1])
            )
        case "status":
            guard parts.count == 1 else {
                throw NativeTelinkControlError.invalidCommand(spec)
            }
            return .status
        default:
            throw NativeTelinkControlError.invalidCommand(spec)
        }
    }

    func accessMessage() throws -> [UInt8] {
        try [NativeTelinkControl.accessOpcode] + packet()
    }

    func metadata() throws -> [String: Any] {
        switch self {
        case .onOff(let turnOn):
            return [
                "control_command": turnOn ? "on" : "off",
                "opcode": "Telink 0x26",
                "packet_type": "sleep",
                "packet_bytes": 10,
            ]
        case .brightness(let percent):
            let telinkIntensity = try NativeTelinkControl.percentToTelinkIntensity(percent)
            return [
                "control_command": "intensity",
                "intensity": telinkIntensity,
                "intensity_percent": Double(telinkIntensity) / 10.0,
                "opcode": "Telink 0x26",
                "packet_type": "brightness",
                "packet_bytes": 10,
            ]
        case .cct(let kelvin, let intensityPercent, let gm, let gmFlag):
            let telinkCct = try NativeTelinkControl.kelvinToTelinkCCT(kelvin)
            let telinkIntensity = try NativeTelinkControl.percentToTelinkIntensity(intensityPercent)
            return [
                "cct": telinkCct,
                "cct_kelvin": telinkCct * 10,
                "control_command": "cct",
                "gm": gm,
                "gm_flag": gmFlag,
                "intensity": telinkIntensity,
                "intensity_percent": Double(telinkIntensity) / 10.0,
                "opcode": "Telink 0x26",
                "packet_type": "cct",
                "packet_bytes": 10,
            ]
        case .raw(let packetHex, let packet):
            let telink = NativeTelinkControl.decodePacket(packet) ?? [:]
            return [
                "control_command": "raw",
                "opcode": "Telink 0x26",
                "packet_type": "raw",
                "packet_bytes": 10,
                "packet_hex": NativeMeshCrypto.hex(packet),
                "requested_packet_hex": packetHex,
                "command_type": telink["command_type"] ?? NSNull(),
                "opera_type": telink["opera_type"] ?? NSNull(),
            ]
        case .status:
            return [
                "control_command": "status",
                "opcode": "Telink 0x26",
                "packet_type": "read_data",
                "packet_bytes": 10,
            ]
        }
    }

    private func packet() throws -> [UInt8] {
        switch self {
        case .onOff(let turnOn):
            return NativeTelinkControl.onOffPacket(turnOn: turnOn)
        case .brightness(let percent):
            return try NativeTelinkControl.brightnessPacket(
                telinkIntensity: NativeTelinkControl.percentToTelinkIntensity(percent)
            )
        case .cct(let kelvin, let intensityPercent, let gm, let gmFlag):
            return try NativeTelinkControl.cctPacket(
                telinkCct: NativeTelinkControl.kelvinToTelinkCCT(kelvin),
                telinkIntensity: NativeTelinkControl.percentToTelinkIntensity(intensityPercent),
                gm: gm,
                gmFlag: gmFlag
            )
        case .raw(_, let packet):
            return packet
        case .status:
            return NativeTelinkControl.statusRequestPacket()
        }
    }
}

struct NativeTelinkControl {
    static let accessOpcode = UInt8(0x26)

    static func percentToTelinkIntensity(_ value: String) throws -> Int {
        guard let number = Double(value), number >= 0, number <= 100 else {
            throw NativeTelinkControlError.invalidParameter("percent must be between 0 and 100")
        }
        return Int((number * 10).rounded())
    }

    static func kelvinToTelinkCCT(_ value: String) throws -> Int {
        guard let kelvin = Int(value), (800...20000).contains(kelvin) else {
            throw NativeTelinkControlError.invalidParameter("cct must be between 800 and 20000")
        }
        return Int((Double(kelvin) / 10.0).rounded())
    }

    static func onOffPacket(turnOn: Bool) -> [UInt8] {
        packetData(low64: 0, high16: 0x8c00 | (turnOn ? 0x0001 : 0x0000))
    }

    static func statusRequestPacket() -> [UInt8] {
        packetData(low64: 0, high16: 0x0e00)
    }

    static func brightnessPacket(telinkIntensity: Int) throws -> [UInt8] {
        guard (0...1000).contains(telinkIntensity) else {
            throw NativeTelinkControlError.invalidParameter("intensity must be between 0 and 1000")
        }
        let low64 = (UInt64(telinkIntensity) & 0x03) << 62
        let high16 = UInt16(0x8f00 | ((telinkIntensity >> 2) & 0xff))
        return packetData(low64: low64, high16: high16)
    }

    static func decodePacket(_ packet: [UInt8]) -> [String: Any]? {
        guard packet.count == 10 else {
            return nil
        }
        let low64 = littleEndianUInt64(packet, offset: 0, count: 8)
        let high16 = UInt16(packet[8]) | (UInt16(packet[9]) << 8)
        let commandType = Int(packet[9] & 0x7f)
        let operaType = Int((high16 >> 15) & 0x01)
        let checksum = packet[0]
        var checksumBytes = packet
        checksumBytes[0] = 0
        let expectedChecksum = UInt8(checksumBytes.reduce(0) { ($0 + Int($1)) & 0xff })

        var result: [String: Any] = [
            "check_sum": Int(checksum),
            "checksum_valid": checksum == expectedChecksum,
            "command_type": commandType,
            "opera_type": operaType,
            "packet_bytes": packet.count,
        ]

        if commandType == 0x02 {
            let cctRaw = Int((low64 >> 52) & 0x3ff)
            let cctFlag = Int((low64 >> 42) & 0x01)
            let gmRaw = Int((low64 >> 45) & 0x7f)
            let gmHigh = Int((low64 >> 44) & 0x01)
            let gmFlag = Int((low64 >> 43) & 0x01)
            let intensity = ((Int(high16) << 2) | Int((low64 >> 62) & 0x03)) & 0x3ff
            let decodedCct = cctFlag == 1 ? cctRaw + 1000 : cctRaw
            let decodedGm = gmHigh == 1 ? gmRaw + 100 : gmRaw
            result["cct"] = [
                "cct": cctRaw,
                "cct_decoded": decodedCct,
                "cct_kelvin": decodedCct * 10,
                "cct_flag": cctFlag,
                "gm": gmRaw,
                "gm_decoded": decodedGm,
                "gm_flag": gmFlag,
                "gm_high": gmHigh,
                "intensity": intensity,
                "intensity_percent": Double(intensity) / 10.0,
                "reserve": Int((low64 >> 9) & 0x1ffffffff),
                "sleep_mode": Int((low64 >> 8) & 0x01),
            ]
        }
        if commandType == 0x0a {
            result["color"] = [
                "hue_candidate": Int(packet[3]),
                "saturation_candidate": Int(packet[4]),
                "value_candidate": Int(packet[5]),
                "mode_candidate": Int(packet[7]),
                "aux_candidate": Int(packet[8]),
                "packet_hex": NativeMeshCrypto.hex(packet),
            ]
        }

        return result
    }

    static func cctPacket(telinkCct: Int, telinkIntensity: Int, gm: Int, gmFlag: Int) throws -> [UInt8] {
        guard (80...2000).contains(telinkCct) else {
            throw NativeTelinkControlError.invalidParameter("cct must be between 80 and 2000")
        }
        guard (0...1000).contains(telinkIntensity) else {
            throw NativeTelinkControlError.invalidParameter("intensity must be between 0 and 1000")
        }
        guard gmFlag == 0 || gmFlag == 1 else {
            throw NativeTelinkControlError.invalidParameter("gm_flag must be 0 or 1")
        }

        var low64 = (UInt64(telinkIntensity) & 0x03) << 62
        var high16 = UInt16(0x8200 | ((telinkIntensity >> 2) & 0xff))
        if telinkCct < 1001 {
            low64 |= UInt64(telinkCct) << 52
            high16 |= UInt16((telinkCct >> 12) & 0xff)
        } else {
            low64 |= UInt64((telinkCct + 0x18) & 0x3ff) << 52
            low64 |= 0x0000_0400_0000_0000
        }

        low64 |= UInt64(gmFlag & 0x01) << 43
        if gmFlag == 1 {
            guard (0...255).contains(gm) else {
                throw NativeTelinkControlError.invalidParameter("gm must be between 0 and 255")
            }
            if gm < 101 {
                high16 |= UInt16((gm >> 19) & 0xff)
                low64 |= UInt64(gm) << 45
            } else {
                low64 |= UInt64((gm + 0x1c) & 0x7f) << 45
                low64 |= 0x0000_1000_0000_0000
            }
        } else {
            guard (0...127).contains(gm) else {
                throw NativeTelinkControlError.invalidParameter("gm must be between 0 and 127 when gm_flag is 0")
            }
            low64 |= UInt64(gm & 0x7f) << 45
        }

        return packetData(low64: low64, high16: high16)
    }

    static func rawPacket(hex: String) throws -> [UInt8] {
        let packet = try NativeMeshCrypto.bytes(hex: hex)
        guard packet.count == 10 else {
            throw NativeTelinkControlError.invalidParameter("raw Telink packet must be exactly 10 bytes")
        }
        guard let decoded = decodePacket(packet),
              decoded["checksum_valid"] as? Bool == true else {
            throw NativeTelinkControlError.invalidParameter("raw Telink packet checksum is invalid")
        }
        return packet
    }

    private static func packetData(low64: UInt64, high16: UInt16) -> [UInt8] {
        var bytes = littleEndianBytes(low64, count: 8) + littleEndianBytes(UInt64(high16), count: 2)
        bytes[0] = 0
        bytes[0] = UInt8(bytes.reduce(0) { ($0 + Int($1)) & 0xff })
        return bytes
    }

    private static func littleEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> UInt64($0 * 8)) & 0xff) }
    }

    private static func littleEndianUInt64(_ bytes: [UInt8], offset: Int, count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { value, index in
            value | (UInt64(bytes[offset + index]) << UInt64(index * 8))
        }
    }
}
