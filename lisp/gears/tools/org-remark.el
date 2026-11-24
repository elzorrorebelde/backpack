;; -*- lexical-binding: t; -*-

(leaf org-remark
  :doc "highlight and annotate any text file (org-mode powered)"
  :url "https://github.com/nobiot/org-remark"
  :when (and (gearp! :tools org-remark) (gearp! :editing org))
  :after org
  :ensure (org-remark :ref "ce00a4cda3aeaa02626b90b5d019fefb5490ef4d" :host github :repo "nobiot/org-remark")
  :preface
  (defvar backpack-org-remark-map (make-sparse-keymap)
    "Prefix keymap for `org-remark' commands.")
  (defun backpack-org-remark-open-toggles-window (orig-fn &rest args)
    "Advice for `org-remark-open': close the notes window if visible.
Otherwise invoke ORIG-FN with ARGS unchanged so the upstream
behaviour (open + narrow + focus) still works."
    (let* ((ibuf (and (buffer-live-p org-remark-last-notes-buffer)
                      org-remark-last-notes-buffer))
           (win  (and ibuf (get-buffer-window ibuf))))
      (if win
          (quit-window nil win)
        (apply orig-fn args))))
  :bind-keymap
  ("C-c m" . backpack-org-remark-map)
  :bind
  (:backpack-org-remark-map
   ("m" . org-remark-mark)
   ("o" . org-remark-open)
   ("]" . org-remark-view-next)
   ("[" . org-remark-view-prev)
   ("r" . org-remark-remove))
  :advice
  (:around org-remark-open backpack-org-remark-open-toggles-window)
  :global-minor-mode org-remark-global-tracking-mode
  :config
  ;; Pens: always enabled when the gear is on.
  (org-remark-create "yellow"   '(:underline "gold" :background "lemon chiffon"))
  (org-remark-create "red-line" '(:underline (:color "red" :style wave)))
  ;; Integrations: opt-in sub-flags on the :tools org-remark gear.
  (when (gearp! :tools org-remark info)
    (require 'org-remark-info)
    (add-hook 'Info-mode-hook #'org-remark-info-mode))
  (when (gearp! :tools org-remark eww)
    (require 'org-remark-eww)
    (add-hook 'eww-mode-hook #'org-remark-eww-mode))
  (when (gearp! :tools org-remark nov)
    (require 'org-remark-nov)
    (add-hook 'nov-mode-hook #'org-remark-nov-mode)))
