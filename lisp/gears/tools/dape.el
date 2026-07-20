;;; dape.el --- Debug Adapter Protocol support via dape  -*- lexical-binding: t; -*-

(leaf dape
  :doc "Debug Adapter Protocol client."
  :when (gearp! :tools dape)
  :ensure (dape :ref "c81da6a8bc75f3e7b2e61f949a44243a3b051765")
  :bind (("C-c d d" . dape))
  :custom
  (dape-buffer-window-arrangement . 'right)
  (dape-info-hide-mode-line . nil)
  :hook
  (kill-emacs-hook . dape-breakpoint-save)
  (backpack-user-after-init-hook . dape-breakpoint-load)
  (dape-start-hook . (lambda () (save-some-buffers t t))) ;; Save buffers before starting a debug session (useful for interpreted langs)
  (dape-compile-hook . #'kill-buffer)
  :config
  ;; Hover documentation via eldoc (on by default, opt-out with -eldoc)
  (unless (gearp! :tools dape -eldoc)
    (when (gearp! :tools eldoc)
      (add-hook 'dape-mode-hook #'eldoc-mode)))

  ;; Repeat-mode for ergonomic keybinding chaining (on by default, opt-out with -repeat)
  (unless (gearp! :tools dape -repeat)
    (add-hook 'dape-mode-hook #'repeat-mode))

  ;; avoid performance hits on GNU/Linux and Windows
  (when (or backpack--system-gnu-p backpack--system-windows-p backpack--system-wsl-p)
    (setq read-process-output-max (* 1024 1024)))

  ;; avoid performance hits on macOS
  (when backpack--system-macos-p
    (setq read-process-output-max (* 64 1024)))
  :global-minor-mode dape-breakpoint-global-mode)
