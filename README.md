# pr-closer

Warn and close pull requests that have failing checks or merge conflicts.

`pr-closer` is a GitHub Action for maintainers who want to keep stale pull requests from piling up while giving contributors a visible daily warning first.

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
      issues: write
      pull-requests: write
    steps:
      - uses: jdx/pr-closer@v1
```

## Options

```yaml
- uses: jdx/pr-closer@v1
  with:
    close-after-days: 7
    ignored-author: jdx
    ignored-label: keep-open
    limit: 500
    dry-run: false
```

| Input | Default | Description |
| --- | --- | --- |
| `close-after-days` | `7` | Number of consecutive warning days before a pull request is closed. |
| `ignored-author` | `jdx` | Pull request author to ignore. |
| `ignored-label` | `keep-open` | Pull request label to ignore. |
| `github-token` | `${{ github.token }}` | Token used to list, comment on, and close pull requests. |
| `limit` | `500` | Maximum number of open pull requests to inspect. |
| `dry-run` | `false` | Log actions without commenting on or closing pull requests. |

## Behavior

Every run inspects open pull requests, skipping the configured author and label. If a pull request has failing checks, merge conflicts, or both, the action comments once per day.

Warnings are tracked with a hidden marker in the comment body and are tied to the pull request head SHA. Pushing new commits resets the warning window. If warnings are interrupted for a day, the consecutive-day count resets.

After the configured number of consecutive warning days, the action closes the pull request with a final comment.

## Requirements

The workflow must grant:

```yaml
permissions:
  issues: write
  pull-requests: write
```

The action uses the GitHub CLI and `jq`, both of which are available on `ubuntu-latest`.

## License

MIT
