# branch-review.el spec

## Goal

`branch-review.el` provides an Emacs package for reviewing the changes on the
current branch/worktree against its merge base with a base branch. The primary
workflow is reading and navigating branch changes in full file buffers, similar
in spirit to a GitHub pull request review, without comment or approval tracking
in version 1.

## Package names

- Package/file: `branch-review.el`
- Feature: `branch-review`
- Overview major mode: `branch-review-overview-mode`
- File minor mode: `branch-review-file-mode`

## Version 1 scope

V1 focuses on review navigation only:

- Show changed files for the current repository/worktree.
- Open changed files as full file buffers.
- Mark and navigate changed hunks inside those full file buffers.
- Support a global display toggle between marked-result view and inline diff
  view.
- Keep review sessions in memory only.

V1 does not include:

- Comments or notes.
- Viewed-file state.
- Approval/request-changes state.
- Persisted review state across Emacs restarts.
- Multiple sessions for the same repository/worktree.
- Untracked file review.

## Session model

There can be one active review session per Git repository/worktree.

A session records:

- Repository root/worktree root.
- Base branch.
- Merge base commit.
- Changed-file list.
- Per-file hunk/range data.
- Display mode.
- Buffers touched by the session so overlays and modes can be cleaned up.

Sessions are in-memory only.

Ending a session closes/buries the overview buffer, disables
`branch-review-file-mode` in buffers touched by that session, and removes review
overlays. File buffers remain open and return to their normal modes.

## Base detection

The common path is reviewing the current branch against the merge base with the
default remote branch.

Default base branch detection should try, in order:

1. `origin/main`
2. `origin/master`
3. The remote HEAD default branch, if available

The merge base is computed between the selected base branch and `HEAD`.

The main command should support an override:

- Plain invocation uses automatic base detection.
- Prefix invocation prompts for a base branch.
- An additional explicit command may also prompt for the base branch.

## Diff contents

The review compares:

```text
merge-base(base, HEAD) -> current working tree state
```

This means committed branch changes, staged changes, and unstaged saved
working-tree changes are included.

Untracked files are ignored.

V1 should use Git's on-disk view. It should not force-save buffers and should
not build temporary snapshots of unsaved live buffer contents. Review data should
refresh after saves for files in an active reviewed repo.

## Refresh behavior

`branch-review-refresh` recomputes the changed-file list and hunk data.

Refresh should happen automatically after saving a tracked file in a reviewed
repo. It should update the overview and overlays while keeping point/window
selection as stable as practical.

If a file's diff disappears after refresh, remove it from the overview
immediately.

## Git and Magit dependency

The package may depend on Magit. Magit should be used wherever it simplifies Git
operations, repository detection, branch selection, faces, or diff-related
behavior.

Use Magit faces for status and diff highlighting where appropriate, falling back
to standard Emacs faces if needed.

## Overview buffer

The overview is a dedicated buffer using `branch-review-overview-mode`.

It displays a flat list of changed files, sorted alphabetically by path.

Each row should be Magit-like:

- Compact status marker, following Magit's style where practical.
- Current path.
- For renamed files, show the old path as additional context.
- Line counts from Git `--numstat` style additions/deletions.
- Binary files display `-`/`-` for line counts.

Supported file statuses:

- Modified
- Added
- Deleted
- Renamed
- Binary

Deleted and binary files should be visually marked as such in the overview.

The overview should include a small header or mode-line status with useful
session context:

- Repo/worktree
- Base branch
- Merge base
- Current file index
- Current hunk index
- Current display mode

The overview should not override normal navigation keys. Moving point onto a
file row should automatically open that file after a small delay.

Customizable behavior:

- Disable overview auto-open.
- Use the same window instead of another window when opening from the overview.

`RET` explicitly opens the selected file. Explicit opening should work for files
that are not auto-opened, such as deleted and binary files.

## Window behavior

Starting or reopening review should create a dedicated overview + file layout:

- Overview buffer in one window.
- Current/selected file in another window by default.

The overview drives file opening. Moving point through the overview opens the
selected file in the file window after a small delay, similar to the way an
occur-style overview can drive navigation.

Ending review does not restore the previous window configuration. It closes or
buries the overview and cleans up review modes/overlays, while leaving file
buffers open.

## File buffers

Normal changed files should be visited as real file buffers, not synthetic
buffers. `branch-review-file-mode` is enabled in those buffers while the session
is active.

Editing should be allowed in reviewed file buffers.

