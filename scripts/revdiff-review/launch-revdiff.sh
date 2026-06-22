#!/usr/bin/env bash
# USER OVERRIDE of revdiff's launcher: open the changed files in Neovim (tmux
# popup) using the local `revdiff_review` plugin, then print captured annotation
# blocks to stdout — same contract the bundled launcher fulfils with the TUI.
#
# Receives the same args the skill passes to the bundled launcher:
#   [base] [against] [--staged] [--only=file ...] [--all-files] [--exclude=prefix ...] [--description*]
#
# Coordination with the nvim plugin: we set $REVDIFF_REVIEW_OUTPUT in the nvim
# env; the plugin's setup() sees it, starts a review session, and auto-exports
# annotation blocks to that file on :qa. We then cat the file to stdout.

set -euo pipefail

NVIM_BIN=$(command -v nvim 2>/dev/null || true)
if [ -z "$NVIM_BIN" ]; then
    echo "error: nvim not found in PATH" >&2
    exit 1
fi

TMPBASE="${TMPDIR:-/tmp}"
OUTPUT_FILE=$(mktemp "$TMPBASE/revdiff-output-XXXXXX")
trap 'rm -f "$OUTPUT_FILE"' EXIT

# shell-quote a single argument for safe embedding in sh -c strings.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ── parse args ─────────────────────────────────────────────────────────────
REFS=()
ONLY=()
EXCLUDES=()
STAGED=0
ALLFILES=0
for arg in "$@"; do
    case "$arg" in
        --staged)            STAGED=1 ;;
        --all-files)         ALLFILES=1 ;;
        --only=*)            ONLY+=("${arg#--only=}") ;;
        --exclude=*)         EXCLUDES+=("${arg#--exclude=}") ;;
        --description=*)     : ;;   # not surfaced in nvim flow
        --description-file=*) : ;;
        -*)                  : ;;   # ignore unknown flags
        *)                   REFS+=("$arg") ;;
    esac
done

CWD="$(pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$CWD")

# ── build the file list ────────────────────────────────────────────────────
NAMES=()
if [ "${#ONLY[@]}" -gt 0 ]; then
    NAMES=("${ONLY[@]}")
elif [ "$ALLFILES" -eq 1 ]; then
    mapfile -t NAMES < <(git -C "$REPO_ROOT" ls-files)
else
    DIFF=(git -C "$REPO_ROOT" diff --name-only)
    [ "$STAGED" -eq 1 ] && DIFF+=(--cached)
    case "${#REFS[@]}" in
        0) [ "$STAGED" -eq 1 ] || DIFF+=(HEAD) ;;
        1) DIFF+=("${REFS[0]}") ;;
        *) DIFF+=("${REFS[0]}" "${REFS[1]}") ;;
    esac
    mapfile -t NAMES < <("${DIFF[@]}" 2>/dev/null || true)
fi

# apply --exclude prefixes
FILES=()
for n in "${NAMES[@]}"; do
    [ -z "$n" ] && continue
    skip=0
    for ex in "${EXCLUDES[@]}"; do
        case "$n" in "$ex"*) skip=1; break ;; esac
    done
    [ "$skip" -eq 1 ] && continue
    # absolutise repo-relative paths; leave already-absolute / existing paths as-is
    if [ -e "$n" ] || [ "${n#/}" != "$n" ]; then
        FILES+=("$n")
    else
        FILES+=("$REPO_ROOT/$n")
    fi
done

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "revdiff(nvim): no files to review" >&2
    exit 0   # empty stdout => skill treats as "no annotations / complete"
fi

BASE="${REFS[0]:-}"

# ── build the nvim command (env-driven session, no -c needed) ───────────────
# /usr/bin/env prefix guarantees the vars reach nvim even though the tmux popup
# inherits the tmux *server* env, not the caller's shell env.
NVIM_CMD="/usr/bin/env $(sq "REVDIFF_REVIEW_OUTPUT=$OUTPUT_FILE")"
[ -n "$BASE" ] && NVIM_CMD="$NVIM_CMD $(sq "REVDIFF_REVIEW_BASE=$BASE")"
NVIM_CMD="$NVIM_CMD $(sq "$NVIM_BIN") -p"
for f in "${FILES[@]}"; do
    NVIM_CMD="$NVIM_CMD $(sq "$f")"
done

DIR_NAME=$(basename "$CWD")
OVERLAY_TITLE="review: ${DIR_NAME}${BASE:+ [$BASE]}"
POPUP_W="${REVDIFF_POPUP_WIDTH:-90%}"
POPUP_H="${REVDIFF_POPUP_HEIGHT:-90%}"

# ── tmux overlay (display-popup -E blocks until nvim exits) ──────────────────
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    TMUX_ARGS=(tmux display-popup -E -w "$POPUP_W" -h "$POPUP_H")
    if [[ "$(tmux -V 2>/dev/null)" =~ ([0-9]+)\.([0-9]+) ]]; then
        if [ "${BASH_REMATCH[1]}" -gt 3 ] || { [ "${BASH_REMATCH[1]}" -eq 3 ] && [ "${BASH_REMATCH[2]}" -ge 3 ]; }; then
            TMUX_ARGS+=(-T " $OVERLAY_TITLE ")
        fi
    fi
    TMUX_ARGS+=(-d "$CWD" -- sh -c "$NVIM_CMD")
    "${TMUX_ARGS[@]}"
    cat "$OUTPUT_FILE"
    exit 0
fi

echo "error: this override only implements the tmux overlay; start Claude inside tmux" >&2
echo "       (extend launch-revdiff.sh with zellij/kitty branches from the bundled launcher if needed)" >&2
exit 1
