;;; ensure.el --- Backpack synchronization mode -*- lexical-binding: t; -*-
;;
;; This file implements the `backpack ensure' command which:
;; 1. Installs elpaca from base-packages (no internet required for elpaca itself)
;; 2. Installs all missing packages needed by enabled gears
;; 3. Builds and byte-compiles packages
;; 4. Prepares the Pele native module when the Mermaid gear is enabled
;; 5. Does NOT activate other packages (that happens in normal mode)
;;
;; Usage: emacs --batch --eval "(setq user-emacs-directory \"/path/to/emacs-backpack/\")" -l ensure.el

;; Set backpack to sync mode BEFORE loading backpack.el
;; This variable is checked by backpack.el during initialization
(setq backpack-mode 'sync)

;; Set up load paths for base-packages before loading backpack.el
;; This is needed because backpack.el requires leaf at load time
(add-to-list 'load-path (expand-file-name "base-packages/leaf.el" user-emacs-directory))
(add-to-list 'load-path (expand-file-name "base-packages/leaf-keywords.el" user-emacs-directory))
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; Load backpack.el which sets up all the infrastructure
;; This will also install/build elpaca from base-packages if needed
(let ((backpack-file (expand-file-name "lisp/backpack.el" user-emacs-directory)))
  (load backpack-file nil nil nil t))

;; At this point, elpaca should be loaded from backpack--ensure-elpaca
;; (build steps are configured by `backpack--setup-elpaca-for-mode';
;; sync mode skips activation via advice rather than a custom step list)

;; Load user configuration to get gear declarations
(let ((init-file (expand-file-name "init.el" backpack-user-dir)))
  (when (file-exists-p init-file)
    (load init-file t)))

;; Load all gears (which queues packages via :ensure)
(backpack-load-gear-files)

;;; Progress reporting during package installation

(defvar backpack--last-progress-message nil
  "Last progress message printed, to avoid duplicates.")

