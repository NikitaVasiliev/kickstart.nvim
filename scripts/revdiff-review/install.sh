#!/usr/bin/env bash
# Install the nvim revdiff override launcher into Claude Code's plugin data dir.
#
# The revdiff Claude plugin resolves launch-revdiff.sh through a user-override
# layer at ${CLAUDE_PLUGIN_DATA}/scripts/launch-revdiff.sh. We symlink the
# repo-tracked launcher there so edits stay version-controlled with the nvim
# plugin it speaks to.
#
# Prereq: the revdiff Claude plugin must be installed first, e.g.
#   claude   then:  /plugin marketplace add umputun/revdiff
#                   /plugin install revdiff@revdiff
#
# Idempotent: safe to re-run. Run after any fresh dotfiles checkout.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/launch-revdiff.sh"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/revdiff-revdiff}"
DEST_DIR="$DATA_DIR/scripts"
DEST="$DEST_DIR/launch-revdiff.sh"

if [ ! -d "$DATA_DIR" ]; then
    echo "error: $DATA_DIR not found — install the revdiff Claude plugin first:" >&2
    echo "       /plugin marketplace add umputun/revdiff && /plugin install revdiff@revdiff" >&2
    exit 1
fi

chmod +x "$SRC"
mkdir -p "$DEST_DIR"
ln -sfn "$SRC" "$DEST"
echo "linked $DEST -> $SRC"
echo "verify: revdiff will now open nvim instead of the TUI."
