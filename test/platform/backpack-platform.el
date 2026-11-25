;;; backpack-platform.el --- Tests for platform detection -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (expand-file-name "lisp" backpack-emacs-dir))
(require 'backpack-platform)

(ert-deftest backpack-platform-detects-nixos-with-marker-on-linux ()
  "Include NixOS alongside GNU when its os-release marker exists."
  (let* ((directory (make-temp-file "backpack-platform-nixos-" t))
         (backpack--nixos-marker-file (expand-file-name "NIXOS" directory))
         (system-type 'gnu/linux))
    (unwind-protect
        (progn
          (with-temp-file backpack--nixos-marker-file (insert "NixOS\n"))
          (should (equal (backpack--detect-system) '(gnu nixos))))
      (delete-directory directory t))))

(ert-deftest backpack-platform-keeps-gnu-linux-without-nixos-marker ()
  "Keep ordinary GNU/Linux classified as GNU without the NixOS marker."
  (let* ((directory (make-temp-file "backpack-platform-linux-" t))
         (backpack--nixos-marker-file (expand-file-name "NIXOS" directory))
         (system-type 'gnu/linux))
    (unwind-protect
        (should (equal (backpack--detect-system) '(gnu)))
      (delete-directory directory t))))

(ert-deftest backpack-platform-does-not-classify-other-systems-as-nixos ()
  "The NixOS marker must not affect a non-Linux system type."
  (let* ((directory (make-temp-file "backpack-platform-other-" t))
         (backpack--nixos-marker-file (expand-file-name "NIXOS" directory))
         (system-type 'darwin))
    (unwind-protect
        (progn
          (with-temp-file backpack--nixos-marker-file (insert "NixOS\n"))
          (should (equal (backpack--detect-system) '(macos bsd)))
          (should-not (memq 'nixos (backpack--detect-system))))
      (delete-directory directory t))))

(provide 'backpack-platform-test)
;;; backpack-platform.el ends here