(defun backpack--get-package-status-summary ()
  "Get a summary of package statuses from elpaca queues."
  (let ((finished 0)
        (failed 0)
        (in-progress 0)
        (blocked 0)
        (total 0)
        (current-packages nil)
        (failed-packages nil))
    (dolist (q elpaca--queues)
      (dolist (entry (elpaca-q<-elpacas q))
        (let* ((e (cdr entry))
               (status (elpaca<-status e))
               (pkg-name (elpaca<-package e)))
          (cl-incf total)
          (cond
           ((eq status 'finished) (cl-incf finished))
           ((eq status 'failed)
            (cl-incf failed)
            (push pkg-name failed-packages))
           ((memq status '(blocked queued)) (cl-incf blocked))
           (t
            (cl-incf in-progress)
            (push (cons pkg-name status) current-packages))))))
    (list :finished finished
          :failed failed
          :in-progress in-progress
          :blocked blocked
          :total total
          :current current-packages
          :failed-packages (nreverse failed-packages))))

(defun backpack--format-progress (summary)
  "Format SUMMARY into a progress string."
  (let* ((finished (plist-get summary :finished))
         (failed (plist-get summary :failed))
         (total (plist-get summary :total))
         (current (plist-get summary :current))
         (current-str (if current
                          (mapconcat (lambda (p)
                                       (format "%s[%s]"
                                               (car p)
                                               (symbol-name (cdr p))))
                                     (seq-take current 3) ", ")
                        "")))
    (format "[%d/%d] %s%s"
            (+ finished failed)
            total
            (if (> failed 0) (format "(failed: %d) " failed) "")
            current-str)))

(defun backpack--print-progress ()
  "Print current elpaca progress."
  (let* ((summary (backpack--get-package-status-summary))
         (msg (backpack--format-progress summary)))
    (unless (equal msg backpack--last-progress-message)
      (setq backpack--last-progress-message msg)
      (message "Installing packages... %s" msg))))

(defun backpack--format-elpaca-log-entry (event)
  "Format a single elpaca log EVENT for display.
EVENT is an `elpaca-event' struct from `elpaca--event-log'."
  (let ((payload (elpaca-event<-payload event))
        (time (elpaca-event<-time event)))
    (format "  [%s] %s%s"
            (or (plist-get payload :status) 'info)
            (or (plist-get payload :info) "")
            (if time (format " (%s)" (format-time-string "%H:%M:%S" time)) ""))))

(defun backpack--dump-failed-package-logs (q)
  "Dump elpaca log events for each failed package in queue Q."
  (dolist (entry (elpaca-q<-elpacas q))
    (let ((e (cdr entry)))
      (when (eq (elpaca<-status e) 'failed)
        (let ((id (elpaca<-id e)))
          (message "")
          (message "  ── %s ──" (elpaca<-package e))
          (dolist (event (reverse (cl-remove-if-not
                                   (lambda (ev) (eq (elpaca-event<-id ev) id))
                                   elpaca--event-log)))
            (message "%s" (backpack--format-elpaca-log-entry event))))))))

(defun backpack--queue-finished-p (q)
  "Return non-nil if all packages in queue Q reached a terminal status."
  (cl-loop for (_ . e) in (elpaca-q<-elpacas q)
           always (memq (elpaca<-status e) '(finished failed))))

(defun backpack--wait-with-progress ()
  "Wait for elpaca to finish while showing progress."
  (message "Installing packages...")
  (let* ((queues (reverse elpaca--queues))
         (q (car elpaca--queues))
         (pending (when (and q (cl-loop for cq in queues
                                        thereis (cl-loop for (_ . e) in (elpaca-q<-elpacas cq)
                                                         thereis (not (memq (elpaca<-status e)
                                                                            '(finished failed))))))
                    (nconc (cl-loop for cq in queues collect cq until (eq cq q)) (list q)))))
    (when pending
      (setq elpaca--waiting t)
      (elpaca-process-queues)
      (let ((last-print-time 0)
            (stall-count 0)
            (last-summary nil))
        (cl-block nil
          (condition-case nil
              (while (cl-loop for pq in pending
                              thereis (cl-loop for (_ . e) in (elpaca-q<-elpacas pq)
                                               thereis (not (memq (elpaca<-status e)
                                                                  '(finished failed)))))
                (discard-input)
                ;; Print progress every 0.5 seconds
                (let* ((now (float-time))
                       (summary (backpack--get-package-status-summary)))
                  (when (> (- now last-print-time) 0.5)
                    (setq last-print-time now)
                    (backpack--print-progress)
                    ;; Check for stall (no progress for too long)
                    (if (equal summary last-summary)
                        (cl-incf stall-count)
                      (setq stall-count 0)
                      (setq last-summary summary))
                    ;; If stalled for 60 iterations (~30 seconds) and we have failures, break
                    (when (and (> stall-count 60)
                               (> (plist-get summary :failed) 0)
                               (= (plist-get summary :in-progress) 0))
                      (message "Installation stalled -- %d package(s) failed: %s"
                               (plist-get summary :failed)
                               (mapconcat #'identity (plist-get summary :failed-packages) ", "))
                      (cl-return))))
                (sit-for elpaca-wait-interval))
            (quit (cl-loop for pq in pending do
                           (cl-loop for (_ . e) in (elpaca-q<-elpacas pq) do
                                    (unless (memq (elpaca<-status e) '(finished failed))
                                      (condition-case nil
                                          (elpaca--fail e "User quit")
                                        (elpaca-build-error nil)))))))))
      (elpaca-split-queue)
      (setq elpaca--waiting nil)
      ;; Activate enable-on-sync packages BEFORE running deferred forms,
      ;; so their config (e.g. treesit-auto's :advice) can reference the
      ;; package.  Must happen after `elpaca--waiting' is cleared so that
      ;; `elpaca--finalize-queue' actually evaluates the filtered forms.
      (when backpack--enable-on-sync-packages
        (backpack--activate-enable-on-sync-packages))
      (mapc #'elpaca--finalize-queue pending)))
  ;; Final progress
  (let* ((summary (backpack--get-package-status-summary))
         (failed-pkgs (plist-get summary :failed-packages)))
    (message "")
    (message "Installing packages... [%d/%d] Done!"
             (plist-get summary :finished)
             (plist-get summary :total))
    (when failed-pkgs
      (message "")
      (message "WARNING: %d package(s) failed to install:" (length failed-pkgs))
      (dolist (pkg failed-pkgs)
        (message "  - %s" pkg))
      (message "")
      (message "Failed package details:")
      (dolist (q elpaca--queues)
        (backpack--dump-failed-package-logs q))
      (message "")
      (message "You may need to run 'backpack ensure' again or check the package recipes."))))

;; Wait for all packages to be installed/built with progress reporting.
;; This also activates enable-on-sync packages before their deferred
;; forms run and before treesit grammars are installed.
(backpack--wait-with-progress)

;; Pele needs a native module in addition to its Elisp package.
(backpack--prepare-pele-module)

;; After elpaca-wait completes, run our finalization
;; (elpaca-after-init-hook doesn't run when using elpaca-wait in batch mode)
(when backpack--treesit-langs
  (message "")
  (message "Installing tree-sitter grammars...")
  (backpack--install-treesit-grammars))

(message "")
(message "========================================")
(message "Backpack synchronization complete!")
(message "You can now start Emacs normally.")
(message "========================================")
(kill-emacs 0)
