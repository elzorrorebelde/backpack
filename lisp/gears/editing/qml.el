;;; qml.el --- QML/QtQuick support -*- lexical-binding: t; -*-

(leaf qml-mode
  :doc "Major mode for editing QML files"
  :when (gearp! :editing qml)
  :ensure (qml-mode :host github :repo "coldnew/qml-mode" :ref "6c5f33ba88ae010bf201a80ee8095e20a724558c")
  :mode ("\\.qml\'" . qml-mode)
  :config
  ;; Standard indentation is 4 spaces, but some projects use 2.
  ;; Defaulting to 2 as it's more common in modern projects.
  (setq-default qml-indent-offset 2)

  ;; Nested leaf for LSP support
  (leaf eglot
    :doc "Language Server Protocol support for qml-mode"
    :when (gearp! :editing qml lsp)
    :doctor
    ("qmlls" . ("the official QML language server from Qt" optional))
    ("qml-lsp" . ("an alternative QML language server" optional))
    :hook (qml-mode-hook . eglot-ensure)
    :config
    (add-to-list 'eglot-server-programs
                 `(qml-mode . ,(eglot-alternatives '(("qmlls")
                                                    ("qml-language-server")))))))
