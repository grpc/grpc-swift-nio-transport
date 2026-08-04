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
#ifndef C_GRPC_NIO_TRANSPORT_LINUX_H_
#define C_GRPC_NIO_TRANSPORT_LINUX_H_

#ifdef __linux__

// glibc 2.36+ only declares `struct ucred` when `_GNU_SOURCE` is defined, and the Swift Glibc
// module does not reliably set it. This target defines `_GNU_SOURCE` (see Package.swift) so that
// including <sys/socket.h> here exposes `struct ucred` and `SO_PEERCRED` to Swift.
#ifndef _GNU_SOURCE
#error You must define _GNU_SOURCE
#endif

#include <sys/socket.h>

#endif  // __linux__

#endif  // C_GRPC_NIO_TRANSPORT_LINUX_H_
