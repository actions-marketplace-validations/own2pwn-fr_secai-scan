#!/usr/bin/env bash
# Post (or update) a recap comment on the current pull request.
#
# Idempotency: the SecAI worker may have already posted a comment via
# the GitHub App. Both bodies carry the marker `<!-- secai:scan-comment -->`
# — we skip if one is already present, otherwise we POST a fresh one
# tagged with `<!-- secai:scan-comment-action -->` so the App and the
# Action can coexist without trampling each other.
#
# Required env: GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_PR_NUMBER,
#               SECAI_API_BASE, SECAI_API_KEY, SECAI_ACTION_SCAN_ID,
#               SECAI_ACTION_FINDINGS_COUNT.

set -euo pipefail

: "${GITHUB_TOKEN:?missing GITHUB_TOKEN}"
: "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"
: "${GITHUB_PR_NUMBER:?missing GITHUB_PR_NUMBER}"
: "${SECAI_API_BASE:?missing SECAI_API_BASE}"
: "${SECAI_API_KEY:?missing SECAI_API_KEY}"
: "${SECAI_ACTION_SCAN_ID:?missing SECAI_ACTION_SCAN_ID}"

# Shared marker (from packages/secai-worker/src/secai/worker/pr_comment.py).
APP_MARKER="<!-- secai:scan-comment -->"
ACTION_MARKER="<!-- secai:scan-comment-action -->"

api="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${GITHUB_PR_NUMBER}/comments"
gh_auth_header="Authorization: Bearer ${GITHUB_TOKEN}"
gh_accept_header="Accept: application/vnd.github+json"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Pull existing comments and look for either marker. The PR REST API
# paginates at 30 items by default — bump to 100 to keep this a single
# round-trip on noisy PRs.
curl --fail --silent --show-error \
  -H "${gh_auth_header}" \
  -H "${gh_accept_header}" \
  "${api}?per_page=100" > "${scratch}/comments.json" || echo '[]' > "${scratch}/comments.json"

cat > "${scratch}/has_marker.py" <<'PY'
import json, sys
markers = sys.argv[1:]
data = json.load(sys.stdin)
if not isinstance(data, list):
    print("no")
    sys.exit(0)
for c in data:
    body = c.get("body") or ""
    if any(m in body for m in markers):
        print("yes")
        sys.exit(0)
print("no")
PY

has_marker=$(python3 "${scratch}/has_marker.py" "$APP_MARKER" "$ACTION_MARKER" < "${scratch}/comments.json")

if [[ "${has_marker}" == "yes" ]]; then
  echo "Existing SecAI comment found — skipping (GitHub App already commented)."
  exit 0
fi

# Build the body. Pull the top 5 findings (highest severity first) for
# a useful preview without bloating the comment.
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${SECAI_API_KEY}" \
  -H "Accept: application/json" \
  "${SECAI_API_BASE%/}/scans/${SECAI_ACTION_SCAN_ID}/findings?limit=500&offset=0" > "${scratch}/findings.json" || echo '[]' > "${scratch}/findings.json"

cat > "${scratch}/render.py" <<'PY'
import json, sys
marker, scan_id, total = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(sys.stdin)
if not isinstance(data, list):
    data = []
sev_rank = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
emoji = {"critical": "🛑", "high": "🔴", "medium": "🟡", "low": "🔵", "info": "⚪"}
data.sort(key=lambda f: sev_rank.get(str(f.get("severity", "info")).lower(), 99))
counts: dict[str, int] = {}
for f in data:
    sev = str(f.get("severity", "info")).lower()
    counts[sev] = counts.get(sev, 0) + 1
lines = ["## SecAI scan", ""]
blockers = counts.get("critical", 0) + counts.get("high", 0)
if blockers:
    lines.append(f"❌ **{blockers} high/critical** of {total} findings.")
elif int(total) > 0:
    lines.append(f"✅ **{total} findings**, none high/critical.")
else:
    lines.append("✅ **Clean scan** — no findings.")
lines.append("")
if counts:
    breakdown = " · ".join(
        f"{emoji.get(s, '⚪')} {s}: **{n}**"
        for s, n in sorted(counts.items(), key=lambda kv: sev_rank.get(kv[0], 99))
    )
    lines.append(breakdown)
    lines.append("")
top = data[:5]
if top:
    lines.append("| Severity | Finding | Location |")
    lines.append("| --- | --- | --- |")
    for f in top:
        sev = str(f.get("severity", "info")).lower()
        title = (f.get("title") or f.get("rule_id") or "(untitled)").replace("|", "\\|")
        loc = f.get("evidence") or f.get("location") or {}
        path = loc.get("file") or loc.get("path") or "?"
        line = loc.get("start_line") or loc.get("line_start") or loc.get("line") or "?"
        lines.append(f"| {emoji.get(sev, '⚪')} {sev} | {title} | `{path}:{line}` |")
    if len(data) > 5:
        lines.append("")
        lines.append(f"_…and {len(data) - 5} more — see the full report._")
lines.append("")
lines.append(f"_Posted by [SecAI Scan GitHub Action](https://github.com/marketplace/actions/secai-scan) — scan `{scan_id}`._")
lines.append("")
lines.append(marker)
print(json.dumps({"body": "\n".join(lines)}))
PY

body=$(python3 "${scratch}/render.py" "$ACTION_MARKER" "$SECAI_ACTION_SCAN_ID" "${SECAI_ACTION_FINDINGS_COUNT:-0}" < "${scratch}/findings.json")

curl --fail --silent --show-error \
  -X POST \
  -H "${gh_auth_header}" \
  -H "${gh_accept_header}" \
  -H "Content-Type: application/json" \
  -d "${body}" \
  "${api}" > /dev/null

echo "Posted SecAI recap comment on PR #${GITHUB_PR_NUMBER}."
