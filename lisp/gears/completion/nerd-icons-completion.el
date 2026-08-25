(leaf nerd-icons-completion
  :doc "use nerd-icons on completion candidates"
  :ensure (nerd-icons-completion :ref "45b585d972192a3eaeb239e15e55de7f46f8920a")
  :unless (or (gearp! :completion -marginalia) ;; unless marginalia was turn off
	      (gearp! :completion marginalia -nerd)) ;; or the user doesn't want marginalia with nerd font icons
  :fonts ("Symbols Nerd Font" . "Recommended by nerd-icons package")
  :custom
  (nerd-icons-font-family . "Symbols Nerd Font Mono")
  :config
  (nerd-icons-completion-mode)
  (with-eval-after-load 'marginalia
    (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup)))
