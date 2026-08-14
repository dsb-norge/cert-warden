#!/usr/bin/env bash
#
# Upsert or delete a "sticky" PR comment — one comment per header, updated in place.
#
#   sticky-comment.sh upsert <header> <body-file>
#   sticky-comment.sh delete <header>
#
# Env: GH_TOKEN (pull-requests: write), REPO (owner/name), PR_NUMBER.
#
# Replaces marocchino/sticky-pull-request-comment: a 36k-line bundled third-party action is
# a lot of trust surface for "find a comment and PATCH it", and it ran inside jobs holding
# tokens it never needed (the pr-preview App token; contents: write). This is ~40 lines of
# first-party gh + jq doing exactly the two calls we use.
#
# The marker format matches the action's (`<!-- Sticky Pull Request Comment<header> -->`,
# appended, no separator) so comments it created before the switch are updated in place, not
# duplicated. The author filter matches only our own workflow identity, so a user pasting the
# marker into their comment cannot get it edited or deleted.
set -euo pipefail
shopt -s inherit_errexit

mode="${1:?usage: sticky-comment.sh <upsert|delete> <header> [body-file]}"
header="${2:?header is required}"
: "${GH_TOKEN:?GH_TOKEN is required}" "${REPO:?REPO is required}" "${PR_NUMBER:?PR_NUMBER is required}"

marker="<!-- Sticky Pull Request Comment${header} -->"

findCommentId() {
  # --paginate emits one JSON array per page; slurp + flatten before filtering.
  gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --paginate |
    jq -rs --arg marker "${marker}" \
      '[.[][] | select(.user.login == "github-actions[bot]" and (.body | contains($marker)))] | first | .id // empty'
}

commentId="$(findCommentId)"

case "${mode}" in
  upsert)
    bodyFile="${3:?body-file is required for upsert}"
    body="$(cat "${bodyFile}")"$'\n'"${marker}"
    if [[ -n "${commentId}" ]]; then
      gh api --method PATCH "repos/${REPO}/issues/comments/${commentId}" \
        --field body="${body}" --silent
      echo "updated sticky comment ${commentId} (header: ${header})"
    else
      gh api --method POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
        --field body="${body}" --silent
      echo "created sticky comment (header: ${header})"
    fi
    ;;
  delete)
    if [[ -n "${commentId}" ]]; then
      gh api --method DELETE "repos/${REPO}/issues/comments/${commentId}" --silent
      echo "deleted sticky comment ${commentId} (header: ${header})"
    else
      echo "no sticky comment to delete (header: ${header})"
    fi
    ;;
  *)
    echo "::error::unknown mode '${mode}' (want upsert|delete)" >&2
    exit 1
    ;;
esac
