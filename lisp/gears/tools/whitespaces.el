(leaf ws-butler
  :unless (gearp! :tools -whitespaces)
  :doc "unobtrusive way to trim whitespace"
  :ensure (ws-butler :ref "d3cba693ba67ab9d41bfa1df06ce8738d3c1292c")
  :global-minor-mode ws-butler-global-mode
  :custom
  (ws-butler-keep-whitespace-before-point . nil))
