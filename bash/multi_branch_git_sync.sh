#!/bin/bash
# Pulls updates for all branches in a git repo

cd /path/to/repo
for branch in $(git branch -r | grep -v '\->'); do
  git checkout --track "$branch" || git checkout "${branch##origin/}"
  git pull
done
