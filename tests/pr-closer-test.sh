#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$GH_LOG"
scenario="${SCENARIO:?}"
if [[ "$1 $2" == "pr list" ]]; then
  case "$scenario" in
    feedback|human|pagination|repeat|draft-failure) echo '[{"number":1,"author":{"login":"alice"},"createdAt":"2026-10-03T00:00:00Z","updatedAt":"2026-10-03T00:00:00Z","headRefName":"feature","headRepository":{"nameWithOwner":"fork/alice"},"isDraft":false}]' ;;
    inactive|bot-activity|bot-push|lookup-failure|feedback-lookup-failure|activity-pagination|human-commit|offset-commit|commits-failure) echo '[{"number":2,"author":{"login":"alice"},"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","headRefName":"feature","headRepository":{"nameWithOwner":"fork/alice"},"isDraft":false}]' ;;
    ambiguous-update) echo '[{"number":2,"author":{"login":"alice"},"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-10-03T00:00:00Z","headRefName":"feature","headRepository":{"nameWithOwner":"fork/alice"},"isDraft":false}]' ;;
    maintainer) echo '[{"number":3,"author":{"login":"maintainer"},"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","headRefName":"feature","headRepository":{"nameWithOwner":"test/repo"},"isDraft":false}]' ;;
  esac
  exit 0
fi
if [[ "$1 $2" == "pr ready" ]]; then
  [[ "$scenario" == draft-failure ]] && exit 1
  exit 0
fi
if [[ "$1 $2" == "pr comment" || "$1 $2" == "pr close" ]]; then
  exit 0
fi
if [[ "$1 $2" == "api graphql" ]]; then
  if [[ "$scenario" == feedback-lookup-failure ]]; then
    echo '{}'
  elif [[ "$scenario" == pagination && "$*" != *'cursor=cursor-2'* ]]; then
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-2"},"nodes":[]}}}}}'
  elif [[ "$scenario" == feedback || "$scenario" == pagination || "$scenario" == repeat || "$scenario" == draft-failure ]]; then
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"author":{"__typename":"Bot","login":"review-bot"},"pullRequestReview":{"state":"COMMENTED"}}]}}]}}}}}'
  elif [[ "$scenario" == human ]]; then
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"author":{"__typename":"User","login":"reviewer"},"pullRequestReview":{"state":"COMMENTED"}}]}}]}}}}}'
  else
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
  fi
  exit 0
fi
path="$2"
if [[ "$path" == *'/permission' ]]; then
  [[ "$scenario" == lookup-failure ]] && exit 1
  [[ "$scenario" == maintainer ]] && { echo write; exit 0; }
  echo read; exit 0
fi
if [[ "$path" == *'/events' ]]; then
  if [[ "$scenario" == activity-pagination ]]; then echo '[[],[{"type":"PushEvent","actor":{"type":"User"},"payload":{"ref":"refs/heads/feature"},"created_at":"2026-10-03T00:00:00Z"}]]'; elif [[ "$scenario" == bot-push ]]; then echo '[[{"type":"PushEvent","actor":{"type":"Bot"},"payload":{"ref":"refs/heads/feature"},"created_at":"2026-10-03T00:00:00Z"}]]'; else echo '[[]]'; fi
  exit 0
fi
if [[ "$path" == *'/comments' ]]; then
  if [[ "$scenario" == bot-activity ]]; then echo '[[{"user":{"login":"ci[bot]","type":"Bot"},"created_at":"2026-10-03T00:00:00Z","body":"bot"}]]'; elif [[ "$scenario" == activity-pagination ]]; then echo '[[],[{"user":{"login":"alice","type":"User"},"created_at":"2026-10-03T00:00:00Z","body":"progress"}]]'; elif [[ "$scenario" == repeat ]]; then echo '[[{"user":{"login":"github-actions[bot]","type":"Bot"},"created_at":"2026-10-03T00:00:00Z","body":"<!-- pr-closer-automated-feedback-draft -->"}]]'; else echo '[[]]'; fi
  exit 0
fi
if [[ "$path" == *'/commits' ]]; then
  [[ "$scenario" == commits-failure ]] && exit 1
  if [[ "$scenario" == bot-push ]]; then echo '[[{"author":{"login":"ci[bot]","type":"Bot"},"committer":{"login":"alice","type":"User"},"commit":{"committer":{"date":"2026-10-03T00:00:00Z"}}}]]'; elif [[ "$scenario" == human-commit ]]; then echo '[[{"author":{"login":"alice","type":"User"},"committer":{"login":"alice","type":"User"},"commit":{"committer":{"date":"2026-10-03T00:00:00Z"}}}]]'; elif [[ "$scenario" == offset-commit ]]; then echo '[[{"author":{"login":"alice","type":"User"},"committer":{"login":"alice","type":"User"},"commit":{"committer":{"date":"2026-10-03T18:00:00-07:00"}}}]]'; else echo '[[]]'; fi
  exit 0
fi
exit 1
EOF
chmod +x "$tmp/bin/gh"

run_case() {
  local scenario="$1"
  if ! GH_LOG="$tmp/$scenario.log" SCENARIO="$scenario" PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=test/repo GH_TOKEN=x NOW=2026-10-04T00:00:00Z CLOSE_AFTER_DAYS=7 "$root/src/pr-closer.sh" > "$tmp/$scenario.out" 2>&1; then
    cat "$tmp/$scenario.out" >&2
    exit 1
  fi
}
assert_contains() { grep -Fq "$2" "$1" || { cat "$1"; echo "expected $2" >&2; exit 1; }; }
assert_absent() { ! grep -Fq "$2" "$1" || { cat "$1"; echo "did not expect $2" >&2; exit 1; }; }

run_case feedback
assert_contains "$tmp/feedback.log" 'pr ready 1'
assert_contains "$tmp/feedback.log" 'pr comment 1'
run_case repeat
assert_contains "$tmp/repeat.log" 'pr ready 1'
assert_absent "$tmp/repeat.log" 'pr comment 1'
run_case pagination
assert_contains "$tmp/pagination.log" 'pr ready 1'
run_case human
assert_absent "$tmp/human.log" 'pr ready'
run_case inactive
assert_contains "$tmp/inactive.log" 'pr close 2'
run_case bot-activity
assert_contains "$tmp/bot-activity.log" 'pr close 2'
run_case bot-push
assert_contains "$tmp/bot-push.log" 'pr close 2'
run_case human-commit
assert_absent "$tmp/human-commit.log" 'pr close 2'
run_case offset-commit
assert_absent "$tmp/offset-commit.log" 'pr close 2'
run_case activity-pagination
assert_absent "$tmp/activity-pagination.log" 'pr close 2'
run_case ambiguous-update
assert_absent "$tmp/ambiguous-update.log" 'pr close 2'
run_case maintainer
assert_absent "$tmp/maintainer.log" 'pr close'
assert_absent "$tmp/maintainer.log" 'pr ready'
run_case lookup-failure
assert_absent "$tmp/lookup-failure.log" 'pr close'
run_case commits-failure
assert_absent "$tmp/commits-failure.log" 'pr close'
run_case feedback-lookup-failure
assert_absent "$tmp/feedback-lookup-failure.log" 'pr close'
run_case draft-failure
assert_contains "$tmp/draft-failure.log" 'pr ready 1'
assert_absent "$tmp/draft-failure.log" 'pr comment 1'
assert_absent "$tmp/draft-failure.log" 'pr close 1'

echo "pr-closer tests passed"