The package should support two display modes.

### Marked-result mode

This is the default display mode.

The buffer shows the current file contents normally. Changed current-side line
ranges are highlighted with overlays. Deletion-only hunks are represented by a
marker at the line immediately after the deletion point.

### Inline diff mode

The buffer still visits the real file and remains editable.

Removed lines are shown as read-only overlay text before the corresponding
current-side hunk. Added/current changed lines are highlighted in the real
buffer.

This mode makes deleted content visible while preserving the real file buffer as
the editing surface.

## Hunk data and navigation

Hunk data should be computed from a zero-context diff, for example:

```sh
git diff --unified=0 <merge-base>
```

The exact command can be adapted as needed to include staged and unstaged saved
working-tree changes, but navigation should be based on changed ranges rather
than context lines.

Navigation targets:

- Modified/added hunks: first changed current-side line.
- Deletion-only hunks: line immediately after the deletion point in the branch
  version.

Next/previous hunk navigation moves across file boundaries. When crossing a file
boundary it updates both the file buffer and the overview selection.

Next/previous changed-file navigation also updates both panes.

## Special file handling

### Added files

Added files open as normal real file buffers. All added lines are changed lines
for marking/navigation purposes.

### Deleted files

Deleted files should not auto-open from overview point movement.

Explicit opening with `RET` opens a synthetic read-only buffer named like:

```text
branch-review:<path>
```

The buffer shows the base-side contents so the reviewer can read what was
deleted.

### Renamed files

Renamed files are listed under the new path. The overview also shows the old
path.

Opening a renamed file visits the new path's real file. Removed old-side content
is visible through inline removed overlays/hunks where applicable.

### Binary files

Binary files should not auto-open from overview point movement.

Explicit opening should let Emacs handle the file as it normally would where
possible, with useful metadata/diff fallback if direct opening is not practical.

## Commands

Main commands:

- `branch-review`: Start review for the current repo/worktree, or reopen the
  overview if a session already exists. With prefix arg, prompt for base branch.
- `branch-review-with-base`: Start/restart review and prompt for base branch.
- `branch-review-overview`: Reopen the overview for the current repo/worktree,
  or start review if no session exists.
- `branch-review-quit`: End the current repo/worktree review session.
- `branch-review-toggle-display`: Toggle marked-result/inline-diff display.
- `branch-review-next-hunk`: Move to the next hunk across files.
- `branch-review-previous-hunk`: Move to the previous hunk across files.
- `branch-review-next-file`: Move to the next changed file.
- `branch-review-previous-file`: Move to the previous changed file.
- `branch-review-refresh`: Recompute file/hunk data and refresh visible
  overlays/overview.

Default global bindings are installed automatically:

| Key | Command |
| --- | --- |
| `C-c r r` | `branch-review` / reopen overview |
| `C-c r q` | `branch-review-quit` |
| `C-c r t` | `branch-review-toggle-display` |
| `C-c r n` | `branch-review-next-hunk` |
| `C-c r p` | `branch-review-previous-hunk` |
| `C-c r f` | `branch-review-next-file` |
| `C-c r b` | `branch-review-previous-file` |

Although `C-c <letter>` is normally reserved for users, this package is
currently private/personal, so v1 installs these bindings by default.

## Customization variables

Likely v1 custom variables:

- `branch-review-base-branch-fallbacks`
  - Default: `("origin/main" "origin/master")`, followed by remote HEAD lookup.
- `branch-review-default-display-mode`
  - Default: marked-result mode.
- `branch-review-auto-open-delay`
  - Small delay before overview point movement opens a file.
- `branch-review-auto-open`
  - Default: enabled.
- `branch-review-open-same-window`
  - Default: disabled. When enabled, overview opening uses the same window.
- `branch-review-install-global-bindings`
  - Default: enabled.

## Implementation notes

Prefer simple, robust Git data sources:

- Use Magit for repo/worktree and branch operations where helpful.
- Use Git porcelain/plumbing output that is easy to parse reliably.
- Use `--numstat` or equivalent for per-file line counts.
- Use zero-context diff data for hunk locations.
- Avoid expensive parsing or buffer snapshot machinery in v1.

Overlay cleanup must be reliable:

- Track overlays per session/buffer.
- Remove overlays when toggling display modes, refreshing, or ending the
  session.
- Disable `branch-review-file-mode` for buffers touched by the ended session.

Refresh should be cheap enough to run after saves in active reviewed repos.
