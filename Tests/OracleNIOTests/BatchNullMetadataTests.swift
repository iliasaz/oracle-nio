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

/// A batch column's shared metadata must come from its VALUES, never from a NULL row: a NULL is
/// described with its bind's static default type and size 1, which beat a BINARY_DOUBLE value
/// (default size 0) under the size rule and made the column a VARCHAR(1) that every value overflowed
/// (ORA-01461).
@Suite struct BatchNullMetadataTests {
    /// A dynamic-type bind whose runtime type is a double but whose static default type is VARCHAR,
    /// the shape of a wrapper that binds values of several types through one Swift type.
    struct AnyDouble: OracleThrowingDynamicTypeEncodable {
        static var defaultOracleType: OracleDataType { .varchar }
        var value: Double
        var oracleType: OracleDataType { .binaryDouble }
        func encode(into buffer: inout ByteBuffer, context: OracleEncodingContext) throws {
            try self.value.encode(into: &buffer, context: context)
        }
    }

    @Test func aNullAfterAValueKeepsTheValuesType() throws {
        var collection = OracleBindingsCollection()
        try collection.appendRow(AnyDouble(value: 0.5) as AnyDouble?, context: .default)
        try collection.appendRow(nil as AnyDouble?, context: .default)
        try collection.appendRow(nil as AnyDouble?, context: .default)
        #expect(collection.metadata.count == 1)
        #expect(collection.metadata[0].dataType == .binaryDouble)
        #expect(collection.metadata[0].isNull == false)
    }

    @Test func aValueAfterANullReplacesTheNullsType() throws {
        var collection = OracleBindingsCollection()
        try collection.appendRow(nil as AnyDouble?, context: .default)
        try collection.appendRow(AnyDouble(value: 0.25) as AnyDouble?, context: .default)
        try collection.appendRow(nil as AnyDouble?, context: .default)
        #expect(collection.metadata[0].dataType == .binaryDouble)
    }

    @Test func anAllNullColumnKeepsTheNullDescription() throws {
        var collection = OracleBindingsCollection()
        try collection.appendRow(nil as AnyDouble?, context: .default)
        try collection.appendRow(nil as AnyDouble?, context: .default)
        #expect(collection.metadata[0].dataType == .varchar)
        #expect(collection.metadata[0].isNull)
    }

    @Test func betweenValuesTheLargerStillWins() throws {
        var collection = OracleBindingsCollection()
        try collection.appendRow("ab" as String?, context: .default)
        try collection.appendRow("abcdef" as String?, context: .default)
        try collection.appendRow(nil as String?, context: .default)
        #expect(collection.metadata[0].size == 6)
    }

    @Test func anOracleBindingsRowWithANullKeepsTheValuesType() throws {
        var value = OracleBindings()
        try value.append(AnyDouble(value: 0.5), context: .default, bindName: "0")
        var null = OracleBindings()
        null.appendNull(.varchar, bindName: "0")
        var collection = OracleBindingsCollection()
        try collection.appendRow(value)
        try collection.appendRow(null)
        #expect(collection.metadata[0].dataType == .binaryDouble)
    }
}
