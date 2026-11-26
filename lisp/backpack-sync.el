;;; backpack-sync.el --- Package synchronisation (build/activate) for Backpack  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jorge Javier Araya Navarro and Backpack contributors

;; Author: Jorge Javier Araya Navarro <jorge@esavara.cr>
;; URL: https://github.com/shackra/backpack

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Elpaca install/build/ensure, mode-based setup, sync-mode form
;; filtering, and gc-mode advice.  `backpack ensure' and `backpack gc'
;; both depend on this module.

;;; Code:

;;; Variables defined in backpack.el (declared here for byte-compiler)

(defvar backpack-mode 'normal
  "Current operating mode for Backpack. Set before this file is loaded.")

(defvar backpack-emacs-dir nil
  "The path of the currently loaded Emacs configuration.")

(defvar backpack-nonessential-dir nil
  "Location where Backpack stores nonessential files.")

(defvar backpack-user-dir nil
  "Location of the user's private configuration.")

(defvar backpack--package-ref-state-file nil
  "Single `.eld' state file containing refs for all Elpaca packages.")

(defvar backpack--native-module-builders nil
  "Alist of (PACKAGE . BUILDER) declarations from `:native-module'.")

(defvar leaf-keywords)
(declare-function leaf-insert-list-before "leaf-keywords")

