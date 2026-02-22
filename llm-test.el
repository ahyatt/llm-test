;;; llm-test.el --- LLM-driven testing for Emacs packages -*- lexical-binding: t -*-

;; Copyright (c) 2026  Andrew Hyatt <ahyatt@gmail.com>

;; Author: Andrew Hyatt <ahyatt@gmail.com>
;; Homepage: https://github.com/ahyatt/llm-test
;; Package-Requires: ((emacs "28.1") (llm "0.18.0") (yaml "0.5.0"))
;; Keywords: testing, tools
;; Version: 0.1.0
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; llm-test is a testing library that uses LLM agents to interpret
;; natural-language test specifications (written in YAML) and execute them
;; against a fresh Emacs process.  Tests are registered as ERT tests, so they
;; integrate with the standard Emacs test infrastructure.
;;
;; Usage:
;;   (require 'llm-test)
;;   (setq llm-test-provider (make-llm-openai :key "..."))
;;   (llm-test-load-tests "path/to/testscripts/")

;;; Code:

(require 'llm)
(require 'yaml)
(require 'ert)
(require 'cl-lib)

(defgroup llm-test nil
  "LLM-driven testing for Emacs packages."
  :group 'tools)

(defcustom llm-test-emacs-executable "emacs"
  "Path to the Emacs executable used to run tests.
A fresh Emacs process (emacs -Q) is launched for each test."
  :type 'string
  :group 'llm-test)

(defcustom llm-test-provider nil
  "The LLM provider to use for the test agent.
This should be an object created by one of the `make-llm-*' constructors
from the `llm' package."
  :type 'sexp
  :group 'llm-test)

;;; Data Structures

(cl-defstruct llm-test-spec
  "A single test specification."
  description)

(cl-defstruct llm-test-group
  "A group of tests with shared setup."
  name setup tests)

;;; YAML Parsing

(defun llm-test--parse-yaml-string (yaml-string)
  "Parse YAML-STRING into a list of `llm-test-group' structs.
The YAML should contain a single group document with keys:
  group: <name>
  setup: <natural language setup description>
  tests:
    - description: <test description>"
  (let* ((parsed (yaml-parse-string yaml-string))
         (group-name (gethash 'group parsed))
         (setup (gethash 'setup parsed))
         (tests-array (gethash 'tests parsed))
         (tests (mapcar (lambda (test-hash)
                          (make-llm-test-spec
                           :description (gethash 'description test-hash)))
                        (append tests-array nil))))
    (unless group-name
      (error "YAML test spec missing required 'group' key"))
    (unless tests
      (error "YAML test spec missing required 'tests' key"))
    (make-llm-test-group
     :name group-name
     :setup (or setup "")
     :tests tests)))

(defun llm-test--parse-yaml-file (file)
  "Parse a YAML test FILE into a `llm-test-group' struct."
  (llm-test--parse-yaml-string
   (with-temp-buffer
     (insert-file-contents file)
     (buffer-string))))

;;; Emacs Subprocess Control

(defcustom llm-test-timeout 30
  "Timeout in seconds for evaluating expressions in the test Emacs process."
  :type 'integer
  :group 'llm-test)

(defvar llm-test--server-name-counter 0
  "Counter for generating unique server names.")

(defun llm-test--start-emacs ()
  "Start a fresh Emacs process for testing.
Returns a plist with :process, :server-name, and :socket-dir."
  (let* ((server-name (format "llm-test-%d-%d"
                              (emacs-pid)
                              (cl-incf llm-test--server-name-counter)))
         (socket-dir (make-temp-file "llm-test-socket-" t))
         (process (start-process
                   (format "llm-test-emacs-%s" server-name)
                   (format " *llm-test-emacs-%s*" server-name)
                   llm-test-emacs-executable
                   "-Q"
                   "--eval" (format "(setq server-socket-dir %S server-name %S)"
                                    socket-dir server-name)
                   (format "--daemon=%s" server-name))))
    ;; Wait for the daemon to be ready by polling for the socket file.
    (let ((deadline (+ (float-time) llm-test-timeout))
          (socket-file (expand-file-name server-name socket-dir)))
      (while (and (< (float-time) deadline)
                  (not (file-exists-p socket-file)))
        (sleep-for 0.1))
      (unless (file-exists-p socket-file)
        (when (process-live-p process)
          (kill-process process))
        (error "Timed out waiting for test Emacs daemon to start")))
    (list :process process
          :server-name server-name
          :socket-dir socket-dir)))

(defun llm-test--eval-in-emacs (emacs-info sexp)
  "Evaluate SEXP in the test Emacs process described by EMACS-INFO.
SEXP should be a string of elisp to evaluate.
Returns the result as a string."
  (let* ((server-name (plist-get emacs-info :server-name))
         (socket-dir (plist-get emacs-info :socket-dir)))
    (with-temp-buffer
      (let ((exit-code
             (call-process "emacsclient" nil t nil
                           (format "--socket-name=%s"
                                   (expand-file-name server-name socket-dir))
                           "--eval" sexp)))
        (if (= exit-code 0)
            (string-trim (buffer-string))
          (error "emacsclient eval failed (exit %d): %s"
                 exit-code (buffer-string)))))))

(defun llm-test--stop-emacs (emacs-info)
  "Stop the test Emacs process described by EMACS-INFO."
  (let* ((server-name (plist-get emacs-info :server-name))
         (socket-dir (plist-get emacs-info :socket-dir))
         (process (plist-get emacs-info :process)))
    (ignore-errors
      (call-process "emacsclient" nil nil nil
                    (format "--socket-name=%s"
                            (expand-file-name server-name socket-dir))
                    "--eval" "(kill-emacs)"))
    (when (process-live-p process)
      (delete-process process))
    (ignore-errors
      (delete-directory socket-dir t))))

;;; Agent Tools and Loop

(defcustom llm-test-max-iterations 20
  "Maximum number of agent iterations before forcing a timeout failure."
  :type 'integer
  :group 'llm-test)

(defun llm-test--make-tools (emacs-info)
  "Create the list of `llm-tool' structs for the test agent.
EMACS-INFO is the plist from `llm-test--start-emacs'."
  (list
   (make-llm-tool
    :function (lambda (code)
                (condition-case err
                    (llm-test--eval-in-emacs emacs-info code)
                  (error (format "ERROR: %s" (error-message-string err)))))
    :name "eval-elisp"
    :description "Evaluate an Emacs Lisp expression in the test Emacs process and return the printed result."
    :args (list (list :name "code" :type 'string
                      :description "The Emacs Lisp expression to evaluate, as a string.")))

   (make-llm-tool
    :function (lambda (buffer-name)
                (condition-case err
                    (llm-test--eval-in-emacs
                     emacs-info
                     (format "(with-current-buffer %S (buffer-substring-no-properties (point-min) (point-max)))"
                             buffer-name))
                  (error (format "ERROR: %s" (error-message-string err)))))
    :name "get-buffer-contents"
    :description "Get the full text content of a named buffer in the test Emacs."
    :args (list (list :name "buffer_name" :type 'string
                      :description "The name of the buffer to read.")))

   (make-llm-tool
    :function (lambda ()
                (condition-case err
                    (llm-test--eval-in-emacs
                     emacs-info
                     "(mapcar #'buffer-name (buffer-list))")
                  (error (format "ERROR: %s" (error-message-string err)))))
    :name "get-buffer-list"
    :description "List all buffer names in the test Emacs."
    :args nil)

   (make-llm-tool
    :function (lambda (keys)
                (condition-case err
                    (llm-test--eval-in-emacs
                     emacs-info
                     (format "(execute-kbd-macro (kbd %S))" keys))
                  (error (format "ERROR: %s" (error-message-string err)))))
    :name "send-keys"
    :description "Send a key sequence to the test Emacs, as if typed by a user.  Use Emacs key notation (e.g. \"C-x C-f\", \"M-x\", \"RET\")."
    :args (list (list :name "keys" :type 'string
                      :description "Key sequence in Emacs notation.")))

   (make-llm-tool
    :function (lambda (reason) (format "PASS: %s" reason))
    :name "pass-test"
    :description "Signal that the current test has PASSED.  Call this when you have verified the expected outcome."
    :args (list (list :name "reason" :type 'string
                      :description "Explanation of why the test passed.")))

   (make-llm-tool
    :function (lambda (reason) (format "FAIL: %s" reason))
    :name "fail-test"
    :description "Signal that the current test has FAILED.  Call this when the observed behavior does not match expectations."
    :args (list (list :name "reason" :type 'string
                      :description "Explanation of why the test failed.")))))

(defconst llm-test--system-prompt
  "You are an Emacs test agent.  You are given a test description in natural \
language and you must execute it step by step in a fresh Emacs process using \
the provided tools.

Your workflow:
1. Read the setup instructions and execute them using eval-elisp or send-keys.
2. Read the test description and perform the actions described.
3. After performing the actions, verify the expected outcome by inspecting \
buffer contents, evaluating elisp expressions, etc.
4. Call pass-test if the outcome matches expectations, or fail-test if it does not.

Important rules:
- Always call exactly one of pass-test or fail-test before finishing.
- Use eval-elisp for programmatic operations and state inspection.
- Use send-keys when the test requires simulating interactive user input.
- If an operation returns an error, try to understand why and report it \
via fail-test.
- Be thorough: verify the actual state, don't assume operations succeeded."
  "System prompt for the LLM test agent.")

(cl-defstruct llm-test-result
  "The result of running a single test."
  passed-p reason)

(defun llm-test--run-test (provider emacs-info group-setup test-spec)
  "Run a single test using PROVIDER against EMACS-INFO.
GROUP-SETUP is the setup string for the test group.
TEST-SPEC is an `llm-test-spec' struct.
Returns an `llm-test-result'."
  (let* ((user-message
          (format "Setup instructions:\n%s\n\nTest to execute:\n%s"
                  group-setup
                  (llm-test-spec-description test-spec)))
         (tools (llm-test--make-tools emacs-info))
         (prompt (llm-make-chat-prompt
                  user-message
                  :context llm-test--system-prompt
                  :tools tools)))
    (cl-loop for iteration from 1 to llm-test-max-iterations
             for result = (llm-chat provider prompt t)
             for tool-results = (plist-get result :tool-results)
             for pass-result = (assoc-default "pass-test" tool-results)
             for fail-result = (assoc-default "fail-test" tool-results)
             if pass-result
             return (make-llm-test-result :passed-p t :reason pass-result)
             if fail-result
             return (make-llm-test-result :passed-p nil :reason fail-result)
             finally return
             (make-llm-test-result
              :passed-p nil
              :reason (format "Agent did not reach a verdict after %d iterations"
                              llm-test-max-iterations)))))

;;; Test Loading

(defun llm-test--slugify (string)
  "Convert STRING to a symbol-safe slug."
  (intern
   (replace-regexp-in-string
    "-+" "-"
    (replace-regexp-in-string
     "[^a-z0-9-]" "-"
     (downcase (string-trim string))))))

(defun llm-test-load-directory (directory)
  "Scan DIRECTORY for .yaml/.yml files and parse them all.
Returns a list of `llm-test-group' structs."
  (let ((files (append (directory-files directory t "\\.yaml\\'")
                       (directory-files directory t "\\.yml\\'"))))
    (mapcar #'llm-test--parse-yaml-file files)))

(defun llm-test-register-tests (directory &optional provider)
  "Load YAML test specs from DIRECTORY and register them as ERT tests.
PROVIDER is the LLM provider to use; defaults to `llm-test-provider'."
  (let ((groups (llm-test-load-directory directory))
        (provider (or provider llm-test-provider)))
    (dolist (group groups)
      (let ((group-slug (llm-test--slugify (llm-test-group-name group)))
            (setup (llm-test-group-setup group)))
        (cl-loop for test in (llm-test-group-tests group)
                 for idx from 1
                 for test-name = (intern (format "llm-test/%s/%d" group-slug idx))
                 for description = (llm-test-spec-description test)
                 do (let ((the-test test)
                          (the-setup setup)
                          (the-provider provider))
                      (ert-set-test
                       test-name
                       (make-ert-test
                        :name test-name
                        :documentation (format "LLM test: %s (test %d)\n%s"
                                               (llm-test-group-name group)
                                               idx description)
                        :body (lambda ()
                                (let ((emacs-info (llm-test--start-emacs)))
                                  (unwind-protect
                                      (let ((result (llm-test--run-test
                                                     the-provider emacs-info
                                                     the-setup the-test)))
                                        (unless (llm-test-result-passed-p result)
                                          (ert-fail
                                           (llm-test-result-reason result))))
                                    (llm-test--stop-emacs emacs-info))))))))))))

(provide 'llm-test)
;;; llm-test.el ends here
