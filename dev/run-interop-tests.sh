#!/bin/bash
## Copyright 2024, gRPC Authors All rights reserved.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.

set -euo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
build_flags=(
  "--package-path" "$here/../IntegrationTests/grpc-interop-tests"
  "-c" "release"
)

# Build the executable
log "Building gRPC interop tests..."
if ! swift build "${build_flags[@]}"; then
  fatal "Build failed"
fi

# Grab the path to the executable.
interop_tests_bin=$(swift build "${build_flags[@]}" --show-bin-path)/grpc-interop-tests

# Start the server. Capture unbuffered stdout otherwise it might not have been
# written to when we read the port.
server_output_file=$(mktemp)
host="127.0.0.1"
port="0"
stdbuf -o0 "$interop_tests_bin" start-server \
  --host "$host" \
  --port "$port" \
  > "$server_output_file" 2>&1 &
server_pid=$!

# Give the server a moment to start up.
sleep 1

# Extract the port number that the server bound to. Capture the whole string
# then narrow it down to just the port.
pattern="listening address: \[ipv4\]$host:[0-9]*$"
bound_port=$(grep -o "$pattern" < "$server_output_file" | grep -o '[0-9]*$')

if [[ -z "$bound_port" ]]; then
  error "Failed to get the bound port."
  kill $server_pid # ignore-unacceptable-language
  exit 1
else
  log "Started server on $host:$bound_port"
fi

# Now run the tests, keeping track of failures.
failed_tests=0
tests=(
  empty_unary
  large_unary
  client_compressed_unary
  server_compressed_unary
  client_streaming
  server_streaming
  server_compressed_streaming
  ping_pong
  empty_stream
  custom_metadata
  status_code_and_message
  special_status_message
  unimplemented_method
  unimplemented_service
)

for test in "${tests[@]}"; do
  # The executable prints the running test and result, don't duplicate that in
  # logs here.
  if ! $interop_tests_bin run-tests --host "$host" --port "$bound_port" "$test"; then
    ((failed_tests++))
  fi
done

# Stop the server
log "Stopping the server..."
kill $server_pid # ignore-unacceptable-language

if [[ $failed_tests -gt 0 ]]; then
  error "$failed_tests tests failed."
  exit 1
else
  log "All tests passed."
  exit 0
fi
