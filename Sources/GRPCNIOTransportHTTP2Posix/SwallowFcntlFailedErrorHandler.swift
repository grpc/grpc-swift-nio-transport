/*
 * Copyright 2026, gRPC Authors All rights reserved.
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

internal import NIOCore
internal import NIOPosix

/// A handler for the listening channel which drops `NIOFcntlFailedError`s.
///
/// On Darwin, `fcntl(2)` on a just-accepted socket whose peer has already closed can fail with
/// `EINVAL`, which NIO surfaces as a `NIOFcntlFailedError`. NIO treats this as recoverable and
/// keeps the listening channel open but still fires the error down the pipeline. The socket
/// which failed to be configured has already been closed by NIO and no `Channel` was created
/// for it: the error is is purely informational.
///
/// When the listening channel is wrapped in a `NIOAsyncChannel`: its handler finishes the
/// stream of accepted connections with _any_ error it catches.
final class SwallowFcntlFailedErrorHandler: ChannelInboundHandler {
  typealias InboundIn = Any
  typealias InboundOut = Any

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    switch error {
    case is NIOFcntlFailedError:
      ()  // Okay, the accepted socket has already been closed by NIO.
    default:
      context.fireErrorCaught(error)
    }
  }
}
