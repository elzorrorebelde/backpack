;; -*- lexical-binding: t; -*-

(defun gear--vterm-run-build-command (directory program &rest args)
  "Run PROGRAM with ARGS in DIRECTORY and fail with its captured output."
  (let ((result (apply #'backpack-process-call directory program args)))
    (unless (eql (plist-get result :status) 0)
      (error "vterm %s failed (status %s)\nstdout:\n%s\nstderr:\n%s"
             program
             (plist-get result :status)
             (plist-get result :stdout)
             (plist-get result :stderr)))
    result))

(defun gear--compile-vterm-native-module (context)
  "Build vterm's native module from CONTEXT during `backpack ensure'."
  (let* ((source-dir (plist-get context :source-dir))
         (build-dir (plist-get context :build-dir))
         (module-file-suffix (plist-get context :module-file-suffix))
         (system-type (plist-get context :system-type))
         (old-ref (plist-get context :old-ref))
         (new-ref (plist-get context :new-ref))
         (module-name (concat "vterm-module" module-file-suffix))
         (module-source (expand-file-name module-name source-dir))
         (module-destination (expand-file-name module-name build-dir))
         (cmake-build-dir (expand-file-name "build" source-dir))
         (cmake-args (and (boundp 'vterm-module-cmake-args)
                          (stringp vterm-module-cmake-args)
                          (split-string-and-unquote vterm-module-cmake-args))))
    (when (memq system-type '(windows-nt ms-dos cygwin))
      (error "vterm is not supported on Windows (current system: %s)" system-type))
    (when (or (not (equal old-ref new-ref))
              (not (file-exists-p module-destination)))
      (make-directory cmake-build-dir t)
      (apply #'gear--vterm-run-build-command
             cmake-build-dir "cmake"
             (append (list "-G" "Unix Makefiles") cmake-args (list "..")))
      (gear--vterm-run-build-command cmake-build-dir "make")
      (copy-file module-source module-destination t)
      (message "Built vterm native module at %s" module-destination))))

;; -- Toggle & project helpers --

(defun backpack/vterm-toggle ()
  "Toggle a vterm buffer in a bottom side window.
If a vterm window is visible, delete it.  Otherwise open one."
  (interactive)
  (if-let* ((buf (get-buffer "*vterm*"))
            (win (get-buffer-window buf)))
      (delete-window win)
    (if (get-buffer "*vterm*")
        (pop-to-buffer "*vterm*")
      (vterm "*vterm*"))))

(defun backpack/vterm-project ()
  "Open vterm at the current project root.
Creates a per-project buffer named *vterm:<project>*."
  (interactive)
  (let* ((pr (project-current t))
         (root (project-root pr))
         (name (format "*vterm:%s*" (file-name-nondirectory
                                     (directory-file-name root))))
         (default-directory root))
    (if-let* ((buf (get-buffer name))
              (win (get-buffer-window buf)))
        (delete-window win)
      (if (get-buffer name)
          (pop-to-buffer name)
        (vterm name)))))

;; -- Display rule: vterm buffers always appear at the bottom --

(when (gearp! :term vterm)
  (add-to-list 'display-buffer-alist
               '("\\*vterm"
                 (display-buffer-in-side-window)
                 (side . bottom)
                 (window-height . 0.35))))

;; -- Main leaf block --

(leaf vterm
  :doc "Fully-featured terminal emulator based on libvterm"
  :when (gearp! :term vterm)
  :ensure (vterm :ref "70921114908ebb260d6686db8cbe2445a64f90a2")
  :native-module gear--compile-vterm-native-module
  :doctor ("cmake"   . ("needed to compile vterm's C module" required))
  :doctor ("make"    . ("needed to build vterm's C module" required))
  :doctor ("libtool" . ("needed to compile vterm's C module" required))
  :bind
  ("C-c t v" . backpack/vterm-toggle)
  ("C-c t p" . backpack/term-project)
  :custom
  ;; Large scrollback (number of lines kept in memory)
  (vterm-max-scrollback . 10000)
  ;; Always use UTF-8
  (vterm-environment . '("LANG=en_US.UTF-8"))
  ;; Kill the buffer when the shell exits
  (vterm-kill-buffer-on-exit . t)
  :config
  ;; Directory tracking -- vterm reads OSC 7 escape sequences emitted by
  ;; the shell to keep `default-directory' in sync.  Add the following
  ;; snippet to your shell RC file (bash/zsh):
  ;;
  ;;   vterm_printf() { printf "\e]%s\e\\" "$1"; }
  ;;   vterm_prompt_end() { vterm_printf "51;A$(whoami)@$(hostname):$(pwd)"; }
  ;;   PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }vterm_prompt_end"
  ;;
  ;; For fish:
  ;;   function vterm_prompt_end; printf '\e]51;A%s@%s:%s\e\\' $USER $hostname $PWD; end
  ;;   functions -c fish_prompt _old_fish_prompt
  ;;   function fish_prompt; _old_fish_prompt; vterm_prompt_end; end
  ;;
  ;; zsh users can alternatively source the bundled helpers:
  ;;   source <path-to-emacs-backpack>/.cache/nonessentials/elpaca/builds/vterm/etc/emacs-vterm-zsh.sh
  (add-hook 'vterm-mode-hook
            (lambda ()
              ;; Ensure the process uses UTF-8
              (set-process-coding-system (get-buffer-process (current-buffer))
                                         'utf-8-unix 'utf-8-unix)
              ;; Close window when buffer is manually killed
              (add-hook 'kill-buffer-hook
                        (lambda ()
                          (when-let* ((win (get-buffer-window)))
                            (delete-window win)))
                        nil t)))
  (add-hook 'vterm-exit-functions
            (lambda (&rest _)
              (when-let* ((win (get-buffer-window)))
                (delete-window win)))))
