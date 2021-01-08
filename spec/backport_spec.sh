#!/usr/bin/env bash

eval "$(shellspec -)"

Describe 'Backport action'
  setup() {
    GITHUB_EVENT_PATH="$(mktemp)"
    GITHUB_WORKSPACE="$(mktemp -d)"
    INPUT_TOKEN="github-token"
    git_repository="$(mktemp -d)"
  }
  Before 'setup'

  cleanup() {
    rm "${GITHUB_EVENT_PATH}"
    rm -rf "${GITHUB_WORKSPACE}"
    rm -rf "${git_repository}"
  }
  After 'cleanup'

  Include backport.sh

  It 'Generates auth'
    When call auth_header 'github-token'
    The output should equal 'eC1hY2Nlc3MtdG9rZW46Z2l0aHViLXRva2Vu'
  End

  Describe 'fail'
    # mock http_post
    http_post() {
      echo "http_post invoked with: $*"
    }
    setup_event_file() {
        cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "pull_request": {
    "_links": {
      "comments": {
        "href": "comments-url"
      }
    }
  }
}
EOF
    }
    Before 'setup_event_file'

    It 'Handles reports failures'
      When run fail message error
      The output should equal '::error::message (error)
::endgroup::
http_post invoked with: comments-url {"body":"message\n\n<details><summary>Error</summary><pre>error</pre></details>"}'
      The status should equal 1
    End
  End

  Describe 'cherry_pick'

    Describe 'Cherry pick succeeds'
      setup_repo() {
        cd "${git_repository}" || exit
        git init -q
        git config user.name testuser
        git config user.email test@example.com
        echo initial > file
        git add file
        git commit -q -m initial file
        git checkout -q -b branch
        git checkout -q -b feature
        echo modified > file
        git commit -q -m change file
        commit="$(git rev-parse HEAD)"
        git checkout -q master
        git merge -q --no-ff --commit "${commit}"
        merge_commit_sha="$(git rev-parse HEAD)"
      }
      Before 'setup_repo'

      It 'Cherry picks'
        When call cherry_pick 'branch' "${git_repository}" 'backport-branch' "${merge_commit_sha}"
        The output should match pattern "::debug::running: git clone -q --no-tags -b branch ${git_repository} *
::debug::rc=0"
        The value "$(cd "${GITHUB_WORKSPACE}" && git show backport-branch:file)" should equal "modified"
      End
    End

    Describe 'Merge conflict'
      # mock http_post
      http_post() {
        echo "http_post invoked with:$*"
      }

      setup_repo() {
        cd "${git_repository}" || exit
        git init -q
        git config user.name testuser
        git config user.email test@example.com
        echo initial > file
        git add file
        git commit -q -m initial file
        git checkout -q -b branch
        echo conflict > file
        git add file
        git commit -q -m conflict
        git checkout -q -b feature master
        echo modified > file
        git commit -q -m change file
        commit="$(git rev-parse HEAD)"
        git checkout -q master
        git merge -q --no-ff --commit "${commit}"
        merge_commit_sha="$(git rev-parse HEAD)"
      }
      Before 'setup_repo'

      setup_event_file() {
        cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "number": 123,
  "pull_request": {
    "state": "merged",
    "merged": true,
    "labels": [
      {
        "name": "backport branch1"
      },
      {
        "name": "backport branch2"
      }
    ],
    "title": "[Backport branch] Something",
    "head": {
      "ref": "sha",
      "repo": {
        "git_refs_url": "git-refs-url{/sha}"
      }
    },
    "_links": {
      "comments": {
        "href": "comments-url"
      }
    }
  }
}
EOF
      }
      Before 'setup_event_file'

      It 'Fails due to merge conflict'
        When run cherry_pick 'branch' "${git_repository}" 'backport-branch' "${merge_commit_sha}"
        The value "$(cd "${GITHUB_WORKSPACE}" && git show backport-branch:file)" should equal "conflict"
        The output should match pattern "::debug::running: git clone -q --no-tags -b branch ${git_repository} *
