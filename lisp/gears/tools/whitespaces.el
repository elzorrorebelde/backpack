(leaf ws-butler
  :unless (gearp! :tools -whitespaces)
  :doc "unobtrusive way to trim whitespace"
  :ensure (ws-butler :ref "67c49cfdf5a5a9f28792c500c8eb0017cfe74a3a")
  :global-minor-mode ws-butler-global-mode
  :custom
  (ws-butler-keep-whitespace-before-point . nil))
