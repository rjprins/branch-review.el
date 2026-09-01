;;; branch-review.el --- Occur-style branch review on magit + diff-hl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rutger Prins

;; Author: Rutger Prins <60062+rjprins@users.noreply.github.com>
;; Maintainer: Rutger Prins <60062+rjprins@users.noreply.github.com>
;; URL: https://github.com/rjprins/branch-review.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (magit "3.3") (diff-hl "1.9"))
;; Keywords: vc, tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A thin UX layer that turns Magit + diff-hl into a GitHub-PR-style
;; branch review, without reinventing diff parsing, overlay management
;; or rename/binary handling.
;;
;; Architecture (what is reused vs. what this package adds):
;;
;;   Overview / file+hunk list  ->  a `magit-diff' buffer produced by
;;     `magit-diff-range' on the merge-base.  Magit's ordered section
;;     tree IS the flat hunk list; n/p/M-n/M-p, folding and RET all work.
;;
;;   Marked-result mode         ->  `diff-hl' with a buffer-local reference
;;     revision set to the merge-base (`diff-hl-reference-revision').
;;     diff-hl already survives `revert-buffer'/auto-revert, parses hunks,
;;     and renders fringe/margin marks.
;;
;;   Inline diff (removed lines)->  `diff-hl-show-hunk' (on demand).
;;
;; What we add on top:
;;
;;   * Base detection + merge-base computation, fed to BOTH tools.
;;   * Occur-style "peek": moving point in the overview opens the file at
;;     point in another window after a short delay, without stealing focus,
;;     and skips deleted/binary files.
;;   * Cross-pane navigation: `branch-review-next-hunk' etc. drive the
;;     overview's section tree (crossing file boundaries) and re-peek, so
;;     both panes stay in sync even when invoked from the file buffer.
;;   * Reliable teardown: clear buffer-local review references, disable any
;;     diff-hl-mode we turned on, cancel timers, remove hooks, bury the overview.
;;
;; Intentional deltas from the original spec: there is no separate synthetic
;; buffer for deleted files (Magit shows the removed content inline in the
;; overview) and no global marked/inline toggle (always-on marks + on-demand
;; `diff-hl-show-hunk').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'face-remap)
(require 'magit)
(require 'diff-hl)
(require 'diff-hl-show-hunk)
(require 'hl-line)

(defgroup branch-review nil
  "GitHub-PR-style branch review built on Magit and diff-hl."
  :group 'tools
  :prefix "branch-review-")

(defcustom branch-review-base-branch-fallbacks '("origin/main" "origin/master")
  "Ordered base-branch candidates tried before the remote HEAD default."
  :type '(repeat string))

(defcustom branch-review-diff-args '("--stat")
  "Extra arguments passed to `magit-diff-range' for the overview.
`--stat' adds per-file line counts while keeping the navigable diff."
  :type '(repeat string))

(defcustom branch-review-auto-open t
  "When non-nil, moving point in the overview opens the file at point."
  :type 'boolean)

(defcustom branch-review-auto-open-delay 0.2
  "Idle delay, in seconds, before the overview auto-opens the file at point."
  :type 'number)

(defcustom branch-review-skip-binary t
  "When non-nil, never auto-open binary files from overview point movement."
  :type 'boolean)

(defcustom branch-review-highlight-current-line t
  "When non-nil, highlight the current line in the visited file buffer."
  :type 'boolean)

(defcustom branch-review-show-header-line t
  "When non-nil, show branch, worktree and base in the overview header line."
  :type 'boolean)

(defcustom branch-review-change-highlight 'line
  "How to mark changed lines in reviewed file buffers.
`line' tints the background of added and modified lines and draws an
overline where lines were removed, GitHub-style.  `marker' keeps
diff-hl's normal rendering (fringe or margin indicators)."
  :type '(choice (const line) (const marker)))

(defface branch-review-inserted-line
  '((((class color) (background light)) :background "#e6ffec" :extend t)
    (((class color) (background dark)) :background "#16311f" :extend t)
    (t :inherit diff-added))
  "Face for added lines in reviewed file buffers.")

(defface branch-review-changed-line
  '((((class color) (background light)) :background "#ddf4ff" :extend t)
    (((class color) (background dark)) :background "#12283c" :extend t)
    (t :inherit diff-changed))
  "Face for modified lines in reviewed file buffers.")

(defface branch-review-removed-line
  '((((class color) (background light)) :overline "#cf222e" :extend t)
    (((class color) (background dark)) :overline "#ff7b72" :extend t)
    (t :inherit diff-removed))
  "Face for the line just below removed lines in reviewed file buffers.
The removed content sat directly above the overline.")

(defface branch-review-current-line
  '((((class color) (background light)) :background "#fff8c5" :extend t)
    (((class color) (background dark)) :background "#3a331a" :extend t)
    (t :inherit hl-line))
  "Face for the current line in reviewed file buffers.
Remaps `hl-line' there while a review session is active.")

(cl-defstruct (branch-review-session (:constructor branch-review--make-session))
  root base merge-base overview touched enabled-diff-hl hl-line)

(defvar branch-review--sessions (make-hash-table :test 'equal)
  "Map of repository/worktree root -> `branch-review-session'.")

(defvar-local branch-review--session nil
  "The session this overview buffer belongs to.")
(defvar-local branch-review--peek-timer nil)
(defvar-local branch-review--last-peek-pos nil)
(defvar-local branch-review--hl-line-cookie nil
  "Face-remap cookie for `branch-review-current-line', or nil.")
(defvar-local branch-review--saved-highlight-function nil
  "Local `diff-hl-highlight-function' shadowed by the review, if any.
The symbol `branch-review--unset' means there was no local binding.")

;;;; Base detection

(defun branch-review--detect-base ()
  "Return a base branch using the fallback list, then remote HEAD, else nil."
  (or (seq-find #'magit-rev-verify branch-review-base-branch-fallbacks)
      (magit-git-string "symbolic-ref" "--quiet" "--short"
                        "refs/remotes/origin/HEAD")))

;;;; Section predicates / navigation

(defun branch-review--diff-file-p ()
  "Non-nil when point is on a real diff file section (not a diffstat row)."
  (and (magit-section-match 'file)
       (not (magit-section-match [file diffstat]))))

(defun branch-review--hunk-p ()
  "Non-nil when point is on a hunk section."
  (magit-section-match 'hunk))

(defun branch-review--step-to (pred forward)
  "Move to the next (FORWARD non-nil) or previous section matching PRED.
Return non-nil on success, leaving point unmoved on failure."
  (let ((orig (point)) (last (point)) hit)
    (while (and (not hit)
                (progn (ignore-errors
                         (if forward (magit-section-forward)
                           (magit-section-backward)))
                       (/= (point) last)))
      (setq last (point))
      (when (funcall pred) (setq hit t)))
    (unless hit (goto-char orig))
    hit))

(defun branch-review--goto-first-file ()
  "Put point on the first real diff file section in the overview."
  (goto-char (point-min))
  (or (branch-review--diff-file-p)
      (branch-review--step-to #'branch-review--diff-file-p t)))

;;;; Peeking (occur-style auto-open)

(defun branch-review--file-binary-p (section)
  "Non-nil when the diff file SECTION represents a binary file."
  (when section
    (save-excursion
      (goto-char (oref section start))
      (and (re-search-forward "^Binary files .+ differ\\|^GIT binary patch"
                              (oref section end) t)
           t))))

(defconst branch-review--tint-priority -60
  "Overlay priority for line tints.
Below hl-line's -50, so the current-line highlight stays visible.")

(defun branch-review--highlight-on-line (ovl type _shape)
  "Render a diff-hl change of TYPE as a whole-line highlight on OVL.
Used as `diff-hl-highlight-function' in reviewed file buffers when
`branch-review-change-highlight' is `line'."
  (move-overlay ovl (point) (line-beginning-position 2))
  (overlay-put ovl 'priority branch-review--tint-priority)
  (overlay-put ovl 'face (pcase type
                           ('insert 'branch-review-inserted-line)
                           ('delete 'branch-review-removed-line)
                           (_ 'branch-review-changed-line))))

(defun branch-review--ensure-diff-hl (buf session)
  "Make sure diff-hl is showing merge-base marks in BUF; record it on SESSION."
  (with-current-buffer buf
    (when session
      (setq-local diff-hl-reference-revision
                  (branch-review-session-merge-base session))
      (cl-pushnew buf (branch-review-session-touched session)))
    (unless (bound-and-true-p diff-hl-mode)
      (diff-hl-mode 1)
      (when session
        (cl-pushnew buf (branch-review-session-enabled-diff-hl session))))
    ;; After enabling the mode, so this wins over diff-hl-margin-mode's
    ;; own buffer-local value (which we save and restore on teardown).
    (when (and session (eq branch-review-change-highlight 'line)
               (bound-and-true-p diff-hl-mode)
               (not (eq diff-hl-highlight-function
                        #'branch-review--highlight-on-line)))
      (setq branch-review--saved-highlight-function
            (if (local-variable-p 'diff-hl-highlight-function)
                diff-hl-highlight-function
              'branch-review--unset))
      (setq-local diff-hl-highlight-function
                  #'branch-review--highlight-on-line))
    (when (bound-and-true-p diff-hl-mode)
      (diff-hl-update))))

(defun branch-review--display (buf pos overview)
  "Show BUF at POS in a window other than OVERVIEW's, without selecting it.
Return the window used."
  (let* ((ov-win (and (buffer-live-p overview) (get-buffer-window overview)))
         (win (or (get-buffer-window buf)
                  (seq-find (lambda (w) (not (eq w ov-win)))
                            (window-list nil 'no-minibuf))
                  (and ov-win (split-window ov-win nil 'right))
                  (selected-window))))
    (when (window-live-p win)
      (unless (eq (window-buffer win) buf)
        (set-window-buffer win buf))
      (when pos
        (with-selected-window win
          (unless (<= (point-min) pos (point-max)) (widen))
          (goto-char pos))))
    win))

(defun branch-review--mark-line (buf win session)
  "Highlight the current line in BUF shown in WIN via `hl-line'.
Enable `hl-line-mode' in BUF if needed (recording it on SESSION for
cleanup), refresh the highlight at point, and recenter if off-screen."
  (when (and branch-review-highlight-current-line
             (buffer-live-p buf) (window-live-p win))
    (with-current-buffer buf
      (unless (bound-and-true-p hl-line-mode)
        (setq-local hl-line-sticky-flag t)
        (hl-line-mode 1)
        (when session
          (cl-pushnew buf (branch-review-session-hl-line session))))
      (when (and session (not branch-review--hl-line-cookie))
        (setq branch-review--hl-line-cookie
              (face-remap-add-relative 'hl-line 'branch-review-current-line))))
    (with-selected-window win
      (when (fboundp 'hl-line-highlight)
        (hl-line-highlight))
      (unless (pos-visible-in-window-p (point) win)
        (recenter)))))

(defun branch-review--peek (overview)
  "Open the worktree file at point in OVERVIEW in another window, no focus steal."
  (when (and (buffer-live-p overview)
             (buffer-local-value 'branch-review--session overview))
    (with-current-buffer overview
      (setq branch-review--last-peek-pos (point))
      (when (derived-mode-p 'magit-diff-mode)
        (let ((file (ignore-errors (magit-diff--file))))
          (when file
            (let ((full (expand-file-name file default-directory))
                  (section (ignore-errors (magit-diff--file-section))))
              (when (and (file-regular-p full)            ; skip deleted/missing
                         (not (and branch-review-skip-binary
                                   (branch-review--file-binary-p section))))
                (pcase-let ((`(,buf ,pos)
                             (ignore-errors (magit-diff-visit-file--noselect t))))
                  (when (buffer-live-p buf)
                    (branch-review--ensure-diff-hl buf branch-review--session)
                    (let ((win (branch-review--display buf pos overview)))
                      (branch-review--mark-line buf win branch-review--session))))))))))))

(defun branch-review--schedule-peek ()
  "Overview `post-command-hook': debounce an auto-open of the file at point."
  (when (and branch-review-auto-open
             branch-review--session
             (not (eql (point) branch-review--last-peek-pos)))
    (when (timerp branch-review--peek-timer)
      (cancel-timer branch-review--peek-timer))
    (let ((buf (current-buffer)))
      (setq branch-review--peek-timer
            (run-with-idle-timer branch-review-auto-open-delay nil
                                 #'branch-review--peek buf)))))

;;;; Visiting from the overview

(defun branch-review-visit-file ()
  "Visit the file at point in the file window and select it.
Unlike Magit's `RET', this keeps the overview visible and reuses the
window the overview opens files into, instead of replacing the overview."
  (interactive)
  (let* ((file (ignore-errors (magit-diff--file)))
         (res (and file (ignore-errors (magit-diff-visit-file--noselect t)))))
    (cond
     ((and res (buffer-live-p (car res)))
      (pcase-let ((`(,buf ,pos) res))
        (branch-review--ensure-diff-hl buf branch-review--session)
        (let ((win (branch-review--display buf pos (current-buffer))))
          (branch-review--mark-line buf win branch-review--session)
          (when (window-live-p win) (select-window win)))))
     (file (magit-diff-visit-file-other-window))
     (t (call-interactively #'magit-visit-thing)))))

(defvar branch-review-overview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'branch-review-visit-file)
    map)
  "Keymap layered on the overview so `RET' opens into the file window.")

(define-minor-mode branch-review-overview-mode
  "Minor mode active in a branch-review overview buffer.
Rebinds `RET' to open the file in the other window and select it,
instead of replacing the overview."
  :lighter " BR"
  :keymap branch-review-overview-mode-map)

;;;; Session lifecycle

(defun branch-review--apply-header (session)
  "Show SESSION's branch, worktree and base in the overview header line."
  (let ((ov (branch-review-session-overview session)))
    (when (and branch-review-show-header-line (buffer-live-p ov))
      (let* ((root (branch-review-session-root session))
             (branch (let ((default-directory root))
                       (or (magit-get-current-branch)
                           (magit-rev-abbrev "HEAD")))))
        (with-current-buffer ov
          (setq header-line-format
                (list " "
                      (propertize (or branch "?") 'face 'magit-branch-local)
                      "  "
                      (abbreviate-file-name root)
                      "  "
                      (propertize
                       (concat "vs " (branch-review-session-base session))
                       'face 'shadow))))))))

(defun branch-review--overview ()
  "Return the live overview buffer for the current repo, or nil."
  (let* ((root (magit-toplevel))
         (s (and root (gethash root branch-review--sessions))))
    (and s (buffer-live-p (branch-review-session-overview s))
         (branch-review-session-overview s))))

(defun branch-review--start (root prompt-base)
  "Start a fresh review in ROOT.  Prompt for the base when PROMPT-BASE."
  (let* ((base (if prompt-base
                   (magit-read-branch-or-commit "Review against base")
                 (or (branch-review--detect-base)
                     (magit-read-branch-or-commit "Review against base"))))
         (mb (or (magit-git-string "merge-base" base "HEAD")
                 (user-error "No merge base between %s and HEAD" base))))
    ;; A single rev means "working tree relative to that rev", i.e. committed +
    ;; staged + unstaged changes since the merge-base.
    (magit-diff-range mb branch-review-diff-args)
    (let* ((overview (magit-get-mode-buffer 'magit-diff-mode))
           (session (branch-review--make-session
                     :root root :base base :merge-base mb
                     :overview overview :touched nil)))
      (puthash root session branch-review--sessions)
      (branch-review--remember-worktree root)
      (when (buffer-live-p overview)
        (with-current-buffer overview
          (setq branch-review--session session
                branch-review--last-peek-pos nil)
          (add-hook 'post-command-hook #'branch-review--schedule-peek nil t)
          (add-hook 'kill-buffer-hook #'branch-review--on-overview-kill nil t)
          (branch-review-overview-mode 1)
          (branch-review--goto-first-file))
        (branch-review--apply-header session)
        (when branch-review-auto-open
          (branch-review--peek overview)))
      (message "Branch review: %s (merge-base %s)" base (magit-rev-abbrev mb))
      session)))

(defun branch-review--teardown (session &optional keep-overview)
  "Clear review-local diff-hl state and disable modes/hooks/timers for SESSION.
Unless KEEP-OVERVIEW, also bury the overview window."
  (dolist (buf (branch-review-session-touched session))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (kill-local-variable 'diff-hl-reference-revision)
        (when branch-review--saved-highlight-function
          (if (eq branch-review--saved-highlight-function 'branch-review--unset)
              (kill-local-variable 'diff-hl-highlight-function)
            (setq-local diff-hl-highlight-function
                        branch-review--saved-highlight-function))
          (kill-local-variable 'branch-review--saved-highlight-function))
        (when branch-review--hl-line-cookie
          (face-remap-remove-relative branch-review--hl-line-cookie)
          (kill-local-variable 'branch-review--hl-line-cookie))
        (when (bound-and-true-p diff-hl-mode) (diff-hl-update)))))
  (dolist (buf (branch-review-session-enabled-diff-hl session))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (bound-and-true-p diff-hl-mode) (diff-hl-mode -1)))))
  (dolist (buf (branch-review-session-hl-line session))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (bound-and-true-p hl-line-mode) (hl-line-mode -1)))))
  (let ((ov (branch-review-session-overview session)))
    (when (buffer-live-p ov)
      (with-current-buffer ov
        (when (timerp branch-review--peek-timer)
          (cancel-timer branch-review--peek-timer))
        (remove-hook 'post-command-hook #'branch-review--schedule-peek t)
        (when (bound-and-true-p branch-review-overview-mode)
          (branch-review-overview-mode -1))
        (kill-local-variable 'header-line-format)
        (setq branch-review--session nil))
      (unless keep-overview
        (quit-windows-on ov))))
  (remhash (branch-review-session-root session) branch-review--sessions))

(defun branch-review--on-overview-kill ()
  "`kill-buffer-hook' for the overview: clean up if the user kills it directly."
  (when branch-review--session
    (branch-review--teardown branch-review--session t)))

;;;; Refresh after save

(defun branch-review--maybe-refresh-after-save ()
  "Refresh the overview when a file under a reviewed root is saved."
  (when (and buffer-file-name (> (hash-table-count branch-review--sessions) 0))
    (let ((file (expand-file-name buffer-file-name)))
      (maphash
       (lambda (root session)
         (when (string-prefix-p (file-name-as-directory root) file)
           (let ((ov (branch-review-session-overview session)))
             (when (buffer-live-p ov)
               (with-current-buffer ov (magit-refresh-buffer))))))
       branch-review--sessions))))

(add-hook 'after-save-hook #'branch-review--maybe-refresh-after-save)

;;;; Known worktrees

(defcustom branch-review-known-worktrees-file
  (locate-user-emacs-file "branch-review-worktrees.eld")
  "File where the MRU list of reviewed worktrees is stored."
  :type 'file)

(defcustom branch-review-open-include-projectile t
  "When non-nil, also offer git projects from `projectile-known-projects'."
  :type 'boolean)

(defcustom branch-review-open-sort 'commit-date
  "How to order worktree candidates in `branch-review-open'.
`commit-date' lists the most recent HEAD commit first, `mru' lists
recently reviewed/seen worktrees first, `alpha' sorts by path."
  :type '(choice (const commit-date) (const mru) (const alpha)))

(defvar branch-review--known-worktrees nil
  "MRU list of worktree roots, most recent first.")
(defvar branch-review--known-worktrees-loaded nil)

(defun branch-review--load-known-worktrees ()
  "Load the MRU worktree list from disk once."
  (unless branch-review--known-worktrees-loaded
    (setq branch-review--known-worktrees-loaded t)
    (when (file-readable-p branch-review-known-worktrees-file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents branch-review-known-worktrees-file)
          (setq branch-review--known-worktrees (read (current-buffer))))))))

(defun branch-review--save-known-worktrees ()
  "Persist the MRU worktree list to disk."
  (ignore-errors
    (with-temp-file branch-review-known-worktrees-file
      (let ((print-length nil) (print-level nil))
        (prin1 branch-review--known-worktrees (current-buffer))))))

(defun branch-review--remember-worktree (root)
  "Record ROOT at the front of the MRU worktree list and persist it."
  (when root
    (branch-review--load-known-worktrees)
    (setq root (file-name-as-directory (expand-file-name root)))
    (setq branch-review--known-worktrees
          (cons root (delete root branch-review--known-worktrees)))
    (when (> (length branch-review--known-worktrees) 50)
      (setcdr (nthcdr 49 branch-review--known-worktrees) nil))
    (branch-review--save-known-worktrees)))

(defun branch-review--open-repo-roots ()
  "Return worktree roots of currently open file buffers."
  (let ((dirs (make-hash-table :test 'equal)) roots)
    (dolist (b (buffer-list))
      (when (buffer-local-value 'buffer-file-name b)
        (puthash (buffer-local-value 'default-directory b) t dirs)))
    (maphash (lambda (d _)
               (let ((top (ignore-errors (magit-toplevel d))))
                 (when top (push top roots))))
             dirs)
    roots))

(defun branch-review--seed-roots ()
  "Return candidate repo roots from the MRU, open buffers and projectile."
  (let (out)
    (dolist (r (append
                branch-review--known-worktrees
                (branch-review--open-repo-roots)
                (and branch-review-open-include-projectile
                     (boundp 'projectile-known-projects)
                     (seq-filter
                      (lambda (r) (file-exists-p (expand-file-name ".git" r)))
                      (mapcar #'expand-file-name
                              (symbol-value 'projectile-known-projects))))))
      (when r (push (file-name-as-directory (expand-file-name r)) out)))
    (nreverse out)))

(defun branch-review--commit-times (shas)
  "Return committer Unix timestamps for SHAS (a list), in order.
Nil or unresolvable shas map to 0."
  (let ((table (make-hash-table :test 'equal))
        (real (delete-dups (delq nil (copy-sequence shas)))))
    (when real
      ;; Key by hash: `git show' dedupes revs on the same commit, so
      ;; positional sha<->line pairing would misassign times.
      (dolist (line (ignore-errors
                      (apply #'magit-git-lines "show" "-s" "--format=%H %ct"
                             real)))
        (when (string-match "\\`\\([0-9a-f]+\\) \\([0-9]+\\)\\'" line)
          (puthash (match-string 1 line)
                   (string-to-number (match-string 2 line))
                   table))))
    (mapcar (lambda (sha) (or (and sha (gethash sha table)) 0)) shas)))

(defun branch-review--open-candidates ()
  "Return (ROOT BRANCH . TS) review candidates.
Expands every seed repo to all of its worktrees via `magit-list-worktrees'
and sorts them per `branch-review-open-sort'."
  (branch-review--load-known-worktrees)
  (let ((covered (make-hash-table :test 'equal))
        (entries '()))
    (dolist (seed (branch-review--seed-roots))
      (when (and (file-directory-p seed) (not (gethash seed covered)))
        (let* ((default-directory seed)
               (wts (ignore-errors (magit-list-worktrees))))
          (when wts
            (let ((roots (mapcar (lambda (w)
                                   (file-name-as-directory
                                    (expand-file-name (nth 0 w))))
                                 wts))
                  (tss (branch-review--commit-times
                        (mapcar (lambda (w) (nth 1 w)) wts))))
              (cl-loop for w in wts for root in roots for ts in tss do
                       (puthash root t covered)
                       (when (and (not (nth 3 w))            ; skip bare
                                  (file-directory-p root)
                                  (not (assoc root entries)))
                         (push (cons root (cons (nth 2 w) ts)) entries))))))))
    (setq entries (nreverse entries))
    (pcase branch-review-open-sort
      ('commit-date (sort entries (lambda (a b) (> (cddr a) (cddr b)))))
      ('alpha (sort entries (lambda (a b) (string< (car a) (car b)))))
      (_ entries))))

(defun branch-review--relative-age (ts)
  "Return a compact relative age string for Unix time TS, or nil."
  (when (and (numberp ts) (> ts 0))
    (let ((secs (max 0 (- (float-time) ts))))
      (cond ((< secs 3600)    (format "%dm" (floor secs 60)))
            ((< secs 86400)   (format "%dh" (floor secs 3600)))
            ((< secs 2592000) (format "%dd" (floor secs 86400)))
            (t                (format "%dmo" (floor secs 2592000)))))))

(defun branch-review--read-worktree ()
  "Read a worktree root from recent/seen worktrees and their siblings."
  (let ((entries (branch-review--open-candidates)))
    (unless entries
      (user-error "No known worktrees yet -- start a review from inside a repo"))
    (let* ((disp->entry (mapcar (lambda (e) (cons (abbreviate-file-name (car e)) e))
                                entries))
           (table
            (lambda (string pred action)
              (if (eq action 'metadata)
                  `(metadata
                    (display-sort-function . identity)
                    (cycle-sort-function . identity)
                    (annotation-function
                     . ,(lambda (cand)
                          (let ((e (cdr (assoc cand disp->entry))))
                            (when e
                              (let ((branch (cadr e))
                                    (age (branch-review--relative-age (cddr e))))
                                (concat
                                 (and branch
                                      (concat "  " (propertize
                                                    branch 'face 'magit-branch-local)))
                                 (and age
                                      (concat "  " (propertize age 'face 'shadow))))))))))
                (complete-with-action action (mapcar #'car disp->entry)
                                      string pred))))
           (choice (completing-read "Review worktree: " table nil t))
           (e (cdr (assoc choice disp->entry))))
      (if e (car e) (file-name-as-directory (expand-file-name choice))))))

;;;; Commands

(defun branch-review--open-root (root prompt-base)
  "Open a review for ROOT, reopening an existing session unless PROMPT-BASE."
  (setq root (file-name-as-directory (expand-file-name root)))
  (let ((existing (gethash root branch-review--sessions)))
    (if (and existing (not prompt-base)
             (buffer-live-p (branch-review-session-overview existing)))
        (progn
          (pop-to-buffer (branch-review-session-overview existing)))
      (when existing (branch-review--teardown existing))
      (let ((default-directory root))
        (branch-review--start root prompt-base)))))

;;;###autoload
(defun branch-review (&optional prompt-base)
  "Start a branch review for the current repo, or reopen its overview.
With prefix arg PROMPT-BASE, (re)start and prompt for the base branch."
  (interactive "P")
  (branch-review--open-root
   (or (magit-toplevel) (user-error "Not inside a Git repository"))
   prompt-base))

;;;###autoload
(defun branch-review-open (&optional prompt-base)
  "Pick a recent/seen worktree and open a branch review there.
Candidates come from previously reviewed worktrees, repos you have open,
and (optionally) `projectile-known-projects'.  With prefix arg
PROMPT-BASE, prompt for the base branch."
  (interactive "P")
  (branch-review--open-root (branch-review--read-worktree) prompt-base))

;;;###autoload
(defun branch-review-with-base ()
  "Start or restart a branch review, prompting for the base branch."
  (interactive)
  (branch-review t))

;;;###autoload
(defun branch-review-overview ()
  "Reopen the overview for the current repo, or start a review."
  (interactive)
  (if-let* ((ov (branch-review--overview)))
      (pop-to-buffer ov)
    (branch-review)))

(defun branch-review-quit ()
  "End the branch review session for the current repo/worktree."
  (interactive)
  (let* ((root (magit-toplevel))
         (session (and root (gethash root branch-review--sessions))))
    (unless session (user-error "No active branch review in this repository"))
    (branch-review--teardown session)
    (message "Branch review ended")))

(defun branch-review-refresh ()
  "Recompute the overview and refresh diff-hl marks for this session."
  (interactive)
  (let* ((root (magit-toplevel))
         (session (and root (gethash root branch-review--sessions))))
    (unless session (user-error "No active branch review in this repository"))
    (let ((ov (branch-review-session-overview session)))
      (when (buffer-live-p ov)
        (with-current-buffer ov (magit-refresh-buffer))))
    (dolist (buf (branch-review-session-touched session))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (bound-and-true-p diff-hl-mode) (diff-hl-update)))))))

(defun branch-review--navigate (pred n)
  "Move the overview by N sections matching PRED, then re-peek."
  (let ((ov (or (branch-review--overview)
                (user-error "No active branch review in this repository"))))
    (with-current-buffer ov
      (let ((ok t))
        (dotimes (_ (abs n))
          (when ok (setq ok (branch-review--step-to pred (> n 0)))))))
    (when-let* ((win (get-buffer-window ov)))
      (set-window-point win (with-current-buffer ov (point))))
    (branch-review--peek ov)))

(defun branch-review-next-hunk ()
  "Select the next hunk across files and open it."
  (interactive)
  (branch-review--navigate #'branch-review--hunk-p 1))

(defun branch-review-previous-hunk ()
  "Select the previous hunk across files and open it."
  (interactive)
  (branch-review--navigate #'branch-review--hunk-p -1))

(defun branch-review-next-file ()
  "Select the next changed file and open it."
  (interactive)
  (branch-review--navigate #'branch-review--diff-file-p 1))

(defun branch-review-previous-file ()
  "Select the previous changed file and open it."
  (interactive)
  (branch-review--navigate #'branch-review--diff-file-p -1))

;;;; Worktree list buffer

(defun branch-review--worktree-list-column-width (rows col fallback)
  "Return the width of column COL over ROWS, at least FALLBACK."
  (max fallback
       (or (cl-loop for r in rows
                    maximize (string-width (aref (cadr r) col)))
           0)))

(defun branch-review--worktree-list-entries ()
  "Compute `tabulated-list-entries' for the worktrees of this repo.
Also fit the Branch and Age column widths to the current rows."
  (let* ((current (file-name-as-directory (expand-file-name (magit-toplevel))))
         (wts (seq-remove (lambda (w) (nth 3 w)) (magit-list-worktrees)))
         (ages (branch-review--commit-times (mapcar (lambda (w) (nth 1 w)) wts)))
         (rows
          (cl-loop
           for w in wts for ts in ages
           for root = (file-name-as-directory (expand-file-name (nth 0 w)))
           for session = (gethash root branch-review--sessions)
           collect
           (list root
                 (vector
                  (if (and session
                           (buffer-live-p (branch-review-session-overview session)))
                      (propertize "•" 'face 'success)
                    " ")
                  (if-let* ((branch (nth 2 w)))
                      (propertize branch 'face (if (equal root current)
                                                   'magit-branch-current
                                                 'magit-branch-local))
                    (propertize (or (magit-rev-abbrev (nth 1 w)) "?")
                                'face 'magit-hash))
                  (propertize (or (branch-review--relative-age ts) "")
                              'face 'shadow)
                  (abbreviate-file-name root))))))
    (setq tabulated-list-format
          (vector
           '("" 1 nil)
           (list "Branch"
                 (branch-review--worktree-list-column-width rows 1 6) t)
           (list "Age"
                 (branch-review--worktree-list-column-width rows 2 3)
                 nil :right-align t)
           '("Path" 0 t)))
    (tabulated-list-init-header)
    rows))

(defun branch-review--worktree-list-goto (root)
  "Move point to the row for ROOT, or to the first row."
  (goto-char (point-min))
  (while (and (not (eobp))
              (not (equal (tabulated-list-get-id) root)))
    (forward-line 1))
  (when (eobp) (goto-char (point-min))))

(defun branch-review-worktree-list-review (&optional prompt-base)
  "Start (or reopen) a branch review on the worktree at point.
With prefix arg PROMPT-BASE, prompt for the base branch."
  (interactive "P")
  (let ((root (or (tabulated-list-get-id)
                  (user-error "No worktree on this line")))
        (list-buf (current-buffer)))
    (unless (file-directory-p root)
      (user-error "Worktree directory %s is missing" root))
    (branch-review--open-root root prompt-base)
    ;; Refresh the review-active dot without moving point.
    (when (buffer-live-p list-buf)
      (with-current-buffer list-buf (revert-buffer)))))

(defvar branch-review-worktree-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'branch-review-worktree-list-review)
    map)
  "Keymap for `branch-review-worktree-list-mode'.")

(define-derived-mode branch-review-worktree-list-mode tabulated-list-mode
  "BR-Worktrees"
  "Major mode listing every worktree of a Git repository.
A dot marks worktrees with an active review session.
\\<branch-review-worktree-list-mode-map>Type \
\\[branch-review-worktree-list-review] to review the worktree at point."
  ;; Placeholder; the entries function refits the widths on every print.
  (setq tabulated-list-format
        [("" 1 nil) ("Branch" 35 t) ("Age" 3 nil :right-align t) ("Path" 0 t)])
  (setq tabulated-list-entries #'branch-review--worktree-list-entries)
  (tabulated-list-init-header))

;;;###autoload
(defun branch-review-worktrees ()
  "List all worktrees of the current repository in a buffer.
`RET' on a worktree starts (or reopens) a branch review for it;
`g' refreshes the list."
  (interactive)
  (let* ((root (or (magit-toplevel) (user-error "Not inside a Git repository")))
         (default-directory root)
         (main (caar (magit-list-worktrees)))
         (buf (get-buffer-create
               (format "*branch-review-worktrees: %s*"
                       (file-name-nondirectory
                        (directory-file-name (or main root)))))))
    (with-current-buffer buf
      (setq default-directory root)
      (branch-review-worktree-list-mode)
      (tabulated-list-print)
      (branch-review--worktree-list-goto
       (file-name-as-directory (expand-file-name root))))
    (pop-to-buffer buf)))

;;;; Keymap

(defvar branch-review-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "r" #'branch-review)
    (define-key map "w" #'branch-review-with-base)
    (define-key map "o" #'branch-review-open)
    (define-key map "O" #'branch-review-overview)
    (define-key map "l" #'branch-review-worktrees)
    (define-key map "q" #'branch-review-quit)
    (define-key map "g" #'branch-review-refresh)
    (define-key map "t" #'diff-hl-show-hunk)        ; on-demand inline view
    (define-key map "n" #'branch-review-next-hunk)
    (define-key map "p" #'branch-review-previous-hunk)
    (define-key map "f" #'branch-review-next-file)
    (define-key map "b" #'branch-review-previous-file)
    map)
  "Prefix keymap for `branch-review' commands.")
(fset 'branch-review-command-map branch-review-command-map)

;; This package does not grab any keys.  Bind the command map yourself, e.g.:
;;   (keymap-global-set "C-c r" 'branch-review-command-map)

(provide 'branch-review)
;;; branch-review.el ends here