(require 'backpack-platform)
(require 'subr-x)

(declare-function backpack-sync-mode-p "backpack")
(declare-function backpack-normal-mode-p "backpack")
(declare-function backpack-gc-mode-p "backpack-gc")
(declare-function backpack--gc-collect-package "backpack-gc")
(declare-function backpack-load-gear-files "backpack")

;;; Packages that should be activated even in sync mode

(defvar backpack--enable-on-sync-packages nil
  "List of package symbols that should be activated even in sync mode.
This is useful for packages like treesit-auto that need to be active
during sync to install tree-sitter grammars.")

(defmacro backpack-enable-on-sync! (&rest packages)
  "Mark PACKAGES to be activated even in sync mode.
Call this macro BEFORE the leaf declaration for packages that need
to be active during sync (e.g., for installing tree-sitter grammars).

Example:
  (backpack-enable-on-sync! treesit-auto)
  (leaf treesit-auto
    :ensure t
    :config ...)"
  `(dolist (pkg ',packages)
     (cl-pushnew pkg backpack--enable-on-sync-packages)))

(defun backpack--activate-package (package-name)
  "Manually activate PACKAGE-NAME by loading its autoloads.
This is used in sync mode for packages marked with `backpack-enable-on-sync!'."
  (let* ((build-dir (expand-file-name (symbol-name package-name) elpaca-builds-directory))
         (autoloads-file (expand-file-name
                          (format "%s-autoloads.el" package-name)
                          build-dir)))
    (if (not (file-exists-p build-dir))
        (message "Backpack: WARNING - build dir for %s does not exist" package-name)
      (add-to-list 'load-path build-dir)
      (if (not (file-exists-p autoloads-file))
          (message "Backpack: WARNING - autoloads for %s not found" package-name)
        (load autoloads-file nil t)
        (condition-case err
            (require package-name)
          (error
           (message "Backpack: Failed to require %s: %S" package-name err)))))))

(defun backpack--activate-enable-on-sync-packages ()
  "Activate all packages marked with `backpack-enable-on-sync!'.
This should be called after packages are built but before their config runs."
  (dolist (pkg backpack--enable-on-sync-packages)
    (message "Backpack: Activating package for sync: %s" pkg)
    (backpack--activate-package pkg)))

;;; Build steps for each mode

(defun backpack--elpaca-skip-activate-in-sync (orig-fn e)
  "Advice to skip `elpaca-activate' during sync mode (`backpack ensure').
Packages are built but not activated in sync mode; activation happens
in normal mode.  Replaces the old `backpack--sync-build-steps' list, which
excluded `elpaca--activate-package' in the pre-generic elpaca API."
  (if (backpack-sync-mode-p)
      (elpaca-continue e)
    (funcall orig-fn e)))

;;; Elpaca installation from base-packages

(defvar elpaca-installer-version 0.12)
(defvar elpaca-directory (expand-file-name "elpaca/" backpack-nonessential-dir))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-sources-directory (expand-file-name "sources" elpaca-directory))

;; Location of elpaca in base-packages (bundled with Backpack)
(defvar backpack--elpaca-source-dir
  (expand-file-name "base-packages/elpaca/" backpack-emacs-dir)
  "Location of the bundled elpaca source in base-packages.")

(defun backpack--copy-directory-recursively (source dest)
  "Copy SOURCE directory recursively to DEST using pure Emacs Lisp.
This is platform-agnostic and doesn't rely on external tools."
  (unless (file-exists-p dest)
    (make-directory dest t))
  (dolist (file (directory-files source t "^[^.]"))
    (let ((dest-file (expand-file-name (file-name-nondirectory file) dest)))
      (cond
       ((file-directory-p file)
        (backpack--copy-directory-recursively file dest-file))
       (t
        (copy-file file dest-file t))))))

(defun backpack--elpaca-repo-dir ()
  "Return the elpaca source checkout directory path."
  (expand-file-name "elpaca/" elpaca-sources-directory))

(defun backpack--elpaca-build-dir ()
  "Return the elpaca build directory path."
  (expand-file-name "elpaca/" elpaca-builds-directory))

(defun backpack--org-build-elpaca-dir ()
  "Return a usable Elpaca source directory for Org's build helper."
  (let* ((entry (and (featurep 'elpaca) (elpaca-get 'elpaca)))
         (entry-dir (when entry
                      (condition-case nil
                          (elpaca<-source-dir entry)
                        (error nil))))
         (fallback-dir (backpack--elpaca-repo-dir)))
    (or (and entry-dir
             (file-readable-p (expand-file-name "elpaca-process.el" entry-dir))
             entry-dir)
        (and (file-readable-p (expand-file-name "elpaca-process.el" fallback-dir))
             fallback-dir)
        (error "Backpack: cannot locate Elpaca's elpaca-process.el for the Org build"))))

(defun backpack--elpaca-menu-org-build-around (orig-fn e)
  "Call ORIG-FN for E with a usable Elpaca source entry.
The Org menu build helper only reads `elpaca<-source-dir' from the
entry returned by `elpaca-get' for `elpaca'."
  (let* ((source-dir (backpack--org-build-elpaca-dir))
         (entry (elpaca<--create :id 'elpaca :package "elpaca"
                                 :source-dir source-dir))
         (original-get (symbol-function 'elpaca-get)))
    (cl-letf (((symbol-function 'elpaca-get)
               (lambda (id)
                 (if (eq id 'elpaca)
                     entry
                   (funcall original-get id)))))
      (funcall orig-fn e))))

(defun backpack--elpaca-installed-p ()
  "Return non-nil if elpaca is already installed in the expected location."
  (let ((repo-dir (backpack--elpaca-repo-dir)))
    (and (file-exists-p repo-dir)
         (file-exists-p (expand-file-name "elpaca.el" repo-dir)))))

(defun backpack--install-elpaca-from-base-packages ()
  "Copy elpaca from base-packages to elpaca-sources-directory.
This uses the bundled elpaca instead of cloning from the internet."
  (let ((repo-dir (backpack--elpaca-repo-dir)))
    (message "Backpack: Installing elpaca from base-packages...")
    (make-directory elpaca-sources-directory t)
    (backpack--copy-directory-recursively backpack--elpaca-source-dir repo-dir)
    (message "Backpack: Elpaca source copied to %s" repo-dir)))

(defun backpack--build-elpaca ()
  "Build elpaca: byte-compile and generate autoloads.
This replicates what the elpaca installer does but without cloning."
  (let* ((repo-dir (backpack--elpaca-repo-dir))
         (build-dir (backpack--elpaca-build-dir))
         (default-directory repo-dir))
    (message "Backpack: Building elpaca...")
    (let ((emacs-exe (concat invocation-directory invocation-name)))
      (call-process emacs-exe nil nil nil
                    "-Q" "-L" "." "--batch"
                    "--eval" "(byte-recompile-directory \".\" 0 'force)"))
    (add-to-list 'load-path repo-dir)
    (require 'elpaca)
    (elpaca-generate-autoloads "elpaca" repo-dir)
    (make-directory build-dir t)
    (dolist (file (directory-files repo-dir t "\\.elc?\\'"))
      (let ((dest (expand-file-name (file-name-nondirectory file) build-dir)))
        (unless (file-exists-p dest)
          (if backpack--system-windows-p
              (copy-file file dest t)
            (if (fboundp 'make-symbolic-link)
                (condition-case nil
                    (make-symbolic-link file dest)
                  (error (copy-file file dest t)))
              (copy-file file dest t))))))
    (message "Backpack: Elpaca built successfully")))

(defun backpack--ensure-elpaca ()
  "Ensure elpaca is installed and built from base-packages.
In sync mode, this will copy and build elpaca if needed.
In normal mode, this just loads elpaca if it's already built."
  (let ((repo-dir (backpack--elpaca-repo-dir))
        (build-dir (backpack--elpaca-build-dir)))
    (cond
     ((and (file-exists-p build-dir)
           (file-exists-p (expand-file-name "elpaca-autoloads.el" build-dir)))
      (add-to-list 'load-path build-dir)
      (require 'elpaca-autoloads nil t))
     ((and (backpack-sync-mode-p)
           (backpack--elpaca-installed-p))
      (backpack--build-elpaca)
      (add-to-list 'load-path build-dir)
      (require 'elpaca-autoloads nil t))
     ((backpack-sync-mode-p)
      (backpack--install-elpaca-from-base-packages)
      (backpack--build-elpaca)
      (add-to-list 'load-path build-dir)
      (require 'elpaca-autoloads nil t))
     ((file-exists-p repo-dir)
      (add-to-list 'load-path repo-dir)
      (when (file-exists-p (expand-file-name "elpaca-autoloads.el" repo-dir))
        (load (expand-file-name "elpaca-autoloads.el" repo-dir) nil t)))
     (t
      (when (backpack-normal-mode-p)
        (display-warning 'backpack
                         "Elpaca is not installed. Run 'backpack ensure' first."
                         :error))))))

;;; Native module builder declarations

(defun backpack--register-native-module-leaf-keyword ()
  "Register Backpack's `:native-module' Leaf keyword before `:elpaca'."
  (unless (plist-member leaf-keywords :native-module)
    (setq leaf-keywords
          (leaf-insert-list-before
           leaf-keywords :elpaca
           (list :native-module
                 '`((backpack--native-module-register ',leaf--name
                                                     ',leaf--value
                                                     ',leaf--raw)
                    ,@leaf--body))))))

(defun backpack--native-module-register (leaf-name callback-values leaf-raw)
  "Register the single CALLBACK-VALUES builder for LEAF-NAME.
LEAF-RAW is Leaf's normalized full keyword plist; it must contain exactly
one `:elpaca' recipe so the builder can be associated with its package.
This function only records the declaration; it never invokes the builder."
  (let* ((orders (plist-get leaf-raw :elpaca))
         (order (and (proper-list-p orders)
                     (= (length orders) 1)
                     (car orders)))
         (package (cond ((symbolp order) order)
                        ((consp order) (car-safe order))))
         (builder (and (proper-list-p callback-values)
                       (= (length callback-values) 1)
                       (car callback-values))))
    (unless (and package (symbolp package) (symbolp builder) builder)
      (error "Backpack :native-module in leaf %s requires one callback and exactly one :ensure package"
             leaf-name))
    (let ((registered (assq package backpack--native-module-builders)))
      (cond
       ((null registered)
        (push (cons package builder) backpack--native-module-builders))
       ((eq builder (cdr registered))
        nil)
       (t
        (error "Backpack :native-module has multiple builders for package %s"
               package))))))

;;; Installed package ref registry

(defun backpack--package-ref-read-state ()
  "Read the single package-ref state file, or return nil when absent/invalid."
  (when (and backpack--package-ref-state-file
             (file-exists-p backpack--package-ref-state-file))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents backpack--package-ref-state-file)
          (let ((state (read (current-buffer))))
            (when (and (proper-list-p state)
                       (cl-every (lambda (entry)
                                   (and (consp entry)
                                        (symbolp (car entry))
                                        (listp (cdr entry))))
                                 state))
              state)))
      (error nil))))

(defun backpack--package-ref-transition (elpaca)
  "Return installed and requested refs for ELPACA before queue commit.
The old ref comes from Backpack's state; the new ref comes from ELPACA's
current recipe.  This is read-only: the queue finish hook commits the new
ref only after the package succeeds."
  (let* ((package (elpaca<-id elpaca))
         (entry (assq package (backpack--package-ref-read-state)))
         (installed-ref (plist-get (cdr entry) :ref))
         (new-ref (plist-get (elpaca<-recipe elpaca) :ref)))
    (list :old-ref installed-ref :new-ref new-ref)))

(defun backpack--package-ref-write-state (state)
  "Write all package refs in STATE to Backpack's single state file."
  (unless backpack--package-ref-state-file
    (error "Backpack package ref state file is not configured"))
  (make-directory (file-name-directory backpack--package-ref-state-file) t)
  (with-temp-file backpack--package-ref-state-file
    (insert ";; -*- lisp-data -*-\n")
    (insert ";; Declared package refs tracked by Backpack.\n")
    (insert ";; Auto-generated -- do not edit.\n")
    (prin1 state (current-buffer))
    (insert "\n")))

(defun backpack--package-ref-record-queue (queue)
  "Record declared refs for successfully finished packages in QUEUE.
Update the shared state file once after processing the whole queue."
  (let ((state (backpack--package-ref-read-state))
        changed)
    (dolist (entry (elpaca-q<-elpacas queue))
      (let* ((elpaca (cdr entry))
             (package (elpaca<-id elpaca))
             (ref (plist-get (elpaca<-recipe elpaca) :ref)))
        (when (and (eq (elpaca<-status elpaca) 'finished)
                   (symbolp package)
                   (stringp ref)
                   (not (string-empty-p ref)))
          (let* ((record (assq package state))
                 (installed-ref (plist-get (cdr record) :ref)))
            (unless (equal ref installed-ref)
              (if record
                  (setcdr record (list :old-ref installed-ref :ref ref))
                (push (cons package (list :old-ref nil :ref ref)) state))
              (setq changed t))))))
    (when changed
      (backpack--package-ref-write-state state))))

(defun backpack--native-module-builder-for-recipe (recipe)
  "Return the registered native module builder for RECIPE, if any."
  (let ((package (plist-get recipe :package)))
    (when package
      (cdr (assq (if (symbolp package) package (intern package))
                 backpack--native-module-builders)))))

(defun backpack--native-module-build-step (elpaca)
  "Run ELPACA's registered native module builder as its final build step."
  (let* ((package (elpaca<-id elpaca))
         (builder (cdr (assq package backpack--native-module-builders))))
    (unless builder
      (error "No :native-module builder registered for package %s" package))
    (unless module-file-suffix
      (error "Package %s declares a native module, but this Emacs lacks dynamic module support"
             package))
    (unless (functionp builder)
      (error "Native module builder %S for package %s is not defined"
             builder package))
    (let ((context
           (append (list :package package
                         :source-dir (elpaca<-source-dir elpaca)
                         :build-dir (elpaca<-build-dir elpaca)
                         :module-file-suffix module-file-suffix
                         :emacs-version emacs-version
                         :system-type system-type)
                   (backpack--package-ref-transition elpaca))))
      (elpaca-note elpaca (format "Running native module builder %s" builder))
      (funcall builder context))
    (elpaca-continue elpaca)))

(defun backpack-process-call (directory program &rest args)
  "Run PROGRAM with ARGS in DIRECTORY and return a result plist.
The result has :status, :stdout, and :stderr keys.  This is Backpack's
process facade for package builders; gears should not call Elpaca's process
functions directly."
  (unless (and (stringp directory) (file-directory-p directory))
    (error "Backpack process directory does not exist: %s" directory))
  (let ((default-directory directory))
    (condition-case err
        (let* ((result (apply #'elpaca-process-call program args))
               (status (car-safe result)))
          (if (numberp status)
              (list :status status
                    :stdout (or (nth 1 result) "")
                    :stderr (or (nth 2 result) ""))
            (list :status nil :stdout "" :stderr (format "%S" result))))
      (error
       (list :status nil :stdout ""
             :stderr (error-message-string err))))))

;;; Package ref change detection

(defun backpack--ref-needs-update-p (repo-dir requested-ref)
  "Return non-nil if REPO-DIR's HEAD doesn't match REQUESTED-REF.
REQUESTED-REF can be a commit hash, tag, or branch name.
Uses `elpaca-process-call' for cross-platform git invocation."
  (when (and repo-dir requested-ref (file-exists-p repo-dir))
    (let ((default-directory repo-dir))
      (condition-case nil
          (let ((current-rev (string-trim
                              (cadr (elpaca-process-call "git" "rev-parse" "HEAD")))))
            (not (or (string-prefix-p requested-ref current-rev)
                     (string-prefix-p current-rev requested-ref)
                     (let ((resolved (elpaca-process-call "git" "rev-parse" requested-ref)))
                       (and (eq (car resolved) 0)
                            (string= current-rev
                                     (string-trim (cadr resolved))))))))
        (error t)))))

(defun backpack--recipe-force-rebuild-on-ref-change (recipe)
  "Modify RECIPE for ref changes and its registered native builder.
In sync mode, force a source/build refresh when the requested :ref differs
from the checked out commit.  If RECIPE has a `:native-module' builder,
append its runner as a `:last' substitution so it runs for both new and
pre-built packages.  Preserve recipe-declared :build rules in either case."
  (when (backpack-sync-mode-p)
    (let* ((package (plist-get recipe :package))
           (requested-ref (plist-get recipe :ref))
           (declared-build (plist-get recipe :build))
           (native-builder (backpack--native-module-builder-for-recipe recipe))
           (repo-dir (when package
                       (or (when (and (plist-get recipe :repo)
                                      (fboundp 'elpaca-git-repo-dir))
                             (condition-case nil
                                 (elpaca-git-repo-dir recipe)
                               (error nil)))
                           (expand-file-name package elpaca-sources-directory))))
           (ref-changed (and requested-ref
                             (backpack--ref-needs-update-p repo-dir requested-ref)))
           rules)
      (when ref-changed
        (message "Backpack: Ref changed for '%s', will fetch and rebuild" package)
        (setq rules (list '(:not elpaca-queue-dependencies elpaca-activate)
                          '(:first elpaca-git--fetch
                                   elpaca-git--checkout-ref
                                   elpaca-queue-dependencies
                                   elpaca-check-version
                                   elpaca-build-link
                                   elpaca-build-autoloads
                                   elpaca-build-compile
                                   elpaca-build-docs))))
      ;; If we modify :build, carry through the recipe's own rules, including
      ;; native/external build steps such as pdf-tools' epdfinfo compilation.
      (when (and declared-build (or ref-changed native-builder))
        (setq rules
              (append rules
                      (if (keywordp (car-safe declared-build))
                          (list declared-build)
                        declared-build))))
      (when native-builder
        (setq rules (append rules
                            '((:last backpack--native-module-build-step)))))
      (when rules `(:build ,rules)))))

(defun backpack--recipe-skip-unbuilt-in-normal-mode (recipe)
  "Modify RECIPE to skip building in normal mode if package isn't already built.
Returns a plist with :build set to activation-only steps for unbuilt packages."
  (when (backpack-normal-mode-p)
    (let* ((package (plist-get recipe :package))
           (build-dir (when package
                        (expand-file-name package elpaca-builds-directory)))
           (builtp (and build-dir (file-exists-p build-dir))))
      (unless builtp
        (message "Backpack: Package '%s' is not installed. Run 'backpack ensure'." package)
        '(:build nil)))))

;;; Elpaca mode configuration

(defun backpack--setup-elpaca-for-mode ()
  "Configure elpaca based on `backpack-mode'."
  (when (featurep 'elpaca)
    (cond
     ((backpack-sync-mode-p)
      (advice-add 'elpaca-activate :around #'backpack--elpaca-skip-activate-in-sync)
      (add-to-list 'elpaca-recipe-functions #'backpack--recipe-force-rebuild-on-ref-change)
      (add-hook 'elpaca-queue-finish-functions #'backpack--package-ref-record-queue))
     ((backpack-normal-mode-p)
      (add-to-list 'elpaca-recipe-functions #'backpack--recipe-skip-unbuilt-in-normal-mode)))))

(defun backpack--packages-need-sync-p ()
  "Return non-nil if packages need synchronization (installation/building).
This checks if the elpaca builds directory exists and has content."
  (not (and (file-exists-p elpaca-builds-directory)
            (directory-files elpaca-builds-directory nil "^[^.]" t))))

(defun backpack--check-packages-installed ()
  "Check if packages are installed, warn user if sync is needed."
  (when (and (backpack-normal-mode-p)
             (backpack--packages-need-sync-p))
    (display-warning
     'backpack
     "Packages are not installed. Run 'backpack ensure' to install them."
     :warning)))

(defun backpack--activate-packages ()
  "Activate all queued packages without attempting installation.
Used in normal mode when packages are already built."
  (when (and (backpack-normal-mode-p) (featurep 'elpaca))
    (backpack--check-packages-installed)
    (elpaca-process-queues)))

(defun backpack--sync-packages ()
  "Install and build all queued packages without activation.
Used in sync mode (`backpack ensure')."
  (when (and (backpack-sync-mode-p) (featurep 'elpaca))
    (backpack--setup-elpaca-for-mode)
    (elpaca-process-queues)))

;;; Elpaca advice hooks (applied after elpaca loads)

(with-eval-after-load 'elpaca-menu-org
  (unless (advice-member-p #'backpack--elpaca-menu-org-build-around
                           'elpaca-menu-org--build)
    (advice-add 'elpaca-menu-org--build :around
                #'backpack--elpaca-menu-org-build-around)))

(with-eval-after-load 'elpaca
  (backpack--setup-elpaca-for-mode)

  (defun backpack--elpaca-gc-advice (orig-fn order &rest body)
    "Advice for `elpaca' macro to collect package names during gc mode.
In gc mode, just collect the package name without actually queuing."
    (let* ((order-val (if (and (consp order) (eq (car order) 'quote))
                          (cadr order)
                        order))
           (pkg-name (cond
                      ((symbolp order-val) order-val)
                      ((consp order-val) (car order-val))
                      (t nil))))
      (if (backpack-gc-mode-p)
          (when pkg-name
            (backpack--gc-collect-package pkg-name)
            nil)
        (apply orig-fn order body))))

  (advice-add 'elpaca--expand-declaration :around #'backpack--elpaca-gc-advice)

  (defun backpack--elpaca-skip-forms-in-sync-mode (orig-fn q)
    "Advice to skip running deferred forms in sync mode.
Packages in `backpack--enable-on-sync-packages' will still have their forms run."
    (if (backpack-sync-mode-p)
        (condition-case err
            (let ((filtered nil)
                  (original-forms (elpaca-q<-forms q)))
              (dolist (entry original-forms)
                (when (memq (car entry) backpack--enable-on-sync-packages)
                  (push entry filtered)))
              ;; The queue struct is (:type list); cl-defstruct does not
              ;; generate a setf for its accessors, so mutate the forms slot
              ;; directly.  Layout: (tag type id time autoloads forms elpacas),
              ;; hence forms is at index 5.
              (setcar (nthcdr 5 q) (nreverse filtered))
              (funcall orig-fn q))
          (error
           (message "Backpack: Error in forms filtering: %S" err)
           (funcall orig-fn q)))
      (funcall orig-fn q)))

  (advice-add 'elpaca--finalize-queue :around #'backpack--elpaca-skip-forms-in-sync-mode))

;;; Interactive ensure command

(defun backpack--reload-packages ()
  "Reload packages in-place after a successful ensure.
Resets elpaca queues, re-loads gear files so packages are re-declared,
then activates them (since they are now built on disk).
Inspired by Doom Emacs's `doom/reload'."
  (setq elpaca--queues (list (elpaca-q<-create)))
  (backpack--setup-elpaca-for-mode)
  (let ((init-file (expand-file-name "init.el" backpack-user-dir)))
    (when (file-exists-p init-file)
      (pcase-let ((`(,gear-form . ,_rest)
                   (backpack--extract-gear-form init-file)))
        (when gear-form
          (eval gear-form)))))
  (backpack-load-gear-files)
  (backpack--activate-packages)
  (message "Backpack: Packages reloaded successfully."))

(declare-function backpack--extract-gear-form "backpack")

;;;###autoload
(defun backpack/ensure ()
  "Run `backpack ensure' in a subprocess, then reload packages in-place.
Inspired by Doom Emacs's `doom/reload' command.  Spawns a batch
Emacs process that installs/builds all packages, then activates
them in the current session without requiring a restart."
  (interactive)
  (let* ((buf-name "*backpack ensure*")
         (emacs (concat invocation-directory invocation-name))
         (ensure-file (expand-file-name "ensure.el" backpack-emacs-dir))
         (default-directory backpack-emacs-dir))
    (with-current-buffer (get-buffer-create buf-name)
      (let ((inhibit-read-only t))
        (erase-buffer))
      (special-mode)
      (pop-to-buffer (current-buffer)))
    (message "Backpack: Running ensure...")
    (make-process
     :name "backpack-ensure"
     :buffer buf-name
     :command (list emacs
                    "--batch"
                    "--eval" (format "(setq user-emacs-directory %S)"
                                     backpack-emacs-dir)
                    "-l" ensure-file)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((exit-code (process-exit-status proc)))
           (if (zerop exit-code)
               (progn
                 (message "Backpack: ensure completed. Reloading packages...")
                 (backpack--reload-packages))
             (message "Backpack: ensure failed (exit %d). Check *backpack ensure* buffer."
                      exit-code)))))
     :filter
     (lambda (proc output)
       (when (buffer-live-p (process-buffer proc))
         (with-current-buffer (process-buffer proc)
           (let ((inhibit-read-only t)
                 (moving (= (point) (process-mark proc))))
             (save-excursion
               (goto-char (process-mark proc))
               (insert output)
               (set-marker (process-mark proc) (point)))
             (when moving
               (goto-char (process-mark proc))))))))))

(provide 'backpack-sync)
;;; backpack-sync.el ends here
