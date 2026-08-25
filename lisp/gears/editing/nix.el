;; Declare tree-sitter languages needed by this gear
(when (backpack-treesit-was-asked 'nix)
  (backpack-treesit-recipe! nix
    :versions ((:until-abi 13 :revision "35b2a51e93625e50e0bbff58b4aad45706cdc299"))))

(leaf nix-mode
  :doc "it works on my machine -- then let's ship your machine"
  :ensure (nix-mode :ref "2c77e7e0b7540efbb20ccaee3557ef90a5dc77f0")
  :when (gearp! :editing nix)
  :hook
  ((nix-mode-hook nix-ts-mode-hook) . electric-pair-local-mode)
  ((nix-mode-hook nix-ts-mode-hook) .
   (lambda ()
     (toggle-truncate-lines +1)
     (unless (gearp! :editing nix -display-line-numbers)
       (display-line-numbers-mode +1)))))

(leaf eglot
  :doc "Language Server Protocol support for nix-mode"
  :when (and (gearp! :editing nix lsp) (gearp! :editing nix))
  :doctor
  ("nixd" . "a feature-rich nix language server interoperating with C++ nix")
  ("nil"  . "an incremental analysis assistant for writing in Nix")
  ("nixfmt" . "format Nix source code, used with your LSP server of choice")
  ("alejandra" . "the Uncompromising Nix Code Formatter, used with your LSP server of choice")
  :hook
  ((nix-mode-hook nix-ts-mode-hook) . eglot-ensure)
  :config
  (add-to-list 'eglot-server-programs
	       `(nix-mode . ,(eglot-alternatives '(("nixd")
						   ("nil" "--stdio")))))
  (add-to-list 'eglot-server-programs
	       `(nix-ts-mode . ,(eglot-alternatives '(("nixd")
						      ("nil" "--stdio"))))))

(leaf nix-ts-mode
  :doc "tree-sitter major mode for nix"
  :ensure (nix-ts-mode :ref "03c77fdbbd22d9b87a654169c26339b28c97d8cd")
  :unless (gearp! :editing nix -treesit)
  :after nix-mode)

(leaf ob-nix
  :doc "a simple org-babel language extension to evaluate nix expressions using `nix-instantiate`"
  :after org
  :ensure (ob-nix :ref "76d71b37fb031f25bd52ff9c98b29292ebe0424e")
  :when (and (gearp! :editing org) (gearp! :editing nix))
  :doctor
  ("nix-instantiate" . "instantiate store derivations from Nix expressions")
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages (append org-babel-load-languages '((nix . t)))))
