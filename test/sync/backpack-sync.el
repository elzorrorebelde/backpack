;;; backpack-sync.el --- Tests for Backpack package synchronization  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (expand-file-name "lisp" backpack-emacs-dir))
(add-to-list 'load-path (expand-file-name "base-packages/leaf.el" backpack-emacs-dir))
(add-to-list 'load-path (expand-file-name "base-packages/leaf-keywords.el" backpack-emacs-dir))
(add-to-list 'load-path (expand-file-name "base-packages/elpaca" backpack-emacs-dir))
(require 'leaf)
(require 'leaf-keywords)
(leaf-keywords-init)
(plist-put leaf-keywords :doctor '`(,@leaf--body))
(plist-put leaf-keywords :fonts '`(,@leaf--body))
(setq leaf-alias-keyword-alist '((:ensure . :elpaca)))
(require 'backpack-pouch)
(require 'backpack-sync)
(backpack--register-native-module-leaf-keyword)
(require 'elpaca)

(defvar backpack-sync-test--native-contexts nil)

(defun backpack-sync-test--native-builder (context)
  "Record CONTEXT to prove Backpack invokes the registered builder."
  (push context backpack-sync-test--native-contexts))

(defun backpack-sync-test--native-builder-fails (context)
  "Signal a synthetic native build error for CONTEXT."
  (error "synthetic native build failure for %s"
         (plist-get context :package)))

(defun backpack-sync-test--native-elpaca-entry (package source-dir build-dir ref)
  "Create a minimal Elpaca entry for PACKAGE and REF."
  (elpaca<--create :id package
                   :package (symbol-name package)
                   :source-dir source-dir
                   :build-dir build-dir
                   :recipe (list :package (symbol-name package) :ref ref)))

(defun backpack-sync-test--with-elpaca-process-file (directory)
  "Create the file used to validate Elpaca source DIRECTORY."
  (with-temp-file (expand-file-name "elpaca-process.el" directory)
    (insert ";;; test fixture\n")))

(ert-deftest backpack-sync-native-module-leaf-keyword-registers-before-elpaca ()
  "Expand the keyword into a declaration before Elpaca defers package forms."
  (let* ((backpack--native-module-builders nil)
         (backpack-sync-test--native-contexts nil)
         (expanded (macroexpand
                    '(leaf native-demo
                       :ensure (native-demo :ref "pin-a")
                       :native-module backpack-sync-test--native-builder)))
         (leaf-protect (nth 3 expanded))
         (registration (nth 2 leaf-protect))
         (elpaca-form (nth 3 leaf-protect))
         (expanded-string (prin1-to-string expanded)))
    (should (eq (car registration) 'backpack--native-module-register))
    (should (eq (car elpaca-form) 'elpaca))
    (should (< (string-match "backpack--native-module-register" expanded-string)
               (string-match "(elpaca (native-demo" expanded-string)))
    (eval registration)
    (should (equal '((native-demo . backpack-sync-test--native-builder))
                   backpack--native-module-builders))
    (should-not backpack-sync-test--native-contexts)))

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

(ert-deftest backpack-sync-native-module-runner-builds-context-and-continues-per-entry ()
  "Provide stable package context and run builders on each ensure pass."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (let* ((source-dir (make-temp-file "backpack-native-source-" t))
            (build-dir (make-temp-file "backpack-native-build-" t))
            (backpack--native-module-builders
             '((native-demo . backpack-sync-test--native-builder)))
            (backpack-sync-test--native-contexts nil)
            (module-file-suffix ".so")
            (continue-count 0)
            (elpaca (backpack-sync-test--native-elpaca-entry
                     'native-demo source-dir build-dir "pin-b")))
       (unwind-protect
           (progn
             (backpack--package-ref-write-state
              '((native-demo :old-ref "pin-zero" :ref "pin-a")))
             (cl-letf (((symbol-function 'elpaca-note) (lambda (&rest _args) nil))
                       ((symbol-function 'elpaca-continue)
                        (lambda (_entry) (cl-incf continue-count))))
               (backpack--native-module-build-step elpaca)
               (backpack--native-module-build-step elpaca))
             (should (= continue-count 2))
             (should (= (length backpack-sync-test--native-contexts) 2))
             (let ((context (car backpack-sync-test--native-contexts)))
               (should (eq (plist-get context :package) 'native-demo))
               (should (equal (plist-get context :source-dir) source-dir))
               (should (equal (plist-get context :build-dir) build-dir))
               (should (equal (plist-get context :module-file-suffix) ".so"))
               (should (equal (plist-get context :emacs-version) emacs-version))
               (should (eq (plist-get context :system-type) system-type))
               (should (equal (plist-get context :old-ref) "pin-a"))
               (should (equal (plist-get context :new-ref) "pin-b"))))
         (delete-directory source-dir t)
         (delete-directory build-dir t))))))

(ert-deftest backpack-sync-native-module-builder-runs-while-activation-is-skipped ()
  "Skip package activation during sync and still run the native builder."
  (let* ((source-dir (make-temp-file "backpack-native-source-" t))
         (build-dir (make-temp-file "backpack-native-build-" t))
         (backpack--native-module-builders
          '((native-demo . backpack-sync-test--native-builder)))
         (backpack-sync-test--native-contexts nil)
         (module-file-suffix ".so")
         (continue-count 0)
         activation-called
         (elpaca (backpack-sync-test--native-elpaca-entry
                  'native-demo source-dir build-dir "pin-a")))
    (unwind-protect
        (cl-letf (((symbol-function 'backpack-sync-mode-p) (lambda () t))
                  ((symbol-function 'elpaca-note) (lambda (&rest _args) nil))
                  ((symbol-function 'elpaca-continue)
                   (lambda (_entry) (cl-incf continue-count))))
          (backpack--elpaca-skip-activate-in-sync
           (lambda (_entry) (setq activation-called t)) elpaca)
          (backpack--native-module-build-step elpaca)
          (should-not activation-called)
          (should (= continue-count 2))
          (should (= (length backpack-sync-test--native-contexts) 1))
          (should (eq (plist-get (car backpack-sync-test--native-contexts) :package)
                      'native-demo)))
      (delete-directory source-dir t)
      (delete-directory build-dir t))))

(ert-deftest backpack-sync-native-module-runner-fails-without-modules-or-on-builder-error ()
  "Reject missing module support and propagate builder errors without continuing."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (let* ((source-dir (make-temp-file "backpack-native-source-" t))
            (build-dir (make-temp-file "backpack-native-build-" t))
            (backpack-sync-test--native-contexts nil)
            (continue-count 0)
            (elpaca (backpack-sync-test--native-elpaca-entry
                     'native-demo source-dir build-dir "pin-a")))
       (unwind-protect
           (progn
             (let ((backpack--native-module-builders
                    '((native-demo . backpack-sync-test--native-builder)))
                   (module-file-suffix nil))
               (cl-letf (((symbol-function 'elpaca-note) (lambda (&rest _args) nil))
                         ((symbol-function 'elpaca-continue)
                          (lambda (_entry) (cl-incf continue-count))))
                 (should-error (backpack--native-module-build-step elpaca)
                               :type 'error)
                 (should-not backpack-sync-test--native-contexts)
                 (should (= continue-count 0))))
             (let ((backpack--native-module-builders
                    '((native-demo . backpack-sync-test--native-builder-fails)))
                   (module-file-suffix ".so"))
               (cl-letf (((symbol-function 'elpaca-note) (lambda (&rest _args) nil))
                         ((symbol-function 'elpaca-continue)
                          (lambda (_entry) (cl-incf continue-count))))
                 (should-error (backpack--native-module-build-step elpaca)
                               :type 'error)
                 (should (= continue-count 0)))))
         (delete-directory source-dir t)
         (delete-directory build-dir t))))))

(ert-deftest backpack-sync-native-module-error-fails-owning-elpaca-entry ()
  "An error from the builder is reported against its package's Elpaca entry."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (let* ((source-dir (make-temp-file "backpack-native-source-" t))
            (build-dir (make-temp-file "backpack-native-build-" t))
            (entry (elpaca<--create
                    :id 'native-demo :package "native-demo"
                    :source-dir source-dir :build-dir build-dir
                    :recipe '(:package "native-demo" :ref "pin-a")
                    :build-steps (list #'backpack--native-module-build-step)
                    :status 'queued))
            (queue (elpaca-q<-create :elpacas (list (cons 'native-demo entry))))
            (elpaca--queues (list queue))
            (elpaca--status-subscribers (make-hash-table :test #'eq))
            (backpack--native-module-builders
             '((native-demo . backpack-sync-test--native-builder-fails)))
            (module-file-suffix ".so")
            failed-entry)
       (unwind-protect
           (progn
             (cl-letf (((symbol-function 'elpaca-note) (lambda (&rest _args) nil))
                       ((symbol-function 'elpaca--fail)
                        (lambda (failed reason)
                          (setq failed-entry failed)
                          (setf (elpaca<-status failed) 'failed))))
               (elpaca--process entry))
             (should (eq failed-entry entry))
             (should (eq (elpaca<-status entry) 'failed)))
         (delete-directory source-dir t)
         (delete-directory build-dir t))))))

(ert-deftest backpack-process-call-wraps-elpaca-process-api ()
  "Expose a normalized Backpack process result without leaking Elpaca's API."
  (let ((directory (make-temp-file "backpack-process-call-" t))
        observed)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'elpaca-process-call)
                     (lambda (program &rest args)
                       (setq observed (list default-directory program args))
                       (list 0 "stdout" "stderr"))))
            (should (equal '(:status 0 :stdout "stdout" :stderr "stderr")
                           (backpack-process-call directory "make" "target")))
            (should (equal (list directory "make" '("target")) observed)))
          (cl-letf (((symbol-function 'elpaca-process-call)
                     (lambda (&rest _args) (error "synthetic process start failure"))))
            (let ((result (backpack-process-call directory "missing-tool")))
              (should-not (plist-get result :status))
              (should (string-match-p "synthetic process start failure"
                                      (plist-get result :stderr))))))
      (delete-directory directory t))))

(ert-deftest backpack-sync-native-module-step-preserves-build-rules-and-runs-last ()
  "Append the native runner after custom steps in normal and pre-built lists."
  (let ((backpack--native-module-builders
         '((native-demo . backpack-sync-test--native-builder)))
        (recipe '(:package "native-demo"
                  :ref "pin-native-demo"
                  :build (:before elpaca-build-link
                                  backpack-sync-test--existing-build-step))))
    (cl-letf (((symbol-function 'backpack-sync-mode-p) (lambda () t))
              ((symbol-function 'backpack--ref-needs-update-p)
               (lambda (&rest _args) nil)))
      (let* ((modified (backpack--recipe-force-rebuild-on-ref-change recipe))
             (rules (plist-get modified :build))
             (normal-steps (elpaca-substitute-build-steps
                            elpaca-default-build-steps rules))
             (pre-built-steps (elpaca-substitute-build-steps
                               elpaca--pre-built-steps rules)))
        (should (memq 'backpack-sync-test--existing-build-step normal-steps))
        (should (eq (car (last normal-steps))
                    'backpack--native-module-build-step))
        (should (eq (car (last pre-built-steps))
                    'backpack--native-module-build-step)))
      (cl-letf (((symbol-function 'backpack--ref-needs-update-p)
                 (lambda (&rest _args) t)))
        (let* ((modified (backpack--recipe-force-rebuild-on-ref-change recipe))
               (rules (plist-get modified :build))
               (steps (elpaca-substitute-build-steps
                       elpaca-default-build-steps rules)))
          (should (memq 'elpaca-git--fetch steps))
          (should (memq 'backpack-sync-test--existing-build-step steps))
          (should (eq (car (last steps))
                      'backpack--native-module-build-step))))
      (cl-letf (((symbol-function 'backpack-sync-mode-p) (lambda () nil)))
        (should-not (backpack--recipe-force-rebuild-on-ref-change recipe))))))

(ert-deftest backpack-sync-package-ref-first-install-records-nil-old-ref ()
  "Record a package's declared pin on its first successful install."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-a") finished)))
     (should (equal '((test-package :old-ref nil :ref "pin-a"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-same-pin-does-not-rotate-history ()
  "Keep the old-ref history unchanged when the declared pin is unchanged."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-a") finished)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-a") finished)))
     (should (equal '((test-package :old-ref nil :ref "pin-a"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-change-shifts-current-ref-to-old-ref ()
  "Move the installed pin to :old-ref when a new pin finishes installing."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-a") finished)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-b") finished)))
     (should (equal '((test-package :old-ref "pin-a" :ref "pin-b"))
                    (backpack--package-ref-read-state))))))

(ert-deftest backpack-sync-package-ref-failed-build-keeps-previous-pin ()
  "Do not record a new pin when Elpaca reports the package as failed."
  (backpack-sync-test--with-package-ref-state
   (lambda ()
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-a") finished)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-b") failed)))
     (should (equal '((test-package :old-ref nil :ref "pin-a"))
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
       '(test-package (:ref "pin-a") finished)))
     (should (equal '((test-package :old-ref nil :ref "pin-a"))
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
      '((test-package :old-ref "pin-zero" :ref "pin-a")))
     (let ((elpaca (elpaca<--create :id 'test-package
                                    :package "test-package"
                                    :recipe '(:ref "pin-b"))))
       (should (equal '(:old-ref "pin-a" :new-ref "pin-b")
                      (backpack--package-ref-transition elpaca))))
     (should (equal '((test-package :old-ref "pin-zero" :ref "pin-a"))
                    (backpack--package-ref-read-state)))
     (backpack--package-ref-record-queue
      (backpack-sync-test--ref-queue
       '(test-package (:ref "pin-b") finished)))
     (should (equal '((test-package :old-ref "pin-a" :ref "pin-b"))
                    (backpack--package-ref-read-state))))))

(provide 'backpack-sync-test)
;;; backpack-sync.el ends here
