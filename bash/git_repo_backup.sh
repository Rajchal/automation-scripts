#!/bin/bash

REPOS=("git@github.com:user/repo1.git" "git@github.com:user/repo2.git")
DEST="/var/backups/git"
DATE=$(date +%F)

mkdir -p "$DEST"
for repo in "${REPOS[@]}"; do
  NAME=$(basename "$repo" .git)
  DIR="$DEST/$NAME"
  if [ -d "$DIR/.git" ]; then
    cd "$DIR" && git pull
  else
    git clone "$repo" "$DIR"
  fi
  tar czf "$DEST/${NAME}_backup_${DATE}.tar.gz" -C "$DIR" .
done

echo "Git repositories backed up to $DEST"
