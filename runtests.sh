#!/bin/bash
# Regression tests for Navigator's path rules (NavigatorCore.swift).
# The app itself is built by ./rebuild.sh — this only exercises the pure logic.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
swift test 2>&1 | grep -E "Test Case .* (failed|passed)|Executed [0-9]+ tests|error:" \
  | grep -vE "passed \(0\.0" || true
echo "─────"
swift test 2>&1 | grep -E "Executed [0-9]+ tests, with" | tail -1
