;;; cmd-mode.el --- Major mode for editing DOS/Windows scripts

;; Original author: Arni Magnusson <arnima@hafro.is>
;; This extension: Noah Peart <noah.v.peart@gmail.com>
;; Keywords: languages

;; This file is not part of GNU Emacs

;; This is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:
;;
;; Extented version of base bat-mode, a major mode for editing
;; DOS/Windows scripts (batch files).  This verison is extended to provide
;; indentation, completion at point functions, extra syntax, user functions,
;; basic interactive shell, and company completion with company-cmd.
;; Features include,  highlighting, a basic template,
;; access to DOS help pages, imenu/outline navigation, the ability to
;; run scripts from within Emacs (also with output to compilation buffer),
;;
;; The syntax
;; groups for highlighting are:
;;
;; Face                          Example
;; cmd-label-face                :LABEL
;; cmd-escaped-newline-face      ^
;; font-lock-comment-face        rem
;; font-lock-builtin-face        copy
;; font-lock-keyword-face        goto
;; font-lock-warning-face        cp
;; font-lock-constant-face       [call] prog
;; font-lock-variable-name-face  %var%
;; font-lock-type-face           -option
;;
;; Usage:
;;
;; See documentation of function `cmd-mode'.
;;
;; Acknowledgements:
;;
;; Extension of base bat-mode.el to include indentation, completion,
;; modified syntax and font-locking, some extra user functions and basic
;; interface for interactive shell.  Mostly modeled after sh-script.el

;;; Code:

(eval-when-compile
  (require 'comint))

(autoload 'comint-completion-at-point "comint")
(autoload 'comint-filename-completion "comint")
(autoload 'comint-send-string "comint")
(autoload 'shell-command-completion "shell")

(defgroup cmd nil
  "Windows cmd shell programming utilities."
  :group 'languages)

(defgroup cmd-script nil
  "Major mode for editing DOS/Windows batch files."
  :link '(custom-group-link :tag "Font Lock Faces group" font-lock-faces)
  :group 'cmd
  :prefix "cmd-")


;; User Variables

(defcustom cmd-indent-level 4
  "Amount by which batch subexpressions are indented."
  :type 'integer
  :group 'cmd-script)
(put 'cmd-indent-level 'safe-local-variable 'integerp)

(defcustom cmd-shell-file
  (downcase (or (getenv "SHELL") "cmd.exe"))
  "The executable file name of the shell."
  :type 'string
  :group 'cmd-script)

(defcustom cmd-compile-file cmd-shell-file
  "Shell used for compiling, default `cmd-shell-file'."
  :type 'string
  :group 'cmd-script)

(defcustom cmd-dynamic-complete-functions
  '(shell-command-completion
    comint-filename-completion)
  "Functions for dynamic completion."
  :type '(repeat function)
  :group 'cmd-script)

(defface cmd-label-face
  '((t :inherit font-lock-warning-face :weight bold))
  "Font Lock mode face used to highlight labels in batch files."
  :group 'cmd-script)

(defface cmd-escaped-newline-face
  '((t :inherit font-lock-warning-face))
  "Face for (non-escaped) ^ at end of line."
  :group 'cmd-script)

(defcustom cmd-assignment-regexp
  "\\_<set\\_> \\(?:/[aApP] \\)?[ \t]*\\^?\"?\\([^ =]+\\)="
  "Regexp to match variable name, the first grouping matches the 
variable name"
  :type 'regexp
  :group 'cmd-script)

(defcustom cmd-beginning-of-command
  "\\([(|&><]\\|[^\\^]\n\\)[ @\t]*\\([[:alpha:]]\\)"
  "Regexp to determine beginning of shell command.  The command starts
at the beginning of the second \\(grouping\\)."
  :type 'regexp
  :group 'cmd-script)

(defcustom cmd-end-of-command
  "\\([[:alpha:]]\\)[ \t]*\\([|&><]\\|$\\)"
  "Regexp to determine the end of a shell command. The actual command
starts at the end of the first \\(grouping\\)."
  :type 'regexp
  :group 'cmd-script)

(defcustom cmd-builtins
  '("assoc" "at" "attrib" "cd" "cls" "chdir" "color" "copy" "date" "del" "dir"
    "doskey" "echo" "endlocal" "erase" "fc" "find" "findstr" "format"
    "ftype" "label" "md" "mkdir" "more" "move" "net" "path" "pause"
    "popd" "prompt" "pushd" "rd" "ren" "rename" "replace" "rmdir" "set"
    "setlocal" "shift" "sort" "subst" "time" "title" "tree" "type"
    "ver" "verify" "vol" "xcopy")
  "Builtin commands."
  :type '(repeat (cons (symbol :tag "Shell")
                       (choice (repeat string))
                       (sexp :format "Evaluate: %v")))
  :group 'cmd-script)

(defcustom cmd-control-keywords
  '("for" "in" "do" "if" "not" "else" "exist" "defined"
    "equ" "geq" "gtr" "leq" "lss" "neq"
    "exit" "start" "goto" "call" "cmd")
  "Control flow keywords."
  :type '(repeat (cons (symbol :tag "Shell")
                       (choice (repeat "string"))
                       (sexp :format "Evaluate: %v")))
  :group 'cmd-script)

(defcustom cmd-unix-keywords
  '("bash" "cat" "cp" "fgrep" "grep" "ls" "sed" "sh" "mv" "rm")
  "Unix keywords."
  :type '(repeat (cons (symbol :tag "Shell"))
                 (choice (repeat string)
                         (sexp :format "Evaluate: %v")))
  :group 'cmd-script)

(defcustom cmd-virtual-env-variables
  '("CD" "DATE" "TIME" "RANDOM" "ERRORLEVEL" "CMDEXTVERSION"
    "CMDCMDLINE")
  "Virtual environment variables"
  :type '(repeat (cons (symbol :tag "Shell"))
                 (choice (repeat string)
                         (sexp :format "Evaluate: %v")))
  :group 'cmd-script)


