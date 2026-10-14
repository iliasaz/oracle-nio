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
import NIOPosix
import NIOSSL
import Testing

@testable import OracleNIO

/// A server that accepts TCP and never writes a byte must not hold a connect
/// attempt beyond `Options.handshakeTimeout`.
@Suite(.timeLimit(.minutes(2))) struct HandshakeTimeoutTests {
    /// Accepts connections and stays silent. Remembers each accepted channel,
    /// so a test can see the client close its end, and can close them itself
    /// to unblock a connect that did not time out.
    final class SilentServer: Sendable {
        let channel: Channel
        let accepted = NIOLockedValueBox<[Channel]>([])

        init() async throws {
            let accepted = self.accepted
            self.channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { child in
                    accepted.withLockedValue { $0.append(child) }
                    return child.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0).get()
        }

        var port: Int { self.channel.localAddress!.port! }

        func shutdown() async throws {
            for child in self.accepted.withLockedValue({ $0 }) {
                try? await child.close()
            }
            try await self.channel.close()
        }
    }

    enum Outcome: Sendable {
        case pending
        case connected
        case failed(any Error)
    }

    private func configuration(port: Int, tls: Bool, timeout: TimeAmount?) throws
        -> OracleConnection.Configuration
    {
        var config = OracleConnection.Configuration(
            host: "127.0.0.1", port: port,
            service: .serviceName("SERVICE"), username: "scott", password: "tiger",
            tls: tls ? .require(try NIOSSLContext(configuration: .makeClientConfiguration())) : .disable
        )
        config.options.connectTimeout = .seconds(5)
        config.options.handshakeTimeout = timeout
        return config
    }

    /// Runs `connect` in its own task and waits for it, bounded by `limit`.
    /// `connect` cannot be cancelled, so a regression would otherwise hang the
    /// suite: on `.pending` the caller shuts the server down, which ends it.
    private func outcome(
        within limit: Duration,
        _ connect: @escaping @Sendable () async throws -> OracleConnection
    ) async -> (Outcome, Duration, Task<Void, Never>) {
        let box = NIOLockedValueBox<Outcome>(.pending)
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            do {
                let connection = try await connect()
                box.withLockedValue { $0 = .connected }
                try? await connection.close()
            } catch {
                box.withLockedValue { $0 = .failed(error) }
            }
        }
        while clock.now - start < limit {
            if case .pending = box.withLockedValue({ $0 }) {
                try? await Task.sleep(for: .milliseconds(10))
            } else {
                break
            }
        }
        return (box.withLockedValue { $0 }, clock.now - start, task)
    }

    private func expectHandshakeTimeout(
        _ outcome: Outcome, elapsed: Duration, timeout: Duration,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .failed(let error) = outcome else {
            Issue.record("expected a handshake timeout, got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        #expect(
            (error as? OracleSQLError)?.code == .handshakeTimeout, "got \(String(reflecting: error))",
            sourceLocation: sourceLocation)
        #expect(elapsed >= timeout, sourceLocation: sourceLocation)
        #expect(elapsed < timeout + .seconds(3), "took \(elapsed)", sourceLocation: sourceLocation)
    }

    /// The client closed its end: the server's accepted channel sees EOF.
    private func clientClosed(_ server: SilentServer) async -> Bool {
        for _ in 0..<300 {
            let children = server.accepted.withLockedValue { $0 }
            if !children.isEmpty, children.allSatisfy({ !$0.isActive }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test(arguments: [false, true])
    func silentServerFailsTheConnectAtTheDeadline(tls: Bool) async throws {
        let server = try await SilentServer()
        let config = try self.configuration(port: server.port, tls: tls, timeout: .milliseconds(500))

        let (outcome, elapsed, task) = await self.outcome(within: .seconds(10)) {
            try await OracleConnection.connect(configuration: config, id: 1)
        }
        self.expectHandshakeTimeout(outcome, elapsed: elapsed, timeout: .milliseconds(500))
        #expect(server.accepted.withLockedValue { $0.count } == 1)
        #expect(await self.clientClosed(server), "the client channel must be closed")

        try await server.shutdown()
        await task.value  // the connect task has ended: nothing leaked
    }

    /// `OracleClient` connects through `ConnectionFactory`; the deadline holds
    /// there too.
    @Test func thePoolsConnectionFactoryHonoursTheDeadline() async throws {
        let server = try await SilentServer()
        let config = try self.configuration(port: server.port, tls: false, timeout: .milliseconds(500))
        let client = OracleClient(configuration: config, drcp: false)

        let (outcome, elapsed, task) = await self.outcome(within: .seconds(10)) {
            try await client.factory.makeConnection(1, pool: client.pool)
        }
        self.expectHandshakeTimeout(outcome, elapsed: elapsed, timeout: .milliseconds(500))
        #expect(await self.clientClosed(server), "the client channel must be closed")

        try await server.shutdown()
        await task.value
    }

    @Test func theDefaultIsThirtySeconds() {
        #expect(OracleConnection.Configuration.Options().handshakeTimeout == .seconds(30))
    }
}
