/*
 * Copyright 2020, gRPC Authors All rights reserved.
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
#ifndef C_GRPC_ZLIB_H_
#define C_GRPC_ZLIB_H_

#include <zlib.h>

static inline int CGRPCNIOTransportZlib_deflateInit2(z_streamp stream, int level, int method, int windowBits,
                                         int memLevel, int strategy) {
  return deflateInit2(stream, level, method, windowBits, memLevel, strategy);
}

static inline unsigned long CGRPCNIOTransportZlib_deflateBound(z_streamp strm, unsigned long sourceLen) {
  return deflateBound(strm, sourceLen);
}

static inline int CGRPCNIOTransportZlib_deflate(z_streamp strm, int flush) {
  return deflate(strm, flush);
}

static inline int CGRPCNIOTransportZlib_deflateReset(z_streamp strm) {
  return deflateReset(strm);
}

static inline int CGRPCNIOTransportZlib_deflateEnd(z_streamp strm) {
  return deflateEnd(strm);
}

static inline int CGRPCNIOTransportZlib_inflateInit2(z_streamp stream, int windowBits) {
  return inflateInit2(stream, windowBits);
}

static inline int CGRPCNIOTransportZlib_inflate(z_streamp strm, int flush) {
  return inflate(strm, flush);
}

static inline int CGRPCNIOTransportZlib_inflateReset(z_streamp strm) {
  return inflateReset(strm);
}

static inline int CGRPCNIOTransportZlib_inflateEnd(z_streamp strm) {
  return inflateEnd(strm);
}

static inline Bytef *CGRPCNIOTransportZlib_castVoidToBytefPointer(void *in) {
  return (Bytef *) in;
}

#endif  // C_GRPC_ZLIB_H_
