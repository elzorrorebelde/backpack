(leaf puni
  :doc "structured editing for all languages (paredit-like).
Soft-delete, slurp/barf, wrap/splice, raise — works with any
major mode that defines sexp boundaries."
  :when (gearp! :tools puni)
  :ensure (puni :ref "04819e0bad5ed62af9e412ef9715b33bb1edc3ba")
  :hook
  (prog-mode-hook . puni-mode)
  (text-mode-hook . puni-mode)
  :bind
  (:puni-mode-map
   ("C-M-f" . puni-forward-sexp)
   ("C-M-b" . puni-backward-sexp)
   ("C-M-k" . puni-kill)
   ("M-("   . puni-wrap-round)
   ("M-s"   . puni-splice)
   ("M-r"   . puni-raise)))
