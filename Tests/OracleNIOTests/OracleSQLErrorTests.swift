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

@Suite(.timeLimit(.minutes(5))) struct OracleSQLErrorTests {
    @Test func serverInfoDescription() {
        let errorWithMessage = OracleSQLError.ServerInfo(
            .init(
                number: 1017,
                rowCount: 0,
                isWarning: false,
                message: "ORA-01017: invalid credential or not authorized; logon denied",
                batchErrors: []
            ))
        #expect(
            String(describing: errorWithMessage) == "ORA-01017: invalid credential or not authorized; logon denied")
        let errorWithoutMessage = OracleSQLError.ServerInfo(
            .init(
                number: 1017,
                rowCount: 0,
                isWarning: false,
                batchErrors: []
            ))
        #expect(String(describing: errorWithoutMessage) == "ORA-01017")
    }

    /// A RETURNING bind writes no bytes, but the bind rendering pairs metadata
    /// with bytes by position, so a NUMBER out-bind placed before text in-binds
    /// is rendered from the first text bind's bytes (the ORA-01483 case). Those
    /// bytes must render as something, never trap the process: "hello world"
    /// used to underflow `101 - byte` in the NUMBER digit loop, and a one-byte
    /// text read as the -1e126 NUMBER and trapped converting it to `Int64`.
    @Test(arguments: ["hello world", "x"])
    func debugDescriptionWithReturnBindBeforeTextBindsDoesNotTrap(text: String) {
        var binds = OracleBindings()
        binds.append(OracleRef(dataType: .number), bindName: "id", isReturning: true)
        binds.append(text, context: .default, bindName: "name")
        binds.appendUnprotected(text, context: .default, bindName: "label")
        let statement = OracleStatement(
            unsafeSQL: "INSERT INTO t (name, label) VALUES (:name, :label) RETURNING id INTO :id",
            binds: binds
        )
        let error = OracleSQLError(code: .server, statement: statement)

        let debug = String(reflecting: error)
        #expect(debug.contains("OracleStatement(sql: "))
        #expect(debug.contains("DB_TYPE_NUMBER"))
        #expect(!String(describing: error).isEmpty)
    }
}
