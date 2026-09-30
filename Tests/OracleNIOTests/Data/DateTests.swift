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

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite(.timeLimit(.minutes(5))) struct DateTests {
    private func makeTimestampBuffer(tzHourByte: UInt8?, tzMinuteByte: UInt8?) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(120))  // year hi: 100 + 2025/100
        buffer.writeInteger(UInt8(125))  // year lo: 100 + 2025%100
        buffer.writeInteger(UInt8(4))  // month
        buffer.writeInteger(UInt8(26))  // day
        buffer.writeInteger(UInt8(13))  // hour + 1 (12:00:00 UTC)
        buffer.writeInteger(UInt8(1))  // minute + 1 (0)
        buffer.writeInteger(UInt8(1))  // second + 1 (0)
        buffer.writeInteger(UInt32(0), endianness: .big, as: UInt32.self)  // fractional ns
        if let hb = tzHourByte, let mb = tzMinuteByte {
            buffer.writeInteger(hb)
            buffer.writeInteger(mb)
        }
        return buffer
    }

    private var expectedApril26Noon2025UTC: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(
            from: DateComponents(
                calendar: utc, timeZone: TimeZone(secondsFromGMT: 0),
                year: 2025, month: 4, day: 26, hour: 12, minute: 0, second: 0, nanosecond: 0
            ))!
    }

    @Test(arguments: [
        // (offset description, tzHour, tzMinute)
        ("-07:00 (PST/MST)", -7, 0),
        ("-05:00 (EST)", -5, 0),
        ("-12:00 (Baker Island)", -12, 0),
        ("-03:30 (Newfoundland std)", -3, -30),
    ])
    func decodeTimestampTZWithNegativeOffset(
        _ label: String, tzHour: Int, tzMinute: Int
    ) throws {
        let hourByte = UInt8(tzHour + Int(Constants.TZ_HOUR_OFFSET))
        let minuteByte = UInt8(tzMinute + Int(Constants.TZ_MINUTE_OFFSET))
        var buffer = makeTimestampBuffer(tzHourByte: hourByte, tzMinuteByte: minuteByte)

        let decoded = try Date(from: &buffer, type: .timestampTZ, context: .default)
        #expect(decoded == expectedApril26Noon2025UTC, "offset \(label)")
    }

    @Test(arguments: [
        ("+00:00 (UTC)", 0, 0),
        ("+05:30 (IST)", 5, 30),
        ("+09:00 (JST)", 9, 0),
        ("+14:00 (Kiribati)", 14, 0),
    ])
    func decodeTimestampTZWithPositiveOffset(
        _ label: String, tzHour: Int, tzMinute: Int
    ) throws {
        let hourByte = UInt8(tzHour + Int(Constants.TZ_HOUR_OFFSET))
        let minuteByte = UInt8(tzMinute + Int(Constants.TZ_MINUTE_OFFSET))
        var buffer = makeTimestampBuffer(tzHourByte: hourByte, tzMinuteByte: minuteByte)

        let decoded = try Date(from: &buffer, type: .timestampTZ, context: .default)
        #expect(decoded == expectedApril26Noon2025UTC, "offset \(label)")
    }

    @Test func decodeTimestampLTZWithNegativeOffset() throws {
        let hourByte = UInt8(-7 + Int(Constants.TZ_HOUR_OFFSET))
        let minuteByte = UInt8(0 + Int(Constants.TZ_MINUTE_OFFSET))
        var buffer = makeTimestampBuffer(tzHourByte: hourByte, tzMinuteByte: minuteByte)
        let decoded = try Date(from: &buffer, type: .timestampLTZ, context: .default)
        #expect(decoded == expectedApril26Noon2025UTC)
    }

    @Test func decodeTimestampWithoutTimeZone() throws {
        var buffer = makeTimestampBuffer(tzHourByte: nil, tzMinuteByte: nil)
        let decoded = try Date(from: &buffer, type: .timestamp, context: .default)
        #expect(decoded == expectedApril26Noon2025UTC)
    }

    // MARK: - Fractional seconds
    //
    // Oracle's TIMESTAMP wire format carries the fractional second in bytes
    // 7...10 as a big-endian count of NANOSECONDS (0...999_999_999). The same
    // layout python-oracledb thin writes (microsecond * 1000) and reads
    // (fsecond // 1000).
    //
    // A Date is a Double of seconds since 2001-01-01, and Foundation derives
    // `DateComponents.nanosecond` from it by truncation, so at a 2026 instant
    // .001234 reads back as 1_234_054 ns (and 1.001234 s as 1_233_999 ns).
    // Exact-byte checks therefore use fractions Foundation holds exactly
    // (binary fractions, or an instant inside the reference second); checks
    // that go through a 2026 Date compare at microsecond precision.

    private var utcCalendar: Calendar {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc
    }

    private func utcDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
        nanosecond: Int
    ) -> Date {
        let utc = self.utcCalendar
        return utc.date(
            from: DateComponents(
                calendar: utc, timeZone: TimeZone(secondsFromGMT: 0),
                year: year, month: month, day: day, hour: hour, minute: minute,
                second: second, nanosecond: nanosecond
            ))!
    }

    /// The instant 2026-09-30T12:34:56 UTC plus `nanosecond`.
    private func september30(nanosecond: Int) -> Date {
        self.utcDate(
            year: 2026, month: 9, day: 30, hour: 12, minute: 34, second: 56,
            nanosecond: nanosecond
        )
    }

    /// Microseconds of the fractional second, rounded to the nearest microsecond.
    /// Deliberately not reduced modulo 1_000_000: a fraction that rounds up to a
    /// whole second reads as 1_000_000, so it cannot pass for a zero fraction.
    private func microseconds(of date: Date) -> Int {
        let nanosecond = self.utcCalendar.dateComponents([.nanosecond], from: date).nanosecond!
        return (nanosecond + 500) / 1_000
    }

    /// The encoded bytes of `date` and the fractional field read from bytes 7...10.
    private func encodeFraction(_ date: Date) throws -> (bytes: [UInt8], fraction: UInt32) {
        var buffer = ByteBuffer()
        date.encode(into: &buffer, context: .default)
        let bytes = try #require(buffer.getBytes(at: 0, length: buffer.readableBytes))
        let fraction = try #require(
            buffer.getInteger(at: 7, endianness: .big, as: UInt32.self))
        return (bytes, fraction)
    }

    @Test func encodeFractionIsANanosecondCountBigEndian() throws {
        // 2001-01-01T00:00:00.001234Z: inside the reference second, where
        // Foundation holds .001234 as exactly 1_234_000 ns.
        let date = self.utcDate(
            year: 2001, month: 1, day: 1, hour: 0, minute: 0, second: 0,
            nanosecond: 1_234_000
        )
        let (bytes, fraction) = try self.encodeFraction(date)
        #expect(bytes.count == 13)
        #expect(Array(bytes[7..<11]) == [0x00, 0x12, 0xD4, 0x50])
        #expect(fraction == 1_234_000)
    }

    @Test func encodeFractionAt2026IsNanosecondsNotMilliseconds() throws {
        // 2026-09-30T12:34:56.001234Z. Foundation reads this Date's fraction
        // as 1_234_054 ns; the encoder rounds to the microsecond, so the wire
        // carries exactly 1_234_000 (0x0012D450). The pre-fix encoder wrote
        // the millisecond count, 1.
        let (bytes, fraction) = try self.encodeFraction(self.september30(nanosecond: 1_234_000))
        #expect(bytes.count == 13)
        #expect(Array(bytes[7..<11]) == [0x00, 0x12, 0xD4, 0x50])
        #expect(fraction == 1_234_000)
    }

    @Test(arguments: [1, 999, 1_234, 123_456, 500_000, 999_999])
    func encodeAt2026CarriesNoSubMicrosecondNoise(microseconds: Int) throws {
        // Foundation reads 1 us at a 2026 instant as 953 ns and .999999 as
        // 999_999_046 ns. Rounding to the microsecond sends what python-oracledb
        // sends (microsecond * 1000), so a TIMESTAMP(9) column stores no noise.
        let (_, fraction) = try self.encodeFraction(
            self.september30(nanosecond: microseconds * 1_000))
        #expect(fraction == UInt32(microseconds * 1_000))
    }

    @Test func encodeRoundsSubMicrosecondToNearest() throws {
        // Inside the reference second Foundation holds these exactly.
        let down = self.utcDate(
            year: 2001, month: 1, day: 1, hour: 0, minute: 0, second: 0, nanosecond: 1_234_400)
        let up = self.utcDate(
            year: 2001, month: 1, day: 1, hour: 0, minute: 0, second: 0, nanosecond: 1_234_600)
        #expect(try self.encodeFraction(down).fraction == 1_234_000)
        #expect(try self.encodeFraction(up).fraction == 1_235_000)
    }

    @Test func encodeFractionRoundingUpCarriesIntoTheNextSecond() throws {
        // 12:34:56.9999998 rounds to 12:34:57.000000, never to a fraction of
        // 1_000_000_000 (out of range) or back to 12:34:56.000000.
        let (bytes, fraction) = try self.encodeFraction(
            self.september30(nanosecond: 999_999_800))
        #expect(Array(bytes[0..<7]) == [120, 126, 9, 30, 13, 35, 58])  // second 57 + 1
        #expect(fraction == 0)
    }

    @Test func encodeHalfSecondIs500MillionNanoseconds() throws {
        let (bytes, fraction) = try self.encodeFraction(self.september30(nanosecond: 500_000_000))
        #expect(Array(bytes[7..<11]) == [0x1D, 0xCD, 0x65, 0x00])
        #expect(fraction == 500_000_000)
    }

    @Test func encodeWholeSecond() throws {
        // A Date always encodes as TIMESTAMP WITH TIME ZONE (13 bytes), a type
        // that does not allow the 7-byte form, so a whole second carries an
        // explicit zero fraction ahead of the two time-zone bytes.
        let (bytes, fraction) = try self.encodeFraction(self.september30(nanosecond: 0))
        #expect(Date.defaultOracleType.bufferSizeFactor == 13)
        #expect(bytes.count == 13)
        #expect(Array(bytes[0..<7]) == [120, 126, 9, 30, 13, 35, 57])
        #expect(fraction == 0)
    }

    /// A TIMESTAMP value with fractional field `fraction`: the 11-byte form a
    /// TIMESTAMP / TIMESTAMP WITH LOCAL TIME ZONE column arrives in, or with
    /// `withTimeZone` the 13-byte TIMESTAMP WITH TIME ZONE form (UTC offset).
    private func makeTimestampBuffer(fraction: UInt32, withTimeZone: Bool) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(120))  // year hi: 100 + 2025/100
        buffer.writeInteger(UInt8(125))  // year lo: 100 + 2025%100
        buffer.writeInteger(UInt8(4))  // month
        buffer.writeInteger(UInt8(26))  // day
        buffer.writeInteger(UInt8(13))  // hour + 1 (12:00:00 UTC)
        buffer.writeInteger(UInt8(1))  // minute + 1 (0)
        buffer.writeInteger(UInt8(1))  // second + 1 (0)
        buffer.writeInteger(fraction, endianness: .big, as: UInt32.self)  // fractional ns
        if withTimeZone {
            buffer.writeInteger(UInt8(Constants.TZ_HOUR_OFFSET))  // +00
            buffer.writeInteger(UInt8(Constants.TZ_MINUTE_OFFSET))  // :00
        }
        return buffer
    }

    @Test(arguments: [
        // (fraction in ns on the wire, expected microseconds)
        // Only the first two fail on the pre-fix decoder, which divided by
        // 10^(decimal digits): right for 9-digit fractions and for zero, wrong
        // for any fraction with a leading zero. The other four are boundaries.
        (UInt32(1_234_000), 1_234),  // .001234 — pre-fix decode read .1234
        (UInt32(1_000), 1),  // .000001 — pre-fix decode read .1
        (UInt32(500_000_000), 500_000),  // .5
        (UInt32(0), 0),  // .0
        (UInt32(123_456_000), 123_456),  // .123456
        (UInt32(999_999_000), 999_999),  // .999999
    ])
    func decodeFractionIsANanosecondCount(fraction: UInt32, expectedMicroseconds: Int) throws {
        let forms: [(OracleDataType, withTimeZone: Bool)] = [
            (.timestamp, false),  // 11 bytes, the TIMESTAMP / TIMESTAMP(6) column shape
            (.timestampLTZ, false),  // 11 bytes
            (.timestamp, true),  // 13 bytes
            (.timestampLTZ, true),
            (.timestampTZ, true),
        ]
        for (type, withTimeZone) in forms {
            var buffer = self.makeTimestampBuffer(fraction: fraction, withTimeZone: withTimeZone)
            let label = "fraction \(fraction) as \(type), \(withTimeZone ? 13 : 11) bytes"
            let decoded = try Date(from: &buffer, type: type, context: .default)
            #expect(self.microseconds(of: decoded) == expectedMicroseconds, "\(label)")
            // The whole second is untouched by the fraction: the decoded instant
            // lies in [noon, noon + 1 s) and exactly the fraction past noon.
            let delta = decoded.timeIntervalSince(self.expectedApril26Noon2025UTC)
            #expect(delta >= 0 && delta < 1, "\(label): delta \(delta)")
            #expect(
                abs(delta - Double(expectedMicroseconds) / 1_000_000) < 0.000_001,
                "\(label): delta \(delta)")
        }
    }

    @Test(arguments: [1, 1_234, 123_456, 500_000, 999_999, 0])
    func roundTripAtMicrosecondPrecision(microseconds: Int) throws {
        let date = self.september30(nanosecond: microseconds * 1_000)
        var buffer = ByteBuffer()
        date.encode(into: &buffer, context: .default)
        #expect(
            buffer.getInteger(at: 7, endianness: .big, as: UInt32.self)
                == UInt32(microseconds * 1_000))
        let decoded = try Date(from: &buffer, type: .timestampTZ, context: .default)
        #expect(self.microseconds(of: decoded) == microseconds)
        #expect(abs(decoded.timeIntervalSince(date)) < 0.000_001)
    }

}
