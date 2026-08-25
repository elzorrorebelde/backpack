(leaf embark
  :doc "contextual actions on minibuffer candidates and beyond.
Enables embark-act, embark-act-all, embark-become, embark-export,
embark-select, and embark-dwim.
Credit: keybindings and indicator setup adapted from chiply/.zetta.d"
  :when (gearp! :completion embark)
  :ensure (embark :ref "87e53827cf6659dcc4ac4e54be9af34aeca44f6e")
  :leaf-defer nil
  :bind
  ("C-."   . embark-act)
  ("C-;"   . embark-dwim)
  ("C->"   . embark-act-all)
  ("C-h B" . embark-bindings)
  (:vertico-map
   ("C-."   . embark-act)
   ("C-;"   . embark-dwim)
   ("C->"   . embark-act-all)
   ("C-SPC" . embark-select))
  :custom
  (embark-help-key . "C-h")
  (embark-confirm-act-all . nil)
  :config
  (setq embark-indicators
	'(embark-verbose-indicator
	  embark-highlight-indicator
	  embark-minimal-indicator)))

(leaf embark-consult
  :doc "integration between embark and consult"
  :when (and (gearp! :completion embark)
	     (not (gearp! :completion -consult)))
  :ensure nil ;; ships with embark
  :after (embark consult))
