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
import NIOEmbedded
import Testing

@testable import OracleNIO

private typealias RowData = OracleBackendMessage.RowData

@Suite(.timeLimit(.minutes(5))) struct RowDataTests {

    @Test func processVectorColumnDataRequestsMissingData() {
        let type = OracleDataType.vector

        var buffer = ByteBuffer(bytes: [
            1, 1,  // length
            0,  // size
            0,  // chunk size
            1,  // value (partial)
        ])
        #expect(
            throws: MissingDataDecodingError.Trigger(),
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })

        buffer = ByteBuffer(bytes: [
            1, 1,  // length
            0,  // size
            0,  // chunk size
            1, 1,  // value
            1,  // locator (partial)
        ])
        #expect(
            throws: MissingDataDecodingError.Trigger(),
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })
    }

    @Test func processObjectColumnDataRequestsMissingData() throws {
        let type = OracleDataType.object

        var buffer = ByteBuffer(bytes: [1, 1])  // type oid
        #expect(
            throws: MissingDataDecodingError.Trigger(),
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })

        buffer = ByteBuffer(bytes: [
            1, 1, 0,  // type oid
            1, 1,  // oid
        ])
        #expect(
            throws: MissingDataDecodingError.Trigger(),
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })

        buffer = ByteBuffer(bytes: [
            1, 1, 0,  // type oid
            1, 1, 0,  // oid
            1, 1,  // snapshot
        ])
        #expect(
            throws: MissingDataDecodingError.Trigger(),
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })

        buffer = ByteBuffer(bytes: [
            1, 1, 0,  // type oid
            1, 1, 0,  // oid
            1, 1, 0,  // snapshot
            0,  // version
            0,  // data length
            0,  // flags
        ])
        #expect(
            throws: Never.self,
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })
    }

    /// Regression test: an object (SDO_GEOMETRY etc.) whose serialized form is
    /// split across a TNS packet boundary *inside* one of the fixed-width
    /// `version`/`flags` fields must request more data, not crash.
    ///
    /// The pre-existing `processObjectColumnDataRequestsMissingData` test only
    /// truncates at the chunked oid/data boundaries (which already throw
    /// `Trigger`); it always encodes the fixed fields as a single zero-length
    /// byte, so the buggy non-throwing `skipUB2()` was never exercised with a
    /// short buffer.
    @Test func processObjectColumnTruncatedInFixedFieldRequestsMissingData() {
        let type = OracleDataType.object

        // type oid / oid / snapshot all empty, then a `version` field whose
        // length byte announces 1 value byte that is missing.
        var buffer = ByteBuffer(bytes: [
            0,  // type oid (empty)
            0,  // oid (empty)
            0,  // snapshot (empty)
            1,  // version: length byte = 1 (value byte missing)
        ])
        #expect(performing: {
            try RowData.decode(from: &buffer, context: .init(columns: type))
        }, throws: { error in
            error is MissingDataDecodingError.Trigger
                || (error as? OraclePartialDecodingError)?.category == .expectedAtLeastNRemainingBytes
        })

        // Reaches the `flags` field, which is truncated. This is the exact
        // path from the reported crash (RowData.swift `buffer.skipUB2() // flags`).
        buffer = ByteBuffer(bytes: [
            0,  // type oid (empty)
            0,  // oid (empty)
            0,  // snapshot (empty)
            0,  // version (empty)
            1, 5,  // data length = 5
            1,  // flags: length byte = 1 (value byte missing)
        ])
        #expect(performing: {
            try RowData.decode(from: &buffer, context: .init(columns: type))
        }, throws: { error in
            error is MissingDataDecodingError.Trigger
                || (error as? OraclePartialDecodingError)?.category == .expectedAtLeastNRemainingBytes
        })
    }

    /// Regression test: a vector column truncated inside the fixed-width
    /// `size`/`chunk size` fields must request more data, not crash.
    @Test func processVectorColumnTruncatedInFixedFieldRequestsMissingData() {
        let type = OracleDataType.vector

        var buffer = ByteBuffer(bytes: [
            1, 1,  // length = 1 (> 0, so size/chunk are read)
            1,  // size: length byte = 1 (value byte missing)
        ])
        #expect(performing: {
            try RowData.decode(from: &buffer, context: .init(columns: type))
        }, throws: { error in
            error is MissingDataDecodingError.Trigger
                || (error as? OraclePartialDecodingError)?.category == .expectedAtLeastNRemainingBytes
        })
    }

    @Test func processLOBColumnDataRequestsMissingData() throws {
        let type = OracleDataType.blob

        var buffer = ByteBuffer(bytes: [
            1, 1,  // length
            1, 1,  // size
            1, 1,  // chunk size
            2, 0,  // locator (partial)
        ])
        #expect(
            throws: MissingDataDecodingError.Trigger(),
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })

        buffer = ByteBuffer(bytes: [
            1, 1,  // length
            1, 1,  // size
            1, 1,  // chunk size
            1, 0,  // locator
        ])
        #expect(
            throws: Never.self,
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })

        buffer = ByteBuffer(bytes: [0])
        #expect(
            throws: Never.self,
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })
    }

    @Test func processBufferSizeZero() throws {
        var buffer = ByteBuffer()
        let context = OracleBackendMessageDecoder.Context(capabilities: .init())
        context.statementContext = .init(statement: "")
        context.describeInfo = .init(columns: [
            .init(
                name: "",
                dataType: .varchar,
                dataTypeSize: 0,
                precision: 0,
                scale: 0,
                bufferSize: 0,
                nullsAllowed: true,
                typeScheme: nil,
                typeName: nil,
                domainSchema: nil,
                domainName: nil,
                annotations: [:],
                vectorDimensions: nil,
                vectorFormat: nil
            )
        ])
        let result = try RowData.decode(from: &buffer, context: context)
        #expect(result == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
    }

    @Test func emptyRowID() throws {
        var buffer = ByteBuffer(bytes: [0])
        let context = OracleBackendMessageDecoder.Context(columns: .rowID)
        let result = try RowData.decode(from: &buffer, context: context)
        #expect(result == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
    }

    @Test func emptyBufferZeroActualBytes() throws {
        var buffer = ByteBuffer(bytes: [0, 1, 255])
        let context = OracleBackendMessageDecoder.Context(capabilities: .init())
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(StatementContext.TestComplete())
        var statement: OracleStatement = ""
        statement.binds.append(.init(dataType: .boolean), bindName: "1", isReturning: false)
        context.statementContext = .init(statement: statement)
        let result = try RowData.decode(from: &buffer, context: context)
        #expect(result == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
    }
}
