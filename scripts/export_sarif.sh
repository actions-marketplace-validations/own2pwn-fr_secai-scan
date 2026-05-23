#!/usr/bin/env bash
# Download the SARIF report for a finished scan.
#
# Required env: SECAI_API_BASE, SECAI_API_KEY, SECAI_ACTION_SCAN_ID,
#               SECAI_ACTION_SARIF_OUTPUT.
# Emits: sarif-path=<output> to $GITHUB_OUTPUT.

set -euo pipefail

: "${SECAI_API_BASE:?missing SECAI_API_BASE}"
: "${SECAI_API_KEY:?missing SECAI_API_KEY}"
: "${SECAI_ACTION_SCAN_ID:?missing SECAI_ACTION_SCAN_ID}"
: "${SECAI_ACTION_SARIF_OUTPUT:?missing SECAI_ACTION_SARIF_OUTPUT}"

mkdir -p "$(dirname "${SECAI_ACTION_SARIF_OUTPUT}")"
echo "Exporting SARIF for scan ${SECAI_ACTION_SCAN_ID} → ${SECAI_ACTION_SARIF_OUTPUT}"

# Prefer the CLI when available (better error messages, retries), and
# fall back to curl so the script keeps working if the CLI version
# pinned by the user is older than `scan export`.
if secai scan export --help >/dev/null 2>&1; then
  secai scan export "${SECAI_ACTION_SCAN_ID}" \
    --format sarif \
    --output "${SECAI_ACTION_SARIF_OUTPUT}"
else
  curl --fail --silent --show-error \
    -H "Authorization: Bearer ${SECAI_API_KEY}" \
    -H "Accept: application/sarif+json" \
    -o "${SECAI_ACTION_SARIF_OUTPUT}" \
    "${SECAI_API_BASE%/}/scans/${SECAI_ACTION_SCAN_ID}/export?format=sarif"
fi

# Basic sanity check — empty file means the API returned nothing.
if [[ ! -s "${SECAI_ACTION_SARIF_OUTPUT}" ]]; then
  echo "SARIF export wrote an empty file — bailing" >&2
  exit 1
fi

echo "sarif-path=${SECAI_ACTION_SARIF_OUTPUT}" >> "$GITHUB_OUTPUT"
echo "SARIF report ready ($(wc -c < "${SECAI_ACTION_SARIF_OUTPUT}") bytes)."
