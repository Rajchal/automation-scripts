#!/bin/bash
#
# Git commit-msg hook
# -------------------
# Enforces Conventional Commits specification.
# Allowed prefixes: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert
#
# To install:
# cp git-commit-msg-hook.sh .git/hooks/commit-msg
# chmod +x .git/hooks/commit-msg
#

# Path to the commit message file
MSG_FILE=$1

# Read the first line of the commit message
COMMIT_MSG=$(head -n1 "$MSG_FILE")

# Regular expression for Conventional Commits
# Format: type(scope?): subject
REGEX="^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_-]+\))?: [a-zA-Z0-9].*$"

# Merge commits are usually auto-generated and should pass
if [[ $COMMIT_MSG == Merge* ]]; then
    exit 0
fi

if [[ ! $COMMIT_MSG =~ $REGEX ]]; then
    echo -e "\e[31mError: Commit message does not follow Conventional Commits specification.\e[0m"
    echo ""
    echo "Expected format: <type>[optional scope]: <description>"
    echo "Example: feat(api): add user authentication"
    echo ""
    echo "Allowed types:"
    echo "  feat     : A new feature"
    echo "  fix      : A bug fix"
    echo "  docs     : Documentation only changes"
    echo "  style    : Changes that do not affect the meaning of the code"
    echo "  refactor : A code change that neither fixes a bug nor adds a feature"
    echo "  perf     : A code change that improves performance"
    echo "  test     : Adding missing tests or correcting existing tests"
    echo "  build    : Changes that affect the build system or external dependencies"
    echo "  ci       : Changes to our CI configuration files and scripts"
    echo "  chore    : Other changes that don't modify src or test files"
    echo "  revert   : Reverts a previous commit"
    echo ""
    exit 1
fi

exit 0
