#!/bin/bash
# LocalFlow acceptance tests. See TestCases/README.md.
#   ./TestCases/run_tests.sh [--build] [--skip-unit] [--engines apple,qwen3] [--long] [--e2e] [--only rules,cleanup]
set -uo pipefail
cd "$(dirname "$0")/.."
exec /usr/bin/env python3 TestCases/run_tests.py "$@"
