;;; outdated.el — check & update pinned package refs in Backpack gears  -*- lexical-binding: t; -*-
;;
;; Dev tool: reports which packages are behind upstream and can update
;; their pinned :ref commits in-place.
;;
;; Usage: ./dev/outdated [--update] [--pouch <p>] [--gear <g>]
;;
;; Prerequisites: run `bin/backpack ensure` first so local clones exist.

(require 'cl-lib)

;; -- Configuration -----------------------------------------------------------

(defvar outdated--repo-root nil
  "Backpack repository root.  Set by shell wrapper before loading this file.")

(defvar outdated--update-p nil
  "When non-nil, prompt to update each outdated package.")

(defvar outdated--pouch-filter nil
  "When non-nil, only check gears in this pouch.")

(defvar outdated--gear-filter nil
  "When non-nil, only check this specific gear name.")

;; -- Path helpers ------------------------------------------------------------

(defun outdated--repos-dir ()
  "Return the elpaca repos directory where git clones live."
  (expand-file-name ".cache/nonessentials/elpaca/repos/" outdated--repo-root))

(defun outdated--gears-dir ()
  "Return the gears directory."
  (expand-file-name "lisp/gears/" outdated--repo-root))

;; -- Plist helpers -----------------------------------------------------------

(defun outdated--plist-get (key plist)
  "Get value for KEY in PLIST (a flat list of :keyword val ...)."
  (catch 'done
    (let ((rest plist))
      (while rest
        (when (eq (car rest) key)
          (throw 'done (if (cdr rest) (cadr rest) nil)))
        (if (keywordp (car rest))
            (if (and (cdr rest) (consp (cadr rest)))
                (setq rest (cddr rest))
              (setq rest (cddr rest)))
          (setq rest (cdr rest))))
      nil)))

(defun outdated--plist-member-p (key plist)
  "Return tail of PLIST starting at KEY if found, nil otherwise."
  (catch 'done
    (let ((rest plist))
      (while rest
        (when (eq (car rest) key)
          (throw 'done rest))
        (if (keywordp (car rest))
            (if (and (cdr rest) (consp (cadr rest)))
                (setq rest (cddr rest))
              (setq rest (cddr rest)))
          (setq rest (cdr rest))))
      nil)))

;; -- Parsing :ensure forms from gear files ----------------------------------

(defun outdated--ensure-form-p (sexp)
  "Return non-nil if SEXP looks like an :ensure form we should process."
  (and (consp sexp) (symbolp (car sexp)) (not (eq (car sexp) 'nil))))

(defun outdated--parse-leaf-block (sexp filepath)
  "Parse a single leaf SEXP from FILEPATH, return list of parsed plists."
  (let* ((leaf-pkg (cadr sexp))
         (tail (cddr sexp))
         (ensure-tail (outdated--plist-member-p :ensure tail))
         (results nil))
    (when ensure-tail
      (let ((ensure-val (cadr ensure-tail)))
        (when (outdated--ensure-form-p ensure-val)
          (let ((pkg (car ensure-val))
                (ref (outdated--plist-get :ref ensure-val)))
            (when ref
              (push (list :package pkg :ref ref
                          :leaf-pkg leaf-pkg :file filepath)
                    results))))))
    (nreverse results)))

(defun outdated--parse-one-file (filepath)
  "Parse FILEPATH, return list of (:package :ref :leaf-pkg :file) plists."
  (let ((entries nil))
    (with-temp-buffer
      (insert-file-contents filepath)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((sexp (read (current-buffer))))
              (when (and (consp sexp) (eq (car sexp) 'leaf))
                (let ((parsed (outdated--parse-leaf-block sexp filepath)))
                  (dolist (e parsed)
                    (push e entries))))))
        (end-of-file nil)))
    (nreverse entries)))

;; -- Git helpers -------------------------------------------------------------

(defun outdated--shell-cmd (cmd)
  "Run CMD via shell, return trimmed stdout or nil on failure."
  (with-temp-buffer
    (let ((exit (call-process shell-file-name nil '(t nil) nil
                              shell-command-switch cmd)))
      (when (zerop exit)
        (string-trim (buffer-string))))))

(defun outdated--pkg-dir (pkg)
  "Return the local clone directory for package PKG (symbol or string)."
  (let ((name (if (symbolp pkg) (symbol-name pkg) pkg)))
    (expand-file-name name (outdated--repos-dir))))

(defun outdated--git-fetch (pkg)
  "Fetch latest tags from origin into PKG's local clone."
  (let ((default-directory (outdated--pkg-dir pkg)))
    (outdated--shell-cmd "git fetch origin --tags 2>&1")))

(defun outdated--git-tags (pkg)
  "Return list of all tags in PKG's local clone."
  (let ((default-directory (outdated--pkg-dir pkg)))
    (let ((out (outdated--shell-cmd "git tag")))
      (when out (split-string out "\n" t)))))

(defun outdated--git-is-ancestor (pkg ancestor descendant)
  "Check if ANCESTOR is an ancestor of DESCENDANT in PKG's clone."
  (let ((default-directory (outdated--pkg-dir pkg)))
    (zerop (call-process "git" nil nil nil
                         "merge-base" "--is-ancestor"
                         ancestor descendant))))

(defun outdated--git-tag-date (pkg tag)
  "Return committer date (Unix timestamp) for TAG in PKG's clone."
  (let ((default-directory (outdated--pkg-dir pkg)))
    (let ((out (outdated--shell-cmd
                (format "git log -1 --format=%%ct %s"
                        (shell-quote-argument tag)))))
      (when out (string-to-number out)))))

(defun outdated--git-ref-parse (pkg ref)
  "Return the full commit SHA for REF in PKG's clone."
  (let ((default-directory (outdated--pkg-dir pkg)))
    (outdated--shell-cmd
     (format "git rev-parse --verify %s" (shell-quote-argument ref)))))

(defun outdated--git-short (sha)
  "Return first 7 chars of SHA."
  (when sha (substring sha 0 7)))

;; -- Latest-ref logic (tag-preferring) ---------------------------------------

(defun outdated--find-latest (pkg pinned-ref)
  "Find the 'latest' ref for PKG, preferring tagged releases.
Returns plist (:sha ... :tag ... :source 'tag|'head) or nil on error."
  (let ((clone-dir (outdated--pkg-dir pkg)))
    (unless (file-directory-p clone-dir)
      (throw 'outdated--skip (list :error "not cloned")))
    (outdated--git-fetch pkg)
    (let* ((tags (outdated--git-tags pkg))
           (descendant-tags nil))
      (dolist (tag tags)
        (when (outdated--git-is-ancestor pkg pinned-ref tag)
          (let ((date (outdated--git-tag-date pkg tag)))
            (when date
              (push (cons tag date) descendant-tags)))))
      (if descendant-tags
          (let* ((best (car (sort descendant-tags
                                  (lambda (a b) (> (cdr a) (cdr b))))))
                 (tag-name (car best))
                 (tag-sha (outdated--git-ref-parse pkg tag-name)))
            (if (and tag-sha (not (string-empty-p tag-sha)))
                (list :sha tag-sha :tag tag-name :source 'tag)
              (let ((head-sha (outdated--git-ref-parse pkg "refs/remotes/origin/HEAD")))
                (when head-sha
                  (list :sha head-sha :tag nil :source 'head)))))
        (let ((head-sha (outdated--git-ref-parse pkg "refs/remotes/origin/HEAD")))
          (when head-sha
            (list :sha head-sha :tag nil :source 'head)))))))

;; -- Scanning ----------------------------------------------------------------

(defun outdated--gear-name-from-path (filepath)
  "Extract gear name (without .el) and pouch from FILEPATH.
Returns (pouch . gear) or nil."
  (let* ((rel (file-relative-name filepath (outdated--gears-dir)))
         (parts (split-string rel "/")))
    (when (>= (length parts) 2)
      (cons (car parts)
            (file-name-sans-extension (car (last parts)))))))

(defun outdated--scan ()
  "Scan all gear files and return a list of package entries.
Each entry is a plist: (:package :ref :leaf-pkg :file :pouch :gear)."
  (let ((results nil)
        (gears-dir (outdated--gears-dir)))
    (dolist (file (directory-files-recursively gears-dir "\\.el$"))
      (let* ((pouch-gear (outdated--gear-name-from-path file))
             (pouch (car pouch-gear))
             (gear (cdr pouch-gear)))
        (when (and (or (null outdated--pouch-filter)
                       (string= pouch outdated--pouch-filter))
                   (or (null outdated--gear-filter)
                       (string= gear outdated--gear-filter)))
          (dolist (entry (outdated--parse-one-file file))
            (setq entry (plist-put entry :pouch pouch))
            (setq entry (plist-put entry :gear gear))
            (push entry results)))))
    (nreverse results)))

;; -- Reporting ---------------------------------------------------------------

(defun outdated--report (entries results)
  "Print a report of ENTRIES with their RESULTS to stdout."
  (let ((current-pouch nil)
        (current-gear nil)
        (count-ok 0)
        (count-outdated 0)
        (count-unpinned 0)
        (count-error 0))
    (dolist (entry entries)
      (let* ((pkg (plist-get entry :package))
             (pouch (plist-get entry :pouch))
             (gear (plist-get entry :gear))
             (ref (plist-get entry :ref))
             (result (cdr (assoc pkg results))))
        (unless (and (string= (or pouch "") (or current-pouch ""))
                     (string= (or gear "") (or current-gear "")))
          (when current-gear (princ "\n" t))
          (setq current-pouch pouch current-gear gear)
          (princ (format "Gear: %s/%s (%s)\n" pouch gear gear) t))
        (cond
         ((plist-get result :error)
          (cl-incf count-error)
          (princ (format "  %-20s %-7s  ERROR: %s\n"
                         pkg (outdated--git-short ref)
                         (plist-get result :error)) t))
         ((null ref)
          (cl-incf count-unpinned)
          (princ (format "  %-20s %-7s  UNPINNED (tracks HEAD)\n" pkg "") t))
         ((string= ref (plist-get result :latest))
          (cl-incf count-ok)
          (let ((tag (plist-get result :tag)))
            (princ (format "  %-20s %-7s  %sOK%s\n"
                           pkg (outdated--git-short ref)
                           (if tag (format "(%-12s) " tag) "")
                           (if tag "" "         ")) t)))
         (t
          (cl-incf count-outdated)
          (let* ((latest-sha (plist-get result :latest))
                 (tag (plist-get result :tag))
                 (label (or tag "HEAD")))
            (princ (format "  %-20s %-7s -> %-8s (%-7s) OUTDATED\n"
                           pkg (outdated--git-short ref)
                           label (outdated--git-short latest-sha)) t))))))
    (princ "\n" t)
    (princ (format "Summary: %d outdated, %d current, %d unpinned, %d errors\n"
                   count-outdated count-ok count-unpinned count-error) t)))

;; -- Updating ----------------------------------------------------------------

(defun outdated--replace-in-file (filepath old-ref new-ref)
  "Replace :ref OLD-REF with :ref NEW-REF in FILEPATH."
  (with-temp-buffer
    (insert-file-contents filepath)
    (goto-char (point-min))
    (when (search-forward (format ":ref \"%s\"" old-ref) nil t)
      (replace-match (format ":ref \"%s\"" new-ref) t t)
      (write-region nil nil filepath)
      t)))

(defun outdated--prompt-update (pkg latest-plist entry)
  "Prompt user whether to update PKG to LATEST."
  (let* ((latest-sha (plist-get latest-plist :latest))
         (tag (plist-get latest-plist :tag))
         (label (or tag "HEAD"))
         (gear (plist-get entry :gear))
         (pouch (plist-get entry :pouch))
         (old-ref (plist-get entry :ref))
         (filepath (plist-get entry :file)))
    (if (string= old-ref latest-sha)
        (princ (format "  %s/%s: already up-to-date\n" gear
                       (plist-get entry :package)) t)
      (progn
        (princ "\n" t)
        (princ (format "Update %s/%s (%s): %s -> %s (%s) [y/N]? "
                       pouch gear (plist-get entry :package)
                       (outdated--git-short old-ref) label
                       (outdated--git-short latest-sha)) t)
        (let ((answer (read-string "")))
          (when (string-match-p "\\`[yY]" answer)
            (if (outdated--replace-in-file filepath old-ref latest-sha)
                (princ (format "  V Updated %s/%s\n" gear
                               (plist-get entry :package)) t)
              (princ (format "  X Failed to update %s/%s\n" gear
                             (plist-get entry :package)) t))))))))

;; -- Main -------------------------------------------------------------------

(defun outdated--main ()
  "Entry point."
  (setq outdated--repo-root (or outdated--repo-root
                                (getenv "BACKPACK_REPO_ROOT")
                                default-directory))
  (let ((repos-dir (outdated--repos-dir)))
    (unless (file-directory-p repos-dir)
      (princ (format "Error: repos directory not found: %s\n" repos-dir) t)
      (princ "Run 'backpack ensure' first to clone package repos.\n" t)
      (kill-emacs 1)))
  (princ "Scanning gears...\n" t)
  (let* ((entries (outdated--scan))
         (results nil))
    (princ (format "Checking %d packages...\n" (length entries)) t)
    (let ((seen (make-hash-table :test 'equal)))
      (dolist (entry entries)
        (let ((pkg (plist-get entry :package))
              (ref (plist-get entry :ref)))
          (unless (gethash pkg seen)
            (puthash pkg t seen)
            (condition-case err
                (let* ((latest (catch 'outdated--skip
                                 (outdated--find-latest pkg ref)))
                       (latest-sha (plist-get latest :sha))
                       (latest-tag (plist-get latest :tag))
                       (latest-source (plist-get latest :source))
                       (latest-error (plist-get latest :error)))
                  (push (cons pkg (list :latest latest-sha :tag latest-tag
                                        :source latest-source
                                        :error latest-error))
                        results))
              (error
               (let ((msg (error-message-string err)))
                 (push (cons pkg (list :latest nil :tag nil :error msg))
                       results)
                 (princ (format "  Error checking %s: %s\n" pkg msg) t))))))))
    (princ "\n" t)
    (outdated--report entries results)
    (princ "\n" t)
    (when outdated--update-p
      (let ((outdated-count 0))
        (dolist (entry entries)
          (let* ((pkg (plist-get entry :package))
                 (result (cdr (assoc pkg results)))
                 (latest-sha (plist-get result :latest))
                 (ref (plist-get entry :ref)))
            (when (and latest-sha (not (string= ref latest-sha))
                       (null (plist-get result :error)))
              (cl-incf outdated-count))))
        (if (zerop outdated-count)
            (princ "\nAll packages up-to-date. Nothing to update.\n" t)
          (princ (format "\n%d package(s) can be updated. Review each:\n"
                         outdated-count) t)
          (dolist (entry entries)
            (let* ((pkg (plist-get entry :package))
                   (result (cdr (assoc pkg results)))
                   (latest-sha (plist-get result :latest))
                   (ref (plist-get entry :ref)))
              (when (and latest-sha (not (string= ref latest-sha))
                         (null (plist-get result :error)))
                (outdated--prompt-update pkg result entry))))
          (princ "\nDone.\n" t)))))
  (kill-emacs 0))

;; -- Argument parsing (batch mode) ------------------------------------------

(defun outdated--parse-argv ()
  "Parse command-line arguments from command-line-args-left."
  (let ((args command-line-args-left))
    (while args
      (pcase (car args)
        ("--update" (setq outdated--update-p t))
        ("--pouch" (setq args (cdr args))
         (setq outdated--pouch-filter (car args)))
        ("--gear" (setq args (cdr args))
         (setq outdated--gear-filter (car args)))
        (_ nil))
      (setq args (cdr args)))))

;; Parse args and run
(outdated--parse-argv)
(princ "\nBackpack Outdated - check pinned package refs\n" t)
(princ (format "Repository root: %s\n"
               (or outdated--repo-root
                   (getenv "BACKPACK_REPO_ROOT")
                   default-directory))
       t)
(outdated--main)

;;; outdated.el ends here