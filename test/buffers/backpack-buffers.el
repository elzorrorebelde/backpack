;;; backpack-buffers.el --- Tests for buffer selection -*- lexical-binding: t; -*-

(require 'ert)
(require 'backpack-buffers)

(defun backpack-test--make-buffer (name mode)
  "Create a real test buffer NAME with major mode MODE."
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (setq major-mode mode)
      (setq-local backpack-real-buffer-p t))
    buf))

(ert-deftest test-backpack-marks-side-window-buffers-persistently ()
  "A buffer keeps its side-window origin after moving to a normal window."
  :tags '(backpack buffers)
  (let ((buf (generate-new-buffer "backpack-side-window-test"))
        window)
    (unwind-protect
        (save-window-excursion
          (setq window
                (display-buffer-in-side-window
                 buf '((side . right) (window-width . 20))))
          (should (window-parameter window 'window-side))
          ;; Global `window-buffer-change-functions' callbacks receive a frame.
          (backpack--mark-side-window-buffers-h (window-frame window))
          (should (buffer-local-value 'backpack-side-window-buffer-p buf))
          (should (memq #'backpack--mark-side-window-buffers-h
                        window-buffer-change-functions))
          (delete-window window)
          (set-window-buffer (selected-window) buf)
          (should (buffer-local-value 'backpack-side-window-buffer-p buf)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest test-backpack-prefers-same-mode-eligible-buffer ()
  "A valid same-mode buffer wins over other valid buffers."
  :tags '(backpack buffers)
  (let* ((current (backpack-test--make-buffer
                   "backpack-current-test" 'text-mode))
         (same-mode (backpack-test--make-buffer
                     "backpack-same-mode-test" 'text-mode))
         (other-mode (backpack-test--make-buffer
                      "backpack-other-mode-test" 'fundamental-mode)))
    (unwind-protect
        (cl-letf (((symbol-function 'buffer-list)
                   (lambda (&optional _frame)
                     (list current other-mode same-mode))))
          (should (eq same-mode
                      (backpack--find-buffer-to-switch-to 'text-mode current))))
      (mapc (lambda (buf)
              (when (buffer-live-p buf)
                (kill-buffer buf)))
            (list current same-mode other-mode)))))

(ert-deftest test-backpack-skips-side-and-special-buffers ()
  "Side-origin and special buffers are skipped even when marked real."
  :tags '(backpack buffers)
  (let* ((current (backpack-test--make-buffer
                   "backpack-current-test" 'text-mode))
         (side (backpack-test--make-buffer
                "backpack-side-test" 'text-mode))
         (special (backpack-test--make-buffer
                   "*EGLOT (project) events*" 'fundamental-mode))
         (normal (backpack-test--make-buffer
                  "backpack-normal-test" 'fundamental-mode)))
    (with-current-buffer side
      (setq-local backpack-side-window-buffer-p t))
    (unwind-protect
        (cl-letf (((symbol-function 'buffer-list)
                   (lambda (&optional _frame)
                     (list current side special normal))))
          (should (backpack-special-buffer-p special))
          (should (eq normal
                      (backpack--find-buffer-to-switch-to 'text-mode current))))
      (mapc (lambda (buf)
              (when (buffer-live-p buf)
                (kill-buffer buf)))
            (list current side special normal)))))

(ert-deftest test-backpack-uses-scratch-when-no-user-buffer-is-eligible ()
  "The fallback is `*scratch*' when only side/special buffers remain."
  :tags '(backpack buffers)
  (let* ((current (backpack-test--make-buffer
                   "backpack-current-test" 'text-mode))
         (side (backpack-test--make-buffer
                "backpack-side-test" 'text-mode))
         (special (backpack-test--make-buffer
                   "*EGLOT (project) events*" 'fundamental-mode)))
    (with-current-buffer side
      (setq-local backpack-side-window-buffer-p t))
    (unwind-protect
        (cl-letf (((symbol-function 'buffer-list)
                   (lambda (&optional _frame)
                     (list current side special))))
          (should (eq (backpack-fallback-buffer)
                      (backpack--find-buffer-to-switch-to 'text-mode current)))
          (should (equal (buffer-name (backpack-fallback-buffer)) "*scratch*")))
      (mapc (lambda (buf)
              (when (buffer-live-p buf)
                (kill-buffer buf)))
            (list current side special)))))

(provide 'backpack-buffers-tests)
;;; backpack-buffers.el ends here
