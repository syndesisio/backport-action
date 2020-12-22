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

  Describe 'cherry_pick'
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
      The value "$(cd "${GITHUB_WORKSPACE}" && git show backport-branch:file)" should equal "modified"
      The line 1 should start with "[backport-branch"
      The line 2 should start with " Date"
      The line 3 should equal      " 1 file changed, 1 insertion(+), 1 deletion(-)"
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
    # mock curl
    curl() {
      export curl_args="$*"
    }

    It 'Creates pull requests'
      When call create_pull_request branch backport-branch title 123 url
      The variable 'curl_args' should equal "-XPOST -fsSL --output /dev/null -H Accept: application/vnd.github.v3+json -H Authorization: Bearer ${INPUT_TOKEN} -H Content-Type: application/json -d {    \"title\": \"[Backport branch] title\",     \"body\": \"Backport of #123\",     \"head\": \"backport-branch\",     \"base\": \"branch\"   } url"
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
      The output should equal '::debug::Backporting pull request #123 to branch branch'
    End
  End

  Describe 'delete_branch'
    # mock curl
    curl() {
      export curl_args="$*"
    }

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
    It 'Deletes branches'
      When call delete_branch head/sha
      The variable 'curl_args' should equal "-XDELETE -fsSL --output /dev/null -H Accept: application/vnd.github.v3+json -H Authorization: Bearer ${INPUT_TOKEN} git-refs-url/head/sha"
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
     It 'Deletes backport branches when pull request is closed'
       When call main
       The variable 'delete_branch_args' should equal 'head/sha'
       The variable 'backport_args' should be undefined
       The status should be success
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
     It 'Doesn''t backport non-merged pull requests'
       When call main
       The variable 'delete_branch_args' should be undefined
       The variable 'backport_args' should be undefined
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
       The status should be success
     End
   End
  End

End