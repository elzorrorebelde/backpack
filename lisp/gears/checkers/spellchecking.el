(leaf jinx
  :doc "a fast just-in-time spell-checker"
  :ensure (jinx :ref "f776ca306801f3b4d26a458d5109ea586d52e716")
  :when (gearp! :checkers spellchecking)
  :hook ((text-mode-hook prog-mode-hook) . jinx-mode)
  :bind ("C-c ." . jinx-correct)
  :custom
  (jinx-camel-modes . '(prog-mode))
  (jinx-delay . 0.01))
