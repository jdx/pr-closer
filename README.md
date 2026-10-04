# pr-closer

Convert ready pull requests with unresolved automated review feedback to draft, and close inactive pull requests.

`pr-closer` is a GitHub Action for maintainers who want to keep stale pull requests from piling up without treating failed CI, merge conflicts, or human review threads as automated feedback.

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
    ignored-authors: |
      jdx
      mise-en-dev
      dependabot[bot]
      renovate[bot]
    ignored-labels: keep-open
    limit: 500
    dry-run: false
```

| Input | Default | Description |
| --- | --- | --- |
| `close-after-days` | `7` | Number of calendar days without contributor activity before a pull request is closed. |
| `ignored-authors` | `jdx`, `mise-en-dev`, `dependabot[bot]`, `renovate[bot]` | Comma-separated or newline-separated pull request authors to ignore. |
| `ignored-author` | | Additional pull request author to ignore. Prefer `ignored-authors` for multiple authors. |
| `ignored-labels` | `keep-open` | Comma-separated or newline-separated pull request labels to ignore. |
| `ignored-label` | | Additional pull request label to ignore. Prefer `ignored-labels` for multiple labels. |
| `github-token` | `${{ github.token }}` | Token used to list, comment on, and close pull requests. |
| `limit` | `500` | Maximum number of open pull requests to inspect. |
| `dry-run` | `false` | Log actions without commenting on or closing pull requests. |

## Behavior

Every run inspects open pull requests, skipping the configured authors and labels. Authors with verified `write`, `maintain`, or `admin` repository permission are also exempt from every action. If the action cannot verify permissions, activity, feedback, or comments for a pull request, it skips that pull request rather than acting on incomplete information.

For a ready PR, the action immediately converts it to draft when GitHub reports an unresolved, non-outdated review thread that contains feedback from a GitHub `Bot` account whose review is not dismissed. It leaves one explanatory comment, marked to avoid repeats. It never marks a PR ready again; the contributor does that.

The automated-feedback check paginates review threads and intentionally does not treat human reviewers, failed checks, merge conflicts, pending checks, outdated threads, resolved threads, or dismissed reviews as triggers. GitHub's review-thread API is the coverage boundary: feedback surfaced only outside review threads is not detected. For safety, a thread with more than 100 comments causes that PR to be skipped rather than incompletely inspected. In particular, this action does not query or integrate with an external `Entire` findings service; an Entire finding is considered only if that service has created a qualifying GitHub Bot-authored review-thread comment.

Separately, the action closes both draft and ready PRs after `close-after-days` days without contributor activity. The clock starts at creation and resets on a non-bot commit in the PR, a non-bot issue comment written by the PR author, or a non-bot GitHub PushEvent for the PR branch. Push events are read from the PR head repository, including a fork, and matched to its branch. A commit is excluded when either GitHub-linked commit identity is a Bot, so bot-generated branch pushes do not reset the timer. GitHub keeps only a limited recent repository-event history; when no matching PushEvent is available, the action falls back to the commit timestamp. A newer PR update that cannot be attributed safely defers closure only while it is within the configured inactivity window; after that, it no longer blocks closure. Comments from bots/actions and action comments do not reset the timer when their identity is known.

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
