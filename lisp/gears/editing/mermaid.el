;; -*- lexical-binding: t; -*-

(leaf pele
  :doc "edit Mermaid diagrams and preview SVGs; the native renderer is provisioned by backpack ensure"
  :url "https://github.com/LuciusChen/pele.el"
  :when (gearp! :editing mermaid)
  :mode (("\\.mmd\\'" . pele-mode)
         ("\\.mermaid\\'" . pele-mode))
  :ensure (pele :ref "8b37ebc41b4b5cd10c3fb645bd8e5d07d1f90fc8" :host github :repo "LuciusChen/pele.el")
  :hook
  (pele-mode-hook . (lambda ()
                      (unless (gearp! :editing mermaid -display-line-numbers)
                        (display-line-numbers-mode))))
  :init
  ;; Rendering is provisioned explicitly by `backpack ensure'.
  (setq pele-module-auto-install nil))

(leaf ob-pele
  :doc "Org previews and Babel rendering for Mermaid diagrams via Pele"
  :when (and (gearp! :editing org) (gearp! :editing mermaid))
  :after org
  :require t
  :hook (org-mode-hook . pele-org-mode)
  :config
  (require 'pele)
  (pele-babel-enable-mermaid))