;; Font-lock

(defvar cmd-font-lock-keywords-var
  '(;; labels
    ("\\(?1:^:[^:].*\\).*\\|\\_<goto\\_>[ \t]+\\(?1::\\w+\\)" 1
     'cmd-label-face)
    ;; escaped newlines
    ("\\(^\\|[^^]\\)\\(\\^^\\)*\\(\\^\\)$" 3 'cmd-escaped-newline-face)
    ;; variables
    ("\\_<\\(defined\\)\\_>[ \t]+\\([^ =]+\\)"
     (2 font-lock-variable-name-face))
    ("\\_<set\\_> \\(?:/[aApP] \\)?[ \t]*\\^?\"?\\([^=]+\\)="
     (1 font-lock-variable-name-face prepend))
    ("%%\\(~\\(?:[$[:alpha:]]*:\\)?\\)?\\([[:alnum:]]+\\)"
     (1 font-lock-type-face prepend t)
     (2 font-lock-variable-name-face prepend))
    ("[^%]%\\([^\n\r%=]+\\)%"
     (1 font-lock-variable-name-face prepend))
    ("[^%]%\\(~[[:alpha:]]*\\)\\([[:digit:]]\\)"
     (1 font-lock-type-face prepend)
     (2 font-lock-variable-name-face prepend))
    ;; delayed expansion
    ("!\\([^ \t\n\r!]+\\)!\"?"
     (1 font-lock-variable-name-face prepend))
    ("[ =][-/]+\\(\\w+\\)"
     (1 font-lock-type-face append)))
  "Default expressions to highlight.")

(defvar cmd-set-numerical-ops
  '("(" ")" "!" "~" "-" "*" "/" "%" "+" ">>" "<<" "&" "|" "^" "="
    "*=" "/=" "%=" "+=" "-=" "&=" "^=" "|=" "<<=" ">>=" ",")
  "Numeric operators available to SET /A expressions.")

(defconst cmd-escaped-line-re
  "\\(?:\\(?:.*[^\\^\n]\\)?\\(?:\\^\\^\\)*\\^\n\\)")

(defun cmd-is-quoted-p (pos)
  (and (eq (char-before pos) ?^)
       (not (cmd-is-quoted-p (1- pos)))))

(defun cmd-in-quoted-string-p (pos)
  (let ((sp (syntax-ppss)))
    (and (nth 3 sp)
         (cmd-is-quoted-p (nth 8 sp)))))

(defconst cmd-syntax-propertize
  (syntax-propertize-rules
   ("^[ \t]*\\(?:\\(@?r\\)em\\_>\\|\\(?1::\\):\\).*" (1 "<"))
   ;; try to treat keywords after echo as words until something
   ("\\(?:\\<@?echo\\_>\\)\\(?1:[^)(&|><\"\n\r]*\\)" (1 "w"))))

