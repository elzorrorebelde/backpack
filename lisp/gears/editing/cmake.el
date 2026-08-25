;;; cmake.el --- CMake support -*- lexical-binding: t; -*-

;; Declare tree-sitter languages needed by this gear
(when (backpack-treesit-was-asked 'cmake)
  (backpack-treesit-recipe! cmake
    :versions ((:until-abi 14 :revision "c7b2a71e7f8ecb167fad4c97227c838439280175"))))

(leaf cmake-mode
  :doc "the build system you need a build system to understand"
  :when (gearp! :editing cmake)
  :ensure (cmake-mode :ref "c162d6852d09a82cf87ff0cda6a23abc775dfdb6")
  :hook
  ((cmake-mode-hook cmake-ts-mode-hook) . electric-pair-local-mode)
  ((cmake-mode-hook cmake-ts-mode-hook) .
   (lambda ()
     (toggle-truncate-lines +1)
     (unless (gearp! :editing cmake -display-line-numbers)
       (display-line-numbers-mode +1)))))

(leaf eglot
  :doc "Language Server Protocol support for CMake"
  :when (and (gearp! :editing cmake) (gearp! :editing cmake lsp))
  :doctor ("cmake-language-server" . "a language server for CMake that provides completion, diagnostics and documentation")
  :hook ((cmake-mode-hook cmake-ts-mode-hook) . eglot-ensure)
  :config
  (add-to-list 'eglot-server-programs '(cmake-mode . ("cmake-language-server")))
  (add-to-list 'eglot-server-programs '(cmake-ts-mode . ("cmake-language-server"))))
