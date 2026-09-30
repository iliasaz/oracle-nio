//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2026 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import Testing

@testable import OracleNIO

/// INTERVAL DAY TO SECOND carries its fractional second in bytes 7...10 as a
/// big-endian count of nanoseconds offset by TNS_DURATION_MID (python-oracledb
/// `decode_interval_ds`, node-oracledb `parseOracleIntervalDS`).
@Suite(.timeLimit(.minutes(5))) struct IntervalDSTests {
    /// An 11-byte INTERVAL DAY TO SECOND wire value.
    private func makeIntervalBuffer(
        days: UInt32 = 0, hours: UInt8 = 0, minutes: UInt8 = 0, seconds: UInt8 = 0,
        nanoseconds: UInt32
    ) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(days + Constants.TNS_DURATION_MID, endianness: .big)
        buffer.writeInteger(hours + Constants.TNS_DURATION_OFFSET)
        buffer.writeInteger(minutes + Constants.TNS_DURATION_OFFSET)
        buffer.writeInteger(seconds + Constants.TNS_DURATION_OFFSET)
        buffer.writeInteger(nanoseconds + Constants.TNS_DURATION_MID, endianness: .big)
        return buffer
    }

    /// The fractional field of an encoded interval, with TNS_DURATION_MID removed.
    private func encodedNanoseconds(_ interval: IntervalDS) throws -> UInt32 {
        var buffer = ByteBuffer()
        interval.encode(into: &buffer, context: .default)
        let raw = try #require(buffer.getInteger(at: 7, endianness: .big, as: UInt32.self))
        return raw - Constants.TNS_DURATION_MID
    }

    @Test func floatLiteralHalfSecondIs500MillionNanoseconds() throws {
        let interval: IntervalDS = 1.5
        #expect(interval.seconds == 1)
        #expect(interval.fractionalSeconds == 500_000_000)
        // Pre-fix, the literal stored 500 (milliseconds) and the wire said 500 ns.
        #expect(try self.encodedNanoseconds(interval) == 500_000_000)
    }

    @Test(arguments: [
        // (literal, expected nanoseconds)
        (3.001234, 1_234_000),  // stored as 3.00123399999..., rounds to the nearest ns
        (0.000001, 1_000),  // one microsecond; pre-fix it truncated to 0 ms
        (59.123456789, 123_456_789),
        (15.0, 0),
    ])
    func floatLiteralFractionIsNanoseconds(literal: Double, expected: Int) throws {
        let interval = IntervalDS(floatLiteral: literal)
        #expect(interval.fractionalSeconds == expected)
        #expect(try self.encodedNanoseconds(interval) == UInt32(expected))
        #expect(abs(interval.double - literal) < 1e-9)
    }

    @Test func floatLiteralRoundingToAWholeSecondCarries() {
        // .9999999999 rounds to 1_000_000_000 ns, which must carry into seconds
        // and cascade, never produce an out-of-range fraction.
        let interval = IntervalDS(floatLiteral: 86_399.999_999_999_9)
        #expect(interval == IntervalDS(days: 1, hours: 0, minutes: 0, seconds: 0, fractionalSeconds: 0))
    }

    @Test func floatLiteralSplitsDaysHoursMinutes() {
        // 1 day 2 h 3 min 4.25 s
        let interval = IntervalDS(floatLiteral: 86_400 + 7_200 + 180 + 4.25)
        #expect(
            interval
                == IntervalDS(days: 1, hours: 2, minutes: 3, seconds: 4, fractionalSeconds: 250_000_000))
    }

    @Test func decodeHalfSecondFromWire() throws {
        var buffer = self.makeIntervalBuffer(nanoseconds: 500_000_000)
        let interval = try IntervalDS(from: &buffer, type: .intervalDS, context: .default)
        #expect(interval.fractionalSeconds == 500_000_000)
        // Pre-fix, `double` divided by 1_000 and read this as 500_000 s.
        #expect(interval.double == 0.5)
    }

    @Test func decodeAsDoubleUsesNanoseconds() throws {
        var buffer = self.makeIntervalBuffer(
            days: 2, hours: 3, minutes: 4, seconds: 5, nanoseconds: 1_234_000)
        let value = try Double(from: &buffer, type: .intervalDS, context: .default)
        #expect(abs(value - (2 * 86_400 + 3 * 3_600 + 4 * 60 + 5.001234)) < 1e-9)
    }

    @Test func wireRoundTripKeepsEveryField() throws {
        let interval = IntervalDS(
            days: 12, hours: 23, minutes: 59, seconds: 58, fractionalSeconds: 999_999_999)
        var buffer = ByteBuffer()
        interval.encode(into: &buffer, context: .default)
        let decoded = try IntervalDS(from: &buffer, type: .intervalDS, context: .default)
        #expect(decoded == interval)
    }

    @Test func jsonRoundTripKeepsNanoseconds() throws {
        var buffer = ByteBuffer()
        var writer = OracleJSONWriter()
        try writer.encode(.intervalDS(1.5), into: &buffer, maxFieldNameSize: 255)
        let result = try OracleJSONParser.parse(from: &buffer)
        guard case .intervalDS(let parsed) = result else {
            Issue.record("expected .intervalDS, got \(result)")
            return
        }
        #expect(parsed.fractionalSeconds == 500_000_000)
        #expect(parsed.double == 1.5)
    }
}
