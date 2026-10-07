#!/bin/sh
set -eu
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 Sources/Model.swift Sources/Activity.swift Sources/ClaudeSource.swift \
    Sources/CodexSource.swift Tests/SessionTrackingTests.swift -o "$TEST_DIR/session-tests"
"$TEST_DIR/session-tests"
