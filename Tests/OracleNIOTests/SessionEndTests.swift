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

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing
import _OracleConnectionPoolModule

@testable import OracleNIO

/// A server error that ends the session while the TCP stream stays up must
/// close the connection, so that `OracleClient`'s pool evicts it.
@Suite(.timeLimit(.minutes(5))) struct SessionEndTests {
    static let sessionEndingCodes = ConnectionStateMachine.sessionEndingServerErrors.sorted()

    private func statement(
        _ sql: OracleStatement = "SELECT 1 FROM dual"
    ) -> (StatementContext, EventLoopPromise<OracleRowStream>) {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        return (StatementContext(statement: sql, promise: promise), promise)
    }

    /// Waits, bounded, for the channel to close. `closeFuture.get()` cannot
    /// be cancelled, so a regression would hang the run instead of failing.
    private func closes(_ channel: NIOAsyncTestingChannel) async -> Bool {
        for _ in 0..<200 where channel.isActive {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !channel.isActive
    }

    @Test func theListCoversTheIssuesCodes() {
        // fork issue 10 and the P3 plan's minimum list
        for code: UInt32 in [22, 28, 1012, 1092, 2396, 2399, 3113, 3114, 3135, 3138] {
            #expect(ConnectionStateMachine.endsServerSession(number: code), "ORA-\(code)")
        }
        #expect(!ConnectionStateMachine.endsServerSession(number: 1))
        #expect(!ConnectionStateMachine.endsServerSession(number: 1013))
    }

    // (a) every listed code fails the statement and closes the connection
    // without a Logoff, with or without a cursor id; (c) the next statement
    // on that connection fails with a typed error instead of trapping.
    @Test(arguments: Self.sessionEndingCodes, [UInt16(0), 7])
    func sessionEndingErrorClosesTheConnection(number: UInt32, cursorID: UInt16) throws {
        let (context, promise) = self.statement()
        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(context))
                == .sendExecute(context, nil, cursorID: 0, requiresDefine: false, noPrefetch: false))

        let action = state.backendErrorReceived(.server(number: number, cursorID: cursorID))
        guard case .failStatement(let failed, let error, let cleanup) = action else {
            Issue.record("expected .failStatement, got \(action)")
            return
        }
        #expect(failed.futureResult === promise.futureResult)
        #expect(error.code == .server)
        #expect(error.serverInfo?.number == number)
        let unwrapped = try #require(cleanup, "the connection must be closed")
        #expect(unwrapped.action == .closeWithoutLogoff)
        #expect(state.isDiscardingInbound)

        // what the channel handler runs after .failStatement
        #expect(state.readyForStatementReceived() == .wait)

        // a statement written to the connection afterwards fails typed
        let (next, nextPromise) = self.statement()
        #expect(
            state.enqueue(task: .statement(next))
                == .failStatement(
                    nextPromise, with: .clientClosesConnection(underlying: nil), cleanupContext: nil))
        #expect(state.readyForStatementReceived() == .wait)
        // a later close() does not try to log off
        #expect(state.close(nil) == .wait)
        #expect(state.closed() == .fireChannelInactive)
    }

    @Test func anOrdinaryServerErrorKeepsTheConnection() {
        let (context, promise) = self.statement()
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(context))
        #expect(
            state.backendErrorReceived(.server(number: 1, cursorID: 7))  // ORA-00001
                == .failStatement(promise, with: .server(.server(number: 1)), cleanupContext: nil))
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    @Test func ora00600RetiresTheConnectionWithALogoff() throws {
        let (context, _) = self.statement()
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(context))
        let action = state.backendErrorReceived(.server(number: 600, cursorID: 7))
        guard case .failStatement(_, _, let cleanup) = action else {
            Issue.record("expected .failStatement, got \(action)")
            return
        }
        #expect(try #require(cleanup).action == .close)
        #expect(state.readyForStatementReceived() == .wait)
        #expect(state.close(nil) == .logoffConnection(nil))
    }

    @Test func sessionEndingErrorWhileStreamingClosesTheConnection() throws {
        let (context, promise) = self.statement()
        let describeInfo = DescribeInfo(columns: [
            .init(
                name: "ID", dataType: .number, dataTypeSize: 0, precision: 11, scale: 127,
                bufferSize: 2, nullsAllowed: true, typeScheme: nil, typeName: nil,
                domainSchema: nil, domainName: nil, annotations: [:], vectorDimensions: nil,
                vectorFormat: nil)
        ])
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(context))
        #expect(state.describeInfoReceived(describeInfo) == .wait)
        #expect(
            state.rowHeaderReceived(.init())
                == .succeedStatement(promise, StatementResult(value: .describeInfo(describeInfo.columns))))

        let action = state.backendErrorReceived(.server(number: 3113))
        guard case .forwardStreamError(let error, _, _, let clientCancelled, let cleanup) = action
        else {
            Issue.record("expected .forwardStreamError, got \(action)")
            return
        }
        #expect(error.serverInfo?.number == 3113)
        #expect(!clientCancelled)
        #expect(try #require(cleanup).action == .closeWithoutLogoff)
        #expect(state.readyForStatementReceived() == .wait)
    }

    @Test func sessionEndingErrorAnsweringAPingClosesTheConnection() throws {
        var state = ConnectionStateMachine.readyForStatement()
        let ping = EmbeddedEventLoop().makePromise(of: Void.self)
        ping.fail(OracleSQLError.uncleanShutdown)
        #expect(state.enqueue(task: .ping(ping)) == .sendPing)
        guard
            case .closeConnectionAndCleanup(let cleanup) =
                state.backendErrorReceived(.server(number: 2396))
        else {
            Issue.record("expected .closeConnectionAndCleanup")
            return
        }
        #expect(cleanup.action == .closeWithoutLogoff)
        #expect(cleanup.error.serverInfo?.number == 2396)
    }

    @Test func anErrorAnsweringTheLogoffClosesTheChannel() {
        var state = ConnectionStateMachine.readyForStatement()
        // close(): cleanup first, then the handler's own close() logs off
        guard case .closeConnectionAndCleanup(let cleanup) = state.close(nil) else {
            Issue.record("expected .closeConnectionAndCleanup")
            return
        }
        #expect(cleanup.action == .close)
        #expect(state.close(nil) == .logoffConnection(nil))
        #expect(state.backendErrorReceived(.server(number: 1012)) == .closeConnection(nil))
        #expect(state.isDiscardingInbound)
    }

    // (c) A non-server error during a statement (an unexpected message, a
    // decoding failure) used to leave the statement sub-state unsaved, so the
    // `readyForStatementReceived` after `.failStatement` hit the "statement
    // is still being executed" preconditionFailure.
    @Test func anUnexpectedMessageDuringAStatementDoesNotTrap() throws {
        let (context, promise) = self.statement()
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(context))
        let action = state.errorHappened(
            .unexpectedBackendMessage(.status(.init(callStatus: 0, endToEndSequenceNumber: 0))))
        guard case .failStatement(let failed, _, let cleanup) = action else {
            Issue.record("expected .failStatement, got \(action)")
            return
        }
        #expect(failed.futureResult === promise.futureResult)
        #expect(try #require(cleanup).action == .close)
        #expect(state.readyForStatementReceived() == .wait)
    }

    // The same through a real channel handler: the statement throws the
    // server's error, the channel closes without a Logoff or Close being
    // written, and messages the server sends after the error are dropped
    // instead of reaching a state that cannot interpret them.
    @Test func ora03138ClosesTheChannel() async throws {
        let (connection, channel) = try await makeAsyncTestingConnection()

        async let result = connection.execute("SELECT 1 FROM dual")
        #expect(try await channel.waitForOutboundWrite(as: OracleFrontendMessage.self) == .execute)
        try await injectBackendMessages(
            [
                .error(.server(number: 3138)),
                .status(.init(callStatus: 0, endToEndSequenceNumber: 0)),
                .error(.server(number: 3114)),
                .marker,
            ],
            into: channel)

        do {
            _ = try await result
            Issue.record("the statement must fail")
        } catch let error as OracleSQLError {
            #expect(error.serverInfo?.number == 3138)
        }
        #expect(await closes(channel), "the channel must close")
        #expect(connection.isClosed)
        #expect(try await channel.readOutbound(as: OracleFrontendMessage.self) == nil)
    }

    // (b) The pool hands out a fresh connection after a session-ending error.
    @Test func thePoolReplacesTheEndedSession() async throws {
        let logger = Logger(label: "SessionEndTests")
        let channels = NIOLockedValueBox<[OracleConnection.ID: NIOAsyncTestingChannel]>([:])
        var poolConfiguration = ConnectionPoolConfiguration()
        poolConfiguration.minimumConnectionCount = 0
        poolConfiguration.maximumConnectionSoftLimit = 1
        poolConfiguration.maximumConnectionHardLimit = 1
        let pool = OracleClient.Pool(
            configuration: poolConfiguration,
            idGenerator: ConnectionIDGenerator(),
            requestType: ConnectionRequest<OracleConnection>.self,
            keepAliveBehavior: OracleKeepAliveBehavior(nil, logger: logger),
            observabilityDelegate: OracleClientMetrics(logger: logger),
            clock: ContinuousClock(),
            connectionFactory: { connectionID, _ in
                let (connection, channel) = try await makeAsyncTestingConnection(
                    id: connectionID, logger: logger)
                channels.withLockedValue { $0[connectionID] = channel }
                return ConnectionAndMetadata(connection: connection, maximalStreamsOnConnection: 1)
            })

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }

            // lease 1: the server ends the session
            let first = try await pool.leaseConnection()
            let firstChannel = try #require(channels.withLockedValue { $0[first.connection.id] })
            async let result = first.connection.execute("SELECT 1 FROM dual")
            #expect(
                try await firstChannel.waitForOutboundWrite(as: OracleFrontendMessage.self) == .execute)
            try await injectBackendMessages([.error(.server(number: 3138))], into: firstChannel)
            do {
                _ = try await result
                Issue.record("the statement must fail")
            } catch let error as OracleSQLError {
                #expect(error.serverInfo?.number == 3138)
            }
            first.release()
            #expect(await closes(firstChannel), "the ended session's channel must close")

            // lease 2: a new connection, on a new channel
            let second = try await pool.leaseConnection()
            #expect(second.connection.id != first.connection.id)
            #expect(first.connection.isClosed)
            #expect(!second.connection.isClosed)
            let secondChannel = try #require(channels.withLockedValue { $0[second.connection.id] })
            second.release()

            // shut down: close the healthy connection gracefully
            async let closed: Void = second.connection.close()
            try await acknowledgeLogoff(on: secondChannel)
            try await closed
            group.cancelAll()
        }
    }
}
