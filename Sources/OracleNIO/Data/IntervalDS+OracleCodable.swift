//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2024 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import NIOCore

/// An Oracle `INTERVAL DAY TO SECOND` value.
///
/// `fractionalSeconds` is a count of **nanoseconds** (`0..<1_000_000_000`), the unit the
/// wire format carries in bytes 7 to 10. `IntervalDS(fractionalSeconds: 500)` is therefore
/// 500 ns, not 500 ms; half a second is `fractionalSeconds: 500_000_000`.
public struct IntervalDS: Sendable, Equatable, Hashable {
    public var days: Int
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var fractionalSeconds: Int

    @inlinable
    public init(days: Int, hours: Int, minutes: Int, seconds: Int, fractionalSeconds: Int) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.fractionalSeconds = fractionalSeconds
    }
}

extension IntervalDS: ExpressibleByFloatLiteral {
    @inlinable
    public init(floatLiteral value: Double) {
        // Split off the fraction first and round it to the nearest nanosecond, so a
        // literal such as 3.001234 (stored as 3.00123399999...) keeps its last digit.
        // Rounding up to a whole second carries into the integral part.
        var whole = value.rounded(.down)
        var fractionalSeconds = ((value - whole) * 1_000_000_000).rounded()
        if fractionalSeconds >= 1_000_000_000 {
            whole += 1
            fractionalSeconds -= 1_000_000_000
        }
        var remaining = whole
        let days = (remaining / (24 * 60 * 60)).rounded(.down)
        remaining -= Double(days) * 24 * 60 * 60
        let hours = (remaining / (60 * 60)).rounded(.down)
        remaining -= Double(hours) * 60 * 60
        let minutes = (remaining / 60).rounded(.down)
        remaining -= Double(minutes) * 60
        let seconds = remaining.rounded(.down)
        self = .init(
            days: Int(days),
            hours: Int(hours),
            minutes: Int(minutes),
            seconds: Int(seconds),
            fractionalSeconds: Int(fractionalSeconds)
        )
    }

    @inlinable
    public var double: Double {
        return (Double(days) * 24 * 60 * 60) + (Double(hours) * 60 * 60) + (Double(minutes) * 60)
            + Double(seconds) + (Double(fractionalSeconds) / 1_000_000_000)
    }
}

extension IntervalDS: Encodable {
    @inlinable
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if encoder is _OracleJSONEncoder {
            try container.encode(self)
        } else {
            try container.encode(double)
        }
    }
}

extension IntervalDS: Decodable {
    @inlinable
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        self = .init(floatLiteral: value)
    }
}

extension IntervalDS: OracleEncodable {
    @inlinable
    public static var defaultOracleType: OracleDataType { .intervalDS }

    @inlinable
    public func encode(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        buffer.writeInteger(
            UInt32(self.days) + Constants.TNS_DURATION_MID, endianness: .big
        )
        buffer.writeInteger(UInt8(self.hours) + Constants.TNS_DURATION_OFFSET)
        buffer.writeInteger(UInt8(self.minutes) + Constants.TNS_DURATION_OFFSET)
        buffer.writeInteger(UInt8(self.seconds) + Constants.TNS_DURATION_OFFSET)
        buffer.writeInteger(
            UInt32(self.fractionalSeconds) + Constants.TNS_DURATION_MID,
            endianness: .big
        )
        buffer.writeInteger(UInt8(buffer.readableBytes))
    }
}

extension IntervalDS: OracleDecodable {
    @inlinable
    public init(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext
    ) throws {
        switch type {
        case .intervalDS:
            let durationMid = Constants.TNS_DURATION_MID
            let durationOffset = Constants.TNS_DURATION_OFFSET
            let days = (buffer.readInteger(endianness: .big, as: UInt32.self) ?? 0) - durationMid
            let fractionalSeconds =
                try buffer.throwingGetInteger(at: 7, endianness: .big, as: UInt32.self)
                - durationMid
            let hours = try buffer.throwingGetInteger(at: 4, as: UInt8.self) - durationOffset
            let minutes = try buffer.throwingGetInteger(at: 5, as: UInt8.self) - durationOffset
            let seconds = try buffer.throwingGetInteger(at: 6, as: UInt8.self) - durationOffset
            self = .init(
                days: Int(days),
                hours: Int(hours),
                minutes: Int(minutes),
                seconds: Int(seconds),
                fractionalSeconds: Int(fractionalSeconds)
            )
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}
