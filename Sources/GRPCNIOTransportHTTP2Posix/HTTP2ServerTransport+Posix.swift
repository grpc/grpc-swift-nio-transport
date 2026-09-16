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

public import GRPCCore
public import GRPCNIOTransportCore  // should be @usableFromInline
internal import NIOCore
internal import NIOExtras
internal import NIOHTTP2
public import NIOPosix  // has to be public because of default argument value in init
private import NIOSSL
private import SwiftASN1
private import Synchronization
public import X509

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport {
  /// A server transport using HTTP/2 built on top of NIOPosix.
  ///
  /// This transport builds on top of SwiftNIO's Posix networking layer and is suitable for use
  /// on Linux and Darwin-based platforms (macOS, iOS, etc.). However, it's *strongly* recommended
  /// that if you are targeting Darwin platforms then you should use the `NIOTS` variant of
  /// the `HTTP2ServerTransport`.
  ///
  /// You can control various aspects of connection creation, management, security and RPC behavior via
  /// the ``Config``.
  ///
  /// Beyond creating the transport you don't need to interact with it directly, instead, pass it
  /// to a `GRPCServer`:
  ///
  /// ```swift
  /// try await withThrowingDiscardingTaskGroup { group in
  ///   let transport = HTTP2ServerTransport.Posix(
  ///     address: .ipv4(host: "127.0.0.1", port: 0),
  ///     transportSecurity: .plaintext
  ///   )
  ///   let server = GRPCServer(transport: transport, services: someServices)
  ///   group.addTask {
  ///     try await server.serve()
  ///   }
  ///
  ///   // ...
  /// }
  /// ```
  public struct Posix: ServerTransport, ListeningServerTransport {
    /// The concrete type of bytes this transport produces and consumes.
    public typealias Bytes = GRPCNIOTransportBytes

    fileprivate struct ListenerFactory: HTTP2ServerTransport.ListenerFactory {
      private let address: Address
      private let transportSecurity: TransportSecurity

      fileprivate let eventLoopGroup: any EventLoopGroup

      init(
        address: Address,
        transportSecurity: TransportSecurity,
        eventLoopGroup: any EventLoopGroup
      ) {
        self.address = address
        self.transportSecurity = transportSecurity
        self.eventLoopGroup = eventLoopGroup
      }

      enum Address {
        case socketAddress(GRPCNIOTransportCore.SocketAddress)
        case listeningSocket(Int)

        var socketAddress: GRPCNIOTransportCore.SocketAddress? {
          switch self {
          case .socketAddress(let address):
            return address
          case .listeningSocket:
            return nil
          }
        }
      }

      func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator
      ) async throws -> NIOAsyncChannel<
        HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel,
        Never
      > {
        let tls: HTTP2ServerTransport.ConnectionConfigurator.TLS
        let sslContext: NIOSSLContext?
        let customVerificationCallback:
          (
            @Sendable (
              [NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResultWithMetadata>
            ) -> Void
          )?

        switch self.transportSecurity.wrapped {
        case .plaintext:
          tls = .none
          sslContext = nil
          customVerificationCallback = nil

        case .tls(let tlsConfig):
          do {
            sslContext = try NIOSSLContext(configuration: TLSConfiguration(tlsConfig))
          } catch {
            throw RuntimeError(
              code: .transportError,
              message: "Couldn't create SSL context, check your TLS configuration.",
              cause: error
            )
          }
          tls = .configured(requireALPN: tlsConfig.requireALPN)
          customVerificationCallback = tlsConfig.customVerificationCallback
        }

        let serverChannel = try await ServerBootstrap(group: self.eventLoopGroup)
          .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
          .serverChannelInitializer { channel in
            #if canImport(Darwin)
            channel.eventLoop.makeCompletedFuture {
              try channel.pipeline.syncOperations.addHandler(SwallowFcntlFailedErrorHandler())
            }.flatMap {
              listenerConfigurator.configure(channel: channel)
            }
            #else
            listenerConfigurator.configure(channel: channel)
            #endif
          }
          .bind(to: self.address) { channel in
            channel.eventLoop.makeCompletedFuture {
              if let sslContext {
                let sslHandler: NIOSSLServerHandler
                if let callback = customVerificationCallback {
                  sslHandler = NIOSSLServerHandler(
                    context: sslContext,
                    customVerificationCallbackWithMetadata: callback
                  )
                } else {
                  sslHandler = NIOSSLServerHandler(context: sslContext)
                }

                try channel.pipeline.syncOperations.addHandler(sslHandler)
              }
            }.flatMap {
              connectionConfigurator.configure(channel: channel, tls: tls)
            }
          }

        return serverChannel
      }

      func listeningAddress(
        of channel: any Channel
      ) async throws -> GRPCNIOTransportCore.SocketAddress? {
        // NIO's `SocketAddress` can't represent a vsock address, so a vsock listening channel has
        // no `localAddress` to report: ask the channel for the address it's bound to instead. A
        // listener bound to `Port/any` only learns its port from the kernel, so this is also the
        // only way to report where it actually is.
        //
        // The option is rejected for sockets which aren't vsock sockets, so asking is also how the
        // address family of a listener gRPC was handed as a descriptor is resolved.
        if let vsock = try? await channel.getOption(.localVsockAddress).get() {
          return .vsock(GRPCNIOTransportCore.SocketAddress.VirtualSocket(vsock))
        }

        return channel.localAddress.map { GRPCNIOTransportCore.SocketAddress($0) }
      }
    }

    private let underlyingTransport: Custom<ListenerFactory>
    private let address: ListenerFactory.Address

    /// The listening address for this server transport.
    ///
    /// It is an `async` property because it will only return once the address has been successfully bound.
    ///
    /// - Throws: A runtime error is thrown if the address could not be bound or is not bound any
    /// longer, because the transport isn't listening anymore. It can also throw if the transport returned an
    /// invalid address.
    public var listeningAddress: GRPCNIOTransportCore.SocketAddress {
      get async throws {
        if let address = await self.underlyingTransport.listeningAddress {
          return address
        }

        switch self.address {
        case .socketAddress(let socketAddress) where socketAddress.virtualSocket != nil:
          // Reading the bound address off the channel failed, so fall back to what was asked for.
          return socketAddress

        case .listeningSocket, .socketAddress:
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

    /// Creates a Posix transport, binding to the given address.
    ///
    /// - Parameters:
    ///   - address: The address to which the server should be bound.
    ///   - transportSecurity: The configuration for securing network traffic.
    ///   - config: The transport configuration.
    ///   - eventLoopGroup: The underlying NIO `EventLoopGroup` to run this transport on.
    public init(
      address: GRPCNIOTransportCore.SocketAddress,
      transportSecurity: TransportSecurity,
      config: Config = .defaults,
      eventLoopGroup: MultiThreadedEventLoopGroup = .singletonMultiThreadedEventLoopGroup
    ) {
      self.init(
        address: .socketAddress(address),
        transportSecurity: transportSecurity,
        config: config,
        eventLoopGroup: eventLoopGroup
      )
    }

    /// Creates a Posix transport from an already bound listening socket.
    ///
    /// - Parameters:
    ///   - fileDescriptor: The file descriptor of an already bound listening socket.
    ///   - transportSecurity: The configuration for securing network traffic.
    ///   - config: The transport configuration.
    ///   - eventLoopGroup: The underlying NIO `EventLoopGroup` to run this transport on.
    /// - Important: gRPC takes ownership of the `fileDescriptor` passed in, you *must not* close
    ///   the descriptor manually.
    @available(gRPCSwiftNIOTransport 2.6, *)
    public init(
      listeningSocketDescriptor fileDescriptor: Int,
      transportSecurity: TransportSecurity,
      config: Config = .defaults,
      eventLoopGroup: MultiThreadedEventLoopGroup = .singletonMultiThreadedEventLoopGroup
    ) {
      self.init(
        address: .listeningSocket(fileDescriptor),
        transportSecurity: transportSecurity,
        config: config,
        eventLoopGroup: eventLoopGroup
      )
    }

    private init(
      address: ListenerFactory.Address,
      transportSecurity: TransportSecurity,
      config: Config = .defaults,
      eventLoopGroup: MultiThreadedEventLoopGroup = .singletonMultiThreadedEventLoopGroup
    ) {
      self.address = address
      self.underlyingTransport = Custom(
        eventLoopGroup: eventLoopGroup,
        quiescingHelper: ServerQuiescingHelper(group: eventLoopGroup),
        config: Custom<ListenerFactory>.Config(
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
      ) { channel in
        var context = HTTP2ServerTransport.Posix.Context()

        do {
          // The validated certificate chain is only available when using a custom verification callback, while the
          // peer certificate is only available when using the BoringSSL backend. But if we can get the certificate
          // chain, we can set the peer certificate (the leaf of the chain) as well.
          if let peerCertificateChain =
            try await channel.nioSSL_peerValidatedCertificateChain().get(),
            let peerCertificateChain = try? X509.ValidatedCertificateChain(peerCertificateChain)
          {
            context.peerCertificate = peerCertificateChain.leaf
            context.peerCertificateChain = peerCertificateChain
          } else if let peerCert = try await channel.nioSSL_peerCertificate().get() {
            let serialized = try peerCert.toDERBytes()
            let swiftCert = try Certificate(derEncoded: serialized)
            context.peerCertificate = swiftCert
          }
        } catch {}

        return context
      }
    }

    /// Stores the server context, making it available to accepted connections.
    public func configure(context: GRPCServerContext) {
      self.underlyingTransport.configure(context: context)
    }

    /// Starts serving, binding the listening address and accepting connections.
    public func listen(
      streamHandler:
        @escaping @Sendable (
          _ stream: RPCStream<Inbound, Outbound>,
          _ context: ServerContext
        ) async -> Void
    ) async throws {
      try await self.underlyingTransport.listen(streamHandler: streamHandler)
    }

    /// Begins graceful shutdown of the listening channel.
    public func beginGracefulShutdown() {
      self.underlyingTransport.beginGracefulShutdown()
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport.Posix {
  /// The transport-specific context for the Posix server transport.
  public struct Context: ServerContext.TransportSpecific {
    /// The peer certificate (if any) from the mTLS handshake.
    public var peerCertificate: Certificate?

    /// The validated peer certificate chain from the mTLS handshake.
    ///
    /// This is only available when using a custom verification callback.
    @available(gRPCSwiftNIOTransport 2.2, *)
    public var peerCertificateChain: X509.ValidatedCertificateChain?

    /// Creates an empty context.
    public init() {
    }
  }

  /// Configuration for the Posix transport.
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

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - http2: HTTP2 configuration.
    ///   - rpc: RPC configuration.
    ///   - connection: Connection configuration.
    ///   - compression: Compression configuration.
    ///   - channelDebuggingCallbacks: Channel callbacks for debugging.
    ///
    /// - SeeAlso: ``defaults(configure:)`` and ``defaults``.
    public init(
      http2: HTTP2ServerTransport.Config.HTTP2,
      rpc: HTTP2ServerTransport.Config.RPC,
      connection: HTTP2ServerTransport.Config.Connection,
      compression: HTTP2ServerTransport.Config.Compression,
      channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks
    ) {
      self.compression = compression
      self.connection = connection
      self.http2 = http2
      self.rpc = rpc
      self.channelDebuggingCallbacks = channelDebuggingCallbacks
    }

    /// Default configuration.
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
        http2: .defaults,
        rpc: .defaults,
        connection: .defaults,
        compression: .defaults,
        channelDebuggingCallbacks: .defaults
      )
      configure(&config)
      return config
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension ServerBootstrap {
  fileprivate func bind<Output: Sendable>(
    to address: HTTP2ServerTransport.Posix.ListenerFactory.Address,
    childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Output>
  ) async throws -> NIOAsyncChannel<Output, Never> {
    switch address {
    case .socketAddress(let address):
      if let virtualSocket = address.virtualSocket {
        return try await self.bind(
          to: VsockAddress(virtualSocket),
          childChannelInitializer: childChannelInitializer
        )
      } else if let uds = address.unixDomainSocket {
        return try await self.bind(
          unixDomainSocketPath: uds.path,
          cleanupExistingSocketFile: true,
          childChannelInitializer: childChannelInitializer
        )
      } else {
        return try await self.bind(
          to: NIOCore.SocketAddress(address),
          childChannelInitializer: childChannelInitializer
        )
      }

    case .listeningSocket(let descriptor):
      return try await self.bind(
        NIOBSDSocket.Handle(descriptor),
        childChannelInitializer: childChannelInitializer
      )
    }
  }
}

/// Provides a static factory method for constructing a Posix-based HTTP/2 server transport bound to a socket address.
@available(gRPCSwiftNIOTransport 2.0, *)
extension ServerTransport where Self == HTTP2ServerTransport.Posix {
  /// Creates a Posix-based HTTP/2 server transport.
  ///
  /// - Parameters:
  ///   - address: The address to which the server should be bound.
  ///   - transportSecurity: The configuration for securing network traffic.
  ///   - config: The transport configuration.
  ///   - eventLoopGroup: The underlying NIO `EventLoopGroup` to the server on. This must
  ///       be a `MultiThreadedEventLoopGroup` or an `EventLoop` from
  ///       a `MultiThreadedEventLoopGroup`.
  public static func http2NIOPosix(
    address: GRPCNIOTransportCore.SocketAddress,
    transportSecurity: HTTP2ServerTransport.Posix.TransportSecurity,
    config: HTTP2ServerTransport.Posix.Config = .defaults,
    eventLoopGroup: MultiThreadedEventLoopGroup = .singletonMultiThreadedEventLoopGroup
  ) -> Self {
    HTTP2ServerTransport.Posix(
      address: address,
      transportSecurity: transportSecurity,
      config: config,
      eventLoopGroup: eventLoopGroup
    )
  }
}

/// Provides a static factory method for constructing a Posix-based HTTP/2 server transport from an already bound listening socket.
@available(gRPCSwiftNIOTransport 2.6, *)
extension ServerTransport where Self == HTTP2ServerTransport.Posix {
  /// Creates a Posix-based HTTP/2 server transport.
  ///
  /// - Parameters:
  ///   - fileDescriptor: The file descriptor of an already bound listening socket.
  ///   - transportSecurity: The configuration for securing network traffic.
  ///   - config: The transport configuration.
  ///   - eventLoopGroup: The underlying NIO `EventLoopGroup` to the server on. This must
  ///       be a `MultiThreadedEventLoopGroup` or an `EventLoop` from
  ///       a `MultiThreadedEventLoopGroup`.
  /// - Important: gRPC takes ownership of the `fileDescriptor` passed in, you *must not* close
  ///   the descriptor manually.
  public static func http2NIOPosix(
    listeningSocketDescriptor fileDescriptor: Int,
    transportSecurity: HTTP2ServerTransport.Posix.TransportSecurity,
    config: HTTP2ServerTransport.Posix.Config = .defaults,
    eventLoopGroup: MultiThreadedEventLoopGroup = .singletonMultiThreadedEventLoopGroup
  ) -> Self {
    HTTP2ServerTransport.Posix(
      listeningSocketDescriptor: fileDescriptor,
      transportSecurity: transportSecurity,
      config: config,
      eventLoopGroup: eventLoopGroup
    )
  }
}
