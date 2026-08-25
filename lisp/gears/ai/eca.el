;; -*- lexical-binding: t; -*-

(leaf eca
  :doc "Editor Code Assistant (ECA) integration for Emacs"
  :url "https://eca.dev"
  :when (gearp! :ai eca)
  :ensure (eca :host github :repo "editor-code-assistant/eca-emacs"
	       :ref "0d11063a9ba2d78961b9c7f1862ba82dc724d234"
	       :files ("*.el"))
  :doctor ("eca" . ("server binary" 'required)))
