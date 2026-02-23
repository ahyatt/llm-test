;;; llm-test-test.el --- Tests for llm-test -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the llm-test YAML parsing and data structures.

;;; Code:

(require 'llm-test)
(require 'ert)

(ert-deftest llm-test-parse-simple-yaml ()
  "Parsing a simple YAML spec should produce the correct group struct."
  (let ((group (llm-test--parse-yaml-string
                "group: my tests\nsetup: do setup\ntests:\n  - description: test one\n  - description: test two\n")))
    (should (equal (llm-test-group-name group) "my tests"))
    (should (equal (llm-test-group-setup group) "do setup"))
    (should (= (length (llm-test-group-tests group)) 2))
    (should (equal (llm-test-spec-description (nth 0 (llm-test-group-tests group)))
                   "test one"))
    (should (equal (llm-test-spec-description (nth 1 (llm-test-group-tests group)))
                   "test two"))))

(ert-deftest llm-test-parse-no-setup ()
  "A YAML spec without setup should default to an empty string."
  (let ((group (llm-test--parse-yaml-string
                "group: no setup\ntests:\n  - description: a test\n")))
    (should (equal (llm-test-group-setup group) ""))
    (should (= (length (llm-test-group-tests group)) 1))))

(ert-deftest llm-test-parse-missing-group ()
  "Parsing YAML without a group key should signal an error."
  (should-error (llm-test--parse-yaml-string
                 "tests:\n  - description: orphan test\n")))

(ert-deftest llm-test-parse-missing-tests ()
  "Parsing YAML without tests should signal an error."
  (should-error (llm-test--parse-yaml-string
                 "group: empty\n")))

(ert-deftest llm-test-parse-file ()
  "Parsing a YAML file from disk should work."
  (let ((file (expand-file-name "testscripts/auto-fill-tests.yaml"
                                (file-name-directory (locate-library "llm-test")))))
    (let ((group (llm-test--parse-yaml-file file)))
      (should (equal (llm-test-group-name group) "auto-fill mode"))
      (should (= (length (llm-test-group-tests group)) 2)))))

(ert-deftest llm-test-load-directory ()
  "Loading a directory should find all YAML files."
  (let ((dir (expand-file-name "testscripts"
                               (file-name-directory (locate-library "llm-test")))))
    (let ((groups (llm-test-load-directory dir)))
      (should (>= (length groups) 2)))))

;;; Slugify tests

(ert-deftest llm-test-slugify ()
  "Slugify should produce clean symbol names."
  (should (eq (llm-test--slugify "auto-fill mode") 'auto-fill-mode))
  (should (eq (llm-test--slugify "Basic Editing!") 'basic-editing-)))

;;; ERT registration tests

(ert-deftest llm-test-register-creates-ert-tests ()
  "Registering tests from a directory should create ERT test symbols."
  (let ((dir (expand-file-name "testscripts"
                               (file-name-directory (locate-library "llm-test")))))
    ;; Use a dummy provider - we won't actually run the tests
    (llm-test-register-tests dir :provider 'dummy-provider)
    (should (ert-test-boundp 'llm-test/auto-fill-mode/1))
    (should (ert-test-boundp 'llm-test/auto-fill-mode/2))
    (should (ert-test-boundp 'llm-test/basic-editing/1))
    (should (ert-test-boundp 'llm-test/basic-editing/2))))

;;; Subprocess control tests

(ert-deftest llm-test-emacs-subprocess-eval ()
  "Starting a fresh Emacs and evaluating elisp should work."
  (let ((info (llm-test--start-emacs)))
    (unwind-protect
        (progn
          (should (equal (llm-test--eval-in-emacs info "(+ 1 2)") "3"))
          (should (equal (llm-test--eval-in-emacs info "(+ 10 20)") "30")))
      (llm-test--stop-emacs info))))

(ert-deftest llm-test-emacs-subprocess-isolation ()
  "The test Emacs should be a clean -Q instance without user config."
  (let ((info (llm-test--start-emacs)))
    (unwind-protect
        ;; In emacs -Q, user-init-file should be nil
        (should (equal (llm-test--eval-in-emacs info "user-init-file") "nil"))
      (llm-test--stop-emacs info))))

(provide 'llm-test-test)
;;; llm-test-test.el ends here
