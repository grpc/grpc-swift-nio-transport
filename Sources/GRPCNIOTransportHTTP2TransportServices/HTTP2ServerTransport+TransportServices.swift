/*
 * Copyright 2024, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if canImport(Network)
public import GRPCCore
public import NIOTransportServices  // has to be public because of default argument value in init
public import GRPCNIOTransportCore

private import NIOCore
private import NIOExtras
private import NIOHTTP2
private import Network

private import Synchronization

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport {
  /// A NIO Transport Services-backed implementation of a server transport.
  public struct TransportServices: ServerTransport, ListeningServerTransport {
    public typealias Bytes = GRPCNIOTransportBytes

    fileprivate struct ListenerFactory: HTTP2ServerTransport.ListenerFactory {
      private let address: GRPCNIOTransportCore.SocketAddress
      private let transportSecurity: TransportSecurity

      fileprivate let eventLoopGroup: any EventLoopGroup

      init(
        address: GRPCNIOTransportCore.SocketAddress,
        transportSecurity: TransportSecurity,
        eventLoopGroup: any EventLoopGroup
      ) {
        self.address = address
        self.transportSecurity = transportSecurity
        self.eventLoopGroup = eventLoopGroup
      }

      func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator
      ) async throws -> NIOAsyncChannel<
        HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel,
        Never
      > {
        let bootstrap: NIOTSListenerBootstrap

        let tls: HTTP2ServerTransport.ConnectionConfigurator.TLS
        switch self.transportSecurity.wrapped {
        case .plaintext:
          tls = .none
          bootstrap = NIOTSListenerBootstrap(group: self.eventLoopGroup)

        case .tls(let tlsConfig):
          tls = .configured(requireALPN: tlsConfig.requireALPN)
          bootstrap = NIOTSListenerBootstrap(group: self.eventLoopGroup)
            .tlsOptions(try NWProtocolTLS.Options(tlsConfig))
        }

        let serverChannel =
          try await bootstrap
          .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
          .serverChannelInitializer { channel in
            listenerConfigurator.configure(channel: channel)
          }
          .bind(to: self.address) { channel in
            channel.eventLoop.makeCompletedFuture {
              let waitForActive = WaitForActive(promise: channel.eventLoop.makePromise())
              try channel.pipeline.syncOperations.addHandler(waitForActive, name: "wait-for-active")
            }.flatMap {
              connectionConfigurator.configure(channel: channel, tls: tls)
            }
          }

        return serverChannel
      }
    }

    private let underlyingTransport: Custom<ListenerFactory>

    /// The listening address for this server transport.
    ///
    /// It is an `async` property because it will only return once the address has been successfully bound.
    ///
    /// - Throws: A runtime error will be thrown if the address could not be bound or is not bound any
    /// longer, because the transport isn't listening anymore. It can also throw if the transport returned an
    /// invalid address.
    public var listeningAddress: GRPCNIOTransportCore.SocketAddress {
      get async throws {
        if let address = await self.underlyingTransport.listeningAddress {
          return address
        } else {
          throw RuntimeError(
            code: .serverIsStopped,
            message: """
              There is no listening address bound for this server: there may have been \
              an error which caused the transport to close, or it may have shut down.
              """
          )
        }
      }
    }

    /// Create a new `TransportServices` transport.
    ///
    /// - Parameters:
    ///   - address: The address to which the server should be bound.
    ///   - transportSecurity: The security settings applied to the transport.
    ///   - config: The transport configuration.
    ///   - eventLoopGroup: The ELG from which to get ELs to run this transport.
    public init(
      address: GRPCNIOTransportCore.SocketAddress,
      transportSecurity: TransportSecurity,
      config: Config = .defaults,
      eventLoopGroup: NIOTSEventLoopGroup = .singletonNIOTSEventLoopGroup
    ) {
      self.underlyingTransport = Custom(
        eventLoopGroup: eventLoopGroup,
        quiescingHelper: ServerQuiescingHelper(group: eventLoopGroup),
        config: .init(
          compression: config.compression,
          connection: config.connection,
          http2: config.http2,
          rpc: config.rpc,
          channelDebuggingCallbacks: config.channelDebuggingCallbacks
        ),
        listenerFactory: ListenerFactory(
          address: address,
          transportSecurity: transportSecurity,
          eventLoopGroup: eventLoopGroup
        )
      )
    }

    public func listen(
      streamHandler:
        @escaping @Sendable (
          _ stream: RPCStream<Inbound, Outbound>,
          _ context: ServerContext
        ) async -> Void
    ) async throws {
      try await self.underlyingTransport.listen(streamHandler: streamHandler)
    }

    public func beginGracefulShutdown() {
      self.underlyingTransport.beginGracefulShutdown()
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport.TransportServices {
  /// Configuration for the `TransportServices` transport.
  public struct Config: Sendable {
    /// Compression configuration.
    public var compression: HTTP2ServerTransport.Config.Compression

    /// Connection configuration.
    public var connection: HTTP2ServerTransport.Config.Connection

    /// HTTP2 configuration.
    public var http2: HTTP2ServerTransport.Config.HTTP2

    /// RPC configuration.
    public var rpc: HTTP2ServerTransport.Config.RPC

    /// Channel callbacks for debugging.
    public var channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks

    /// Construct a new `Config`.
    /// - Parameters:
    ///   - compression: Compression configuration.
    ///   - connection: Connection configuration.
    ///   - http2: HTTP2 configuration.
    ///   - rpc: RPC configuration.
    ///   - channelDebuggingCallbacks: Channel callbacks for debugging.
    ///
    /// - SeeAlso: ``defaults(configure:)`` and ``defaults``.
    public init(
      compression: HTTP2ServerTransport.Config.Compression,
      connection: HTTP2ServerTransport.Config.Connection,
      http2: HTTP2ServerTransport.Config.HTTP2,
      rpc: HTTP2ServerTransport.Config.RPC,
      channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks
    ) {
      self.compression = compression
      self.connection = connection
      self.http2 = http2
      self.rpc = rpc
      self.channelDebuggingCallbacks = channelDebuggingCallbacks
    }

    public static var defaults: Self {
      Self.defaults()
    }

    /// Default values for the different configurations.
    ///
    /// - Parameters:
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    public static func defaults(
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        compression: .defaults,
        connection: .defaults,
        http2: .defaults,
        rpc: .defaults,
        channelDebuggingCallbacks: .defaults
      )
      configure(&config)
      return config
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension NIOTSListenerBootstrap {
  fileprivate func bind<Output: Sendable>(
    to address: GRPCNIOTransportCore.SocketAddress,
    childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Output>
  ) async throws -> NIOAsyncChannel<Output, Never> {
    if address.virtualSocket != nil {
      throw RuntimeError(
        code: .transportError,
        message: """
            Virtual sockets are not supported by 'HTTP2ServerTransport.TransportServices'. \
            Please use the 'HTTP2ServerTransport.Posix' transport.
          """
      )
    } else {
      return try await self.bind(
        to: NIOCore.SocketAddress(address),
        childChannelInitializer: childChannelInitializer
      )
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension ServerTransport where Self == HTTP2ServerTransport.TransportServices {
  /// Create a new `TransportServices` based HTTP/2 server transport.
  ///
  /// - Parameters:
  ///   - address: The address to which the server should be bound.
  ///   - transportSecurity: The security settings applied to the transport.
  ///   - config: The transport configuration.
  ///   - eventLoopGroup: The underlying NIO `EventLoopGroup` to the server on. This must
  ///       be a `NIOTSEventLoopGroup` or an `EventLoop` from a `NIOTSEventLoopGroup`.
  public static func http2NIOTS(
    address: GRPCNIOTransportCore.SocketAddress,
    transportSecurity: HTTP2ServerTransport.TransportServices.TransportSecurity,
    config: HTTP2ServerTransport.TransportServices.Config = .defaults,
    eventLoopGroup: NIOTSEventLoopGroup = .singletonNIOTSEventLoopGroup
  ) -> Self {
    return HTTP2ServerTransport.TransportServices(
      address: address,
      transportSecurity: transportSecurity,
      config: config,
      eventLoopGroup: eventLoopGroup
    )
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension NWProtocolTLS.Options {
  convenience init(_ tlsConfig: HTTP2ServerTransport.TransportServices.TLS) throws {
    self.init()

    let identity = try tlsConfig.identityProvider()
    let maybeSecIdentity: sec_identity_t?

    if tlsConfig.additionalCertificates.isEmpty {
      maybeSecIdentity = sec_identity_create(identity)
    } else {
      let certificates = tlsConfig.additionalCertificates as CFArray
      maybeSecIdentity = sec_identity_create_with_certificates(identity, certificates)
    }

    guard let sec_identity = maybeSecIdentity else {
      throw RuntimeError(
        code: .transportError,
        message: """
          There was an issue creating the SecIdentity required to set up TLS. \
          Please check your TLS configuration.
          """
      )
    }

    sec_protocol_options_set_local_identity(
      self.securityProtocolOptions,
      sec_identity
    )

    switch tlsConfig.clientCertificateVerification.wrapped {
    case .doNotVerify:
      sec_protocol_options_set_peer_authentication_required(
        self.securityProtocolOptions,
        false
      )

    case .fullVerification, .noHostnameVerification:
      sec_protocol_options_set_peer_authentication_required(
        self.securityProtocolOptions,
        true
      )
    }

    sec_protocol_options_set_min_tls_protocol_version(
      self.securityProtocolOptions,
      .TLSv12
    )

    for `protocol` in ["grpc-exp", "h2"] {
      sec_protocol_options_add_tls_application_protocol(
        self.securityProtocolOptions,
        `protocol`
      )
    }

    self.setUpVerifyBlock(trustRootsSource: tlsConfig.trustRoots)
  }
}
#endif
