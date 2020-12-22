.DEFAULT_GOAL: all

all : check test

check:
	shellcheck --severity=style *.sh spec/*.sh

test:
	shellspec
