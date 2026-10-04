#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

CLOSE_AFTER_DAYS="${CLOSE_AFTER_DAYS:-7}"
DRY_RUN="${DRY_RUN:-false}"
IGNORED_AUTHOR="${IGNORED_AUTHOR:-}"
DEFAULT_IGNORED_AUTHORS="$(printf 'jdx\nmise-en-dev\ndependabot[bot]\nrenovate[bot]')"
IGNORED_AUTHORS="${IGNORED_AUTHORS:-$DEFAULT_IGNORED_AUTHORS}"
IGNORED_LABEL="${IGNORED_LABEL:-}"
IGNORED_LABELS="${IGNORED_LABELS:-keep-open}"
LIMIT="${LIMIT:-500}"
NOW="${NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
DRAFT_MARKER="<!-- pr-closer-automated-feedback-draft -->"

if ! [[ "$CLOSE_AFTER_DAYS" =~ ^[0-9]+$ ]] || (( CLOSE_AFTER_DAYS < 1 )); then
  echo "close-after-days must be a positive integer" >&2; exit 1
fi
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || (( LIMIT < 1 )); then
  echo "limit must be a positive integer" >&2; exit 1
fi

api() { gh api "$@"; }
comment_pr() { local pr="$1" body="$2"; [[ "$DRY_RUN" == true ]] && { echo "Would comment on PR #$pr:"; echo "$body"; } || gh pr comment "$pr" -R "$GITHUB_REPOSITORY" --body "$body"; }
close_pr() { local pr="$1" body="$2"; [[ "$DRY_RUN" == true ]] && { echo "Would close PR #$pr:"; echo "$body"; } || gh pr close "$pr" -R "$GITHUB_REPOSITORY" -c "$body"; }
draft_pr() { local pr="$1"; [[ "$DRY_RUN" == true ]] && echo "Would convert PR #$pr to draft" || gh pr ready "$pr" -R "$GITHUB_REPOSITORY" --undo; }

append_search_exclusions() {
  local field="$1" values="$2"
  tr ',' '\n' <<< "$values" | while IFS= read -r value; do
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    [[ -n "$value" ]] || continue
    printf -- ' -%s:"%s"' "$field" "$value"
  done
}

is_maintainer() {
  local login="$1" permission
  if ! permission="$(api "repos/$GITHUB_REPOSITORY/collaborators/$login/permission" --jq .permission)"; then
    echo "Skipping PR author $login: could not verify repository permission" >&2; return 2
  fi
  [[ "$permission" == admin || "$permission" == maintain || "$permission" == write ]]
}

has_active_automated_feedback() {
  local pr="$1" cursor="null" response
  while :; do
    if ! response="$(api graphql -f query='query($owner:String!, $name:String!, $number:Int!, $cursor:String) { repository(owner:$owner,name:$name) { pullRequest(number:$number) { reviewThreads(first:100, after:$cursor) { pageInfo { hasNextPage endCursor } nodes { isResolved isOutdated comments(first:100) { pageInfo { hasNextPage } nodes { author { __typename login } pullRequestReview { state } } } } } } } }' -F owner="${GITHUB_REPOSITORY%/*}" -F name="${GITHUB_REPOSITORY#*/}" -F number="$pr" -F cursor="$cursor")"; then
      echo "Skipping PR #$pr: could not query review threads" >&2; return 2
    fi
    if jq -e '.data.repository.pullRequest == null' >/dev/null <<< "$response"; then
      echo "Skipping PR #$pr: review thread lookup returned no pull request" >&2; return 2
    fi
    if ! jq -e '(.data.repository.pullRequest? // empty) as $pr | ($pr.reviewThreads? | type == "object") and ($pr.reviewThreads.nodes | type == "array") and ($pr.reviewThreads.pageInfo.hasNextPage | type == "boolean") and all($pr.reviewThreads.nodes[]; (.comments.nodes | type == "array") and (.comments.pageInfo.hasNextPage | type == "boolean"))' >/dev/null <<< "$response"; then
      echo "Skipping PR #$pr: review thread lookup returned an incomplete response" >&2; return 2
    fi
    if jq -e '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.pageInfo.hasNextPage)] | length > 0' >/dev/null <<< "$response"; then
      echo "Skipping PR #$pr: a review thread has more than 100 comments" >&2; return 2
    fi
    if jq -e '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not) | select(.isOutdated | not) | .comments.nodes[] | select(.author.__typename == "Bot") | select((.pullRequestReview.state // "") != "DISMISSED")] | length > 0' >/dev/null <<< "$response"; then return 0; fi
    [[ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<< "$response")" == true ]] || return 1
    cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<< "$response")"
  done
}

