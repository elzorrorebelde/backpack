;; -*- lexical-binding: t; -*-

(leaf tempel
  :doc "Template expansion system — lightweight snippet engine.
Define templates in a single file (`tempel-file') with a simple
indentation-based syntax.  Integrates with corfu via `tempel-complete'."
  :when (gearp! :completion templates)
  :ensure (tempel :ref "9299c5d0f35dbb02de2565404a082224c4d11654")
  :custom
  (tempel-path . `,(expand-file-name "templates/*/*.eld" backpack-user-dir))
  :bind
  (("M-+" . tempel-complete)   ;; complete template name via completing-read
   ("M-*" . tempel-insert))    ;; insert & expand template
  :init
  ;; Register tempel-complete in the global capf chain for non-eglot buffers.
  ;; Depth -10 ensures it runs before cape and other capfs.
  (add-hook 'completion-at-point-functions #'tempel-complete -10)
  ;; For eglot-managed buffers: re-assert tempel priority AFTER eglot has
  ;; set up its buffer-local capf.  Depth -10 guarantees tempel runs before
  ;; eglot-completion-at-point (which is appended with no depth).
  (add-hook 'eglot-managed-mode-hook
            (lambda ()
              (add-hook 'completion-at-point-functions #'tempel-complete -10 t))))
