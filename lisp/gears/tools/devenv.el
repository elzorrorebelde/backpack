;; -*- lexical-binding: t; -*-

;;; devenv.el --- devenv project environments without direnv  -*- lexical-binding: t; -*-

;; This file is loaded by `backpack-load-gear-files'.  It has no
;; `provide': every gear self-gates with `gearp!'.

;;; Commentary:

;; This gear makes the environment that `devenv' prepares for a project
;; available to the processes started from that project's buffers, even
;; when the project has no `.envrc' (and therefore no direnv support).
;;
;; Detection walks upward from the buffer's directory looking for
;; `devenv.nix' or `devenv.yaml'; the closest marker wins, so nested
;; devenv projects beat the project that contains them.  When the
;; directory that owns the marker also has a `.envrc' (or when a closer
;; directory has one), direnv is in charge and this gear stays out of the
;; way -- enable the `direnv' gear for those projects.
;;
;; The environment is evaluated once per project with
;;     devenv shell -- env -0
;; and then applied buffer-locally to `process-environment' and
;; `exec-path', so it does not leak into unrelated buffers.
;;
;; devenv refuses to evaluate projects the user has not reviewed.  This
;; gear never auto-trusts a project: it shows a warning with the
;; `devenv allow' instruction and leaves the decision to the user.  Use
;; `M-x backpack-devenv-reload' after allowing the project, or whenever
;; `devenv.nix' changes.

;;; Code:

(require 'cl-lib)

(defvar backpack-emacs-dir)

(defconst backpack-devenv--cache-miss 'backpack-devenv--cache-miss
  "Sentinel used to tell a cache miss apart from a cached nil value.")

(defconst backpack-devenv--denied-regexp
  (concat "\\(not allowed\\|not trusted\\|untrusted"
          "\\|needs to be trusted\\|needs to be allowed"
          "\\|devenv allow\\|allow this project\\)")
  "Regexp matching devenv output for a project it refuses to evaluate.")

(defvar backpack-devenv--root-cache (make-hash-table :test #'equal)
  "Map of directory names to the devenv root detected for them.")

(defvar backpack-devenv--environment-cache (make-hash-table :test #'equal)
  "Map of devenv roots to their evaluated environment results.")

(defvar backpack-devenv--warned (make-hash-table :test #'equal)
  "Devenv roots for which a warning was already shown.")

(defvar-local backpack-devenv-buffer-root nil
  "Devenv project root whose environment is active in this buffer.")

(defvar-local backpack-devenv--applied-variables nil
  "Environment variable names this gear set in the current buffer.")

;;; Detection

(defun backpack-devenv--marker-p (directory)
  "Return non-nil when DIRECTORY contains a devenv project marker."
  (or (file-exists-p (expand-file-name "devenv.nix" directory))
      (file-exists-p (expand-file-name "devenv.yaml" directory))))

(defun backpack-devenv--envrc-p (directory)
  "Return non-nil when DIRECTORY contains a direnv `.envrc' file."
  (file-exists-p (expand-file-name ".envrc" directory)))

(defun backpack-devenv--parent-dir (directory)
  "Return the parent of DIRECTORY, or nil at the filesystem root."
  (let ((parent (file-name-directory (directory-file-name directory))))
    (unless (equal parent directory)
      parent)))

