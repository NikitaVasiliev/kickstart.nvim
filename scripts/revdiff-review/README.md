# revdiff-review (nvim ⇄ Claude Code)

Review **any buffer** in Neovim with line / range / file-level annotations, then
hand them to Claude Code. The revdiff Claude plugin's TUI is replaced by Neovim
via a user-override launcher, so the skill's review loop runs unchanged.

## Components

| Part | Path |
|---|---|
| nvim module | `lua/revdiff_review/init.lua` |
| nvim spec (loads module) | `lua/plugins/revdiff-review.lua` |
| override launcher (canonical) | `scripts/revdiff-review/launch-revdiff.sh` |
| installer (symlinks launcher) | `scripts/revdiff-review/install.sh` |

The launcher and the module share the `REVDIFF_REVIEW_OUTPUT` / `REVDIFF_REVIEW_BASE`
env protocol — keep them versioned together.

## How it runs

```
revdiff skill → ${CLAUDE_PLUGIN_DATA}/scripts/launch-revdiff.sh (symlink → this repo)
              → tmux popup: nvim -p <changed files>   (REVDIFF_REVIEW_OUTPUT set)
              → annotate (<leader>rc / <leader>rf), :qa
              → plugin auto-exports annotation blocks → launcher prints to stdout
              → skill's plan → address → loop  (unchanged)
```

Interactive (no Claude) flow also works: annotate, `<leader>re` to export to
`~/.config/revdiff/history/<repo>/<ts>.md`, then tell Claude "use my latest
revdiff annotations".

## Reproduce on a new host (from scratch)

Prerequisites: `nvim`, `tmux`, `git`, `stow`, and the Claude Code CLI (`claude`).
Run Claude **inside tmux** (only the tmux overlay branch is implemented).

```bash
# 1. dotfiles + submodules (the nvim config is a git submodule)
git clone --recurse-submodules <dotfiles-url> ~/.dotfiles
cd ~/.dotfiles && stow nvim tmux shell        # + any other packages

# 2. revdiff Claude plugin
claude
#   /plugin marketplace add umputun/revdiff
#   /plugin install revdiff@revdiff
#   (exit)

# 3. link the nvim override launcher into Claude's data dir
~/.config/nvim/scripts/revdiff-review/install.sh

# 4. first nvim launch installs plugins (lazy auto-imports lua/plugins/)
nvim +qa
```

Then, inside tmux + Claude Code: ask for a review ("review changes",
"revdiff HEAD~1", "revdiff all files exclude vendor"). It opens nvim.

### Notes
- The override lives under the plugin **id** dir (`revdiff-revdiff`), which is
  version-independent — it survives revdiff plugin updates.
- To fall back to the real revdiff TUI: `chmod -x` the symlink target (the
  resolver then uses the bundled launcher).
- Non-tmux terminals: copy the zellij/kitty branches from the bundled
  `launch-revdiff.sh` into `launch-revdiff.sh` here.

### Submodule gotcha
The nvim config is a submodule (`kickstart.nvim` fork). After changing the nvim
plugin you must commit **inside the submodule**, push it, then bump the pointer
in the outer dotfiles repo — otherwise a fresh `--recurse-submodules` clone gets
the old commit.