latest_contributor_activity() {
  local pr="$1" author="$2" created_at="$3" updated_at="$4" head_ref="$5" head_repository="$6" comments commits events activity_times candidate epoch latest="" latest_epoch=0 has_push_event updated_epoch
  if ! comments="$(api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query issue comments" >&2; return 2; fi
  if ! commits="$(api "repos/$GITHUB_REPOSITORY/pulls/$pr/commits" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query commits" >&2; return 2; fi
  if ! events="$(api "repos/$head_repository/events" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query head-repository push events" >&2; return 2; fi
  has_push_event="$(jq -r --arg ref "refs/heads/$head_ref" 'any(flatten[]?; .type == "PushEvent" and .payload.ref == $ref and .actor.type != "Bot")' <<< "$events")" || return 2
  if ! activity_times="$(jq -r --arg author "$author" --arg created "$created_at" --arg ref "refs/heads/$head_ref" '[ $created, ($comments | flatten[]? | select(.user.login == $author and .user.type != "Bot") | .created_at), ($commits | flatten[]? | select(.author.type != "Bot" and .committer.type != "Bot") | (.commit.committer.date // .commit.author.date)), ($events | flatten[]? | select(.type == "PushEvent" and .payload.ref == $ref and .actor.type != "Bot") | .created_at) ] | map(select(. != null)) | .[]' --argjson comments "$comments" --argjson commits "$commits" --argjson events "$events" -n)"; then
    echo "Skipping PR #$pr: could not read contributor activity timestamps" >&2; return 2
  fi
  while IFS= read -r candidate; do
    if ! epoch="$(date -u -d "$candidate" +%s)"; then
      echo "Skipping PR #$pr: could not parse contributor activity timestamp" >&2; return 2
    fi
    if [[ -z "$latest" || "$epoch" -gt "$latest_epoch" ]]; then
      latest="$candidate"
      latest_epoch="$epoch"
    fi
  done <<< "$activity_times"
  if [[ "$has_push_event" != true ]]; then
    if ! updated_epoch="$(date -u -d "$updated_at" +%s)"; then
      echo "Skipping PR #$pr: could not parse pull request update timestamp" >&2; return 2
    fi
    if (( updated_epoch > latest_epoch && updated_epoch > cutoff_epoch )); then
      echo "Deferring inactive close for PR #$pr: a newer update cannot be attributed safely" >&2
      return 3
    fi
  fi
  printf '%s\n' "$latest"
}

maybe_draft_for_feedback() {
  local pr="$1" is_draft="$2" comments status
  [[ "$is_draft" == true ]] && return
  if has_active_automated_feedback "$pr"; then status=0; else status=$?; fi
  [[ $status -eq 0 ]] || { [[ $status -eq 1 ]] && return 0; return 2; }
  if ! comments="$(api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" --paginate --slurp)"; then echo "Skipping draft action for PR #$pr: could not inspect explanatory comments" >&2; return 2; fi
  if ! draft_pr "$pr"; then
    echo "Skipping PR #$pr: could not convert it to draft" >&2
    return 2
  fi
  echo "Converted PR #$pr to draft due to unresolved automated review feedback"
  if jq -e --arg marker "$DRAFT_MARKER" '[flatten[]? | select(.body | contains($marker))] | length > 0' >/dev/null <<< "$comments"; then echo "PR #$pr already has an automated-feedback explanation"; else
    comment_pr "$pr" "$(cat <<EOF
This PR was converted to draft because it has unresolved automated review feedback. Please resolve the feedback and mark it ready for review when you are ready to continue.

*This comment was generated by an automated workflow.*

$DRAFT_MARKER
EOF
)"
  fi
}

close_inactive_pr() {
  local pr="$1" last_activity="$2"
  echo "Closing PR #$pr (no contributor activity for at least $CLOSE_AFTER_DAYS days; last activity: $last_activity)"
  close_pr "$pr" "This PR has had no contributor activity for at least $CLOSE_AFTER_DAYS days, so it is being closed automatically.

Contributor commits and replies reset this timer. Please reopen or create a new PR if you'd like to continue working on it.

*This comment was generated by an automated workflow.*"
}

cutoff_epoch="$(date -u -d "$NOW -$CLOSE_AFTER_DAYS days" +%s)"
pr_search="$(printf 'sort:updated-asc'; append_search_exclusions author "$IGNORED_AUTHORS"; append_search_exclusions author "$IGNORED_AUTHOR"; append_search_exclusions label "$IGNORED_LABELS"; append_search_exclusions label "$IGNORED_LABEL")"
prs="$(gh pr list -R "$GITHUB_REPOSITORY" --state open --search "$pr_search" --json number,author,createdAt,updatedAt,headRefName,headRepository,isDraft --limit "$LIMIT")" || { echo "Could not list pull requests; no changes were made" >&2; exit 1; }
while IFS=$'\t' read -r pr author created_at updated_at head_ref head_repository is_draft; do
  [[ -n "$pr" ]] || continue
  if is_maintainer "$author"; then echo "Skipping PR #$pr: $author has repository write, maintain, or admin permission"; continue
  else status=$?; [[ $status -eq 2 ]] && { echo "Skipping PR #$pr: maintainer exemption could not be checked" >&2; continue; }; fi
  if [[ -z "$head_repository" || "$head_repository" == "null" ]]; then
    echo "Skipping PR #$pr: head repository could not be determined" >&2
    continue
  fi
  can_close=true
  if last_activity="$(latest_contributor_activity "$pr" "$author" "$created_at" "$updated_at" "$head_ref" "$head_repository")"; then :; else
    status=$?
    if [[ $status -eq 3 ]]; then
      can_close=false
    else
      echo "Skipping PR #$pr: contributor activity could not be determined" >&2
      continue
    fi
  fi
  if maybe_draft_for_feedback "$pr" "$is_draft"; then :; else
    status=$?
    if [[ $status -eq 2 ]]; then
      echo "Skipping inactive-close action for PR #$pr: automated feedback could not be determined" >&2
      continue
    fi
  fi
  if [[ "$can_close" == true ]] && (( $(date -u -d "$last_activity" +%s) <= cutoff_epoch )); then close_inactive_pr "$pr" "$last_activity"; fi
done < <(jq -r '.[] | [.number, .author.login, .createdAt, .updatedAt, .headRefName, .headRepository.nameWithOwner, .isDraft] | @tsv' <<< "$prs")
