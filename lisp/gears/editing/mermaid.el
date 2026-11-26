;; -*- lexical-binding: t; -*-

(defun gear--compile-pele-native-module (context)
  "Build and install Pele's native module from CONTEXT during `backpack ensure'."
  (let* ((source-dir (plist-get context :source-dir))
         (build-dir (plist-get context :build-dir))
         (module-file-suffix (plist-get context :module-file-suffix))
         (system-type (plist-get context :system-type))
         (old-ref (plist-get context :old-ref))
         (new-ref (plist-get context :new-ref))
         (module-name (concat "pele-native" module-file-suffix))
         (module-source (expand-file-name module-name source-dir))
         (module-destination (expand-file-name module-name build-dir))
         (emacs-executable (expand-file-name invocation-name invocation-directory)))
    (unless (memq system-type '(darwin gnu/linux))
      (error "Pele source builds support macOS and Linux only (current system: %s)"
             system-type))
    (when (or (not (equal old-ref new-ref))
              (not (file-exists-p module-destination)))
      (let ((result (backpack-process-call source-dir "make" "-B"
                                           (concat "EMACS=" emacs-executable))))
        (unless (eql (plist-get result :status) 0)
          (error "Pele native module build failed (status %s)\nstdout:\n%s\nstderr:\n%s"
                 (plist-get result :status)
                 (plist-get result :stdout)
                 (plist-get result :stderr)))
        (copy-file module-source module-destination t)
        (message "Built Pele native module at %s" module-destination)))))

(leaf pele
  :doc "edit Mermaid diagrams and preview SVGs; the native renderer is provisioned by backpack ensure"
  :url "https://github.com/LuciusChen/pele.el"
  :when (gearp! :editing mermaid)
  :mode (("\\.mmd\\'" . pele-mode)
	 ("\\.mermaid\\'" . pele-mode))
  :ensure (pele :ref "8b37ebc41b4b5cd10c3fb645bd8e5d07d1f90fc8" :host github :repo "LuciusChen/pele.el")
  :native-module gear--compile-pele-native-module
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
