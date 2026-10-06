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
CLOSED_AUTHOR="${CLOSED_AUTHOR:-}"
CLOSED_AUTHORS="${CLOSED_AUTHORS:-}"
CLOSED_AFTER="${CLOSED_AFTER:-}"
NOW="${NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
# Kept stable so warnings posted by older action versions remain idempotent.
AI_FEEDBACK_WARNING_MARKER="<!-- pr-closer-automated-feedback-draft -->"

if ! [[ "$CLOSE_AFTER_DAYS" =~ ^[0-9]+$ ]] || (( CLOSE_AFTER_DAYS < 1 )); then
  echo "close-after-days must be a positive integer" >&2; exit 1
fi
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || (( LIMIT < 1 )); then
  echo "limit must be a positive integer" >&2; exit 1
fi

if [[ -n "$CLOSED_AUTHOR$CLOSED_AUTHORS" ]]; then
  if ! [[ "$CLOSED_AFTER" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -u -d "$CLOSED_AFTER" >/dev/null 2>&1; then
    echo "closed-after must be a YYYY-MM-DD date when closed-authors is set" >&2; exit 1
  fi
fi

api() { gh api "$@"; }
comment_pr() { local pr="$1" body="$2"; [[ "$DRY_RUN" == true ]] && { echo "Would comment on PR #$pr:"; echo "$body"; } || gh pr comment "$pr" -R "$GITHUB_REPOSITORY" --body "$body"; }
close_pr() { local pr="$1" body="$2"; [[ "$DRY_RUN" == true ]] && { echo "Would close PR #$pr:"; echo "$body"; } || gh pr close "$pr" -R "$GITHUB_REPOSITORY" -c "$body"; }
draft_pr() { local pr="$1"; [[ "$DRY_RUN" == true ]] && echo "Would convert PR #$pr to draft" || gh pr ready "$pr" -R "$GITHUB_REPOSITORY" --undo; }
has_ai_feedback_warning() { jq -e --arg marker "$AI_FEEDBACK_WARNING_MARKER" '[flatten[]? | select(.user.type == "Bot" and ((.body // "") | contains($marker)))] | length > 0' >/dev/null; }

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
  local pr="$1" author="$2" created_at="$3" updated_at="$4" head_ref="$5" head_repository="$6" comments review_comments reviews commits events activity_times human_activity_times ambiguous_activity_times bot_activity_times candidate epoch latest="" latest_epoch=0 human_latest_epoch=0 ambiguous_latest_epoch=0 bot_latest_epoch=0 updated_epoch
  if ! comments="$(api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query issue comments" >&2; return 2; fi
  if ! review_comments="$(api "repos/$GITHUB_REPOSITORY/pulls/$pr/comments" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query review comments" >&2; return 2; fi
  if ! reviews="$(api "repos/$GITHUB_REPOSITORY/pulls/$pr/reviews" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query reviews" >&2; return 2; fi
  if ! commits="$(api "repos/$GITHUB_REPOSITORY/pulls/$pr/commits" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query commits" >&2; return 2; fi
  if ! events="$(api "repos/$head_repository/events" --paginate --slurp)"; then echo "Skipping PR #$pr: could not query head-repository push events" >&2; return 2; fi
  if ! activity_times="$(jq -r -n --arg author "$author" --arg created "$created_at" --arg ref "refs/heads/$head_ref" --slurpfile comments <(printf '%s' "$comments") --slurpfile commits <(printf '%s' "$commits") --slurpfile events <(printf '%s' "$events") '[ $created, ($comments[0] | flatten[]? | select(.user.login == $author and .user.type != "Bot") | (.updated_at // .created_at)), ($commits[0] | flatten[]? | select(.author.type != "Bot" and .committer.type != "Bot") | (.commit.committer.date // .commit.author.date)), ($events[0] | flatten[]? | select(.type == "PushEvent" and .payload.ref == $ref and .actor.type != "Bot") | .created_at) ] | map(select(. != null)) | .[]')"; then
    echo "Skipping PR #$pr: could not read contributor activity timestamps" >&2; return 2
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ! epoch="$(date -u -d "$candidate" +%s)"; then
      echo "Skipping PR #$pr: could not parse contributor activity timestamp" >&2; return 2
    fi
    if [[ -z "$latest" || "$epoch" -gt "$latest_epoch" ]]; then
      latest="$candidate"
      latest_epoch="$epoch"
    fi
  done <<< "$activity_times"
  # A recent human edit or review from someone other than the PR author is
  # not contributor activity, but it must prevent a later bot update from
  # making the PR look safely inactive.
  if ! human_activity_times="$(jq -r -n --arg ref "refs/heads/$head_ref" --slurpfile comments <(printf '%s' "$comments") --slurpfile review_comments <(printf '%s' "$review_comments") --slurpfile reviews <(printf '%s' "$reviews") --slurpfile commits <(printf '%s' "$commits") --slurpfile events <(printf '%s' "$events") '[ ($comments[0] | flatten[]? | select(.user.type != "Bot") | (.updated_at // .created_at)), ($review_comments[0] | flatten[]? | select(.user.type != "Bot") | (.updated_at // .created_at)), ($reviews[0] | flatten[]? | select(.user.type != "Bot" and .submitted_at != null) | .submitted_at), ($commits[0] | flatten[]? | select(.author.type != "Bot" and .committer.type != "Bot") | (.commit.committer.date // .commit.author.date)), ($events[0] | flatten[]? | select(.type == "PushEvent" and .payload.ref == $ref and .actor.type != "Bot") | .created_at) ] | map(select(. != null)) | .[]')"; then
    echo "Skipping PR #$pr: could not read human activity timestamps" >&2; return 2
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ! epoch="$(date -u -d "$candidate" +%s)"; then
      echo "Skipping PR #$pr: could not parse human activity timestamp" >&2; return 2
    fi
    (( epoch > human_latest_epoch )) && human_latest_epoch="$epoch"
  done <<< "$human_activity_times"
  if ! ambiguous_activity_times="$(jq -r -n --slurpfile comments <(printf '%s' "$comments") --slurpfile review_comments <(printf '%s' "$review_comments") '[ ($comments[0] | flatten[]? | select(.user.type == "Bot" and .updated_at != null and .updated_at != .created_at) | .updated_at), ($review_comments[0] | flatten[]? | select(.user.type == "Bot" and .updated_at != null and .updated_at != .created_at) | .updated_at) ] | map(select(. != null)) | .[]')"; then
    echo "Skipping PR #$pr: could not read ambiguous activity timestamps" >&2; return 2
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ! epoch="$(date -u -d "$candidate" +%s)"; then
      echo "Skipping PR #$pr: could not parse ambiguous activity timestamp" >&2; return 2
    fi
    (( epoch > ambiguous_latest_epoch )) && ambiguous_latest_epoch="$epoch"
  done <<< "$ambiguous_activity_times"
  # GitHub's updatedAt includes action and bot activity. A REST issue comment
  # identifies its original author, not its editor, so only an unedited bot
  # comment is safe attribution. Any edited bot comment remains ambiguous.
  if ! bot_activity_times="$(jq -r -n --slurpfile comments <(printf '%s' "$comments") '[ $comments[0] | flatten[]? | select(.user.type == "Bot" and ((.updated_at // .created_at) == .created_at)) | .created_at ] | map(select(. != null)) | .[]')"; then
    echo "Skipping PR #$pr: could not read bot activity timestamps" >&2; return 2
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ! epoch="$(date -u -d "$candidate" +%s)"; then
      echo "Skipping PR #$pr: could not parse bot activity timestamp" >&2; return 2
    fi
    (( epoch > bot_latest_epoch )) && bot_latest_epoch="$epoch"
  done <<< "$bot_activity_times"
  if ! updated_epoch="$(date -u -d "$updated_at" +%s)"; then
    echo "Skipping PR #$pr: could not parse pull request update timestamp" >&2; return 2
  fi
  if (( human_latest_epoch > latest_epoch && human_latest_epoch > cutoff_epoch )); then
    echo "Deferring inactive close for PR #$pr: a newer human update is not contributor activity" >&2
    return 3
  fi
  if (( ambiguous_latest_epoch > cutoff_epoch )); then
    echo "Deferring inactive close for PR #$pr: a recent bot-comment edit cannot be attributed safely" >&2
    return 3
  fi
  # Only an update at the exact timestamp of known bot activity is safe to
  # ignore. A merely newer (or future-dated) bot timestamp cannot explain the
  # update and must keep the fail-closed attribution guard in place.
  if (( updated_epoch > latest_epoch && updated_epoch > cutoff_epoch && updated_epoch != bot_latest_epoch )); then
    echo "Deferring inactive close for PR #$pr: a newer update cannot be attributed safely" >&2
    return 3
  fi
  printf '%s\n' "$latest"
}

maybe_draft_for_feedback() {
  local pr="$1" is_draft="$2" comments status warning_body
  if has_active_automated_feedback "$pr"; then status=0; else status=$?; fi
  [[ $status -eq 0 ]] || { [[ $status -eq 1 ]] && return 0; return 2; }
  if ! comments="$(api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" --paginate --slurp)"; then echo "Skipping draft action for PR #$pr: could not inspect explanatory comments" >&2; return 2; fi
  if has_ai_feedback_warning <<< "$comments"; then echo "PR #$pr already has an AI-feedback warning"; else
    warning_body="This PR has unresolved AI review feedback. Please address or resolve the review threads, then mark the PR ready for review when you are ready to continue. See the repository's contributing guidance for the expected review process.

*This comment was generated by an automated workflow.*

$AI_FEEDBACK_WARNING_MARKER"
    # Re-read immediately before posting so overlapping scheduled/manual runs
    # normally observe the marker written by the other run.
    if ! comments="$(api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" --paginate --slurp)"; then
      echo "Skipping draft action for PR #$pr: could not recheck AI-feedback warnings" >&2
      return 2
    fi
    if has_ai_feedback_warning <<< "$comments"; then
      echo "PR #$pr already has an AI-feedback warning"
    elif ! comment_pr "$pr" "$warning_body"; then
      echo "Skipping PR #$pr: could not post the automated-feedback explanation" >&2
      return 2
    fi
  fi
  [[ "$is_draft" == true ]] && return
  if ! draft_pr "$pr"; then
    echo "Skipping PR #$pr: could not convert it to draft" >&2
    return 2
  fi
  echo "Converted PR #$pr to draft due to unresolved automated review feedback"
}

