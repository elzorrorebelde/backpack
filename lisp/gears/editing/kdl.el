;; -*- lexical-binding: t -*-
;; Declare tree-sitter languages needed by this gear
(when (backpack-treesit-was-asked 'kdl)
  (backpack-treesit-recipe! kdl
    :url "https://github.com/tree-sitter-grammars/tree-sitter-kdl"
    :ext "\\.kdl\\'"
    :ts-mode 'kdl-ts-mode
    :versions ((:until-abi 14 :revision "b37e3d58e5c5cf8d739b315d6114e02d42e66664"))))

(leaf kdl-mode
  :doc "the KDL document language — nodes, values, and types, no curly-brace soup"
  :ensure (kdl-mode :host github :repo "taquangtrung/emacs-kdl-mode" :ref "c6ef2a0375b1e179c08a2e0f3809d318d8a0c090")
  :when (gearp! :editing kdl)
  :hook
  ((kdl-mode-hook kdl-ts-mode-hook) . electric-pair-local-mode)
  ((kdl-mode-hook kdl-ts-mode-hook) .
   (lambda ()
     (toggle-truncate-lines +1)
     (unless (gearp! :editing kdl -display-line-numbers)
       (display-line-numbers-mode +1)))))

(leaf kdl-ts-mode
  :doc "tree-sitter major mode for KDL files"
  :ensure (kdl-ts-mode :host github :repo "merrickluo/kdl-ts-mode" :ref "02400f0a7030f04b85ef89d769d5a58f8f10b538")
  :unless (gearp! :editing kdl -treesit)
  :after kdl-mode)
