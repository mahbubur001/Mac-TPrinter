#!/usr/bin/env bash
# Runs the unit tests with the pinned SDK. The Command Line Tools toolchain intermittently fails to
# load the swift-testing macro plugin ("plugin for module 'TestingMacros' not found") on alternate
# runs; retry up to twice when that specific error appears.
set -uo pipefail
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"

for attempt in 1 2 3; do
    output="$(swift test "$@" 2>&1)"
    status=$?
    if [[ $status -ne 0 && "$output" == *"plugin for module 'TestingMacros' not found"* && $attempt -lt 3 ]]; then
        echo "TestingMacros plugin flake, retrying…" >&2
        continue
    fi
    echo "$output"
    exit $status
done