close_inactive_pr() {
  local pr="$1" last_activity="$2"
  echo "Closing PR #$pr (no contributor activity for at least $CLOSE_AFTER_DAYS days; last activity: $last_activity)"
  close_pr "$pr" "This PR has had no contributor activity for at least $CLOSE_AFTER_DAYS days, so it is being closed automatically.

Contributor commits and replies reset this timer. Please reopen or create a new PR if you'd like to continue working on it.

*This comment was generated by an automated workflow.*"
}

close_blocked_pr() {
  local pr="$1" author="$2"
  echo "Closing PR #$pr: pull requests from $author opened after $CLOSED_AFTER are not accepted"
  close_pr "$pr" "Pull requests from this account are not being accepted in this repository, so this PR is being closed automatically.

If you believe this is a mistake, please open an issue to discuss it.

*This comment was generated by an automated workflow.*"
}

# Close new pull requests from blocked authors. Only PRs created on a day after
# CLOSED_AFTER are affected, so earlier work is left alone. The ignored labels
# still apply, and authors with write access are never closed.
close_blocked_authors() {
  local closed_authors author blocked_prs pr created_at status
  closed_authors="$(printf '%s\n%s\n' "$CLOSED_AUTHORS" "$CLOSED_AUTHOR" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF && !seen[$0]++')"
  while IFS= read -r author; do
    [[ -n "$author" ]] || continue
    if ! blocked_prs="$(gh pr list -R "$GITHUB_REPOSITORY" --state open --author "$author" --search "$(append_search_exclusions label "$IGNORED_LABELS"; append_search_exclusions label "$IGNORED_LABEL")" --json number,createdAt --limit "$LIMIT")"; then
      echo "Skipping closed author $author: could not list pull requests" >&2; continue
    fi
    [[ -n "$blocked_prs" && "$blocked_prs" != "[]" ]] || continue
    if is_maintainer "$author"; then echo "Skipping closed author $author: they have repository write, maintain, or admin permission"; continue
    else status=$?; [[ $status -eq 2 ]] && { echo "Skipping closed author $author: maintainer exemption could not be checked" >&2; continue; }; fi
    while IFS=$'\t' read -r pr created_at; do
      [[ -n "$pr" ]] || continue
      [[ "${created_at:0:10}" > "$CLOSED_AFTER" ]] || continue
      close_blocked_pr "$pr" "$author"
    done < <(jq -r '.[] | [.number, .createdAt] | @tsv' <<< "$blocked_prs")
  done <<< "$closed_authors"
}

cutoff_epoch="$(date -u -d "$NOW -$CLOSE_AFTER_DAYS days" +%s)"
close_blocked_authors
pr_search="$(printf 'sort:updated-asc'; append_search_exclusions author "$IGNORED_AUTHORS"; append_search_exclusions author "$CLOSED_AUTHORS"; append_search_exclusions author "$CLOSED_AUTHOR"; append_search_exclusions author "$IGNORED_AUTHOR"; append_search_exclusions label "$IGNORED_LABELS"; append_search_exclusions label "$IGNORED_LABEL")"
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
