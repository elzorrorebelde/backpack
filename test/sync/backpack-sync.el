;;; backpack-sync.el --- Tests for Backpack package synchronization  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (expand-file-name "lisp" backpack-emacs-dir))
(add-to-list 'load-path (expand-file-name "base-packages/elpaca" backpack-emacs-dir))
(require 'backpack-pouch)
(require 'backpack-sync)
(require 'elpaca)

(defvar pele--directory)

(defun backpack-sync-test--with-elpaca-process-file (directory)
  "Create the file used to validate Elpaca source DIRECTORY."
  (with-temp-file (expand-file-name "elpaca-process.el" directory)
    (insert ";;; test fixture\n")))

(ert-deftest backpack-sync-org-build-dir-falls-back-without-queued-elpaca ()
  "Use Backpack's Elpaca checkout when no Elpaca queue entry exists."
  (let ((fallback-dir (make-temp-file "backpack-sync-elpaca-" t)))
    (unwind-protect
        (progn
          (backpack-sync-test--with-elpaca-process-file fallback-dir)
          (cl-letf (((symbol-function 'elpaca-get) (lambda (_id) nil))
                    ((symbol-function 'backpack--elpaca-repo-dir)
                     (lambda () fallback-dir)))
            (should (equal fallback-dir
                           (backpack--org-build-elpaca-dir)))))
      (delete-directory fallback-dir t))))

(ert-deftest backpack-sync-org-build-dir-prefers-valid-queued-elpaca ()
  "Prefer a valid Elpaca queue entry over Backpack's fallback directory."
  (let ((entry-dir (make-temp-file "backpack-sync-elpaca-entry-" t))
        (fallback-dir (make-temp-file "backpack-sync-elpaca-fallback-" t)))
    (unwind-protect
        (progn
          (backpack-sync-test--with-elpaca-process-file entry-dir)
          (backpack-sync-test--with-elpaca-process-file fallback-dir)
          (let ((entry (elpaca<--create :id 'elpaca :package "elpaca"
                                        :source-dir entry-dir)))
            (cl-letf (((symbol-function 'elpaca-get)
                       (lambda (_id) entry))
                      ((symbol-function 'backpack--elpaca-repo-dir)
                       (lambda () fallback-dir)))
              (should (equal entry-dir
                             (backpack--org-build-elpaca-dir))))))
      (delete-directory entry-dir t)
      (delete-directory fallback-dir t))))

(ert-deftest backpack-sync-org-build-around-delegates-with-fallback-entry ()
  "Delegate to Org's build helper with a temporary valid Elpaca entry."
  (let ((fallback-dir (make-temp-file "backpack-sync-elpaca-" t))
        observed-entry
        observed-package
        result)
    (unwind-protect
        (progn
          (backpack-sync-test--with-elpaca-process-file fallback-dir)
          (cl-letf (((symbol-function 'elpaca-get) (lambda (_id) nil))
                    ((symbol-function 'backpack--org-build-elpaca-dir)
                     (lambda () fallback-dir)))
            (setq result
                  (backpack--elpaca-menu-org-build-around
                   (lambda (package)
                     (setq observed-package package
                           observed-entry (elpaca-get 'elpaca))
                     :delegated)
                   'org-package)))
          (should (eq result :delegated))
          (should (eq observed-package 'org-package))
          (should (equal fallback-dir
                         (elpaca<-source-dir observed-entry))))
      (delete-directory fallback-dir t))))

(defun backpack-sync-test--with-pele-state (source-dir module-file nixos thunk &optional runtime-dir)
  "Run THUNK with a simulated enabled Pele gear and Elpaca package entry."
  (let ((backpack--gear '(:editing mermaid))
        (backpack--system-nixos-p nixos)
        (system-type 'gnu/linux)
        (module-file-suffix ".so")
        (pele--directory (or runtime-dir (file-name-directory module-file)))
        (features (copy-sequence features)))
    (provide 'pele)
    (provide 'pele-module)
    (cl-letf (((symbol-function 'backpack-sync-mode-p) (lambda () t))
              ((symbol-function 'elpaca-get) (lambda (_package) 'pele-entry))
              ((symbol-function 'elpaca<-source-dir) (lambda (_entry) source-dir))
              ((symbol-function 'backpack--activate-package)
               (lambda (_package) (provide 'pele)))
              ((symbol-function 'pele--module-file)
               (lambda () (and (file-exists-p module-file) module-file)))
              ((symbol-function 'backpack--pele-source-revision)
               (lambda (_source-dir) "fixture-revision")))
      (funcall thunk))))

(ert-deftest backpack-sync-pele-available-module-skips-build-and-download ()
  "Do not rebuild or download when Pele already resolves a module."
  (let* ((directory (make-temp-file "backpack-sync-pele-" t))
         (module (expand-file-name "pele-native.so" directory))
         (build-count 0)
         (download-count 0))
    (unwind-protect
        (progn
          (with-temp-file module (insert "native module fixture"))
          (with-temp-file (backpack--pele-build-stamp-file directory)
            (insert "fixture-revision\n"))
          (backpack-sync-test--with-pele-state
           directory module nil
           (lambda ()
             (cl-letf (((symbol-function 'backpack--compile-pele-module)
                        (lambda (_source) (cl-incf build-count)))
                       ((symbol-function 'pele-download-module)
                        (lambda () (cl-incf download-count)))
                       ((symbol-function 'message) (lambda (&rest _args) nil)))
               (should (equal (backpack--pele-module-file-if-available directory)
                              module))
               (backpack--prepare-pele-module))))
          (should (= build-count 0))
          (should (= download-count 0)))
      (delete-directory directory t))))

(ert-deftest backpack-sync-pele-rebuilds-module-from-stale-source-revision ()
  "Rebuild a local module if its stamp does not match the Elpaca revision."
  (let* ((directory (make-temp-file "backpack-sync-pele-" t))
         (module (expand-file-name "pele-native.so" directory))
         (build-count 0)
         (download-count 0))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "Makefile" directory) (insert "all:\n"))
          (with-temp-file module (insert "stale native module"))
          (with-temp-file (backpack--pele-build-stamp-file directory)
            (insert "old-source-revision\n"))
          (backpack-sync-test--with-pele-state
           directory module nil
           (lambda ()
             (cl-letf (((symbol-function 'backpack--compile-pele-module)
                        (lambda (source-dir)
                          (cl-incf build-count)
                          (with-temp-file module (insert "current native module"))
                          (with-temp-file (backpack--pele-build-stamp-file source-dir)
                            (insert "fixture-revision\n"))))
                       ((symbol-function 'pele-download-module)
                        (lambda () (cl-incf download-count)))
                       ((symbol-function 'message) (lambda (&rest _args) nil)))
               (backpack--prepare-pele-module))))
          (should (= build-count 1))
          (should (= download-count 0)))
      (delete-directory directory t))))

(ert-deftest backpack-sync-pele-build-success-avoids-download ()
  "Build Pele when no module is present and do not download after success."
  (let* ((directory (make-temp-file "backpack-sync-pele-" t))
         (module (expand-file-name "pele-native.so" directory))
         (build-count 0)
         (download-count 0))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "Makefile" directory) (insert "all:\n"))
          (backpack-sync-test--with-pele-state
           directory module nil
           (lambda ()
             (cl-letf (((symbol-function 'backpack--compile-pele-module)
                        (lambda (source-dir)
                          (cl-incf build-count)
                          (with-temp-file module (insert "native module fixture"))
                          (with-temp-file (backpack--pele-build-stamp-file source-dir)
                            (insert "fixture-revision\n"))))
                       ((symbol-function 'pele-download-module)
                        (lambda () (cl-incf download-count)))
                       ((symbol-function 'message) (lambda (&rest _args) nil)))
               (backpack--prepare-pele-module))))
          (should (= build-count 1))
          (should (= download-count 0)))
      (delete-directory directory t))))

(ert-deftest backpack-sync-pele-build-failure-falls-back-off-nixos ()
  "Warn with compiler details and use Pele's prebuilt module off NixOS."
  (let* ((directory (make-temp-file "backpack-sync-pele-" t))
         (module (expand-file-name "prebuilt/pele-native.so" directory))
         (runtime-dir (expand-file-name "runtime" directory))
         (download-count 0)
         warning-text)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "Makefile" directory) (insert "all:\n"))
          (backpack-sync-test--with-pele-state
           directory module nil
           (lambda ()
             (cl-letf (((symbol-function 'backpack--compile-pele-module)
                        (lambda (_source) (error "synthetic compiler diagnostic")))
                       ((symbol-function 'pele-download-module)
                        (lambda ()
                          (cl-incf download-count)
                          (make-directory (file-name-directory module) t)
                          (with-temp-file module (insert "verified module fixture"))))
                       ((symbol-function 'display-warning)
                        (lambda (_type text &optional _level) (setq warning-text text)))
                       ((symbol-function 'message) (lambda (&rest _args) nil)))
               (backpack--prepare-pele-module)))
           runtime-dir)
          (should (= download-count 1))
          (should (string-match-p "synthetic compiler diagnostic" warning-text)))
      (delete-directory directory t))))

(ert-deftest backpack-sync-pele-build-failure-on-nixos-does-not-download ()
  "Fail with the compiler diagnostic and never download on NixOS."
  (let* ((directory (make-temp-file "backpack-sync-pele-" t))
         (module (expand-file-name "prebuilt/pele-native.so" directory))
         (runtime-dir (expand-file-name "runtime" directory))
         (download-count 0))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "Makefile" directory) (insert "all:\n"))
          (let ((err
                 (backpack-sync-test--with-pele-state
                  directory module t
                  (lambda ()
                    (cl-letf (((symbol-function 'backpack--compile-pele-module)
                               (lambda (_source) (error "synthetic Nix build failure")))
                              ((symbol-function 'pele-download-module)
                               (lambda () (cl-incf download-count)))
                              ((symbol-function 'display-warning)
                               (lambda (&rest _args) nil))
                              ((symbol-function 'message) (lambda (&rest _args) nil)))
                      (should-error (backpack--prepare-pele-module))))
                  runtime-dir)))
            (should (string-match-p "NixOS" (error-message-string err)))
            (should (string-match-p "synthetic Nix build failure" (error-message-string err))))
          (should (= download-count 0)))
      (delete-directory directory t))))

(ert-deftest backpack-sync-pele-provisioning-reports-fallback-failure ()
  "Include both build and download errors when neither path succeeds."
  (let* ((directory (make-temp-file "backpack-sync-pele-" t))
         (module (expand-file-name "prebuilt/pele-native.so" directory))
         (runtime-dir (expand-file-name "runtime" directory))
         err)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "Makefile" directory) (insert "all:\n"))
          (setq err
                (backpack-sync-test--with-pele-state
                 directory module nil
                 (lambda ()
                   (cl-letf (((symbol-function 'backpack--compile-pele-module)
                              (lambda (_source) (error "synthetic compile failure")))
                             ((symbol-function 'pele-download-module)
                              (lambda () (error "synthetic download failure")))
                             ((symbol-function 'display-warning)
                              (lambda (&rest _args) nil))
                             ((symbol-function 'message) (lambda (&rest _args) nil)))
                     (should-error (backpack--prepare-pele-module))))
                 runtime-dir))
          (should (string-match-p "synthetic compile failure" (error-message-string err)))
          (should (string-match-p "synthetic download failure" (error-message-string err))))
      (delete-directory directory t))))

(ert-deftest backpack-sync-pele-rejects-unsupported-platform-before-build ()
  "Fail before activating or building Pele on unsupported platforms."
  (let ((backpack--gear '(:editing mermaid))
        (system-type 'windows-nt)
        activate-count
        build-count)
    (cl-letf (((symbol-function 'backpack-sync-mode-p) (lambda () t))
              ((symbol-function 'backpack--activate-package)
               (lambda (_package) (cl-incf activate-count)))
              ((symbol-function 'backpack--compile-pele-module)
               (lambda (_source) (cl-incf build-count))))
      (should-error (backpack--prepare-pele-module))
      (should-not activate-count)
      (should-not build-count))))

(ert-deftest backpack-sync-pele-make-uses-current-emacs-and-captures-output ()
  "Pass the running Emacs executable to make and retain its output."
  (let* ((directory (make-temp-file "backpack-sync-pele-make-" t))
         (module-file-suffix ".so")
         (expected-emacs (expand-file-name invocation-name invocation-directory))
         observed-args result)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'process-file)
                     (lambda (program infile destination _display &rest args)
                       (should (equal program "make"))
                       (should-not infile)
                       (should (eq destination t))
                       (setq observed-args args)
                       (insert "mock make output")
                       0)))
            (setq result (backpack--run-pele-make directory)))
          (should (equal observed-args (list "-B" (concat "EMACS=" expected-emacs))))
          (should (eql (plist-get result :status) 0))
          (should (equal (plist-get result :output) "mock make output"))
          (should (equal (plist-get result :module)
                         (expand-file-name "pele-native.so" directory))))
      (delete-directory directory t))))

(defun backpack-sync-test--with-package-ref-state (function)
  "Call FUNCTION with a temporary Backpack package-ref state file."
  (let* ((directory (make-temp-file "backpack-sync-refs-" t))
         (backpack--package-ref-state-file
          (expand-file-name "package-refs.eld" directory)))
    (unwind-protect
        (funcall function)
      (delete-directory directory t))))

(defun backpack-sync-test--ref-queue (&rest package-specs)
  "Return an Elpaca queue containing PACKAGE-SPECS.
Each spec has the form (ID RECIPE STATUS)."
  (elpaca-q<-create
   :elpacas
   (mapcar (lambda (spec)
             (let* ((id (nth 0 spec))
                    (recipe (nth 1 spec))
                    (status (nth 2 spec))
                    (entry (elpaca<--create :id id
                                            :package (symbol-name id)
                                            :recipe recipe
                                            :status status)))
               (cons id entry)))
           package-specs)))

(ert-deftest backpack-sync-package-ref-first-install-records-nil-old-ref ()
  "Record a package's declared pin on its first successful install."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-a") finished)))
     (should (equal '((vterm :old-ref nil :ref "pin-a"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-same-pin-does-not-rotate-history ()
  "Keep the old-ref history unchanged when the declared pin is unchanged."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-a") finished)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-a") finished)))
     (should (equal '((vterm :old-ref nil :ref "pin-a"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-change-shifts-current-ref-to-old-ref ()
  "Move the installed pin to :old-ref when a new pin finishes installing."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-a") finished)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-b") finished)))
     (should (equal '((vterm :old-ref "pin-a" :ref "pin-b"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-failed-build-keeps-previous-pin ()
  "Do not record a new pin when Elpaca reports the package as failed."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-a") finished)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-b") failed)))
     (should (equal '((vterm :old-ref nil :ref "pin-a"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-batch-records-only-finished-pinned-packages ()
  "Record multiple successful refs in one queue and skip failures/unpinned entries."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-vterm") finished)
       '(pele (:ref "pin-pele") finished)
       '(failed-package (:ref "pin-failed") failed)
       '(unpinned (:branch "main") finished)))
     (should (equal '((pele :old-ref nil :ref "pin-pele")
                      (vterm :old-ref nil :ref "pin-vterm"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-missing-or-corrupt-file-is-recoverable ()
  "Treat a missing/corrupt state file as empty and rewrite it on success."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (should-not (backpack--package-ref-read-state))
     (with-temp-file backpack--package-ref-state-file
       (insert "("))
     (should-not (backpack--package-ref-read-state))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-a") finished)))
     (should (equal '((vterm :old-ref nil :ref "pin-a"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-recorder-registers-on-sync-queue-finish ()
  "Register the shared ref recorder as an Elpaca queue finish function in sync mode."
  (let ((elpaca-recipe-functions nil)
        (elpaca-queue-finish-functions nil))
    (unwind-protect
        (cl-letf (((symbol-function 'backpack-sync-mode-p) (lambda () t))
                  ((symbol-function 'backpack-normal-mode-p) (lambda () nil)))
          (backpack--setup-elpaca-for-mode)
          (should (memq #'backpack--package-ref-record-queue
                        elpaca-queue-finish-functions)))
      (advice-remove 'elpaca-activate #'backpack--elpaca-skip-activate-in-sync))))

(ert-deftest backpack-sync-package-ref-transition-uses-installed-ref-before-queue-commit ()
  "Expose the installed pin and recipe pin without committing prematurely."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-write-state
      '((vterm :old-ref "pin-zero" :ref "pin-a")))
     (let ((elpaca (elpaca<--create :id 'vterm
                                    :package "vterm"
                                    :recipe '(:ref "pin-b"))))
       (should (equal '(:old-ref "pin-a" :new-ref "pin-b")
                      (backpack--package-ref-transition elpaca))))
     (should (equal '((vterm :old-ref "pin-zero" :ref "pin-a"))
                    (backpack--package-ref-read-state)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(vterm (:ref "pin-b") finished)))
     (should (equal '((vterm :old-ref "pin-a" :ref "pin-b"))
                    (backpack--package-ref-read-state))))))

(provide 'backpack-sync-test)
;;; backpack-sync.el ends here
