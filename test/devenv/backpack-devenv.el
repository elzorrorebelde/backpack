;;; backpack-devenv.el --- Tests for the devenv gear  -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests exercise project detection (markers, `.envrc' precedence,
;; nested projects), environment evaluation (ok/denied/error), buffer-local
;; application, one-shot warnings for untrusted projects, and
;; `backpack-devenv-reload'.  The devenv CLI is never invoked: the
;; low-level `backpack-devenv--run' is stubbed in every test that needs an
;; environment.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'backpack-pouch)

(load (expand-file-name "lisp/gears/tools/devenv.el" backpack-emacs-dir) nil t)

;;; Helpers

(defun backpack-devenv-test--make-project (files)
  "Create a temporary project containing FILES (relative paths)."
  (let ((root (file-name-as-directory (make-temp-file "backpack-devenv-" t))))
    (dolist (file files)
      (let ((path (expand-file-name file root)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path
          (insert ""))))
    root))

(defmacro backpack-devenv-test--with-project (files root &rest body)
  "Create a project with FILES, bind its root to ROOT and run BODY."
  (declare (indent 2))
  `(let ((,root (backpack-devenv-test--make-project ,files)))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,root t))))

(defmacro backpack-devenv-test--with-caches (&rest body)
  "Run BODY with fresh devenv discovery and environment caches."
  (declare (indent 0))
  `(let ((backpack-devenv--root-cache (make-hash-table :test #'equal))
         (backpack-devenv--environment-cache (make-hash-table :test #'equal))
         (backpack-devenv--warned (make-hash-table :test #'equal)))
     ,@body))

(defun backpack-devenv-test--run-result (code stdout stderr)
  "Build the plist returned by `backpack-devenv--run' for tests."
  (list :code code :stdout stdout :stderr stderr))

(defmacro backpack-devenv-test--with-run (code stdout stderr &rest body)
  "Stub `backpack-devenv--run' while running BODY."
  (declare (indent 3))
  `(cl-letf (((symbol-function 'backpack-devenv--run)
              (lambda (_root)
                (backpack-devenv-test--run-result ,code ,stdout ,stderr))))
     ,@body))

(defmacro backpack-devenv-test--capture-messages (&rest body)
  "Run BODY, capturing the strings passed to `message'."
  (declare (indent 0))
  `(let ((messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (apply #'format-message format-string args) messages))))
       ,@body)
     (nreverse messages)))

(defun backpack-devenv-test--buffer (name directory)
  "Create a test buffer NAME whose `default-directory' is DIRECTORY."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (setq-local default-directory directory))
    buffer))

;;; Detection

(ert-deftest test-devenv-find-root-devenv-nix ()
  "A devenv.nix marker is detected from a nested directory."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project '("devenv.nix" "src/main.go") root
    (backpack-devenv-test--with-caches
      (should (equal (file-name-as-directory (expand-file-name root))
                     (backpack-devenv-find-root
                      (expand-file-name "src" root)))))))

(ert-deftest test-devenv-find-root-devenv-yaml ()
  "A devenv.yaml marker is also a valid project marker."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project '("devenv.yaml" "README.md") root
    (backpack-devenv-test--with-caches
      (should (equal (file-name-as-directory (expand-file-name root))
                     (backpack-devenv-find-root root))))))

(ert-deftest test-devenv-find-root-without-markers ()
  "A directory tree without devenv markers has no project root."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project '("README.md" "src/main.go") root
    (backpack-devenv-test--with-caches
      (should-not (backpack-devenv-find-root
                   (expand-file-name "src" root))))))

(ert-deftest test-devenv-envrc-in-same-project-wins ()
  "A project with both devenv markers and .envrc is left to direnv."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project '("devenv.nix" ".envrc" "src/main.go") root
    (backpack-devenv-test--with-caches
      (should-not (backpack-devenv-find-root root))
      (should-not (backpack-devenv-find-root
                   (expand-file-name "src" root))))))

