#!/bin/sh
# Copy pre-commit hook into .git/hooks and make it executable.
set -e

HOOKS_DIR="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOKS_DIR"
cp "$(dirname "$0")/pre-commit" "$HOOKS_DIR/pre-commit"
chmod +x "$HOOKS_DIR/pre-commit"

echo "Installed pre-commit hook to $HOOKS_DIR/pre-commit"
