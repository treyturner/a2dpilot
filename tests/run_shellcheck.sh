#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd)
VERSION_FILE=$PROJECT_DIR/.shellcheck-version

[[ -f $VERSION_FILE && ! -L $VERSION_FILE ]] || {
  printf 'ERROR: Missing or unsafe ShellCheck version file: %s\n' "$VERSION_FILE" >&2
  exit 1
}
IFS= read -r EXPECTED_VERSION < "$VERSION_FILE"
[[ $EXPECTED_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'ERROR: Invalid pinned ShellCheck version: %s\n' "$EXPECTED_VERSION" >&2
  exit 1
}
command -v shellcheck >/dev/null 2>&1 || {
  printf 'ERROR: ShellCheck %s is required but shellcheck was not found.\n' \
    "$EXPECTED_VERSION" >&2
  exit 1
}
ACTUAL_VERSION=$(shellcheck --version | awk '$1 == "version:" { print $2; exit }')
[[ $ACTUAL_VERSION == "$EXPECTED_VERSION" ]] || {
  printf 'ERROR: ShellCheck %s is required; found %s.\n' \
    "$EXPECTED_VERSION" "${ACTUAL_VERSION:-unknown}" >&2
  exit 1
}

exec shellcheck -x \
  "$PROJECT_DIR/a2dpilot" \
  "$PROJECT_DIR/tests/a2dpilot_test.sh" \
  "$PROJECT_DIR/tests/run_shellcheck.sh"
