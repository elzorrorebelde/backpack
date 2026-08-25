(leaf envrc
  :doc "Emacs support for direnv which operates buffer-locally"
  :when (gearp! :tools direnv)
  :ensure (envrc :ref "e4f9fd79a612c8f81b4ba5b12ee7261fc33568f0")
  ;; Prevent envrc from activating in backpack-emacs-dir.
  ;; Backpack itself is a devenv project, but we do not want its
  ;; .envrc to kick in when Emacs is installed there.
  :init
  (define-advice envrc-mode (:before-while (&optional arg) backpack--skip-emacs-dir)
    "Do not enable envrc-mode inside `backpack-emacs-dir'."
    (or (and (numberp arg) (< arg 1))  ; always allow disabling
        (not (file-in-directory-p default-directory backpack-emacs-dir))))
  :global-minor-mode envrc-global-mode
  :bind-keymap
  ("C-c e" . envrc-command-map))
