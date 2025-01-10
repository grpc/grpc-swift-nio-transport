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
public import GRPCNIOTransportCore
public import NIOTransportServices  // has to be public because of default argument value in init
public import NIOCore  // has to be public because of EventLoopGroup param in init

private import Network

extension HTTP2ClientTransport {
  /// A `ClientTransport` using HTTP/2 built on top of `NIOTransportServices`.
  ///
  /// This transport builds on top of SwiftNIO's Transport Services networking layer and is the recommended
  /// variant for use on Darwin-based platforms (macOS, iOS, etc.).
  /// If you are targeting Linux platforms then you should use the `NIOPosix` variant of
  /// the `HTTP2ClientTransport`.
  ///
  /// To use this transport you need to provide a 'target' to connect to which will be resolved
  /// by an appropriate resolver from the resolver registry. By default the resolver registry can
  /// resolve DNS targets, IPv4 and IPv6 targets, and Unix domain socket targets. Virtual Socket
  /// targets are not supported with this transport. If you use a custom target you must also provide an
  /// appropriately configured registry.
  ///
  /// You can control various aspects of connection creation, management, security and RPC behavior via
  /// the ``Config``. Load balancing policies and other RPC specific behavior can be configured via
  /// the `ServiceConfig` (if it isn't provided by a resolver).
  ///
  /// Beyond creating the transport you don't need to interact with it directly, instead, pass it
  /// to a `GRPCClient`:
  ///
  /// ```swift
  /// try await withThrowingDiscardingTaskGroup { group in
  ///   let transport = try HTTP2ClientTransport.TransportServices(
  ///     target: .ipv4(host: "example.com"),
  ///     transportSecurity: .plaintext
  ///   )
  ///   let client = GRPCClient(transport: transport)
  ///   group.addTask {
  ///     try await client.run()
  ///   }
  ///
  ///   // ...
  /// }
  /// ```
  public struct TransportServices: ClientTransport {
    public typealias Bytes = GRPCNIOTransportBytes

    private let channel: GRPCChannel

    public var retryThrottle: RetryThrottle? {
      self.channel.retryThrottle
    }

    /// Creates a new NIOTransportServices-based HTTP/2 client transport.
    ///
    /// - Parameters:
    ///   - target: A target to resolve.
    ///   - transportSecurity: The configuration for securing network traffic.
    ///   - config: Configuration for the transport.
    ///   - resolverRegistry: A registry of resolver factories.
    ///   - serviceConfig: Service config controlling how the transport should establish and
    ///       load-balance connections.
    ///   - eventLoopGroup: The underlying NIO `EventLoopGroup` to run connections on. This must
    ///       be a `MultiThreadedEventLoopGroup` or an `EventLoop` from
    ///       a `MultiThreadedEventLoopGroup`.
    /// - Throws: When no suitable resolver could be found for the `target`.
    public init(
      target: any ResolvableTarget,
      transportSecurity: TransportSecurity,
      config: Config = .defaults,
      resolverRegistry: NameResolverRegistry = .defaults,
      serviceConfig: ServiceConfig = ServiceConfig(),
      eventLoopGroup: any EventLoopGroup = .singletonNIOTSEventLoopGroup
    ) throws {
      guard let resolver = resolverRegistry.makeResolver(for: target) else {
        throw RuntimeError(
          code: .transportError,
          message: """
            No suitable resolvers to resolve '\(target)'. You must make sure that the resolver \
            registry has a suitable name resolver factory registered for the given target.
            """
        )
      }

      self.channel = GRPCChannel(
        resolver: resolver,
        connector: Connector(
          eventLoopGroup: eventLoopGroup,
          config: config,
          transportSecurity: transportSecurity
        ),
        config: GRPCChannel.Config(transportServices: config),
        defaultServiceConfig: serviceConfig
      )
    }

    public func connect() async throws {
      await self.channel.connect()
    }

    public func beginGracefulShutdown() {
      self.channel.beginGracefulShutdown()
    }

    public func withStream<T: Sendable>(
      descriptor: MethodDescriptor,
      options: CallOptions,
      _ closure: (RPCStream<Inbound, Outbound>) async throws -> T
    ) async throws -> T {
      try await self.channel.withStream(descriptor: descriptor, options: options, closure)
    }

    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? {
      self.channel.config(forMethod: descriptor)
    }
  }
}

extension HTTP2ClientTransport.TransportServices {
  struct Connector: HTTP2Connector {
    private let config: HTTP2ClientTransport.TransportServices.Config
    private let transportSecurity: HTTP2ClientTransport.TransportServices.TransportSecurity
    private let eventLoopGroup: any EventLoopGroup

    init(
      eventLoopGroup: any EventLoopGroup,
      config: HTTP2ClientTransport.TransportServices.Config,
      transportSecurity: HTTP2ClientTransport.TransportServices.TransportSecurity
    ) {
      self.eventLoopGroup = eventLoopGroup
      self.config = config
      self.transportSecurity = transportSecurity
    }

    func establishConnection(
      to address: GRPCNIOTransportCore.SocketAddress,
      authority: String?
    ) async throws -> HTTP2Connection {
      let bootstrap: NIOTSConnectionBootstrap
      let isPlainText: Bool
      switch self.transportSecurity.wrapped {
      case .plaintext:
        isPlainText = true
        bootstrap = NIOTSConnectionBootstrap(group: self.eventLoopGroup)
          .channelOption(NIOTSChannelOptions.waitForActivity, value: false)

      case .tls(let tlsConfig):
        isPlainText = false
        do {
          let options = try NWProtocolTLS.Options(tlsConfig, authority: authority)
          bootstrap = NIOTSConnectionBootstrap(group: self.eventLoopGroup)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .tlsOptions(options)
        } catch {
          throw RuntimeError(
            code: .transportError,
            message: "Couldn't create NWProtocolTLS.Options, check your TLS configuration.",
            cause: error
          )
        }
      }

      let (channel, multiplexer) = try await bootstrap.connect(to: address) { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.configureGRPCClientPipeline(
            channel: channel,
            config: GRPCChannel.Config(transportServices: self.config)
          )
        }
      }

