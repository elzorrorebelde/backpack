(leaf transient
  :doc "Transient command dispatching (needed by Magit and diff-hl menu)"
  :when (or (gearp! :tools magit)
            (gearp! :ui diff-hl))
  :ensure (transient :ref "0ec75dcce235f5ab3d39a02b878e6aaa78159b22"))

(leaf magit
  :when (gearp! :tools magit)
  :doc "an interface to the version control system Git"
  :bind ("C-x g" . magit-status)
  :ensure (magit :ref "67f203853e74e926e2c99f60ed508840714f7ced")
  :custom
  ;; Show magit-status in the entire frame; other magit buffers use
  ;; the traditional split behaviour.  The pre-display-buffer-hook
  ;; already contains `magit-save-window-configuration' by default,
  ;; so the previous layout is recorded automatically.
  (magit-display-buffer-function . #'magit-display-buffer-fullframe-status-v1)
  ;; Restore the saved window configuration when quitting magit (default).
  (magit-bury-buffer-function . #'magit-restore-window-configuration))

(leaf forge
  :when (gearp! :tools magit forge)
  :doc "work with Git forges from Magit"
  :ensure (forge :ref "29f45d8f247079a1d8d2247efdacb5b50a3b1e51")
  :config
  (setq forge-database-file (expand-file-name "forge-database.sqlite" backpack-cache-dir)))

(leaf magit-difftastic
  :when (gearp! :tools magit difftastic)
  :doc "difftastic integration for Magit"
  :ensure (magit-difftastic :host github :repo "rschmukler/magit-difftastic" :ref "0e9fd361b77bcd40ac76ab18b7afd5c3a9331194")
  :doctor (executable-find "difft")
  :global-minor-mode magit-difftastic-mode)

(leaf diff-review
  :unless (gearp! :tools magit -review)
  :doc "Review a git diff the way a pull request page does"
  :ensure (diff-review :host github :repo "xiaoxinghu/diff-review" :ref "49cba292bb933e2a1a90f61145e29311636544ae")
  :hook ((diff-review-mode diff-review-sidebar-mode) . hl-line-mode)
  :config
  (with-eval-after-load 'magit
    (diff-review-magit-mode)))

;; Register magit-project-status in project-switch-commands eagerly
;; so it appears in C-x p p dispatch before magit is loaded.
;; magit-extras.el does this after loading, but we want it available
;; immediately.  Its guard clause prevents duplication when magit
;; later loads.
(when (gearp! :tools magit)
  (autoload 'magit-project-status "magit-extras"
    "Run `magit-status' in the current project's root." t)
  (with-eval-after-load 'project
    (keymap-set project-prefix-map "m" #'magit-project-status)
    (add-to-list 'project-switch-commands '(magit-project-status "Magit") t)))
