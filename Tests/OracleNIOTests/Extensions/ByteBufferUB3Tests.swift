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

import NIOCore
import Testing

@testable import OracleNIO

/// A 3-byte UB4/UB8 that straddles a TNS packet boundary must ask for more data, not trap
/// (`ByteBuffer+UB.swift:67: Fatal error` from `RowID.init(fromWire:)` in `BackendError.decode`).
@Suite struct ByteBufferUB3Tests {
    /// Error info (TNS_MSG_TYPE_ERROR) cut inside `rowid.rba`, announced as 3 bytes, 1 present.
    static func errorInfoCutInsideRBA() -> ByteBuffer {
        var b = ByteBuffer()
        b.writeInteger(UInt8(4))  // MessageID.error
        b.writeBytes([UInt8](repeating: 0, count: 8))  // call status ... error position (all zero UBs)
        b.writeBytes([UInt8](repeating: 0, count: 6))  // sql type, fatal, flags, cursor opts, UDI, warning
        b.writeBytes([0x03, 0x01])  // rba: length 3, one value byte
        return b
    }

    @Test func complete3ByteValuesDecode() {
        var b = ByteBuffer(bytes: [0x03, 0x01, 0x02, 0x03, 0x03, 0x01, 0x00, 0x00])
        #expect(b.readUB4() == 0x01_02_03)
        #expect(b.readUB8() == 65_536)
        #expect(b.readableBytes == 0)
    }

    @Test(arguments: [[0x03], [0x03, 0x01], [0x03, 0x01, 0x02]] as [[UInt8]])
    func truncated3ByteValuesAreNil(bytes: [UInt8]) {
        var b4 = ByteBuffer(bytes: bytes)
        #expect(b4.readUB4() == nil)
        var b8 = ByteBuffer(bytes: bytes)
        #expect(b8.readUB8() == nil)
        var t = ByteBuffer(bytes: bytes)
        #expect(throws: OraclePartialDecodingError.self) { try t.throwingReadUB4() }
    }

    @Test func rowIDCutAfterPartitionThrowsPartial() {
        var b = ByteBuffer(bytes: [0x03, 0x01, 0x02, 0x03, 0x00])  // rba, partition, then the end
        #expect(throws: OraclePartialDecodingError.self) { _ = try RowID(fromWire: &b) }
    }

    @Test func errorInfoCutInsideRowIDIsMissingData() {
        var b = Self.errorInfoCutInsideRBA()
        var messages = TinySequence<OracleBackendMessage>()
        let ctx = OracleBackendMessageDecoder.Context(capabilities: .init())
        do {
            try OracleBackendMessage.decodeData(from: &b, into: &messages, context: ctx)
            Issue.record("decoded a truncated error-info message")
        } catch let error as MissingDataDecodingError {
            #expect(error.resetToReaderIndex == 0)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
