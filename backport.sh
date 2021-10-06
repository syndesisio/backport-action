#!/bin/bash
set -o errexit -o pipefail -o nounset

newline_at_eof() {
  local file="$1"
  if [ -s "${file}" ] && [ "$(tail -c1 "${file}"; echo x)" != $'\nx' ]
  then
    # ensure newline at the end of file
    echo ''>> "${file}"
  fi
}

debug() {
  local outvar=$1
  shift
  echo "::debug::running: $*"

  local stdout
  stdout="$(mktemp)"
  # shellcheck disable=SC2001
  ("$@" 2> >(sed -e 's/^/::debug::err:/') > "${stdout}")
  local rc=$?
  # shellcheck disable=SC2140
  eval "${outvar}"="'$(cat "${stdout}")'"
  newline_at_eof "${stdout}"
  sed -e 's/^/::debug::out:/' "${stdout}"
  rm "${stdout}"

  bash -c 'echo -n' # force flushing stdout so that debug out/err are outputted before rc
  echo "::debug::rc=${rc}"

  return ${rc}
}

http_post() {
  local url=$1
  local json=$2

  local output
  output="$(mktemp)"

  result=''
  debug result curl -XPOST --fail -v -fsL \
    --output "${output}" \
    -w '{"http_code":%{http_code},"url_effective":"%{url_effective}"}' \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "${json}" \
    "${url}"|| true

  newline_at_eof "${output}"
  sed -e 's/^/::debug::output:/' "${output}"
  rm "${output}"

  echo "::debug::result=${result}"
  if [[ ! $(echo "${result}" |jq -r .http_code) =~ ^"2" ]]
  then
    local message
    message=$(echo "${result}"| jq -r -s 'add | (.http_code|tostring) + ", effective url: " + .url_effective')
    echo "::error::Error in HTTP POST to ${url} of \`${json}\`: ${message}"
    exit 1
  fi
}

fail() {
  local message=$1
  local error=${2:-}

  echo "::error::${message} (${error})"
  echo '::endgroup::'

  local comment="${message}"
  if [ -n "${error}" ]
  then
    comment+="\n\n<details><summary>Error</summary><pre>${error}</pre></details>"
  fi
  local comment_json
  comment_json="$(jq -n -c --arg body "${comment}" '{"body": $body|gsub ("\\\\n";"\n")}')"

  local comments_url
  comments_url=$(jq --raw-output .pull_request._links.comments.href "${GITHUB_EVENT_PATH}")

  http_post "${comments_url}" "${comment_json}"

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

  output=''
  test -d "${GITHUB_WORKSPACE}/.git" && debug output git -C "${GITHUB_WORKSPACE}" checkout -b "${branch}" -t "origin/${branch}" || debug output git clone -q --no-tags -b "${branch}" "${repository}" "${GITHUB_WORKSPACE}" || fail "Unable to clone from repository \`${repository}\` a branch named \`${branch}\`, this should not have happened" &&
  (
    cd "${GITHUB_WORKSPACE}"

    local user_name
    user_name="$(git --no-pager log --format=format:'%an' -n 1)"
    local user_email
    user_email="$(git --no-pager log --format=format:'%ae' -n 1)"

    set +e

    debug output git checkout -q -b "${backport_branch}" || fail "Unable to checkout branch named \`${branch}\`, you might need to create it or use a different label."

    debug output git -c user.name="${user_name}" -c user.email="${user_email}" cherry-pick -x --mainline 1 "${merge_sha}" || fail "Unable to cherry-pick commit ${merge_sha} on top of branch \`${branch}\`.\n\nThis pull request needs to be backported manually." "${output}
$(git status)"

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

    git -c user.name="${user_name}" -c user.email="${user_email}" -c "http.https://github.com.extraheader=Authorization: basic ${auth}" push --set-upstream origin "${backport_branch}" 2>/dev/null || fail "Unable to push the backported branch, did you try to backport the same PR twice without deleting the \`${backport_branch}\` branch?"

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

  http_post "${pulls_url}" "${pull_request}"
}

backport() {
  local number=$1
  local branch=$2

  echo '::group::Performing backport'
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
  echo '::endgroup::'
}

delete_branch() {
  echo '::group::Deleting closed pull request branch'

  local branch=$1
  local refs_url
  refs_url=$(tmp=$(jq --raw-output .pull_request.head.repo.git_refs_url "${GITHUB_EVENT_PATH}"); echo "${tmp%{*}")
  local output
  output="$(mktemp)"

  debug status curl -XDELETE -v -fsL \
    --fail \
    --output "${output}" \
    -w '%{http_code}' \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    "$refs_url/heads/$branch" || true

  newline_at_eof "${output}"
  sed -e 's/^/::debug::output:/' "${output}"
  rm "${output}"

  echo "::debug::status=${status}"
  if [[ "${status}" == 204 || "${status}" == 422 ]]; then
    echo 'Deleted'
  else
    echo 'Failed to delete branch'
    fail "Unable to delete pull request branch '${branch}'. Please delete it manually."
  fi

  echo '::endgroup::'
}

check_token() {
  echo '::group::Checking token'

  if [[ -z ${INPUT_TOKEN+x} ]]; then
    echo '::error::INPUT_TOKEN is was not provided, by default it should be set to {{ github.token }}'
    echo '::endgroup::'
    exit 1
  fi

  local output
  output="$(mktemp)"

  status=''
  debug status curl -v -fsL \
    --fail \
    --output "${output}" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    "https://api.github.com/zen" || true

  newline_at_eof "${output}"
  sed -e 's/^/::debug::output:/' "${output}"
  rm "${output}"

  echo "::debug::status=${status}"
  if [[ ${status} != 200 ]]
  then
    echo '::error::Provided INPUT_TOKEN is not valid according to the zen API'
    echo '::endgroup::'
    exit 1
  fi

  echo 'Token seems valid'
  echo '::endgroup::'
}

main() {
  echo '::group::Environment'
  for e in $(printenv)
  do
    echo "::debug::${e}"
  done
  echo '::endgroup::'

  local state
  state=$(jq --raw-output .pull_request.state "${GITHUB_EVENT_PATH}")
  local login
  login=$(jq --raw-output .pull_request.user.login "${GITHUB_EVENT_PATH}")
  local title
  title=$(jq --raw-output .pull_request.title "${GITHUB_EVENT_PATH}")
  local merged
  merged=$(jq --raw-output .pull_request.merged "${GITHUB_EVENT_PATH}")

  if [[ "$state" == "closed" && "$login" == "github-actions[bot]" && "$title" == '[Backport '* ]]; then
    check_token
    delete_branch "$(jq --raw-output .pull_request.head.ref "${GITHUB_EVENT_PATH}")"
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
      check_token
      backport "${number}" "${branch}"
    fi
  done
}


${__SOURCED__:+return}

main "$@"
