# pr-closer

Warn and close broken pull requests, and close old pull requests.

`pr-closer` is a GitHub Action for maintainers who want to keep stale pull requests from piling up while giving contributors a visible warning for failing checks and merge conflicts.

## Usage

Create `.github/workflows/pr-closer.yml` in the repository you want to maintain:

```yaml
name: pr-closer

on:
  schedule:
    - cron: "0 0 * * *"
  workflow_dispatch:

jobs:
  pr-closer:
    runs-on: ubuntu-latest
    permissions:
      checks: read
      issues: write
      pull-requests: write
      statuses: read
    steps:
      - uses: jdx/pr-closer@v1
```

## Options

```yaml
- uses: jdx/pr-closer@v1
  with:
    close-after-days: 7
    max-age-days: 30
    ignored-author: jdx
    ignored-label: keep-open
    limit: 500
    dry-run: false
```

| Input | Default | Description |
| --- | --- | --- |
| `close-after-days` | `7` | Number of calendar days after the first warning before a pull request with failing checks or merge conflicts is closed. |
| `max-age-days` | `30` | Number of full days an otherwise healthy pull request with settled checks can remain open before it is closed. |
| `ignored-author` | `jdx` | Pull request author to ignore. |
| `ignored-label` | `keep-open` | Pull request label to ignore. |
| `github-token` | `${{ github.token }}` | Token used to list, comment on, and close pull requests. |
| `limit` | `500` | Maximum number of open pull requests to inspect. |
| `dry-run` | `false` | Log actions without commenting on or closing pull requests. |

## Behavior

Every run inspects open pull requests, skipping the configured author and label.

If a pull request has failing checks, merge conflicts, or both, the action comments once per day. Warnings are tracked with a hidden marker in the comment body and are tied to the pull request head SHA. Pushing new commits resets the warning window. Missed or delayed scheduled runs do not reset the warning window.

After the configured number of calendar days from the first warning, the action closes the broken pull request with a final comment.

If a pull request does not have failing checks, pending checks, or merge conflicts and was created at least `max-age-days` full days ago, the action closes it with a comment. Draft and non-draft pull requests are treated the same way.

## Requirements

The workflow must grant:

```yaml
permissions:
  checks: read
  issues: write
  pull-requests: write
  statuses: read
```

The action uses the GitHub CLI and `jq`, both of which are available on `ubuntu-latest`.

## Releasing

The `release-plz` workflow runs after pushes to `main`. When there are unreleased changes, it updates `VERSION` on the `release` branch and opens or updates a pull request with the `release` label. The workflow uses `RELEASE_PLZ_GITHUB_TOKEN` so the generated pull request can trigger the release workflow when merged.

When a release pull request is merged, the release workflow creates the exact version tag, updates the major tag, and creates a GitHub release.

The workflow can also be run manually with an optional version input.

## License

MIT
