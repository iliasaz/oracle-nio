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
import NIOCore
import NIOEmbedded
import Testing

@testable import OracleNIO

/// Establishes an ``OracleConnection`` over a `NIOAsyncTestingChannel`, playing
/// the server's side of the handshake (no OOB check, fast auth, the client's
/// verification of the server's auth response bypassed).
func makeAsyncTestingConnection(
    id: OracleConnection.ID = 1,
    logger: Logger = Logger(label: "AsyncTestingConnection")
) async throws -> (OracleConnection, NIOAsyncTestingChannel) {
    typealias C = OracleBackendMessageDecoder.Container
    let eventLoop = NIOAsyncTestingEventLoop()
    let protocolVersion =
        OracleBackendMessageEncoder
        .ProtocolVersion(Int(Constants.TNS_VERSION_MINIMUM))
    let channel = try await NIOAsyncTestingChannel(loop: eventLoop) { channel in
        try channel.pipeline.syncOperations.addHandler(
            ReverseByteToMessageHandler(OracleFrontendMessageDecoder()))
        try channel.pipeline.syncOperations.addHandler(
            ReverseMessageToByteHandler(OracleBackendMessageEncoder(protocolVersion: protocolVersion))
        )
    }
    try await channel.connect(to: .makeAddressResolvingHost("localhost", port: 1521))

    let configuration = OracleConnection.Configuration(
        establishedChannel: channel,
        service: .serviceName("oracle"),
        username: "username",
        password: "password"
    )

    async let connectionPromise = OracleConnection.connect(
        on: eventLoop,
        configuration: configuration,
        id: id,
        logger: logger
    )

    let connect = try await channel.waitForOutboundWrite(as: OracleFrontendMessage.self)
    #expect(connect == .connect)
    try await channel.writeInbound(
        C(messages: [
            OracleBackendMessage.accept(.init(newCapabilities: .desired()))
        ]))
    protocolVersion.value.withLockedValue({ $0 = Int(Constants.TNS_VERSION_DESIRED) })

    let fastAuth = try await channel.waitForOutboundWrite(as: OracleFrontendMessage.self)
    #expect(fastAuth == .fastAuth)
    try await channel.writeInbound(
        C(messages: [
            .parameter([
                "AUTH_PBKDF2_CSK_SALT": .init(
                    value: "D390EB852C15E0BB6D09B35634196549", flags: 0),
                "AUTH_SESSKEY": .init(
                    value: "E25A7AE255A27542B254C2566696E7902F8C06DCB46CB30F1EA9D859F56B5C94",
                    flags: 0),
                "AUTH_VFR_DATA": .init(
                    value: "CA52D77E4C359A2A5701E4DADB594963",
                    flags: Constants.TNS_VERIFIER_TYPE_12C),
                "AUTH_PBKDF2_VGEN_COUNT": .init(value: "4096", flags: 0),
                "AUTH_PBKDF2_SDER_COUNT": .init(value: "3", flags: 0),
                "AUTH_GLOBALLY_UNIQUE_DBID\0": .init(
                    value: "EB3F4E21E6E94E317CBA938EE89045DF", flags: 0),
            ])
        ]))
    let authPhase2 = try await channel.waitForOutboundWrite(as: OracleFrontendMessage.self)
    #expect(authPhase2 == .authPhaseTwo)

    // bypass security check
    try await channel.pipeline.handler(type: OracleChannelHandler.self).map { $0.setComboKey(nil) }.get()

    try await channel.writeInbound(
        C(messages: [
            .parameter([
                "AUTH_VERSION_NO": .init(value: "386138501", flags: 0),
                "AUTH_SESSION_ID": .init(value: "\(50 + id)", flags: 0),
                "AUTH_SERIAL_NUM": .init(value: "11865", flags: 0),
            ])
        ]))

    return (try await connectionPromise, channel)
}

/// Delivers already-decoded backend messages to the connection, as if the
/// server had sent them in one packet.
///
/// Used for messages the test encoder cannot put on the wire (for example
/// `.error`): they enter the pipeline right after the client's decoder.
func injectBackendMessages(
    _ messages: [OracleBackendMessage],
    into channel: NIOAsyncTestingChannel
) async throws {
    let container = OracleBackendMessageDecoder.Container(
        flags: 0, messages: TinySequence(messages))
    try await channel.pipeline
        .context(handlerType: ByteToMessageHandler<OracleBackendMessageDecoder>.self)
        .map { context in
            context.fireChannelRead(NIOAny(TinySequence([container])))
        }
        .get()
}

/// Answers the client's Logoff and checks the following Close, which is
/// what a graceful ``OracleConnection/close()`` exchanges with the server.
func acknowledgeLogoff(on channel: NIOAsyncTestingChannel) async throws {
    let logoff = try await channel.waitForOutboundWrite(as: OracleFrontendMessage.self)
    #expect(logoff == .logoff)
    try await channel.writeInbound(
        OracleBackendMessageDecoder.Container(messages: [
            .status(.init(callStatus: 0, endToEndSequenceNumber: 0))
        ]))
    let close = try await channel.waitForOutboundWrite(as: OracleFrontendMessage.self)
    #expect(close == .close)
}

extension BackendError {
    /// A server error as the server reports it for a failed call.
    static func server(number: UInt32, cursorID: UInt16 = 0) -> BackendError {
        BackendError(
            number: number, cursorID: cursorID, position: 0, rowCount: 0, isWarning: false,
            message: "ORA-\(String(number, padding: 5)): test", rowID: nil, batchErrors: [])
    }
}
