;;; outdated.el — check & update pinned package refs in Backpack gears  -*- lexical-binding: t; -*-
;;
;; Dev tool: reports which packages are behind upstream and can update
;; their pinned :ref commits in-place.
;;
;; Usage: ./dev/outdated [--update] [--pouch <p>] [--gear <g>]
;;
;; Resolves package URLs using elpaca's menu system (cached MELPA + ELPA
;; indices).  No extra network after `backpack ensure`.
;; Clones each repo into a temp dir for tag-preferring checks.

(require 'cl-lib)

;; -- Configuration -----------------------------------------------------------

(defvar outdated--repo-root nil)
(defvar outdated--update-p nil)
(defvar outdated--pouch-filter nil)
(defvar outdated--gear-filter nil)

;; -- Elpaca bootstrap --------------------------------------------------------

(defun outdated--bootstrap-elpaca ()
  (let ((bp (or outdated--repo-root
                (getenv "BACKPACK_REPO_ROOT")
                default-directory)))
    (add-to-list 'load-path (expand-file-name "base-packages/leaf.el" bp))
    (add-to-list 'load-path (expand-file-name "base-packages/leaf-keywords.el" bp))
    (add-to-list 'load-path (expand-file-name "base-packages/elpaca" bp))
    (require 'leaf)
    (setq user-emacs-directory bp)
    (setq elpaca-directory
          (expand-file-name ".cache/nonessentials/elpaca/" bp))
    (setq elpaca-cache-directory
          (expand-file-name "cache" elpaca-directory))
    (setq elpaca-builds-directory
          (expand-file-name "builds" elpaca-directory))
    (setq elpaca-repos-directory
          (expand-file-name "repos" elpaca-directory))
    (load (expand-file-name "base-packages/elpaca/elpaca.el" bp) nil t)
    (condition-case nil
        (load (expand-file-name "base-packages/elpaca/elpaca-menu-melpa.el" bp)
              nil t)
      (error (princ "WARNING: no MELPA menu\n" t)))
    (condition-case nil
        (load (expand-file-name "base-packages/elpaca/elpaca-menu-elpa.el" bp)
              nil t)
      (error (princ "WARNING: no ELPA menu\n" t)))
    (setq elpaca-menu-functions
          '(elpaca-menu-melpa elpaca-menu-non-gnu-elpa
                              elpaca-menu-gnu-elpa elpaca-menu-declarations))))

;; -- Path helpers ------------------------------------------------------------

(defun outdated--gears-dir ()
  (expand-file-name "lisp/gears/" outdated--repo-root))

;; -- Plist helpers -----------------------------------------------------------

(defun outdated--plist-get (key plist)
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
  (catch 'done
    (let ((rest plist))
      (while rest
        (when (eq (car rest) key) (throw 'done rest))
        (if (keywordp (car rest))
            (if (and (cdr rest) (consp (cadr rest)))
                (setq rest (cddr rest))
              (setq rest (cddr rest)))
          (setq rest (cdr rest))))
      nil)))

;; -- Parser ------------------------------------------------------------------

(defun outdated--ensure-form-p (sexp)
  (and (consp sexp) (symbolp (car sexp)) (not (eq (car sexp) 'nil))))

(defun outdated--parse-leaf-block (sexp filepath)
  (let* ((leaf-pkg (cadr sexp))
         (tail (cddr sexp))
         (ensure-tail (outdated--plist-member-p :ensure tail))
         (results nil))
    (when ensure-tail
      (let ((ensure-val (cadr ensure-tail)))
        (when (outdated--ensure-form-p ensure-val)
          (let ((pkg (car ensure-val))
                (ref (outdated--plist-get :ref ensure-val))
                (host (outdated--plist-get :host ensure-val))
                (repo (outdated--plist-get :repo ensure-val)))
            (push (list :package pkg :ref ref :host host :repo repo
                        :leaf-pkg leaf-pkg :file filepath)
                  results)))))
    (nreverse results)))

(defun outdated--parse-one-file (filepath)
  (let ((entries nil))
    (with-temp-buffer
      (insert-file-contents filepath)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((sexp (read (current-buffer))))
              (when (and (consp sexp) (eq (car sexp) 'leaf))
                (dolist (e (outdated--parse-leaf-block sexp filepath))
                  (push e entries)))))
        (end-of-file nil)))
    (nreverse entries)))

;; -- URL resolution via elpaca recipe ----------------------------------------

(defun outdated--recipe->url (recipe pkg-name)
  "Convert a full elpaca RECIPE plist to a git URL string.
Handles string repos, cons cell repos ((url . local-name))."
  (let* ((fetcher (plist-get recipe :fetcher))
         (rrepo (plist-get recipe :repo))
         (rurl (plist-get recipe :url))
         ;; GNU/NonGNU ELPA uses cons cells: ("url" . "local-name")
         (repo-url (cond ((stringp rrepo) rrepo)
                         ((consp rrepo) (car rrepo)))))
    (cond
     ;; Already a full URL (from GNU/NonGNU ELPA cons cells)
     ((and (stringp repo-url)
           (string-match-p "\\`https?://\\|\\`git@" repo-url))
      repo-url)
     ;; github/gitlab/codeberg fetcher + string repo
     ((and (memq fetcher '(github gitlab codeberg)) (stringp repo-url))
      (let ((h (cond ((eq fetcher 'github) "github.com")
                      ((eq fetcher 'gitlab) "gitlab.com")
                      ((eq fetcher 'codeberg) "codeberg.org"))))
        (format "https://%s/%s" h repo-url)))
     ;; explicit :url
     ((stringp rurl) rurl)
     ;; git fetcher with repo
     ((and (eq fetcher 'git) (stringp repo-url)) repo-url)
     ;; sourcehut
     ((eq fetcher 'sourcehut)
      (format "https://git.sr.ht/~%s" (or repo-url pkg-name)))
     ;; fallback: assume github
     ((stringp repo-url)
      (format "https://github.com/%s" repo-url)))))

(defun outdated--resolve-url (entry)
  "Resolve git URL for ENTRY."
  (catch 'outdated--resolve-done
    (let* ((pkg (plist-get entry :package))
           (host (plist-get entry :host))
           (repo (plist-get entry :repo))
           (pkg-name (if (symbolp pkg) (symbol-name pkg) pkg)))
      ;; Tier 1: explicit :host/:repo in gear file
      (when host
        (let ((host-str
               (cond ((eq host 'github) "github.com")
                     ((eq host 'gitlab) "gitlab.com")
                     ((eq host 'codeberg) "codeberg.org")
                     ((eq host 'sourcehut) "git.sr.ht")
                     ((stringp host) host))))
          (when host-str
            (throw 'outdated--resolve-done
              (if (eq host 'sourcehut)
                  (format "https://%s/~%s" host-str (or repo pkg-name))
                (format "https://%s/%s" host-str (or repo pkg-name)))))))
      ;; Tier 2: elpaca recipe (cached menus)
      (condition-case nil
          (throw 'outdated--resolve-done
            (outdated--recipe->url
             (elpaca-recipe (list (intern pkg-name)))
             pkg-name))
        (error nil))
      nil)))

;; -- Shell helpers -----------------------------------------------------------

(defun outdated--sh (cmd)
  (with-temp-buffer
    (let ((exit (call-process shell-file-name nil '(t nil) nil
                              shell-command-switch cmd)))
      (when (zerop exit) (string-trim (buffer-string))))))

(defun outdated--short (sha)
  (when sha (substring sha 0 7)))

;; -- Temp clone + tag-preferring check ---------------------------------------

(defun outdated--check-package (url pinned-ref)
  "Shallow-clone URL, find latest tag/HEAD vs PINNED-REF."
  (catch 'outdated--check-early
    (let ((resolved-url url))
      (unless (outdated--sh (format "git ls-remote -q %s HEAD"
                                    (shell-quote-argument resolved-url)))
        (setq resolved-url (concat url ".git"))
        (unless (outdated--sh (format "git ls-remote -q %s HEAD"
                                      (shell-quote-argument resolved-url)))
          (throw 'outdated--check-early
            (list :error "URL is not a git repository"))))
      (let* ((tmp-dir (make-temp-file "bp-check-" t))
             (result nil))
        (unwind-protect
            (condition-case err
                (progn
                  (outdated--sh (format "git init %s 2>/dev/null"
                                        (shell-quote-argument tmp-dir)))
                  (let ((default-directory tmp-dir))
                    (outdated--sh (format "git remote add origin %s"
                                          (shell-quote-argument resolved-url)))
                    (outdated--sh "git fetch --tags origin 2>&1")
                    (unless (zerop (call-process "git" nil nil nil
                                                 "cat-file" "-e" pinned-ref))
                      (outdated--sh
                       (format "git fetch origin %s 2>&1"
                               (shell-quote-argument pinned-ref))))
                    (let ((head-sha (outdated--sh
                                     "git rev-parse refs/remotes/origin/HEAD")))
                      (let* ((tags (split-string
                                    (or (outdated--sh "git tag") "") "\n" t))
                             (desc nil))
                        (dolist (tag tags)
                          (condition-case nil
                              (when (zerop
                                     (call-process
                                      "git" nil nil nil
                                      "merge-base" "--is-ancestor"
                                      pinned-ref tag))
                                (let ((d (outdated--sh
                                          (format
                                           "git log -1 --format=%%ct %s"
                                           (shell-quote-argument tag)))))
                                  (when d
                                    (push (cons tag (string-to-number d))
                                          desc))))
                            (error nil)))
                        (if desc
                            (let* ((best (car
                                          (sort desc
                                                (lambda (a b)
                                                  (> (cdr a) (cdr b))))))
                                   (tag-name (car best))
                                   (tag-sha (outdated--sh
                                             (format
                                              "git rev-parse --verify %s^{commit}"
                                              (shell-quote-argument
                                               tag-name)))))
                              (setq result
                                    (list :latest (or tag-sha head-sha)
                                          :tag (and tag-sha tag-name)
                                          :source (if tag-sha 'tag 'head))))
                          (when head-sha
                            (setq result
                                  (list :latest head-sha :tag nil
                                        :source 'head))))))))
              (error
               (setq result (list :error (error-message-string err)))))
          (condition-case nil
              (call-process "rm" nil nil nil "-rf" tmp-dir)
            (error nil)))
        result))))

;; -- Scanning ----------------------------------------------------------------

(defun outdated--gear-name-from-path (filepath)
  (let* ((rel (file-relative-name filepath (outdated--gears-dir)))
         (parts (split-string rel "/")))
    (when (>= (length parts) 2)
      (cons (car parts) (file-name-sans-extension (car (last parts)))))))

(defun outdated--scan ()
  (let ((results nil)
        (gears-dir (outdated--gears-dir)))
    (dolist (file (directory-files-recursively gears-dir "\\.el$"))
      (let* ((pkg (outdated--gear-name-from-path file)))
        (when (and pkg
                   (or (null outdated--pouch-filter)
                       (string= (car pkg) outdated--pouch-filter))
                   (or (null outdated--gear-filter)
                       (string= (cdr pkg) outdated--gear-filter)))
          (dolist (entry (outdated--parse-one-file file))
            (when (plist-get entry :ref)
              (setq entry (plist-put entry :pouch (car pkg)))
              (setq entry (plist-put entry :gear (cdr pkg)))
              (push entry results))))))
    (nreverse results)))

;; -- Reporting ---------------------------------------------------------------

(defun outdated--report (entries results)
  (let ((cp nil) (cg nil) (ok 0) (out 0) (err 0))
    (dolist (entry entries)
      (let* ((pkg (plist-get entry :package))
             (pouch (plist-get entry :pouch))
             (gear (plist-get entry :gear))
             (ref (plist-get entry :ref))
             (name (if (symbolp pkg) (symbol-name pkg) pkg))
             (r (cdr (assoc name results))))
        (unless (and (string= (or pouch "") (or cp ""))
                     (string= (or gear "") (or cg "")))
          (when cg (princ "\n" t))
          (setq cp pouch cg gear)
          (princ (format "Gear: %s/%s (%s)\n" pouch gear gear) t))
        (cond
         ((plist-get r :error)
          (cl-incf err)
          (princ (format "  %-25s %-7s  ERROR: %s\n"
                         name (outdated--short ref) (plist-get r :error)) t))
         ((string= ref (plist-get r :latest))
          (cl-incf ok)
          (let ((tag (plist-get r :tag)))
            (princ
             (format "  %-25s %-7s  %sOK\n"
                     name (outdated--short ref)
                     (if tag (format "(%-12s) " tag) "")) t)))
         (t
          (cl-incf out)
          (let* ((sha (plist-get r :latest))
                 (tag (plist-get r :tag))
                 (label (or tag "HEAD")))
            (princ (format "  %-25s %-7s -> %-8s (%-7s) OUTDATED\n"
                           name (outdated--short ref) label
                           (outdated--short sha)) t))))))
    (princ "\n" t)
    (princ (format "Summary: %d outdated, %d current, %d errors\n"
                   out ok err) t)))

;; -- Updating ----------------------------------------------------------------

(defun outdated--replace-ref (filepath old-ref new-ref)
  (with-temp-buffer
    (insert-file-contents filepath)
    (goto-char (point-min))
    (when (search-forward (format ":ref \"%s\"" old-ref) nil t)
      (replace-match (format ":ref \"%s\"" new-ref) t t)
      (write-region nil nil filepath)
      t)))

(defun outdated--do-update (entry result)
  (let* ((pkg (plist-get entry :package))
         (name (if (symbolp pkg) (symbol-name pkg) pkg))
         (sha (plist-get result :latest))
         (tag (plist-get result :tag))
         (label (or tag "HEAD"))
         (gear (plist-get entry :gear))
         (pouch (plist-get entry :pouch))
         (old (plist-get entry :ref))
         (fp (plist-get entry :file)))
    (if (string= old sha)
        (princ (format "  %s/%s: already up-to-date\n" gear name) t)
      (progn (princ "\n" t)
             (princ (format "Update %s/%s (%s): %s -> %s (%s) [y/N]? "
                            pouch gear name (outdated--short old)
                            label (outdated--short sha)) t)
             (when (string-match-p "\\`[yY]" (read-string ""))
               (if (outdated--replace-ref fp old sha)
                   (princ (format "  V Updated %s/%s\n" gear name) t)
                 (princ (format "  X Failed to update %s/%s\n"
                                gear name) t)))))))

;; -- Main --------------------------------------------------------------------

(defun outdated--main ()
  (setq outdated--repo-root
        (or outdated--repo-root
            (getenv "BACKPACK_REPO_ROOT")
            default-directory))
  (princ "Bootstrapping elpaca (cached indices)...\n" t)
  (condition-case err
      (outdated--bootstrap-elpaca)
    (error (princ (format "FATAL: %s\n" (error-message-string err)) t)
           (kill-emacs 1)))
  (princ "Scanning gears...\n" t)
  (let* ((entries (outdated--scan))
         (results nil)
         (total (length entries))
         (done 0)
         (seen (make-hash-table :test 'equal)))
    (princ (format "Checking %d packages...\n" total) t)
    (dolist (entry entries)
      (let* ((pkg (plist-get entry :package))
             (name (if (symbolp pkg) (symbol-name pkg) pkg))
             (ref (plist-get entry :ref)))
        (unless (gethash name seen)
          (puthash name t seen)
          (cl-incf done)
          (princ (format "  [%d/%d] %s..." done total name) t)
          (let ((url (outdated--resolve-url entry)))
            (if (not url)
                (progn (princ " no URL\n" t)
                       (push (cons name (list :error "no URL resolved"))
                             results))
              (let ((check (outdated--check-package url ref)))
                (if (plist-get check :error)
                    (progn (princ (format " ERROR: %s\n"
                                          (plist-get check :error)) t)
                           (push (cons name check) results))
                  (let ((sha (plist-get check :latest))
                        (tag (plist-get check :tag)))
                    (if (string= ref sha)
                        (princ (format " OK%s\n"
                                       (if tag (format " (%s)" tag) "")) t)
                      (princ (format " -> %s (%s)\n"
                                     (or tag "HEAD")
                                     (outdated--short sha)) t))
                    (push (cons name check) results)))))))))
    (princ "\n" t)
    (outdated--report entries results)
    (princ "\n" t)
    (when outdated--update-p
      (let ((out 0))
        (dolist (entry entries)
          (let* ((name (if (symbolp (plist-get entry :package))
                           (symbol-name (plist-get entry :package))
                         (plist-get entry :package)))
                 (r (cdr (assoc name results)))
                 (sha (plist-get r :latest)))
            (when (and sha (not (string= (plist-get entry :ref) sha))
                       (null (plist-get r :error)))
              (cl-incf out))))
        (if (zerop out)
            (princ "\nAll up-to-date.\n" t)
          (progn (princ (format "\n%d package(s) can be updated:\n" out) t)
                 (dolist (entry entries)
                   (let* ((name (if (symbolp (plist-get entry :package))
                                    (symbol-name (plist-get entry :package))
                                  (plist-get entry :package)))
                          (r (cdr (assoc name results)))
                          (sha (plist-get r :latest)))
                     (when (and sha
                                (not (string= (plist-get entry :ref) sha))
                                (null (plist-get r :error)))
                       (outdated--do-update entry r))))
                 (princ "\nDone.\n" t))))))
  (kill-emacs 0))

;; -- Argument parsing --------------------------------------------------------

(defun outdated--parse-argv ()
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

(outdated--parse-argv)
(princ "\nBackpack Outdated - check pinned package refs\n" t)
(princ (format "Repository root: %s\n"
               (or outdated--repo-root
                   (getenv "BACKPACK_REPO_ROOT")
                   default-directory)) t)
(outdated--main)

;;; outdated.el ends here