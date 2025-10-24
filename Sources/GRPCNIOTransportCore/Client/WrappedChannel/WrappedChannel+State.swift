/*
 * Copyright 2025, gRPC Authors All rights reserved.
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

internal import GRPCCore
internal import NIOHTTP2

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.WrappedChannel {
  enum State {
    case idle(Idle)
    case configuring(Configuring)
    case configured(Configured)
    case ready(Ready)
    case shuttingDown
    case shutDown

    struct Idle {
      var queue: RequestQueue<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>>

      init() {
        self.queue = RequestQueue()
      }
    }

    struct Configuring {
      var queue: RequestQueue<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>>

      init(from state: consuming Idle) {
        self.queue = state.queue
      }
    }

    struct Configured {
      var queue: RequestQueue<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>>
      var multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>

      init(
        from state: consuming Configuring,
        multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>
      ) {
        self.queue = state.queue
        self.multiplexer = multiplexer
      }
    }

    struct Ready {
      var multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>

      init(from state: consuming Configured) {
        self.multiplexer = state.multiplexer
      }
    }

    init() {
      self = .idle(Idle())
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.WrappedChannel.State {
  enum ConnectAction {
    case configureChannel
    case `return`
  }

  mutating func connect() -> ConnectAction {
    switch consume self {
    case .idle(let state):
      self = .configuring(Configuring(from: state))
      return .configureChannel

    case .configuring(let state):
      self = .configuring(state)
      return .return

    case .configured(let state):
      self = .configured(state)
      return .return

    case .ready(let state):
      self = .ready(state)
      return .return

    case .shuttingDown:
      self = .shuttingDown
      return .return

    case .shutDown:
      self = .shutDown
      return .return
    }
  }

  enum ChannelConfiguredAction {
    case `continue`
    case shutDown
  }

  mutating func channelConfigured(
    multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>?
  ) -> ChannelConfiguredAction {
    let action: ChannelConfiguredAction

    switch consume self {
    case .configuring(let state):
      if let multiplexer = multiplexer {
        self = .configured(Configured(from: state, multiplexer: multiplexer))
        action = .continue
      } else {
        self = .shutDown
        action = .shutDown
      }

    case .shuttingDown:
      // Either way, close the channel.
      self = .shuttingDown
      action = .shutDown

    case .idle:
      fatalError("Invalid state")

    case .configured:
      fatalError("Invalid state")

    case .ready:
      fatalError("Invalid state")

    case .shutDown:
      fatalError("Invalid state")
    }

    return action
  }

  enum ReadyAction {
    case none
    case resume(
      continuations: [RequestQueue<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>>.Continuation],
      multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>
    )
  }

  mutating func ready() -> ReadyAction {
    switch consume self {
    case .configured(var state):
      let continuations = state.queue.removeAll()
      let multiplexer = state.multiplexer
      self = .ready(Ready(from: state))
      return .resume(continuations: continuations, multiplexer: multiplexer)

    case .shuttingDown:
      self = .shuttingDown
      return .none

    case .idle:
      fatalError("Invalid state")

    case .configuring:
      fatalError("Invalid state")

    case .ready:
      fatalError("Invalid state")

    case .shutDown:
      fatalError("Invalid state")
    }
  }

  enum BeginGracefulShutDownAction {
    case none
    case emitGracefulShutdownEvent
  }

  mutating func beginGracefulShutdown() -> BeginGracefulShutDownAction {
    let action: BeginGracefulShutDownAction

    switch consume self {
    case .idle:
      self = .shutDown
      action = .none

    case .configuring:
      self = .shuttingDown
      action = .none

    case .configured:
      self = .shuttingDown
      action = .emitGracefulShutdownEvent

    case .ready:
      self = .shuttingDown
      action = .emitGracefulShutdownEvent

    case .shuttingDown:
      self = .shuttingDown
      action = .none

    case .shutDown:
      self = .shutDown
      action = .none
    }

    return action
  }

  enum ConnectionClosedAction {
    case none
    case failQueuedStreams([CheckedContinuation<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>, any Error>])
  }

  mutating func connectionClosed() -> ConnectionClosedAction {
    switch consume self {
    case .idle(var state):
      self = .shutDown
      let continuations = state.queue.removeAll()
      return .failQueuedStreams(continuations)

    case .configuring(var state):
      self = .shutDown
      let continuations = state.queue.removeAll()
      return .failQueuedStreams(continuations)

    case .configured(var state):
      self = .shutDown
      let continuations = state.queue.removeAll()
      return .failQueuedStreams(continuations)

    case .ready:
      self = .shutDown
      return .none

    case .shuttingDown:
      self = .shuttingDown
      return .none

    case .shutDown:
      self = .shutDown
      return .none
    }
  }

  enum CreateStreamAction {
    case enqueue
    case create(NIOHTTP2Handler.AsyncStreamMultiplexer<Void>)
    case `throw`(RPCError)
  }

  mutating func createStream() -> CreateStreamAction {
    switch self {
    case .idle:
      return .enqueue
    case .configuring:
      return .enqueue
    case .configured:
      return .enqueue
    case .ready(let state):
      return .create(state.multiplexer)
    case .shuttingDown:
      return .throw(RPCError(code: .unavailable, message: "Transport is shut down."))
    case .shutDown:
      return .throw(RPCError(code: .unavailable, message: "Transport is shut down."))
    }
  }

  enum EnqueueAction {
    case none
    case resume(Result<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>, RPCError>)
  }

  mutating func enqueue(
    continuation: RequestQueue<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>>.Continuation,
    withID id: QueueEntryID
  ) -> EnqueueAction {
    let action: EnqueueAction

    switch consume self {
    case .idle(var state):
      state.queue.append(continuation: continuation, waitForReady: true, id: id)
      action = .none
      self = .idle(state)

    case .configuring(var state):
      state.queue.append(continuation: continuation, waitForReady: true, id: id)
      action = .none
      self = .configuring(state)

    case .configured(var state):
      state.queue.append(continuation: continuation, waitForReady: true, id: id)
      action = .none
      self = .configured(state)

    case .ready(let state):
      action = .resume(.success(state.multiplexer))
      self = .ready(state)

    case .shuttingDown:
      let error = RPCError(code: .unavailable, message: "Transport is shutting down.")
      action = .resume(.failure(error))
      self = .shuttingDown

    case .shutDown:
      let error = RPCError(code: .unavailable, message: "Transport is shut down.")
      action = .resume(.failure(error))
      self = .shutDown
    }

    return action
  }

  enum DequeueAction {
    case dequeued(RequestQueue<NIOHTTP2Handler.AsyncStreamMultiplexer<Void>>.Continuation)
    case none
  }

  mutating func dequeue(id: QueueEntryID) -> DequeueAction {
    let action: DequeueAction

    switch consume self {
    case .idle(var state):
      let continuation = state.queue.removeEntry(withID: id)
      action = continuation.map { .dequeued($0) } ?? .none
      self = .idle(state)

    case .configuring(var state):
      let continuation = state.queue.removeEntry(withID: id)
      action = continuation.map { .dequeued($0) } ?? .none
      self = .configuring(state)

    case .configured(var state):
      let continuation = state.queue.removeEntry(withID: id)
      action = continuation.map { .dequeued($0) } ?? .none
      self = .configured(state)

    case .ready(let state):
      self = .ready(state)
      action = .none

    case .shuttingDown:
      self = .shuttingDown
      action = .none

    case .shutDown:
      self = .shutDown
      action = .none
    }

    return action
  }
}
