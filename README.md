# SecAI Scan — GitHub Action

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-SecAI%20Scan-blue?logo=github)](https://github.com/marketplace/actions/secai-scan)

Run the [SecAI](https://secai.own2pwn.fr) AI-native AppSec scanner on
every pull request and push. SAST, SCA, IaC and secrets — agent-driven,
with reachability filtering and a deterministic-then-LLM SAST pipeline.

The action queues a scan against your repository, waits for it to
finish, exports the report as SARIF (ready for GitHub Code Scanning),
optionally posts a recap comment on the PR, and gates the build on a
configurable severity threshold.

---

## Quick start

```yaml
# .github/workflows/secai.yml
name: SecAI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  pull-requests: write

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: own2pwn-fr/secai-scan@v1
        with:
          api-key: ${{ secrets.SECAI_API_KEY }}
```

That's it. Defaults run all four scan kinds (`sast,sca,iac,secret`),
fail the job on any high/critical finding, and post a single recap
comment per PR.

---

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `api-key` | yes | — | SecAI API key (`sok_<prefix>_<secret>`). Generate from **Dashboard → Settings → API keys**. |
| `api-url` | no | `https://secai.own2pwn.fr/api` | API base URL. Override for self-hosted SecAI deployments. |
| `repository` | no | `${{ github.repository }}` | GitHub `owner/name`. Used to auto-register the repo with SecAI on first run. |
| `repository-id` | no | — | Pre-registered SecAI repository UUID. When set, skips auto-registration. |
| `ref` | no | `${{ github.event.pull_request.head.sha || github.sha }}` | Commit SHA being scanned. Recorded on the scan; SecAI fetches the latest commit from the registered repo independently. |
| `kinds` | no | `sast,sca,iac,secret` | Comma-separated scan kinds. Subset of `sast`, `sca`, `iac`, `secret`. |
| `fail-on-severity` | no | `high` | Exit non-zero if any finding meets or exceeds this severity. One of `critical`, `high`, `medium`, `low`, `none`. |
| `comment-on-pr` | no | `true` | Post a recap comment. Skipped automatically if the SecAI GitHub App has already commented (detected via HTML marker). |
| `wait` | no | `true` | Wait for the scan to finish before the step exits. Set to `false` for fire-and-forget. |
| `timeout-minutes` | no | `30` | Max minutes to wait. The CLI polls every 5 seconds. |
| `sarif-output` | no | `secai.sarif` | Path to write SARIF. Set to empty string to disable. |
| `cli-version` | no | `latest` | `secai-cli` version to install. Pin to a specific release for reproducibility. |

## Outputs

| Name | Description |
| --- | --- |
| `scan-id` | UUID of the scan. |
| `status` | Terminal status: `succeeded`, `failed`, `cancelled`, `budget_exceeded`, or `queued` (when `wait=false`). |
| `findings-count` | Total findings across all severities. `0` when the scan didn't reach `succeeded`. |
| `sarif-path` | Path of the SARIF file. Empty when export is disabled or the scan didn't complete. |

---

## Examples

### 1. Upload to GitHub Code Scanning

```yaml
permissions:
  contents: read
  pull-requests: write
  security-events: write

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - id: secai
        uses: own2pwn-fr/secai-scan@v1
        continue-on-error: true
        with:
          api-key: ${{ secrets.SECAI_API_KEY }}
          fail-on-severity: high

      - uses: github/codeql-action/upload-sarif@v3
        if: always() && steps.secai.outputs.sarif-path != ''
        with:
          sarif_file: ${{ steps.secai.outputs.sarif-path }}
          category: secai

      - if: steps.secai.outcome == 'failure'
        run: exit 1
```

`continue-on-error` keeps the upload running even when the gate trips,
so findings still surface in the Code Scanning tab. The trailing `exit
1` mirrors the gate failure once the SARIF is in place.

### 2. Monorepo matrix

See [`examples/matrix.yml`](./examples/matrix.yml) for a strategy that
scans each subproject as its own SecAI repository.

### 3. Fire-and-forget (no PR gate)

```yaml
- uses: own2pwn-fr/secai-scan@v1
  with:
    api-key: ${{ secrets.SECAI_API_KEY }}
    wait: false
    comment-on-pr: false
```

Useful when you've installed the [SecAI GitHub App](https://github.com/marketplace/secai)
and rely on its commit check rather than the in-line action.

---

## Usage notes

### API key scope

Create a CI-only key from the dashboard and rotate it on a schedule.
The action sends it as `Authorization: Bearer <key>` — never logged.

### Repository auto-registration

The first run on a new GitHub repository calls `POST /repositories` to
register it. Subsequent runs reuse the same SecAI repository UUID. If
you'd rather pre-register from the dashboard or via the CLI, set the
`repository-id` input.

### Coexisting with the GitHub App

If you have the [SecAI GitHub App](https://github.com/marketplace/secai)
installed, both will produce findings. The Action defers to the App's
comment when it detects the `<!-- secai:scan-comment -->` marker, so
you won't get duplicate noise on PRs.

### Credits

Every scan costs SecAI credits — see
[Pricing](https://www.own2pwn.fr/produits/ai-native-appsec) for the current cost per
KLOC + entrypoint. The action exits with a clear error if your
workspace runs out of credits (HTTP 402).

### Self-hosted

Set `api-url` to your private SecAI instance. The action talks
exclusively to that URL — no calls to `secai.own2pwn.fr` outside of
fetching the CLI from PyPI.

---

## Troubleshooting

### `HTTP 401: unauthorized`

The API key is missing, malformed, or revoked. Re-issue from the
dashboard and check the `SECAI_API_KEY` secret has been set on the
repository (not just the org level if `Allow workflow access` is off).

### `HTTP 402: insufficient credits`

Your workspace is out of credits for the current month. The action
fails fast — no half-scan. Top up from **Dashboard → Billing**.

### `HTTP 404: repository not found`

The pre-registered UUID in `repository-id` does not belong to the
tenant the API key is scoped to, or it was deleted from the dashboard.
Clear `repository-id` to let the action auto-register, or re-register
from the dashboard.

### `SARIF export wrote an empty file`

The scan finished without any findings *and* without a results
container. Usually means the underlying scanner skipped your
language(s); check the scan detail page on the dashboard for the
language detection log.

### The action timed out

Long monorepos can exceed the default 30 minutes. Bump
`timeout-minutes` and consider splitting into a matrix.

---

## Pricing

Free tier covers occasional scans. Larger workspaces need a paid plan
— see <https://www.own2pwn.fr/produits/ai-native-appsec>.

---

## License

MIT — see [LICENSE](./LICENSE).
