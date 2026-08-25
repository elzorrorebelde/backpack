;; Declare tree-sitter languages needed by this gear
(when (backpack-treesit-was-asked 'clojure "30.1")
  (backpack-treesit-recipe! clojure
    :ts-mode 'clojure-ts-mode
    :remap 'clojure-mode
    :url "https://github.com/sogaiu/tree-sitter-clojure"
    :revision "unstable-20250526"
    :ext "\\\.clj[csx]?\\'"
    :versions ((:until-abi 14 :revision "e43eff80d17cf34852dcd92ca5e6986d23a7040f")))
  ;; clojure-ts-mode embeds markdown-inline (docstrings) and regex
  ;; (regex literal highlighting) grammars by default
  (backpack-treesit-recipe! regex
    :url "https://github.com/tree-sitter/tree-sitter-regex"
    :versions ((:until-abi 14 :revision "cf769a1b4d712590eefbe613c3431e82c1cf04f7"))))

(leaf clojure-mode
  :doc "a monad is just a monoid in the category of endofunctors, what's the problem?"
  :ensure (clojure-mode :ref "3c68569738f04a22d52f1ca28f593c2ee733bf04")
  :when (gearp! :editing clojure)
  :hook
  ((clojure-mode-hook clojure-ts-mode-hook) . electric-pair-local-mode)
  ((clojure-mode-hook clojure-ts-mode-hook) .
   (lambda ()
     (toggle-truncate-lines +1)
     (unless (gearp! :editing clojure -display-line-numbers)
       (display-line-numbers-mode +1)))))

(leaf clojure-ts-mode
  :doc "tree-sitter support for Clojure"
  :when (gearp! :editing clojure)
  :unless (gearp! :editing clojure -treesit)
  :emacs>= "30.1"
  :ensure (clojure-ts-mode :ref "2bce67a68c270157d940ac9374ab393804c7e00d")
  :after clojure-mode
  :custom
  ;; Backpack handles grammar installation; disable clojure-ts-mode's
  ;; own installer to avoid redundant recompilation on file visit.
  (clojure-ts-ensure-grammars . nil))

(leaf cider
  :doc "the Clojure Interactive Development Environment that Rocks"
  :when (gearp! :editing clojure cider)
  :ensure (cider :ref "c17d11494b35502079caeac2fe7c39173349ce10"))

(leaf eglot
  :doc "Language Server Protocol support for Clojure"
  :when (and (gearp! :editing clojure) (gearp! :editing clojure lsp))
  :doctor ("clojure-lsp" . ("a language server for Clojure providing navigation, diagnostics, and refactoring" required))
  :hook ((clojure-mode-hook clojure-ts-mode-hook) . eglot-ensure)
  :config
  ;; LSP protocol extensions note: clojure-lsp supports non-standard extensions
  ;; for rename-file, clean-ns, stub-generation, extract-def, and move-coll.
  ;; Not yet implemented.
  (add-to-list 'eglot-server-programs '(clojure-mode . ("clojure-lsp")))
  (add-to-list 'eglot-server-programs '(clojure-ts-mode . ("clojure-lsp"))))

(leaf ob-clojure
  :doc "Clojure source blocks in org-mode"
  :when (and (gearp! :editing clojure) (gearp! :editing org))
  :after org
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages (append org-babel-load-languages '((clojure . t)))))