      return HTTP2Connection(
        channel: channel,
        multiplexer: multiplexer,
        isPlaintext: isPlainText
      )
    }
  }
}

extension HTTP2ClientTransport.TransportServices {
  /// Configuration for the `TransportServices` transport.
  public struct Config: Sendable {
    /// Configuration for HTTP/2 connections.
    public var http2: HTTP2ClientTransport.Config.HTTP2

    /// Configuration for backoff used when establishing a connection.
    public var backoff: HTTP2ClientTransport.Config.Backoff

    /// Configuration for connection management.
    public var connection: HTTP2ClientTransport.Config.Connection

    /// Compression configuration.
    public var compression: HTTP2ClientTransport.Config.Compression

    /// Creates a new connection configuration.
    ///
    /// - Parameters:
    ///   - http2: HTTP2 configuration.
    ///   - backoff: Backoff configuration.
    ///   - connection: Connection configuration.
    ///   - compression: Compression configuration.
    ///
    /// - SeeAlso: ``defaults(configure:)`` and ``defaults``.
    public init(
      http2: HTTP2ClientTransport.Config.HTTP2,
      backoff: HTTP2ClientTransport.Config.Backoff,
      connection: HTTP2ClientTransport.Config.Connection,
      compression: HTTP2ClientTransport.Config.Compression
    ) {
      self.http2 = http2
      self.connection = connection
      self.backoff = backoff
      self.compression = compression
    }

    /// Default configuration.
    public static var defaults: Self {
      Self.defaults()
    }

    /// Default values.
    ///
    /// - Parameters:
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    public static func defaults(
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        http2: .defaults,
        backoff: .defaults,
        connection: .defaults,
        compression: .defaults
      )
      configure(&config)
      return config
    }
  }
}

extension GRPCChannel.Config {
  init(transportServices config: HTTP2ClientTransport.TransportServices.Config) {
    self.init(
      http2: config.http2,
      backoff: config.backoff,
      connection: config.connection,
      compression: config.compression
    )
  }
}

extension NIOTSConnectionBootstrap {
  fileprivate func connect<Output: Sendable>(
    to address: GRPCNIOTransportCore.SocketAddress,
    childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Output>
  ) async throws -> Output {
    if address.virtualSocket != nil {
      throw RuntimeError(
        code: .transportError,
        message: """
            Virtual sockets are not supported by 'HTTP2ClientTransport.TransportServices'. \
            Please use the 'HTTP2ClientTransport.Posix' transport.
          """
      )
    } else {
      return try await self.connect(
        to: NIOCore.SocketAddress(address),
        channelInitializer: childChannelInitializer
      )
    }
  }
}

extension ClientTransport where Self == HTTP2ClientTransport.TransportServices {
  /// Create a new `TransportServices` based HTTP/2 client transport.
  ///
  /// - Parameters:
  ///   - target: A target to resolve.
  ///   - transportSecurity: The security settings applied to the transport.
  ///   - config: Configuration for the transport.
  ///   - resolverRegistry: A registry of resolver factories.
  ///   - serviceConfig: Service config controlling how the transport should establish and
  ///       load-balance connections.
  ///   - eventLoopGroup: The underlying NIO `EventLoopGroup` to run connections on. This must
  ///       be a `NIOTSEventLoopGroup` or an `EventLoop` from
  ///       a `NIOTSEventLoopGroup`.
  /// - Throws: When no suitable resolver could be found for the `target`.
  public static func http2NIOTS(
    target: any ResolvableTarget,
    transportSecurity: HTTP2ClientTransport.TransportServices.TransportSecurity,
    config: HTTP2ClientTransport.TransportServices.Config = .defaults,
    resolverRegistry: NameResolverRegistry = .defaults,
    serviceConfig: ServiceConfig = ServiceConfig(),
    eventLoopGroup: any EventLoopGroup = .singletonNIOTSEventLoopGroup
  ) throws -> Self {
    try HTTP2ClientTransport.TransportServices(
      target: target,
      transportSecurity: transportSecurity,
      config: config,
      resolverRegistry: resolverRegistry,
      serviceConfig: serviceConfig,
      eventLoopGroup: eventLoopGroup
    )
  }
}

extension NWProtocolTLS.Options {
  convenience init(
    _ tlsConfig: HTTP2ClientTransport.TransportServices.TLS,
    authority: String?
  ) throws {
    self.init()

    if let identityProvider = tlsConfig.identityProvider {
      guard let sec_identity = sec_identity_create(try identityProvider()) else {
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
    }

    switch tlsConfig.serverCertificateVerification.wrapped {
    case .doNotVerify:
      sec_protocol_options_set_peer_authentication_required(
        self.securityProtocolOptions,
        false
      )

    case .fullVerification:
      sec_protocol_options_set_peer_authentication_required(
        self.securityProtocolOptions,
        true
      )
      authority?.withCString { serverName in
        sec_protocol_options_set_tls_server_name(
          self.securityProtocolOptions,
          serverName
        )
      }

    case .noHostnameVerification:
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
