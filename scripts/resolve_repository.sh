#!/usr/bin/env bash
# Resolve a GitHub `owner/repo` to a SecAI repository UUID.
#
# Order of resolution:
#   1. If SECAI_ACTION_REPOSITORY_ID is set, take it verbatim.
#   2. List repositories owned by the calling tenant and match on
#      `git_url == https://github.com/<owner>/<repo>`.
#   3. If no match, POST /repositories to register it.
#
# Required env: SECAI_API_BASE, SECAI_API_KEY, SECAI_ACTION_REPOSITORY.
# Optional env: SECAI_ACTION_REPOSITORY_ID.
# Emits: ${GITHUB_OUTPUT} "repository-id=<uuid>"

set -euo pipefail

: "${SECAI_API_BASE:?missing SECAI_API_BASE}"
: "${SECAI_API_KEY:?missing SECAI_API_KEY}"

if [[ -n "${SECAI_ACTION_REPOSITORY_ID:-}" ]]; then
  echo "Using user-supplied SecAI repository id: ${SECAI_ACTION_REPOSITORY_ID}"
  echo "repository-id=${SECAI_ACTION_REPOSITORY_ID}" >> "$GITHUB_OUTPUT"
  exit 0
fi

: "${SECAI_ACTION_REPOSITORY:?missing SECAI_ACTION_REPOSITORY}"
GIT_URL="https://github.com/${SECAI_ACTION_REPOSITORY}"

# `curl` against the SecAI API. Keep the Authorization header on the
# `-H` side so it never lands in command-line listings on the runner.
auth_header="Authorization: Bearer ${SECAI_API_KEY}"

echo "Looking up SecAI repository for ${GIT_URL}…"

# /repositories paginates at 200 by default — large workspaces may
# need a few pages, but the dashboard caps it well below.
list_resp=$(curl --fail --silent --show-error \
  -H "${auth_header}" \
  -H "Accept: application/json" \
  "${SECAI_API_BASE%/}/repositories?limit=200&offset=0")

# We can't mix a heredoc *and* a here-string on the same invocation
# (one stdin per command), so write the script to a temp file and
# pipe the API response into it.
match_script=$(mktemp)
trap 'rm -f "$match_script"' EXIT
cat > "$match_script" <<'PY'
import json, sys, urllib.parse
target = sys.argv[1].rstrip("/")
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(0)
def _norm(url: str) -> str:
    if not url:
        return ""
    parsed = urllib.parse.urlparse(url.rstrip("/"))
    netloc = parsed.netloc.lower()
    path = parsed.path
    if path.endswith(".git"):
        path = path[:-4]
    return f"{parsed.scheme}://{netloc}{path}"
norm_target = _norm(target)
for row in data:
    git_url = row.get("git_url") or ""
    if _norm(git_url) == norm_target:
        print(row["id"])
        break
PY
match=$(printf '%s' "$list_resp" | python3 "$match_script" "$GIT_URL")

if [[ -n "${match}" ]]; then
  echo "Found existing SecAI repository: ${match}"
  echo "repository-id=${match}" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "No existing SecAI repository for ${GIT_URL} — registering."
create_resp=$(curl --fail --silent --show-error \
  -X POST \
  -H "${auth_header}" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d "$(printf '{"source_kind":"git","git_url":"%s"}' "${GIT_URL}")" \
  "${SECAI_API_BASE%/}/repositories")

new_id=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])' <<<"$create_resp")
echo "Registered SecAI repository: ${new_id}"
echo "repository-id=${new_id}" >> "$GITHUB_OUTPUT"
