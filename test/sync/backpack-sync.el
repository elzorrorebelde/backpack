;;; backpack-sync.el --- Tests for Backpack package synchronization  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (expand-file-name "lisp" backpack-emacs-dir))
(add-to-list 'load-path (expand-file-name "base-packages/elpaca" backpack-emacs-dir))
(require 'backpack-sync)
(require 'elpaca)

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

(provide 'backpack-sync-test)
;;; backpack-sync.el ends here
