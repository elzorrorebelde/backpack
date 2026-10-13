;; -*- lexical-binding: t; -*-

;; PDF viewing with pdf-tools.
;;
;; The epdfinfo native server is compiled by a custom elpaca build step
;; (`backpack--pdf-compile-epdfinfo'), injected via the recipe's `:build'
;; substitution rule so it runs after the git checkout but before
;; `elpaca-build-link' (which then copies the binary into the build dir).
;; It runs during `backpack ensure' only when pdf-tools is installed for
;; the first time or when its pinned ref changes (Backpack's
;; `backpack--recipe-force-rebuild-on-ref-change' forces the rebuild).
;;
;; System requirements beyond the binaries listed in :doctor:
;;   - poppler-glib development libraries
;;   - cairo development libraries
;;   - glib development libraries

(defun backpack--pdf-compile-epdfinfo (e)
  "Build step: compile the pdf-tools epdfinfo server in E's source dir.
Signals an error (with make's output) on failure so elpaca marks the
package as failed instead of silently shipping a build without the binary."
  (let ((default-directory (elpaca<-source-dir e)))
    (elpaca-with-process (elpaca-process-call "make" "server/epdfinfo")
      (unless success
        (error "epdfinfo compilation failed: %s"
               (string-trim (concat (or stdout "") "\n" (or stderr "")))))))
  (elpaca-continue e))

(leaf pdf-tools
  :doc "PDF viewer with annotations, search, and outline navigation (requires poppler)"
  :when (gearp! :tools pdf)
  ;; The `:build' rule injects the epdfinfo compilation as a build step
  ;; running before `elpaca-build-link' (the old `:pre-build' recipe
  ;; keyword was removed from elpaca).  Unlike a ("make" ...) command,
  ;; this step checks the exit code and bubbles make's output up to the
  ;; `backpack ensure' failure log on error.
  :ensure (pdf-tools
           :ref "5245f092e35712df6559a7782a93bb61896175dd"
           :files (:defaults "server/epdfinfo" "server/epdfinfo.exe")
           :build (:before elpaca-build-link backpack--pdf-compile-epdfinfo))
  ;; Multiple :doctor entries (one per binary) -- matches the convention
  ;; used by vterm (cmake + libtool). The inventory parser
  ;; (`backpack-inventory--extract-doctor-entries') expects exactly one
  ;; cons per :doctor value; a single :doctor with a list of conses
  ;; would not be parsed correctly.
  :doctor ("make"       . ("needed to compile the epdfinfo server" required))
  :doctor ("autoreconf" . ("needed to generate the server build system" required))
  :doctor ("cc"         . ("C compiler used to build the epdfinfo server" required))
  :doctor ("pkg-config" . ("used by the server configure script to locate poppler-glib" required))
  :config
  ;; Point pdf-tools at the compiled binary.  The build step above
  ;; compiles server/epdfinfo in the source dir; :files copies it flat
  ;; into the elpaca build directory.  Must be set BEFORE calling
  ;; pdf-tools-install so it finds the right binary.
  ;;
  ;; We use `locate-library' instead of `pdf-tools-directory' because
  ;; the latter is a defconst in pdf-tools.el (not autoloaded), and
  ;; elpaca only loads autoloads before running the deferred body —
  ;; pdf-tools.el is not yet required at this point.
  (let ((dir (file-name-directory (locate-library "pdf-tools"))))
    (setq pdf-info-epdfinfo-program
          (expand-file-name
           (if backpack--system-windows-p "epdfinfo.exe" "epdfinfo")
           dir))
    ;; Register PDF files and enable the bundled minor modes.
    ;; We only install if the epdfinfo binary from `backpack ensure'
    ;; is present; otherwise we warn the user.
    ;; `pdf-tools-install-noverify' is NOT autoloaded (unlike
    ;; `pdf-tools-install'), so require the package first.
    (if (file-executable-p pdf-info-epdfinfo-program)
        (progn
          (require 'pdf-tools)
          (pdf-tools-install-noverify))
      (display-warning
       'backpack
       (format "epdfinfo not found at %s; run `backpack ensure' first"
               pdf-info-epdfinfo-program)
       :warning))))