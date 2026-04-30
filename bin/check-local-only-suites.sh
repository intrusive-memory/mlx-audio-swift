#!/usr/bin/env bash
# check-local-only-suites.sh
#
# Guards against accidental removal of local-only test suites from CLAUDE.md.
# Parses the "Local-Only Test Suites" markdown table in CLAUDE.md and checks that
# every suite in the canonical list is still present.
#
# Exit codes:
#   0 — all expected suites are present in CLAUDE.md
#   1 — one or more expected suites are missing from CLAUDE.md
#
# Usage:
#   bin/check-local-only-suites.sh [path/to/CLAUDE.md]
#
# The optional argument overrides the default path (PROJECT_ROOT/CLAUDE.md).
# This allows synthetic deletion testing against a temporary copy:
#   cp CLAUDE.md /tmp/CLAUDE.md.bak
#   # delete a line from CLAUDE.md
#   bin/check-local-only-suites.sh CLAUDE.md   # should exit 1
#   cp /tmp/CLAUDE.md.bak CLAUDE.md            # restore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLAUDE_MD="${1:-${REPO_ROOT}/CLAUDE.md}"

if [[ ! -f "${CLAUDE_MD}" ]]; then
  echo "ERROR: CLAUDE.md not found at: ${CLAUDE_MD}" >&2
  exit 1
fi

# Canonical list of local-only test suites.
# Update this list when a suite is intentionally added or renamed.
# Removing a suite from CLAUDE.md without updating this list will cause CI to fail.
EXPECTED_SUITES=(
  "SNACTests"
  "MimiTests"
  "Qwen3TTSTests"
  "LlamaTTSTests"
  "SopranoTTSTests"
  "PocketTTSTests"
  "Qwen3TTSVoiceDesignTests"
  "Qwen3ASRTests"
  "GLMASRTests"
  "MarvisTTSGenerateTests"
)

MISSING=()

for suite in "${EXPECTED_SUITES[@]}"; do
  if ! grep -q "${suite}" "${CLAUDE_MD}"; then
    MISSING+=("${suite}")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: The following local-only test suites are missing from CLAUDE.md:" >&2
  for suite in "${MISSING[@]}"; do
    echo "  - ${suite}" >&2
  done
  echo "" >&2
  echo "If you intentionally removed a suite, update EXPECTED_SUITES in:" >&2
  echo "  ${BASH_SOURCE[0]}" >&2
  echo "" >&2
  echo "If you renamed a suite, update both CLAUDE.md and EXPECTED_SUITES." >&2
  exit 1
fi

echo "OK: All ${#EXPECTED_SUITES[@]} local-only test suites are present in CLAUDE.md."
exit 0