(defun backpack-devenv--backpack-dir-p (directory)
  "Return non-nil when DIRECTORY is Backpack's own source directory."
  (when (bound-and-true-p backpack-emacs-dir)
    (let ((directory (directory-file-name (expand-file-name directory)))
          (backpack (directory-file-name (expand-file-name backpack-emacs-dir))))
      ;; Backpack ships a devenv project of its own (plus a `.envrc');
      ;; do not hijack buffers that edit its source code.
      (or (equal directory backpack)
          (file-in-directory-p directory backpack)))))

(defun backpack-devenv-find-root (&optional directory)
  "Return the devenv project root that applies to DIRECTORY.

Search upward from DIRECTORY (default `default-directory') for
`devenv.nix' or `devenv.yaml'.  The closest marker wins, so nested
projects take precedence over the projects containing them.

Return nil when no marker is found, when a `.envrc' is found first
(direnv owns that environment), or when the marker belongs to
Backpack's own source directory.  Results are cached per directory;
`backpack-devenv-reload' flushes the cache."
  (let* ((start (file-name-as-directory
                 (expand-file-name (or directory default-directory))))
         (cached (gethash start backpack-devenv--root-cache
                          backpack-devenv--cache-miss)))
    (if (not (eq cached backpack-devenv--cache-miss))
        cached
      (let ((dir start)
            (root nil)
            (done nil))
        (while (and dir (not done))
          (cond
           ((backpack-devenv--envrc-p dir)
            (setq done t))
           ((backpack-devenv--marker-p dir)
            (setq root dir
                  done t))
           (t
            (setq dir (backpack-devenv--parent-dir dir)))))
        (when (and root (backpack-devenv--backpack-dir-p root))
          (setq root nil))
        (puthash start root backpack-devenv--root-cache)
        root))))

;;; Evaluating the environment

(defun backpack-devenv--run (root)
  "Run `devenv shell -- env -0' in ROOT.

Return a plist with `:code' (the exit status), `:stdout' (the
NUL-separated environment) and `:stderr' (diagnostics)."
  (let* ((stdout-buffer (generate-new-buffer " *backpack-devenv-stdout*"))
         (stderr-buffer (generate-new-buffer " *backpack-devenv-stderr*"))
         (default-directory (file-name-as-directory root))
         ;; Evaluate the project from a clean base so repeated calls do
         ;; not compound a previously applied environment.
         (process-environment (default-value 'process-environment))
         (exec-path (default-value 'exec-path))
         (process nil))
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "backpack-devenv"
                 :buffer stdout-buffer
                 :stderr stderr-buffer
                 :command '("devenv" "shell" "--" "env" "-0")
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t))
          (while (process-live-p process)
            (accept-process-output process 0.1))
          (list :code (process-exit-status process)
                :stdout (with-current-buffer stdout-buffer (buffer-string))
                :stderr (with-current-buffer stderr-buffer (buffer-string))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p stdout-buffer)
        (kill-buffer stdout-buffer))
      (when (buffer-live-p stderr-buffer)
        (kill-buffer stderr-buffer)))))

(defun backpack-devenv--parse-environment (output)
  "Return the environment entries found in OUTPUT.
OUTPUT is the NUL-separated `env -0' output produced by devenv."
  (cl-remove-if-not
   (lambda (entry)
     (and (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" entry)
          ;; Let subprocesses derive these from their own working
          ;; directory instead of pinning them to the project root.
          (not (member (backpack-devenv--variable-name entry)
                       '("PWD" "OLDPWD")))))
   (split-string output "\0" t)))

(defun backpack-devenv--evaluate (root)
  "Evaluate the devenv environment of ROOT.

Return a plist with `:status' (`ok', `denied' or `error'), plus
`:environment' (a list of \"NAME=VALUE\" strings) when the status
is `ok' and `:output' (diagnostics) otherwise."
  (if (not (let ((exec-path (default-value 'exec-path)))
             ;; Look for the CLI with the base `exec-path': the buffer
             ;; may already have had a devenv `PATH' applied.
             (executable-find "devenv")))
      (list :status 'error
            :output "the devenv CLI was not found in `exec-path'")
    (condition-case err
        (let* ((result (backpack-devenv--run root))
               (code (plist-get result :code))
               (stdout (or (plist-get result :stdout) ""))
               (stderr (or (plist-get result :stderr) ""))
               (output (string-trim (concat stderr stdout))))
          (cond
           ((string-match-p backpack-devenv--denied-regexp
                            (concat stderr "\n" stdout))
            (list :status 'denied :output output))
           ((not (zerop code))
            (list :status 'error :output output))
           (t
            (let ((environment (backpack-devenv--parse-environment stdout)))
              (if environment
                  (list :status 'ok
                        :environment environment
                        :output output)
                (list :status 'error
                      :output (string-trim
                               (concat "devenv returned an empty environment\n"
                                       output))))))))
      (error
       (list :status 'error
             :output (error-message-string err))))))

(defun backpack-devenv--result (root)
  "Return the cached evaluation result for ROOT, evaluating it if needed."
  (let ((cached (gethash root backpack-devenv--environment-cache
                         backpack-devenv--cache-miss)))
    (if (not (eq cached backpack-devenv--cache-miss))
        cached
      (puthash root (backpack-devenv--evaluate root)
               backpack-devenv--environment-cache))))

;;; Applying the environment

(defun backpack-devenv--variable-name (entry)
  "Return the variable name of a `process-environment' ENTRY."
  (substring entry 0 (or (string-search "=" entry) (length entry))))

(defun backpack-devenv--path-value (environment)
  "Return the PATH value of the ENVIRONMENT entry list, if any."
  (when-let* ((entry (cl-find "PATH" environment
                              :key #'backpack-devenv--variable-name
                              :test #'equal)))
    (substring entry (1+ (string-search "=" entry)))))

(defun backpack-devenv--merge-environment (environment base)
  "Return BASE with the variables in ENVIRONMENT taking precedence.
BASE is a `process-environment' value; ENVIRONMENT is a list of
\"NAME=VALUE\" strings produced by devenv."
  (let ((names (mapcar #'backpack-devenv--variable-name environment)))
    (append environment
            (cl-remove-if (lambda (entry)
                            (member (backpack-devenv--variable-name entry)
                                    names))
                          base))))

(defun backpack-devenv--exec-path (environment)
  "Return an `exec-path' value built from the PATH in ENVIRONMENT."
  (when-let* ((path (backpack-devenv--path-value environment)))
    (split-string path (regexp-quote path-separator) t)))

(defun backpack-devenv--apply (buffer root environment)
  "Apply the devenv ENVIRONMENT of ROOT to BUFFER.
The change is buffer-local, so unrelated buffers keep their own
`process-environment' and `exec-path'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((names (mapcar #'backpack-devenv--variable-name environment))
             (stale (append names backpack-devenv--applied-variables))
             (base (cl-remove-if
                    (lambda (entry)
                      (member (backpack-devenv--variable-name entry) stale))
                    process-environment)))
        (setq-local process-environment
                    (backpack-devenv--merge-environment environment base))
        (setq-local backpack-devenv--applied-variables names)
        (when-let* ((paths (backpack-devenv--exec-path environment)))
          (setq-local exec-path paths))
        (setq-local backpack-devenv-buffer-root root)
        t))))

;;; Activation

(defun backpack-devenv--warn (root result)
  "Warn once about the failed devenv RESULT for ROOT."
  (unless (gethash root backpack-devenv--warned)
    (puthash root t backpack-devenv--warned)
    (let* ((details (string-trim
                     (replace-regexp-in-string
                      "[ \t\n]+" " " (or (plist-get result :output) ""))))
           (summary (string-limit details 300 t)))
      (message "%s"
               (propertize
                (if (eq (plist-get result :status) 'denied)
                    (format "Backpack: devenv project %s is not allowed; review it and run `devenv allow' there, then `M-x backpack-devenv-reload'%s"
                            root
                            (if (string-empty-p summary)
                                ""
                              (format " (%s)" summary)))
                  (format "Backpack: could not evaluate devenv project %s%s"
                          root
                          (if (string-empty-p summary)
                              ""
                            (format ": %s" summary))))
                'face 'warning)))))

(defun backpack-devenv--activate-root (root)
  "Evaluate and apply the devenv environment of ROOT in the current buffer.
Return non-nil when the environment was applied.  A project devenv
refuses to evaluate is reported once per session and never trusted."
  (let ((result (backpack-devenv--result root)))
    (if (eq (plist-get result :status) 'ok)
        (backpack-devenv--apply (current-buffer) root
                                (plist-get result :environment))
      (backpack-devenv--warn root result)
      nil)))

(defun backpack-devenv--find-file-h ()
  "Apply the devenv environment of the visited project, if any."
  (unless (file-remote-p default-directory)
    (when-let* ((root (backpack-devenv-find-root default-directory)))
      (backpack-devenv--activate-root root))))

;;; Reload

(defun backpack-devenv--buffer-root (buffer)
  "Return the devenv root that applies to BUFFER, if any."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (and (not (file-remote-p default-directory))
           (or backpack-devenv-buffer-root
               (backpack-devenv-find-root default-directory))))))

(defun backpack-devenv--project-buffers (root)
  "Return the live buffers whose devenv project is ROOT."
  (cl-remove-if-not
   (lambda (buffer) (equal root (backpack-devenv--buffer-root buffer)))
   (buffer-list)))

(defun backpack-devenv-reload ()
  "Re-evaluate the devenv environment and apply it to the project buffers.

Forget the cached environment of the current project, run
`devenv shell -- env -0' again and apply the result to the current
buffer and to every other buffer that belongs to the same devenv
project.  Run this after allowing a project with `devenv allow' or
after changing `devenv.nix'."
  (interactive)
  (let ((root (backpack-devenv--buffer-root (current-buffer))))
    (unless root
      (user-error "No devenv project found for this buffer"))
    (clrhash backpack-devenv--root-cache)
    (remhash root backpack-devenv--environment-cache)
    (remhash root backpack-devenv--warned)
    (let ((result (backpack-devenv--result root)))
      (cond
       ((eq (plist-get result :status) 'ok)
        (dolist (buffer (backpack-devenv--project-buffers root))
          (backpack-devenv--apply buffer root
                                  (plist-get result :environment)))
        (message "Backpack: devenv environment reloaded for %s" root))
       (t
        (backpack-devenv--warn root result))))))

(leaf devenv
  :doc "devenv project environments applied to buffers, without direnv"
  :when (gearp! :tools devenv)
  :doctor ("devenv" . ("the CLI that builds and exposes project environments" required))
  :init
  (add-hook 'find-file-hook #'backpack-devenv--find-file-h))

;;; devenv.el ends here
