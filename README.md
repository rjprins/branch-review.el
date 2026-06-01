# branch-review.el

[![CI](https://github.com/rjprins/branch-review.el/actions/workflows/ci.yml/badge.svg)](https://github.com/rjprins/branch-review.el/actions/workflows/ci.yml)

Review the changes on your current branch (or any worktree) inside Emacs,
GitHub-pull-request style, **in your real file buffers** — without leaving your
editor and without reinventing what [Magit](https://magit.vc) and
[diff-hl](https://github.com/dgutov/diff-hl) already do well.

`branch-review` is a thin layer that wires together:

- **Magit** — the diff of `merge-base(base, HEAD)` → working tree is your review
  overview: an ordered file/hunk tree you can fold and navigate.
- **diff-hl** — change markers in the real file buffers, computed against the
  merge base.
- a little glue that adds the workflow on top: base detection, an occur-style
  "peek", current-line highlighting, cross-pane navigation, a recent-worktree
  picker, and reliable teardown.

> **Not on MELPA.** Install straight from this repo (see below). It's a personal
> tool, but it might be useful to you too.

## What it gives you

- **One command to review a branch.** `M-x branch-review` compares your branch
  against its merge base with `origin/main` (auto-detected) and opens a review.
- **A worktree picker.** `M-x branch-review-open` lists recent/seen worktrees —
  including every *sibling* worktree of repos you know — sorted by most recent
  commit and annotated with branch and age. Built for a worktree-per-ticket
  flow.
- **Occur-style navigation.** Move point through the overview and the file at
  point opens in the other window after a short delay, without stealing focus.
  Deleted and binary files are skipped.
- **The change you're on, highlighted.** The current line is highlighted in the
  file buffer (via `hl-line`) and follows you as you move between hunks.
- **`RET` opens into the file window**, keeping the overview visible instead of
  replacing it.
- **Cross-pane hunk/file navigation** that keeps the overview and the file
  buffer in sync, even when driven from the file buffer.

## Requirements

- Emacs 28.1+
- [Magit](https://magit.vc) 3.3+
- [diff-hl](https://github.com/dgutov/diff-hl) 1.9+

## Installation

### Emacs 30+ (`use-package` with `:vc`)

```elisp
(use-package branch-review
  :vc (:url "https://github.com/rjprins/branch-review.el" :rev :newest)
  :after magit)
```

…or without `use-package`:

```elisp
(package-vc-install "https://github.com/rjprins/branch-review.el")
```

### straight.el

```elisp
(use-package branch-review
  :straight (branch-review :type git :host github :repo "rjprins/branch-review.el"))
```

### Manual

```sh
git clone https://github.com/rjprins/branch-review.el ~/src/branch-review.el
```

```elisp
(add-to-list 'load-path "~/src/branch-review.el")
(require 'branch-review)
```

> **No fringes?** `diff-hl` draws its change markers in the fringe by default. If
> you run without fringes, enable margin rendering so the markers show up:
> `(diff-hl-margin-mode 1)`.

## Usage

Start a review with `M-x branch-review` from anywhere inside a Git repository, or
pick a worktree with `M-x branch-review-open`. Move point through the overview to
preview files, navigate with the keys below, and end the session with
`branch-review-quit`.

### Commands and default keybindings

`branch-review` provides a prefix command map, `branch-review-command-map`. It
does not grab any keys — bind the map wherever you like:

```elisp
(keymap-global-set "C-c r" 'branch-review-command-map)        ; Emacs 29+
;; or, on older Emacs:
;; (global-set-key (kbd "C-c r") 'branch-review-command-map)
```

The keys below assume that `C-c r` binding:

| Key                   | Command                     | Does                                                  |
|-----------------------|-----------------------------|-------------------------------------------------------|
| `C-c r r`             | `branch-review`             | Review current repo (or reopen); `C-u` prompts for base |
| `C-c r o`             | `branch-review-open`        | Pick a recent/seen worktree to review                 |
| `C-c r w`             | `branch-review-with-base`   | Review, prompting for the base branch                 |
| `C-c r O`             | `branch-review-overview`    | Reopen the overview                                   |
| `C-c r q`             | `branch-review-quit`        | End the review and clean up                           |
| `C-c r g`             | `branch-review-refresh`     | Recompute the overview and marks                      |
| `C-c r n` / `C-c r p` | next / previous hunk        | across file boundaries, panes stay in sync            |
| `C-c r f` / `C-c r b` | next / previous file        |                                                       |
| `C-c r t`             | `diff-hl-show-hunk`         | Show the hunk inline (including removed lines)         |

Inside the overview, `RET` opens the file at point in the file window. All the
usual Magit diff keys still work there (`TAB` to fold, `n`/`p`, etc.).

## Configuration

| Variable                                 | Default                                  | Meaning                                                       |
|------------------------------------------|------------------------------------------|---------------------------------------------------------------|
| `branch-review-base-branch-fallbacks`    | `("origin/main" "origin/master")`        | Base branches tried before the remote HEAD default            |
| `branch-review-diff-args`                | `("--stat")`                             | Extra args for the overview diff (`--stat` adds line counts)  |
| `branch-review-auto-open`                | `t`                                      | Auto-open the file at point in the overview                   |
| `branch-review-auto-open-delay`          | `0.2`                                    | Idle delay (seconds) before auto-open                         |
| `branch-review-skip-binary`              | `t`                                      | Don't auto-open binary files                                  |
| `branch-review-highlight-current-line`   | `t`                                      | Highlight the current line in the file buffer                 |
| `branch-review-open-sort`                | `commit-date`                            | Worktree ordering: `commit-date`, `mru`, or `alpha`           |
| `branch-review-open-include-projectile`  | `t`                                      | Also offer git projects from `projectile-known-projects`      |
| `branch-review-known-worktrees-file`     | `~/.emacs.d/branch-review-worktrees.eld` | Where the recent-worktree list is stored                      |

## How it works (and what it deliberately doesn't do)

`branch-review` keeps your real file buffers as the editing surface. The diff is
computed against `merge-base(base, HEAD)` using Git's on-disk view (committed +
staged + unstaged saved changes), so review data refreshes after you save. It
does **not** build synthetic per-file buffers or snapshot unsaved buffers.

Because it leans on Magit and `diff-hl`, several fiddly things come for free:
hunk parsing, rename/binary handling, and surviving `revert-buffer` /
auto-revert. Deleted-file contents are read inline in the Magit overview rather
than in a separate buffer, and there is no global marked/inline toggle — marks
are always on, with `diff-hl-show-hunk` for an on-demand inline view.

See [`SPEC.md`](SPEC.md) for the original design notes.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