(defun cmd-font-lock-keywords ()
  "Function to get simple fontification for `cmd-font-lock-keywords'.
This adds rules for comments and assignments."
  (let ((cntrls (concat "\\_<" (regexp-opt cmd-control-keywords t) "\\_>"))
        (builtins (concat "\\_<" (regexp-opt cmd-builtins t) "\\_>"))
        (unix (concat "\\_<" (regexp-opt cmd-unix-keywords t) "\\_>")))
    (append
     cmd-font-lock-keywords-var
     `((,cntrls (1 font-lock-keyword-face nil t))
       (,builtins (1 font-lock-builtin-face))
       (,unix (1 font-lock-warning-face))))))


;; syntax

(defvar cmd-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; Beware: `w' should not be used for non-alphabetic chars.
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?~ "_" table)
    (modify-syntax-entry ?- "_" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?# "_" table)
    (modify-syntax-entry ?\} "_" table)
    (modify-syntax-entry ?\{ "_" table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    ;; escapes, but not in all cases like b/w ""?
    ;; (modify-syntax-entry ?^ "\\" table)
    (modify-syntax-entry ?@ "'" table)
    (modify-syntax-entry ?\\ "." table)
    (modify-syntax-entry ?% "." table)
    (modify-syntax-entry ?& "." table)
    (modify-syntax-entry ?| "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?\; "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?, "." table)
    table))


;; Completion

(defun cmd--vars-before-point ()
  "Vars could really be named anything, even with quotes interspersed,
just check for prior SET.  This drops a leading ^ or \", although that could
be a variable name, it usually isn't."
  (save-excursion
    (let ((vars ()))
      (while (re-search-backward
              "[Ss][Ee][Tt] +\\(?:/[aApP][\t ]+\\)?\\^?\"?\\([^= ]+\\)=" nil t)
        (push (match-string 1) vars))
      vars)))

(defun cmd--cmd-completion-table (string pred action)
  (let ((cmds
         (append (when (fboundp 'imenu--make-index-alist)
                   (mapcar #'car (imenu--make-index-alist)))
                 (mapcar (lambda (v) (concat v "="))
                         (cmd--vars-before-point))
                 (locate-file-completion-table
                  exec-path exec-suffixes string pred t))))
    (complete-with-action action cmds string pred)))

(defun cmd--environment-vars ()
  "Environment variables from `process-environment'."
  (mapcar (lambda (x)
            (substring x 0 (string-match "=" x)))
          process-environment))

(defun cmd--labels ()
  (save-excursion
    (goto-char (point-min))
    (let ((vars ()))
      (while (re-search-forward "^:\\([^: \n\r]+\\)" nil t)
        (push (match-string-no-properties 1) vars))
      vars)))

(defun cmd--for-vars ()
  (save-excursion
    (re-search-backward "%%\\(\\w+\\)" nil t)
    (list (match-string-no-properties 1))))

(defvar cmd-for-variable-modifiers
  '("" "f" "d" "p" "n" "x" "s" "a" "t" "z" "$PATH")
  "Variable modifiers in for loops.")

(defvar cmd-for-f-modifiers
  '("eol" "skip" "delims" "usebackq")
  "For /F options.")

(defun cmd-completion-at-point-function ()
  (save-excursion
    (skip-chars-forward "^%!\t\n ")
    (let ((end (point))
          (_ (skip-chars-backward "^~:%!\t\n "))
          (start (point)))
      (cond
       ((eq (char-before) ?%)
        (if (not (eq (char-before (1- (point))) ?%))
            (let ((case-fold-search t))
              (list start end (append (cmd--vars-before-point)
                                      (cmd--environment-vars)
                                      cmd-virtual-env-variables)))
          (list start end (cmd--for-vars))))
       ((and (eq (char-before) ?~)
             (eq (char-before (1- (point))) ?%))
        (list start end cmd-for-variable-modifiers))
       ((eq (char-before) ?!)
        (list start end (cmd--vars-before-point)))
       ((and (eq (char-before) ?:)
             (eq (char-before (1- (point))) ? ))
        (list start end (cmd--labels)))
       ;; (t nil
       ;;    (list start end #'cmd--cmd-completion-table))
       ))))


;; Indentation

(require 'smie)

(defconst cmd-smie-grammar
  (smie-prec2->grammar
   (smie-precs->prec2
    '((assoc ",") (assoc " ") (assoc ";")))))

(defun cmd-smie-rules (kind token)
  (pcase (cons kind token)
    (`(:elem . basic) cmd-indent-level)
    (`(:elem . args) 0)
    (`(:before . "(")
     (smie-rule-parent))
    (`(:list-intro . ,(or `"\n" `"")) t)))

(defun cmd-smie--forward-token ()
  (forward-comment (point-max))
  (cond
   ((and (looking-at "\\^\n")
         (cmd-is-quoted-p (1+ (point))))
    (goto-char (match-end 0))
    (smie-default-forward-token))
   (t (smie-default-forward-token))))

(defun cmd-smie--backward-token ()
  (forward-comment (- (point)))
  (cond
   ((and (eq (char-before) ?^)
         (cmd-is-quoted-p (point)))
    (skip-chars-backward "\\^")
    (smie-default-backward-token))
   (t (smie-default-backward-token))))

;; (defun cmd--line-continued-p ()
;;   (save-excursion
;;     (looking-back "[^\\(?:\\_<in\\_>\\)]*\)" 1)
;;     (end-of-line)
;;     (looking-back "\\^'")))
;; "\\(^\\|[^^]\\)\\(\\^^\\)*\\(\\^\\)$"

;; (defvar cmd-delimiters '(?& ?\| ?< ?> ?\( ?\))


;; User functions

(defun cmd-help-cmd (cmd)
  "Show help for batch file command CMD."
  (interactive "sHelp: ")
  (if (string-equal cmd "net")
      ;; FIXME: liable to quoting nightmare.  Use call-process?
      (shell-command "net /?") (shell-command (concat "help " cmd))))

(defun cmd-run ()
  "Run a batch file."
  (interactive)
  ;; FIXME: liable to quoting nightmare.  Use call/start-process?
  (save-buffer) (shell-command buffer-file-name))

(defun cmd-run-args (args)
  "Run a batch file with ARGS."
  (interactive "sArgs: ")
  ;; FIXME: Use `compile'?
  (shell-command (concat buffer-file-name " " args)))

(defun cmd-template ()
  "Insert minimal batch file template."
  (interactive)
  (goto-char (point-min))
  (insert "@echo off\nsetlocal enableextensions\n\n"))

(defun cmd-help  (&optional arg)
  "Show help output for command in other window in view-mode.  Command 
will be determined by one of `ARG', read from minibuffer with prefix,
or symbol-at-point will be attempted before requesting input."
    (interactive "P")
    (let ((cmd (or arg
                   (and current-prefix-arg
                        (read-string "Help: "))
                   (and (symbol-at-point)
                        (symbol-name (symbol-at-point)))
                   (read-string "Help: ")))
          (buff (get-buffer-create "*cmd help*")))
      (with-current-buffer-window
       "*cmd help*" nil nil
       (call-process-shell-command
        (if (string= cmd "net")
            "net /?" (concat "help " cmd)) nil "*cmd help*" 1)
       (view-mode 1))))

(defun cmd-help-online  ()
  "Lookup online documentation at ss64.com/nt."
    (interactive)
    (let* ((url "http://ss64.com/nt/")
           (default (and (symbol-at-point)
                         (symbol-name (symbol-at-point))))
           (cmd (read-from-minibuffer "Help: " default nil nil default)))
      (browse-url (format "%s/%s.html" url (downcase cmd)))))

(defun cmd-compile (&optional args)
  "Run script and output in compilation buffer."
  (interactive "P")
  (save-buffer)
  (let ((flags (and args
                    (read-string "Args: ")))
        (cmd (concat cmd-compile-file " /C ")))
    (compile (concat cmd args " " buffer-file-name))))


;; Inferior shell interaction - from sh-script.el

(defvar explicit-shell-file-name)

(defvar cmd-shell
  (file-name-nondirectory
   (file-name-sans-extension cmd-shell-file))
  "The shell.")
;;;###autoload(put 'cmd-shell 'safe-local-variable 'symbolp)

(defvar-local cmd-shell-process nil
  "The inferior shell process for interaction.") 

(defun cmd-shell-process (force)
  "Get a shell process for interaction.
If FORCE is non-nil and no process found, create one."
  (if (process-live-p cmd-shell-process)
      cmd-shell-process
    (setq cmd-shell-process
          (let ((procs (process-list))
                found proc)
            (while (and (not found) procs
                        (process-live-p (setq proc (pop procs)))
                        (process-command proc))
              (when (string= cmd-shell (file-name-nondirectory
                                        (car (process-command proc))))
                (setq found proc)))
            (or found
                (and force
                     (get-buffer-process
                      (let ((explicit-shell-file-name cmd-shell-file))
                        (shell)))))))))

(defun cmd-show-shell ()
  "Pop to the shell interaction buffer."
  (interactive)
  (pop-to-buffer (process-buffer (cmd-shell-process t))))

;; test string
;; (defun cmd-munge-text (text)
;;   "Strip comments, extra `%', and `\n' to send interactive text."
;;   (while (string-mat)))

(defun cmd-send-text (text)
  "Send text to the `cmd-shell-process'."
  (comint-send-string (cmd-shell-process t) (concat text "\n")))

(defun cmd-cd-here ()
  "Change directory of interactive shell to current one."
  (interactive)
  (cmd-send-text (concat "cd " default-directory)))

(defun cmd-send-line-or-region-and-step ()
  "Send the current line to the inferior shell and step to the next line.
When the region is active, send the region instead."
  (interactive)
  (let (from to end)
    (if (use-region-p)
        (setq from (region-beginning)
              to (region-end)
              end to)
      (setq from (line-beginning-position)
            to (line-end-position)
            end (1+ to)))
    (cmd-send-text (buffer-substring-no-properties from to))
    (goto-char end)))


;; 5  Main function

(defvar cmd-menu
  '("Cmd"
    ["Compile" cmd-compile :help "Compile (prefix for args)" :keys "<f5>"]
    ["Run" cmd-run :help "Run script" :keys "C-c C-c"]
    ["Run with Args" cmd-run-args :help "Run script with args" :keys "C-c C-a"]
    "--"
    ["Help" cmd-help :help "Show help at point (or prompt)" :keys "C-c ?"]
    ["Help online" cmd-help-online :help "Show help online" :keys "C-c C-?"]
    ["Help (Command)" cmd-help-cmd :help "Show help (prompt)"
     :keys "C-c C-/"]
    "--"
    ["Imenu" imenu :help "Navigate with imenu"]
    "--"
    ["Template" cmd-template :help "Insert template" :keys "C-c C-t"]))

(defvar cmd-mode-map
  (let ((map (make-sparse-keymap)))
    (easy-menu-define nil map nil cmd-menu)
    (define-key map "\C-c?"         'cmd-help)
    (define-key map (kbd "C-c C-?") 'cmd-help-online)
    (define-key map "\C-cC-/"       'cmd-help-cmd)
    (define-key map "\C-c\C-a"      'cmd-run-args)
    (define-key map "\C-c\C-c"      'cmd-run)
    (define-key map "\C-c\C-t"      'cmd-template)
    (define-key map (kbd "<f5>")    'cmd-compile)
    (define-key map "\C-c\C-z"      'cmd-show-shell)
    (define-key map "\C-x\C-e"      'cmd-send-line-or-region-and-step)
    (define-key map "\C-c\C-d"      'cmd-cd-here)
    map))

(define-abbrev-table 'cmd-mode-abbrev-table ())

;;;###autoload
(define-derived-mode cmd-mode prog-mode "cmd"
  "Major mode for editing DOS/Windows batch files.\n
Run script using `cmd-compile', `cmd-run' and `cmd-run-args'.
Start a new script from `cmd-template'.\n
Read help pages for DOS commands with
`cmd-help', `cmd-help', or `cmd-help-online'.
Navigate between sections using `imenu'.\n
\\{cmd-mode-map}"
  (make-local-variable 'cmd-shell-file)
  (make-local-variable 'cmd-shell)
  (setq-local local-abbrev-table cmd-mode-abbrev-table)
  (setq-local comment-start "rem ")
  (setq-local comment-start-skip "\\(?:::+\\|rem \\)[ \t]*")
  (setq-local comint-dynamic-complete-functions
              cmd-dynamic-complete-functions)
  (add-hook 'completion-at-point-functions #'comint-completion-at-point nil t)
  (add-hook 'completion-at-point-functions
            #'cmd-completion-at-point-function nil t)
  (setq-local comint-prompt-regexp "^[ \t]*")
  (setq-local syntax-propertize-function cmd-syntax-propertize)
  (add-hook 'syntax-propertize-extend-region-functions
            #'syntax-propertize-multiline 'append 'local)
  (setq-local font-lock-defaults
              `((cmd-font-lock-keywords)
                nil t)) ; case-insensitive keywords
  (setq-local imenu-generic-expression '((nil "^:[^:].*" 0)))
  (setq-local imenu-case-fold-search t)
  (setq-local outline-regexp ":[^:]")
  (smie-setup cmd-smie-grammar #'cmd-smie-rules
              :forward-token #'cmd-smie--forward-token
              :backward-token #'cmd-smie--backward-token))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.\\(bat\\|cmd\\)\\'" . cmd-mode))

(provide 'cmd-mode)

;;; cmd-mode.el ends here
