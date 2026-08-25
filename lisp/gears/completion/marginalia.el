(leaf marginalia
  :doc "adds marginalia to the minibuffer completions"
  :unless (gearp! :completion -marginalia)
  :ensure (marginalia :ref "7ec0b70afb43a756ecd45a958c6ebe797717fc91")
  :bind (:minibuffer-local-map
         ("M-A" . marginalia-cycle))
  :leaf-defer nil
  :config
  (marginalia-mode))