::debug::rc=0
::debug::running: git checkout -q -b backport-branch
::debug::rc=0
::debug::running: git -c user.name=testuser -c user.email=test@example.com cherry-pick -x --mainline 1 ${merge_commit_sha}
::debug::err:error: could not apply *... Merge commit '*'
::debug::err:hint: after resolving the conflicts, mark the corrected paths
::debug::err:hint: with 'git add <paths>' or 'git rm <paths>'
::debug::err:hint: and commit the result with 'git commit'
::debug::out:Auto-merging file
::debug::out:CONFLICT (content): Merge conflict in file
::debug::rc=1
::error::Unable to cherry-pick commit ${merge_commit_sha} on top of branch \`branch\`.\n\nThis pull request needs to be backported manually. (Auto-merging file
CONFLICT (content): Merge conflict in file
On branch backport-branch
You are currently cherry-picking commit *.
  (fix conflicts and run \"git cherry-pick --continue\")
  (use \"git cherry-pick --skip\" to skip this patch)
  (use \"git cherry-pick --abort\" to cancel the cherry-pick operation)

Unmerged paths:
  (use \"git add <file>...\" to mark resolution)
	both modified:   file

no changes added to commit (use \"git add\" and/or \"git commit -a\"))
::endgroup::
http_post invoked with:comments-url {\"body\":\"Unable to cherry-pick commit * on top of branch \`branch\`.\\n\\nThis pull request needs to be backported manually.\\n\\n<details><summary>Error</summary><pre>Auto-merging file\\nCONFLICT (content): Merge conflict in file\\nOn branch backport-branch\nYou are currently cherry-picking commit *.\n  (fix conflicts and run \\\"git cherry-pick --continue\\\")\n  (use \\\"git cherry-pick --skip\\\" to skip this patch)\n  (use \\\"git cherry-pick --abort\\\" to cancel the cherry-pick operation)\n\nUnmerged paths:\n  (use \\\"git add <file>...\\\" to mark resolution)\n\\tboth modified:   file\n\nno changes added to commit (use \\\"git add\\\" and/or \\\"git commit -a\\\")</pre></details>\"}"
        The status should equal 1
      End
    End

  End

  Describe 'push'
    setup_repo() {
      cd "${git_repository}" || exit
      git init -q
      git config user.name testuser
      git config user.email test@example.com
      echo initial > file
      git add file
      git commit -q -m initial file
      cd "${GITHUB_WORKSPACE}" || exit
      git clone -q "${git_repository}" .
      git config user.name otheruser
      git config user.email other@example.com
      git checkout -q -b backport-branch
      echo modified > file
      git commit -q -m change file
    }
    Before 'setup_repo'

    It 'Pushes'
      When call push 'backport-branch'
      The value "$(cd "${git_repository}" && git show backport-branch:file)" should equal "modified"
      The output should start with "Branch 'backport-branch' set up to track remote branch 'backport-branch' from 'origin'"
    End
  End

  Describe 'create_pull_request'
    # mock http_post
    http_post() {
      export http_post_args="$*"
    }

    It 'Creates pull requests'
      When call create_pull_request branch backport-branch title 123 url
      The variable 'http_post_args' should equal "url {    \"title\": \"[Backport branch] title\",     \"body\": \"Backport of #123\",     \"head\": \"backport-branch\",     \"base\": \"branch\"   }"
    End
  End

  Describe 'backport'
    # mock functions
    cherry_pick() {
      export cherry_pick_args="$*"
    }

    push() {
      export push_args="$*"
    }

    create_pull_request() {
      export create_pull_request_args="$*"
    }

    setup_event_file() {
    cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "repository": {
    "clone_url": "clone-url",
    "pulls_url": "pulls-url{/number}"
  },
  "pull_request": {
    "title": "title",
    "merge_commit_sha": "merge-commit-sha"
  }
}
EOF
    }
    Before 'setup_event_file'

    It 'Backports'
      When call backport 123 branch
      The variable 'cherry_pick_args' should equal 'branch clone-url backport/123-to-branch merge-commit-sha'
      The variable 'push_args' should equal 'backport/123-to-branch'
      The variable 'create_pull_request_args' should equal 'branch backport/123-to-branch title 123 pulls-url'
      The output should equal '::group::Performing backport
::debug::Backporting pull request #123 to branch branch
::endgroup::'
    End
  End

  Describe 'delete_branch'
    setup_event_file() {
    cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "pull_request": {
    "head": {
      "repo": {
        "git_refs_url": "git-refs-url{/sha}"
      }
    }
  }
}
EOF
    }
    Before 'setup_event_file'

    Describe 'Happy path'
      curl_args="$(mktemp)"
      # mock curl
      curl() {
        echo "$@" > "${curl_args}"
        echo 204
      }

      After "rm \"${curl_args}\""

      It 'Deletes branches'
        When call delete_branch backport/123-to-branch
        The value "$(cat "${curl_args}")" should match pattern "-XDELETE -v -fsL --fail --output * -w %{http_code} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer ${INPUT_TOKEN} git-refs-url/heads/backport/123-to-branch"
      The output should match pattern '::group::Deleting closed pull request branch
::debug::running: curl -XDELETE -v -fsL --fail --output * -w %{http_code} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer github-token git-refs-url/heads/backport/123-to-branch
::debug::out:204
::debug::rc=0
::debug::status=204
Deleted
::endgroup::'
      End
    End

    Describe 'REST API returns 442'
      curl_args="$(mktemp)"
      # mock curl
      curl() {
        echo "$@" > "${curl_args}"
        echo 422
      }

      After "rm \"${curl_args}\""

      It 'Doesn''t fail on deleted branches'
        When call delete_branch backport/123-to-branch
        The value "$(cat "${curl_args}")" should match pattern "-XDELETE -v -fsL --fail --output * -w %{http_code} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer ${INPUT_TOKEN} git-refs-url/heads/backport/123-to-branch"
        The output should match pattern '::group::Deleting closed pull request branch
::debug::running: curl -XDELETE -v -fsL --fail --output * -w %{http_code} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer github-token git-refs-url/heads/backport/123-to-branch
::debug::out:422
::debug::rc=0
::debug::status=422
Deleted
::endgroup::'
      End
    End

    Describe 'REST API returns 401'
      curl_args="$(mktemp)"
      # mock curl
      curl() {
        echo "$@" > "${curl_args}"
        echo 401
      }

      fail() {
        echo '::endgroup::'
        exit 1
      }

      After "rm \"${curl_args}\""

      It 'Fails to delete branch'
        When run delete_branch backport/123-to-branch
        The value "$(cat "${curl_args}")" should match pattern "-XDELETE -v -fsL --fail --output * -w %{http_code} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer ${INPUT_TOKEN} git-refs-url/heads/backport/123-to-branch"
        The output should match pattern '::group::Deleting closed pull request branch
::debug::running: curl -XDELETE -v -fsL --fail --output * -w %{http_code} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer github-token git-refs-url/heads/backport/123-to-branch
::debug::out:401
::debug::rc=0
::debug::status=401
Failed to delete branch
::endgroup::'
        The status should equal 1
      End
    End
  End

  Describe 'main'
    # mock functions
    delete_branch() {
      export delete_branch_args="$*"
    }

    backport() {
      export backport_args+=("$*")
    }

    Describe 'Token is valid'
      check_token() {
        return
      }

      Describe 'Pull request was closed'
        setup_event_file() {
        cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "pull_request": {
    "state": "closed",
    "user": {
      "login": "github-actions[bot]"
    },
    "labels": [],
    "title": "[Backport branch] Something",
    "head": {
      "ref": "backport/123-to-branch",
      "repo": {
        "git_refs_url": "git-refs-url{/sha}"
      }
    }
  }
}
EOF
        }

        Before 'setup_event_file'

        It 'Deletes backport branches when pull request is closed'
          When call main
          The variable 'delete_branch_args' should equal 'backport/123-to-branch'
          The variable 'backport_args' should be undefined
          The output should include '::debug::HOME'
          The status should be success
        End
      End

      Describe 'Pull request merged'
        setup_event_file() {
        cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "number": 123,
  "pull_request": {
    "state": "merged",
    "merged": true,
    "labels": [
      {
        "name": "backport branch1"
      },
      {
        "name": "backport branch2"
      }
    ],
    "title": "[Backport branch] Something",
    "head": {
      "ref": "sha",
      "repo": {
        "git_refs_url": "git-refs-url{/sha}"
      }
    }
  }
}
EOF
      }

        Before 'setup_event_file'
        It 'Backports merged pull requests'
          When call main
          The variable 'delete_branch_args' should be undefined
          The variable 'backport_args[*]' should equal '123 branch1 123 branch2'
          The output should include '::debug::HOME'
          The status should be success
        End
      End

    End

    Describe 'Pull request not merged'
      setup_event_file() {
      cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "pull_request": {
    "state": "open",
    "merged": false,
    "user": {
      "login": "github-actions[bot]"
    },
    "labels": [],
    "title": "[Backport branch] Something"
  }
}
EOF
      }
      Before 'setup_event_file'
      It 'Doesn''t backport non-merged pull requests'
        When call main
        The variable 'delete_branch_args' should be undefined
        The variable 'backport_args' should be undefined
        The output should include '::debug::HOME'
        The status should be success
      End
    End

    Describe 'INPUT_TOKEN not set'
      remove_input_token() {
        unset INPUT_TOKEN
      }

      setup_event_file() {
      cat<<EOF>"${GITHUB_EVENT_PATH}"
{
  "number": 123,
  "pull_request": {
    "state": "merged",
    "merged": true,
    "labels": [
      {
        "name": "backport branch1"
      },
      {
        "name": "backport branch2"
      }
    ],
    "title": "[Backport branch] Something",
    "head": {
      "ref": "sha",
      "repo": {
        "git_refs_url": "git-refs-url{/sha}"
      }
    }
  }
}
EOF
      }

      Before 'setup_event_file'
      Before 'remove_input_token'

      It 'Stops working'
        When run main
        The variable 'delete_branch_args' should be undefined
        The variable 'backport_args[*]' should be undefined
        The output should include '::error::INPUT_TOKEN is was not provided, by default it should be set to {{ github.token }}'
        The status should equal 1
      End
    End

    Describe 'Token checks'
      Describe 'Token not set'
        remove_input_token() {
          unset INPUT_TOKEN
        }
        Before 'remove_input_token'

        It 'Checks INPUT_TOKEN is defined'
          When run check_token
          The output should include '::error::INPUT_TOKEN is was not provided, by default it should be set to {{ github.token }}'
          The status should equal 1
        End
      End

      Describe 'Token is set'
        curl_args="$(mktemp)"
        # mock curl
        curl() {
          echo "$@" > "${curl_args}"
          echo "curl verbose output" 1>&2
          echo "curl verbose output (second line)" 1>&2
          echo 401
        }

        After "rm \"${curl_args}\""

        It 'Fails when zen API returns status 4xx'
          When run check_token
          The output should match pattern '::group::Checking token
::debug::running: curl -v -fsL --fail --output * -w %{http_code} -H Authorization: Bearer github-token https://api.github.com/zen
::debug::err:curl verbose output
::debug::err:curl verbose output (second line)
::debug::out:401
::debug::rc=0
::debug::status=401
::error::Provided INPUT_TOKEN is not valid according to the zen API
::endgroup::'
          The value "$(cat "${curl_args}")" should match pattern '-v -fsL --fail --output * -w %{http_code} -H Authorization: Bearer github-token https://api.github.com/zen'
          The status should equal 1
        End

        # mock curl
        curl() {
          echo "$@" > "${curl_args}"
          echo "curl verbose output" >&2
          echo "curl verbose output (second line)" >&2
          local args="$*"
          echo '200'
        }

        It 'Succeeds when zen API returns status 2xx'
          When run check_token
          The output should match pattern '::group::Checking token
::debug::running: curl -v -fsL --fail --output * -w %{http_code} -H Authorization: Bearer github-token https://api.github.com/zen
::debug::err:curl verbose output
::debug::err:curl verbose output (second line)
::debug::out:200
::debug::rc=0
::debug::status=200
Token seems valid
::endgroup::'
          The value "$(cat "${curl_args}")" should match pattern '-v -fsL --fail --output * -w %{http_code} -H Authorization: Bearer github-token https://api.github.com/zen'
          The status should equal 0
        End
      End
    End
  End

  Describe 'http_post'
    # mock curl
    curl_args="$(mktemp)"
    curl() {
      echo "$@" > "${curl_args}"
      echo "${#@}" >> "${curl_args}"
      local args="$*"
      local output
      output="$(local tmp="${args/*--output /}"; echo "${tmp/% */}")"
      echo 'curl output' > "${output}"
      echo 'curl output (second line)' >> "${output}"
      echo 'curl error output' >&2
      echo 'curl error output (second line)' >&2
      echo '{"http_code":401,"url_effective":"url"}'

      return 22
    }

    After "rm \"${curl_args}\""

    It 'Should handle errors'
      When run http_post url '{"json":"data"}'
      The output should match pattern '::debug::running: curl -XPOST --fail -v -fsL --output * -w {"http_code":%{http_code},"url_effective":"%{url_effective}"} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer github-token -H Content-Type: application/json -d {"json":"data"} url
::debug::err:curl error output
::debug::err:curl error output (second line)
::debug::out:{"http_code":401,"url_effective":"url"}
::debug::rc=22
::debug::output:curl output
::debug::output:curl output (second line)
::debug::result={"http_code":401,"url_effective":"url"}
::error::Error in HTTP POST to url of '"\`"'{"json":"data"}'"\`"': 401, effective url: url'
      The value "$(cat "${curl_args}")" should match pattern '-XPOST --fail -v -fsL --output * -w {"http_code":%{http_code},"url_effective":"%{url_effective}"} -H Accept: application/vnd.github.v3+json -H Authorization: Bearer github-token -H Content-Type: application/json -d {"json":"data"} url
17'
      The status should equal 1
    End
  End

  Describe 'debug'
    prog_args="$(mktemp)"
    prog() {
      echo "$@" > "${prog_args}"
      echo "${#@}" >> "${prog_args}"
      echo 'stdout 1'
      echo 'stderr 1' >&2
      echo 'stderr 2' >&2
      echo 'stdout 2'
      echo 'stdout 3'
      echo 'stderr 3' >&2
      exit 3
    }

    After "rm \"${prog_args}\""

    It 'Should debug log and execute'
      out=""
      When call debug out prog -a -b -c "'x y'" '"z w"'
      The output should equal "::debug::running: prog -a -b -c 'x y' \"z w\""'
::debug::err:stderr 1
::debug::err:stderr 2
::debug::err:stderr 3
::debug::out:stdout 1
::debug::out:stdout 2
::debug::out:stdout 3
::debug::rc=3'
      The value "$(cat "${prog_args}")" should equal "-a -b -c 'x y' \"z w\"
5"
      The value "${out}" should equal 'stdout 1
stdout 2
stdout 3'
      The status should equal 3
    End
  End

  Describe 'newline_at_eof'
    file="$(mktemp)"

    After "rm \"${file}\""

    It 'Should add newline to file'
      echo -n 'abc'> "${file}"
      When call newline_at_eof "${file}"
      The value "$(stat --format='%s' "${file}")" should equal 4
    End

    It 'Should not add newline to file if it exists'
      echo 'text'> "${file}"
      When call newline_at_eof "${file}"
      The value "$(stat --format='%s' "${file}")" should equal 5
    End

    It 'Newline should not be added to empty files'
      echo -n ''> "${file}"
      When call newline_at_eof "${file}"
      The value "$(stat --format='%s' "${file}")" should equal 0
    End
  End

End