(ert-deftest test-devenv-nearest-nested-project-wins ()
  "The closest devenv marker wins over an enclosing project."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project
      '("devenv.nix" "nested/devenv.yaml" "nested/deeper/file.txt")
      root
    (backpack-devenv-test--with-caches
      (should (equal (file-name-as-directory (expand-file-name "nested/" root))
                     (backpack-devenv-find-root
                      (expand-file-name "nested/deeper" root)))))))

(ert-deftest test-devenv-closer-envrc-wins-over-enclosing-project ()
  "A nested direnv project is not hijacked by an enclosing devenv project."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project
      '("devenv.nix" "nested/.envrc" "nested/file.txt")
      root
    (backpack-devenv-test--with-caches
      (should-not (backpack-devenv-find-root
                   (expand-file-name "nested" root))))))

;;; Evaluation

(ert-deftest test-devenv-evaluate-parses-nul-separated-environment ()
  "`env -0' output is parsed into entries, dropping PWD and OLDPWD."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-caches
    (backpack-devenv-test--with-run
        0 "FOO=bar\0PATH=/opt/bin:/usr/bin\0PWD=/tmp\0OLDPWD=/\0" ""
      (let ((result (backpack-devenv--evaluate "/tmp/project/")))
        (should (eq 'ok (plist-get result :status)))
        (should (equal '("FOO=bar" "PATH=/opt/bin:/usr/bin")
                       (plist-get result :environment)))))))

(ert-deftest test-devenv-evaluate-denied-project ()
  "A project devenv refuses to evaluate is reported as denied."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-caches
    (backpack-devenv-test--with-run
        1 "" "Project is not allowed. Run `devenv allow` first."
      (let ((result (backpack-devenv--evaluate "/tmp/project/")))
        (should (eq 'denied (plist-get result :status)))
        (should (string-match-p "devenv allow" (plist-get result :output)))))))

(ert-deftest test-devenv-evaluate-error ()
  "A failing devenv invocation is reported as an error."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-caches
    (backpack-devenv-test--with-run 2 "" "boom" ""
      (let ((result (backpack-devenv--evaluate "/tmp/project/")))
        (should (eq 'error (plist-get result :status)))
        (should (string-match-p "boom" (plist-get result :output)))))))

(ert-deftest test-devenv-evaluate-empty-environment-is-an-error ()
  "A successful devenv run without environment entries is an error."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-caches
    (backpack-devenv-test--with-run 0 "" ""
      (let ((result (backpack-devenv--evaluate "/tmp/project/")))
        (should (eq 'error (plist-get result :status)))))))

(ert-deftest test-devenv-evaluate-without-cli ()
  "A missing devenv CLI is reported as an error without running it."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-caches
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_command) nil)))
      (let ((result (backpack-devenv--evaluate "/tmp/project/")))
        (should (eq 'error (plist-get result :status)))
        (should (string-match-p "devenv CLI" (plist-get result :output)))))))

;;; Application

(ert-deftest test-devenv-apply-is-buffer-local ()
  "Applying an environment only changes the target buffer."
  :tags '(backpack devenv)
  (let ((buffer (backpack-devenv-test--buffer "devenv-apply" "/tmp/"))
        (global-environment (default-value 'process-environment))
        (global-exec-path (default-value 'exec-path)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local process-environment '("KEEP=1" "FOO=old")))
          (backpack-devenv--apply
           buffer "/tmp/project/"
           '("FOO=new" "PATH=/opt/bin:/usr/bin" "PWD=/tmp/project"))
          (with-current-buffer buffer
            (should (member "FOO=new" process-environment))
            (should-not (member "FOO=old" process-environment))
            (should (member "KEEP=1" process-environment))
            (should (equal '("/opt/bin" "/usr/bin") exec-path))
            (should (equal "/tmp/project/" backpack-devenv-buffer-root)))
          (should (equal global-environment (default-value 'process-environment)))
          (should (equal global-exec-path (default-value 'exec-path))))
      (kill-buffer buffer))))

(ert-deftest test-devenv-apply-drops-previously-applied-variables ()
  "Re-applying an environment removes variables the new one lacks."
  :tags '(backpack devenv)
  (let ((buffer (backpack-devenv-test--buffer "devenv-reapply" "/tmp/")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local process-environment '("KEEP=1")))
          (backpack-devenv--apply buffer "/tmp/project/"
                                  '("EXTRA=1" "FOO=old"))
          (backpack-devenv--apply buffer "/tmp/project/"
                                  '("FOO=new"))
          (with-current-buffer buffer
            (should (member "FOO=new" process-environment))
            (should-not (member "EXTRA=1" process-environment))
            (should-not (member "FOO=old" process-environment))
            (should (member "KEEP=1" process-environment))))
      (kill-buffer buffer))))

(ert-deftest test-devenv-denied-project-warns-once ()
  "Visiting an untrusted project warns once, instructs `devenv allow'
and never applies an environment."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-caches
    (backpack-devenv-test--with-run
        1 "" "Project is not allowed. Run `devenv allow` first."
      (let ((buffer (backpack-devenv-test--buffer
                     "devenv-denied" "/tmp/project/")))
        (unwind-protect
            (let ((messages
                   (backpack-devenv-test--capture-messages
                     (with-current-buffer buffer
                       (backpack-devenv--activate-root "/tmp/project/"))
                     (with-current-buffer buffer
                       (backpack-devenv--activate-root "/tmp/project/")))))
              (should (= 1 (length messages)))
              (should (string-match-p "devenv allow" (car messages)))
              (with-current-buffer buffer
                (should-not backpack-devenv-buffer-root)))
          (kill-buffer buffer))))))

(ert-deftest test-devenv-reload-updates-all-project-buffers ()
  "Reloading refreshes the environment in every buffer of the project."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project '("devenv.nix" "a.txt" "b.txt") root
    (backpack-devenv-test--with-caches
      (let ((buffer-a (backpack-devenv-test--buffer "devenv-a" root))
            (buffer-b (backpack-devenv-test--buffer "devenv-b" root))
            (unrelated (backpack-devenv-test--buffer "devenv-other" "/tmp/")))
        (unwind-protect
            (cl-letf (((symbol-function 'backpack-devenv--run)
                       (lambda (_root)
                         (backpack-devenv-test--run-result
                          0 "FOO=old\0PATH=/old/bin\0" ""))))
              (dolist (buffer (list buffer-a buffer-b))
                (with-current-buffer buffer
                  (backpack-devenv--activate-root root)))
              (cl-letf (((symbol-function 'backpack-devenv--run)
                         (lambda (_root)
                           (backpack-devenv-test--run-result
                            0 "FOO=new\0PATH=/new/bin\0" ""))))
                (with-current-buffer buffer-a
                  (backpack-devenv-reload)))
              (dolist (buffer (list buffer-a buffer-b))
                (with-current-buffer buffer
                  (should (member "FOO=new" process-environment))
                  (should-not (member "FOO=old" process-environment))
                  (should (equal '("/new/bin") exec-path))))
              (with-current-buffer unrelated
                (should-not backpack-devenv-buffer-root)
                (should-not (member "FOO=new" process-environment))))
          (dolist (buffer (list buffer-a buffer-b unrelated))
            (kill-buffer buffer)))))))

(ert-deftest test-devenv-reload-without-project-signals-error ()
  "Reloading outside a devenv project signals a `user-error'."
  :tags '(backpack devenv)
  (backpack-devenv-test--with-project '("README.md") root
    (backpack-devenv-test--with-caches
      (let ((buffer (backpack-devenv-test--buffer "devenv-none" root)))
        (unwind-protect
            (with-current-buffer buffer
              (should-error (backpack-devenv-reload) :type 'user-error))
          (kill-buffer buffer))))))

(provide 'backpack-devenv)
;;; backpack-devenv.el ends here
