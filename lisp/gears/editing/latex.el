(leaf auctex
  :doc "for documents that look beautiful but whose source makes you weep"
  :when (gearp! :editing latex)
  :ensure (auctex :ref "1c17eb433c7a040df4136911672cb8bd0bbf36e2")
  :mode ("\\.tex\\'" . LaTeX-mode)
  :hook
  (LaTeX-mode-hook . visual-line-mode)
  (LaTeX-mode-hook . reftex-mode)
  :custom
  (TeX-auto-save . t)
  (TeX-parse-self . t)
  (TeX-master . nil)
  (reftex-plug-into-AUCTeX . t)
  :doctor
  ("latexmk" . ("build automation for LaTeX documents" optional))
  :config
  (when (gearp! :editing latex display-line-numbers)
    (add-hook 'LaTeX-mode-hook #'display-line-numbers-mode)))

(leaf eglot
  :doc "Language Server Protocol support for LaTeX"
  :when (and (gearp! :editing latex) (gearp! :editing latex lsp))
  :doctor
  ("texlab" . "an implementation of the Language Server Protocol for LaTeX")
  :hook
  (LaTeX-mode-hook . eglot-ensure))

(leaf citar
  :doc "citation management with vertico/consult integration"
  :when (gearp! :editing latex refs)
  :ensure (citar :host github :repo "emacs-citar/citar" :ref "5efc5ac78f235cdaafe361758d03c7a51a015dd1")
  :require citar-latex
  :doctor
  ("biber" . ("bibliography processor for biblatex" optional)))
