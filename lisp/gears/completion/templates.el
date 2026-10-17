;; -*- lexical-binding: t; -*-

(leaf tempel
  :doc "Template expansion system — lightweight snippet engine.
Define templates in a single file (`tempel-file') with a simple
indentation-based syntax.  Integrates with corfu via `cape-tempel'."
  :when (gearp! :completion templates)
  :ensure (tempel :ref "9299c5d0f35dbb02de2565404a082224c4d11654")
  :custom
  (tempel-path . `,(expand-file-name "templates/*/*.eld" backpack-user-dir))
  :bind
  (("M-+" . tempel-complete)   ;; complete template name via completing-read
   ("M-*" . tempel-insert))    ;; insert & expand template
  :init
  ;; Register tempel in the capf chain so Corfu picks it up.
  ;; Priority 10: runs after basic completion but before other capes.
  (add-hook 'completion-at-point-functions #'tempel-expand 10))
