#!/usr/bin/env bash
set -euo pipefail

version="${VERSION:-}"
if [[ -z "$version" ]]; then
  version="$(<VERSION)"
fi
version="${version#v}"

if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  echo "VERSION must be a semantic version like 1.0.2" >&2
  exit 1
fi

major_version="${version%%.*}"
tag_name="v$version"
major_tag_name="v$major_version"

# Configure git to use gh's credential helper. The checkout step uses
# persist-credentials: false, so the token is not written to .git/config.
gh auth setup-git

if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null; then
  echo "Tag $tag_name already exists locally"
else
  git tag "$tag_name"
fi

if git ls-remote --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1; then
  echo "Tag $tag_name already exists on remote"
else
  git push origin "$tag_name"
fi

git tag "$major_tag_name" -f
if ! git push origin "$major_tag_name" -f; then
  echo "Failed to push $major_tag_name tag, fetching and retrying..."
  git fetch origin "refs/tags/$major_tag_name:refs/tags/$major_tag_name" -f
  git tag "$major_tag_name" -f
  git push origin "$major_tag_name" -f
fi

if gh release view "$tag_name" >/dev/null 2>&1; then
  echo "Release $tag_name already exists, skipping creation"
else
  gh release create "$tag_name" --generate-notes --verify-tag
fi
