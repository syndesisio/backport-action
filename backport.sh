#!/bin/bash
set -e
set -o pipefail
set -x

fail() {
  local message=$1

  local comment="{\
    \"body\": \"${message}\"
  }"

  local comments
  comments=$(jq --raw-output .pull_request._links.comments.href "$GITHUB_EVENT_PATH")

  curl -XPOST -fsSL \
    --output /dev/null \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${comment}" \
    "${comments}"

  exit 1
}

backport() {
  local number=$1
  local branch=$2

  echo "::debug::Backporting pull request #${number} to branch ${branch}"

  local repository
  repository=$(jq --raw-output .repository.clone_url "$GITHUB_EVENT_PATH")
  local backport_branch
  backport_branch="backport/${number}-to-${branch}"
  local merge_sha
  merge_sha=$(jq --raw-output .pull_request.merge_commit_sha "$GITHUB_EVENT_PATH")
  local auth
  auth=$(tmp=$(echo -n "x-access-token:${INPUT_TOKEN}"|base64); echo -n "${tmp/$'\n'/}");

  git clone --no-tags -b "${branch}" "${repository}" "${GITHUB_WORKSPACE}"
  (
    cd "${GITHUB_WORKSPACE}";
    git config --global user.email "$(git --no-pager log --format=format:'%ae' -n 1)"
    git config --global user.name "$(git --no-pager log --format=format:'%an' -n 1)"
    set +e
    git checkout -b "${backport_branch}" || fail "Unable to checkout branch named \'${branch}\', you might need to create it or use a different label.";
    git cherry-pick --mainline 1 "${merge_sha}" || fail "Unable to cherry-pick commit ${merge_sha} on top of branch \`${branch}\`.\n\nThis pull request needs to be backported manually.";
    git -c "http.extraheader=Authorization: basic ${auth}" push --set-upstream origin "${backport_branch}" || fail "Unable to push the backported branch, did you try to backport the same PR twice without deleting the ${backport_branch} branch?";
    set -e
  )

  local title
  title=$(jq --raw-output .pull_request.title "$GITHUB_EVENT_PATH")
  local pull_request_title="[Backport ${branch}] ${title}"
  local pull_request_body="Backport of #${number}"
  local pull_request="{\
    \"title\": \"${pull_request_title}\", \
    \"body\": \"${pull_request_body}\", \
    \"head\": \"${backport_branch}\", \
    \"base\": \"${branch}\" \
  }"

  local pulls
  pulls=$(tmp=$(jq --raw-output .repository.pulls_url "$GITHUB_EVENT_PATH"); echo "${tmp%{*}")

  curl -XPOST -fsSL \
    --output /dev/null \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${pull_request}" \
    "${pulls}"
}

delete() {
  local ref=$1
  local refs
  refs=$(tmp=$(jq --raw-output .pull_request.head.repo.git_refs_url "$GITHUB_EVENT_PATH"); echo "${tmp%{*}")

  curl -XDELETE -fsSL \
    --output /dev/null \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    "$refs/$ref"
}

main() {
  local number
  number=$(jq --raw-output .number "$GITHUB_EVENT_PATH")
  local state
  state=$(jq --raw-output .pull_request.state "$GITHUB_EVENT_PATH")
  local login
  login=$(jq --raw-output .pull_request.user.login "$GITHUB_EVENT_PATH")
  local title
  title=$(jq --raw-output .pull_request.title "$GITHUB_EVENT_PATH")
  local merged
  merged=$(jq --raw-output .pull_request.merged "$GITHUB_EVENT_PATH")
  local labels
  labels=$(jq --raw-output .pull_request.labels[].name "$GITHUB_EVENT_PATH")

  if [[ "$state" == "closed" && "$login" == "github-actions[bot]" && "$title" == '[Backport '* ]]; then
    delete "head/$(jq --raw-output .pull_request.head.ref "$GITHUB_EVENT_PATH")"
    exit 0
  fi

  if [[ "$merged" != "true" ]]; then
    exit 0
  fi

  IFS=$'\n'
  for label in ${labels}; do
    # label needs to be `backport <name of the branch>`
    if [[ "${label}" == 'backport '* ]]; then
      local branch=${label#* }
      backport "${number}" "${branch}"
    fi
  done
}

main "$@"
