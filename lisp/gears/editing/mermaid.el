;; -*- lexical-binding: t; -*-

(leaf mermaid-mode
  :doc "major mode for editing mermaid diagram files"
  :url "https://github.com/abrochard/mermaid-mode"
  :when (gearp! :editing mermaid)
  :mode ("\\.mmd\\'" "\\.mermaid\\'")
  :ensure (mermaid-mode :ref "804dbcb1452e7496ae0c48e20362da6351227246" :host github :repo "abrochard/mermaid-mode")
  :doctor ("mmdc" . "mermaid-cli, required to render mermaid diagrams")
  :hook
  (mermaid-mode-hook . (lambda ()
                         (unless (gearp! :editing mermaid -display-line-numbers)
                           (display-line-numbers-mode)))))

(leaf ob-mermaid
  :doc "org-babel support for mermaid diagrams"
  :url "https://github.com/arnm/ob-mermaid"
  :when (and (gearp! :editing org) (gearp! :editing mermaid))
  :after org
  :ensure (ob-mermaid :ref "30c2da02e3d24dbec0d004d3c6dfe7b381500b05" :host github :repo "arnm/ob-mermaid")
  :doctor ("mmdc" . "mermaid-cli, required to render mermaid diagrams")
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages (append org-babel-load-languages '((mermaid . t)))))
