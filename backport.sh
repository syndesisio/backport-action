#!/bin/bash
set -e
set -o pipefail

fail() {
  local message=$1

  echo "::error::${message}"

  local comment
  comment="$(jq -n -c --arg body "${message}" '{"body": $body|gsub ("\\\\n";"\n")}')"

  local comments_url
  comments_url=$(jq --raw-output .pull_request._links.comments.href "${GITHUB_EVENT_PATH}")

  curl -XPOST -fsSL \
    --output /dev/null \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${comment}" \
    "${comments_url}"

  exit 1
}

auth_header() {
  local token=$1
  echo -n "$(echo -n "x-access-token:${token}"|base64 --wrap=0)"
}

cherry_pick() {
  local branch=$1
  local repository=$2
  local backport_branch=$3
  local merge_sha=$4

  git clone -q --no-tags -b "${branch}" "${repository}" "${GITHUB_WORKSPACE}" || fail "Unable to clone from repository \'${repository}\' a branch named \'${branch}\', this should not have happened"
  (
    cd "${GITHUB_WORKSPACE}"

    local user_name
    user_name="$(git --no-pager log --format=format:'%an' -n 1)"
    local user_email
    user_email="$(git --no-pager log --format=format:'%ae' -n 1)"

    set +e

    git checkout -q -b "${backport_branch}" > /dev/null 2>&1 || fail "Unable to checkout branch named \'${branch}\', you might need to create it or use a different label."

    local err
    err=$(git -c user.name="${user_name}" -c user.email="${user_email}" cherry-pick --mainline 1 "${merge_sha}" 2>&1) || fail "Unable to cherry-pick commit ${merge_sha} on top of branch '${branch}'.\n\nThis pull request needs to be backported manually.\nError:\n\`\`\`\n${err}\n\`\`\`"

    set -e
  )
}

push() {
  local backport_branch=$1

  local auth
  auth="$(auth_header "${INPUT_TOKEN}")"

  (
    cd "${GITHUB_WORKSPACE}"

    local user_name
    user_name="$(git --no-pager log --format=format:'%an' -n 1)"
    local user_email
    user_email="$(git --no-pager log --format=format:'%ae' -n 1)"

    set +e

    git -c user.name="${user_name}" -c user.email="${user_email}" -c "http.https://github.com.extraheader=Authorization: basic ${auth}" push -q --set-upstream origin "${backport_branch}" || fail "Unable to push the backported branch, did you try to backport the same PR twice without deleting the ${backport_branch} branch?"

    set -e
  )
}

create_pull_request() {
  local branch=$1
  local backport_branch=$2
  local title=$3
  local number=$4
  local pulls_url=$5

  local pull_request_title="[Backport ${branch}] ${title}"

  local pull_request_body="Backport of #${number}"

  local pull_request="{\
    \"title\": \"${pull_request_title}\", \
    \"body\": \"${pull_request_body}\", \
    \"head\": \"${backport_branch}\", \
    \"base\": \"${branch}\" \
  }"

  curl -XPOST -fsSL \
    --output /dev/null \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${pull_request}" \
    "${pulls_url}"
}

backport() {
  local number=$1
  local branch=$2

  echo "::debug::Backporting pull request #${number} to branch ${branch}"

  local repository
  repository=$(jq --raw-output .repository.clone_url "${GITHUB_EVENT_PATH}")

  local backport_branch
  backport_branch="backport/${number}-to-${branch}"

  local merge_sha
  merge_sha=$(jq --raw-output .pull_request.merge_commit_sha "${GITHUB_EVENT_PATH}")

  cherry_pick "${branch}" "${repository}" "${backport_branch}" "${merge_sha}"
  push "${backport_branch}"

  local title
  title=$(jq --raw-output .pull_request.title "${GITHUB_EVENT_PATH}")

  local pulls_url
  pulls_url=$(tmp=$(jq --raw-output .repository.pulls_url "${GITHUB_EVENT_PATH}"); echo "${tmp%{*}")

  create_pull_request "${branch}" "${backport_branch}" "${title}" "${number}" "${pulls_url}"
}

delete_branch() {
  local ref=$1
  local refs
  refs=$(tmp=$(jq --raw-output .pull_request.head.repo.git_refs_url "${GITHUB_EVENT_PATH}"); echo "${tmp%{*}")

  curl -XDELETE -fsSL \
    --output /dev/null \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    "$refs/$ref"
}

check_token_is_defined() {
  if [[ -z ${INPUT_TOKEN+x} ]]; then
    echo '::error::INPUT_TOKEN is was not provided, by default it should be set to {{ github.token }}'
    exit 1
  fi
}

main() {
  echo "::debug::environment"
  for e in $(printenv)
  do
    echo "::debug::${e}"
  done

  local state
  state=$(jq --raw-output .pull_request.state "${GITHUB_EVENT_PATH}")
  local login
  login=$(jq --raw-output .pull_request.user.login "${GITHUB_EVENT_PATH}")
  local title
  title=$(jq --raw-output .pull_request.title "${GITHUB_EVENT_PATH}")
  local merged
  merged=$(jq --raw-output .pull_request.merged "${GITHUB_EVENT_PATH}")

  if [[ "$state" == "closed" && "$login" == "github-actions[bot]" && "$title" == '[Backport '* ]]; then
    check_token_is_defined
    delete_branch "head/$(jq --raw-output .pull_request.head.ref "${GITHUB_EVENT_PATH}")"
    return
  fi

  if [[ "$merged" != "true" ]]; then
    return
  fi

  local number
  number=$(jq --raw-output .number "${GITHUB_EVENT_PATH}")
  local labels
  labels=$(jq --raw-output .pull_request.labels[].name "${GITHUB_EVENT_PATH}")

  local default_ifs="${IFS}"
  IFS=$'\n'
  for label in ${labels}; do
    IFS="${default_ifs}"
    # label needs to be `backport <name of the branch>`
    if [[ "${label}" == 'backport '* ]]; then
      local branch=${label#* }
      check_token_is_defined
      backport "${number}" "${branch}"
    fi
  done
}


${__SOURCED__:+return}

main "$@"
