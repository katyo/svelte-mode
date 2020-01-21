;;; svelte-mode.el --- Emacs major mode for Svelte -*- lexical-binding:t -*-
;; Copyright (C) 2020 Leaf.

;; Author: Leaf <leafvocation@gmail.com>
;; Created: 21 Jan 2020
;; Keywords: wp languages
;; Homepage: https://github.com/leafOfTree/svelte-mode
;; Version: 1.0.0
;; Package-Version: 20200121.1
;; Package-Requires: ((emacs "26.1"))
;; Credits: mhtml-mode

;; This file is NOT part of GNU Emacs.

;; You can redistribute it and/or modify it under the terms of
;; the GNU Lesser General Public License v3.0.

;;; Commentary:

;; This major mode includes JavaScript/CSS and other language modes
;; as submode in html-mode.

;;; Code:
(eval-when-compile (require 'cl-lib))
(require 'sgml-mode)
(require 'js)
(require 'css-mode)
(require 'prog-mode)

(defcustom svelte-tag-relative-indent t
  "How <script> and <style> bodies are indented relative to the tag.

When t, indentation looks like:

  <script>
    code();
  </script>

When nil, indentation of the script body starts just below the
tag, like:

  <script>
  code();
  </script>

When `ignore', the script body starts in the first column, like:

  <script>
code();
  </script>"
  :group 'sgml
  :type '(choice (const nil) (const t) (const ignore))
  :safe 'symbolp
  :version "26.1")

(cl-defstruct svelte--submode
  name 			; Name of this submode.
  end-tag 		; HTML end tag.
  syntax-table          ; Syntax table.
  propertize            ; Propertize function.
  keymap                ; Keymap.
  ;; Captured locals that are set when entering a region.
  crucial-captured-locals
  ;; Other captured local variables; these are not set when entering a
  ;; region but let-bound during certain operations, e.g.,
  ;; indentation.
  captured-locals
  (excluded-locals
   () :documentation "Local variables that are not to be captured."))

(defconst svelte--crucial-variable-prefix
  (regexp-opt '("comment-" "uncomment-" "electric-indent-"
                "smie-" "forward-sexp-function" "completion-" "major-mode"))
  "Regexp matching the prefix of \"crucial\" buffer-locals we want to capture.")

(defconst svelte--variable-prefix
  (regexp-opt '("font-lock-" "indent-line-function"))
  "Regexp matching the prefix of buffer-locals we want to capture.")

(defun svelte--construct-submode (mode &rest args)
  "Computes the buffer-local variables in submode MODE with ARGS passed to it."
  (let ((captured-locals nil)
        (crucial-captured-locals nil)
        (submode (apply #'make-svelte--submode args)))
    (with-temp-buffer
      (funcall mode)
      ;; Make sure font lock is all set up.
      (font-lock-set-defaults)
      ;; This has to be set to a value other than the svelte-mode
      ;; value, to avoid recursion.
      (unless (variable-binding-locus 'font-lock-fontify-region-function)
        (setq-local font-lock-fontify-region-function
                    #'font-lock-default-fontify-region))
      (dolist (iter (buffer-local-variables))
	(when (string-match svelte--crucial-variable-prefix
                            (symbol-name (car iter)))
          (push iter crucial-captured-locals))
        (when (string-match svelte--variable-prefix (symbol-name (car iter)))
	  (unless (member (car iter)
			  (svelte--submode-excluded-locals submode))
	    (push iter captured-locals))))
      (setf (svelte--submode-crucial-captured-locals submode)
            crucial-captured-locals)
      (setf (svelte--submode-captured-locals submode) captured-locals))
    submode))

(defun svelte--mark-buffer-locals (submode)
  "Make buffer local variables from SUBMODE."
  (dolist (iter (svelte--submode-captured-locals submode))
    (make-local-variable (car iter))))

(defvar-local svelte--crucial-variables nil
  "List of all crucial variable symbols.")

(defun svelte--mark-crucial-buffer-locals (submode)
  "Make crucial buffer local variables from SUBMODE."
  (dolist (iter (svelte--submode-crucial-captured-locals submode))
    (make-local-variable (car iter))
    (push (car iter) svelte--crucial-variables)))

(defconst svelte--css-submode
  (svelte--construct-submode 'css-mode
                            :name "CSS"
                            :end-tag "</style>"
                            :syntax-table css-mode-syntax-table
                            :propertize css-syntax-propertize-function
                            :keymap css-mode-map))

(defconst svelte--js-submode
  (svelte--construct-submode 'js-mode
                            :name "JavaScript"
                            :end-tag "</script>"
                            :syntax-table js-mode-syntax-table
                            :propertize #'js-syntax-propertize
                            :keymap js-mode-map))

(defvar svelte-block-re)
(defvar svelte-expression-re)
(defvar svelte-directive-prefix-re)
(defvar svelte--directive-prefix)
(defvar svelte--block-keyword)
(defvar svelte--font-lock-html-keywords)

(defvar svelte--pug-submode)
(defvar pug-tab-width)
(defvar pug-indent-function)
(defvar pug-mode-syntax-table)
(defvar pug-mode-map)
(defvar svelte--coffee-submode)
(defvar coffee-tab-with)
(defvar coffee-mode-syntax-table)
(defvar coffee-mode-map)

(defvar emmet-use-style-tag-and-attr-detection)
(declare-function emmet-check-if-between "emmet-mode")
(declare-function pug-forward-through-whitespace "pug-mode")
(declare-function pug-compute-indentation-advice "svelte-mode")

(defmacro svelte--with-locals (submode &rest body)
  "Bind SUBMODE local variables and then run BODY."
  (declare (indent 1))
  `(cl-progv
       (when ,submode (mapcar #'car (svelte--submode-captured-locals ,submode)))
       (when ,submode (mapcar #'cdr (svelte--submode-captured-locals ,submode)))
     (cl-progv
	 (when ,submode (mapcar #'car (svelte--submode-crucial-captured-locals
				       ,submode)))
	 (when ,submode (mapcar #'cdr (svelte--submode-crucial-captured-locals
				       ,submode)))
       ,@body)))

(defun svelte--submode-lighter ()
  "Mode-line lighter indicating the current submode."
  ;; The end of the buffer has no text properties, so in this case
  ;; back up one character, if possible.
  (let* ((where (if (and (eobp) (not (bobp)))
                    (1- (point))
                  (point)))
         (submode (get-text-property where 'svelte-submode)))
    (if submode
        (svelte--submode-name submode)
      nil)))

(defvar-local svelte--last-submode nil
  "Record the last visited submode.
This is used by `svelte--pre-command'.")

(defvar-local svelte--stashed-crucial-variables nil
  "Alist of stashed values of the crucial variables.")

(defun svelte--stash-crucial-variables ()
  "Stash crucial variables of current buffer."
  (setq svelte--stashed-crucial-variables
        (mapcar (lambda (sym)
                  (cons sym (buffer-local-value sym (current-buffer))))
                svelte--crucial-variables)))

(defun svelte--map-in-crucial-variables (alist)
  "Set all crucial variables in ALIST."
  (dolist (item alist)
    (set (car item) (cdr item))))

(defun svelte--pre-command ()
  "Run pre- and post-hook for each command if current submode is changed."
  (let ((submode (get-text-property (point) 'svelte-submode)))
    (unless (eq submode svelte--last-submode)
      ;; If we're entering a submode, and the previous submode was
      ;; nil, then stash the current values first.  This lets the user
      ;; at least modify some values directly.  FIXME maybe always
      ;; stash into the current mode?
      (when (and submode (not svelte--last-submode))
        (svelte--stash-crucial-variables))
      (svelte--map-in-crucial-variables
       (if submode
           (svelte--submode-crucial-captured-locals submode)
         svelte--stashed-crucial-variables))
      (setq svelte--last-submode submode))))

;;; Syntax propertize
(defun svelte--syntax-propertize-submode (submode end)
  "Set text properties from point to END or `end-tag' before END in SUBMODE."
  (save-excursion
    (when (search-forward (svelte--submode-end-tag submode) end t)
      (setq end (match-beginning 0))))
  (set-text-properties (point) end
                       (list 'svelte-submode submode
                             'syntax-table (svelte--submode-syntax-table submode)
                             ;; We want local-map here so that we act
                             ;; more like the sub-mode and don't
                             ;; override minor mode maps.
                             'local-map (svelte--submode-keymap submode)))
  (when (svelte--submode-propertize submode)
    (funcall (svelte--submode-propertize submode) (point) end))
  (goto-char end))

(defvar svelte--syntax-propertize
  (syntax-propertize-rules
   ("<template.*pug.*>"
    (0 (ignore
        (goto-char (match-end 0))
        ;; Don't apply in a comment.
        (unless (syntax-ppss-context (syntax-ppss))
	  (unless (boundp 'svelte--pug-submode)
	    (svelte--load-pug-submode))
          (svelte--syntax-propertize-submode svelte--pug-submode end)))))
   ("<script.*coffee.*>"
    (0 (ignore
	(goto-char (match-end 0))
	;; Don't apply in a comment.
	(unless (syntax-ppss-context (syntax-ppss))
	  (unless (boundp 'svelte--coffee-submode)
	    (svelte--load-coffee-submode))
	  (svelte--syntax-propertize-submode svelte--coffee-submode end)))))
   ("<style.*?>"
    (0 (ignore
        (goto-char (match-end 0))
        ;; Don't apply in a comment.
        (unless (syntax-ppss-context (syntax-ppss))
          (svelte--syntax-propertize-submode svelte--css-submode end)))))
   ("<script.*?>"
    (0 (ignore
        (goto-char (match-end 0))
        ;; Don't apply in a comment.
        (unless (syntax-ppss-context (syntax-ppss))
          (svelte--syntax-propertize-submode svelte--js-submode end)))))
   sgml-syntax-propertize-rules)
  "Svelte syntax propertize rules.")

(defun svelte-syntax-propertize (start end)
  "Svelte syntax propertize function for text between START and END."

  ;; First remove our special settings from the affected text.  They
  ;; will be re-applied as needed.
  (remove-list-of-text-properties start end
                                  '(syntax-table local-map svelte-submode))
  (goto-char start)
  ;; Be sure to look back one character, because START won't yet have
  ;; been propertized.
  (unless (bobp)
    (let ((submode (get-text-property (1- (point)) 'svelte-submode)))
      (if submode
          (svelte--syntax-propertize-submode submode end))))
  (sgml-syntax-propertize (point) end svelte--syntax-propertize))

(setq svelte--block-keyword '("if" "else" "each" "await" "then" "catch" "as"))
(setq svelte--directive-prefix '("on" "bind" "use" "in" "out" "transition" "animate" "class"))

;;; Indentation
(defun svelte-indent-line ()
  "Indent the current line as HTML, JS, or CSS, according to its context."
  (interactive)
  (let ((submode (save-excursion
                   (back-to-indentation)
                   (get-text-property (point) 'svelte-submode))))
    (if submode
        (save-restriction
          (let* ((region-start
                  (or (previous-single-property-change (point) 'svelte-submode)
                      (point)))
                 (base-indent (save-excursion
                                (goto-char region-start)
                                (sgml-calculate-indent))))
            (cond
             ((eq svelte-tag-relative-indent nil)
              (setq base-indent (- base-indent sgml-basic-offset)))
             ((eq svelte-tag-relative-indent 'ignore)
              (setq base-indent 0)))
            (narrow-to-region region-start (point-max))
            (let ((prog-indentation-context (list base-indent)))
              (svelte--with-locals submode
                ;; indent-line-function was rebound by
                ;; svelte--with-locals.
                (funcall indent-line-function)))))
      ;; HTML.
      (svelte-html-indent-line))))

(defun svelte-html-indent-line ()
  "Indent HTML within Svelte."
  (interactive)
  (let* ((savep (point))
	 (block-offset (svelte--html-block-offset))
	 (indent-col
	  (save-excursion
	    (back-to-indentation)
	    (if (>= (point) savep) (setq savep nil))
	    (sgml-calculate-indent))))
    (when block-offset
      (save-excursion
	(forward-line -1)
	(setq indent-col (+ block-offset (current-indentation)))))
    (if (null indent-col)
	'noindent
      (if savep
	  (save-excursion (indent-line-to indent-col))
	(indent-line-to indent-col)))))

(defun svelte--html-block-offset ()
  "Indentation offset of Svelte blocks like {#if...}, {#each...}."
  (cond ((or (svelte--previous-block "beginning"))
	 sgml-basic-offset)
	((or (svelte--current-block "middle")
	     (svelte--current-block "end")
	     (and (svelte--previous-block "end")
		  (svelte--current-tag "end")))
	 (- 0 sgml-basic-offset))
	((or (svelte--previous-block "end")
	     (and (svelte--previous-block "end")
		  (svelte--current-tag "start")))
	 0)))
(defun svelte--current-tag (type)
  "Search current line to find tag of TYPE(beginning or end)."
  (interactive)
  (let ((bound (save-excursion
		 (beginning-of-line)
		 (point)))
	(tag-re (cond ((equal type "beginning")
		       ;; "<\\w+")
		       "^[\t ]*<\\w+")
		      ((equal type "end")
		       "^[\t ]*</\\w+"))))
    (when tag-re
      (save-excursion
	(end-of-line)
	(re-search-backward tag-re bound t)))))

(defun svelte--previous-block (type)
  "Search previous line to find block of TYPE(beginning, middle or end)."
  (let ((bound (svelte--beginning-of-previous-line))
	(block-re (cond ((equal type "beginning")
			 (svelte--beginning-of-block-re))
			((equal type "middle")
			 (svelte--middle-of-block-re))
			((equal type "end")
			 (svelte--end-of-block-re)))))
    (when block-re
      (save-excursion
	(beginning-of-line)
	(re-search-backward block-re bound t)))))

(defun svelte--current-block (type)
  "Search current line to find block of TYPE(beginning, middle or end)."
  (let ((bound (save-excursion
		 (beginning-of-line)
		 (point)))
	(block-re (cond ((equal type "beginning")
			 (svelte--beginning-of-block-re))
			((equal type "middle")
			 (svelte--middle-of-block-re))
			((equal type "end")
			 (svelte--end-of-block-re)))))
    (when block-re
      (save-excursion
	(end-of-line)
	(re-search-backward block-re bound t)))))

(defun svelte--beginning-of-block-re ()
  "Regexp of beginning of block."
  (concat
   "{#\\("
   (string-join svelte--block-keyword "\\|")
   "\\)"))

(defun svelte--middle-of-block-re ()
  "Regexp of middle of block."
  (concat
   "{:\\("
   (string-join svelte--block-keyword "\\|")
   "\\)"))

(defun svelte--end-of-block-re ()
  "Regexp of end of block."
  (concat
   "{/\\("
   (string-join svelte--block-keyword "\\|")
   "\\)"))

(defun svelte--beginning-of-previous-line ()
  "Beginning of previous non-blank line."
  (save-excursion
    (forward-line -1)
    (end-of-line)
    (skip-chars-backward "\n[:space:]")
    (beginning-of-line)
    (point)))

;;; Font lock
(defvar font-lock-beg)
(defvar font-lock-end)

(defun svelte--extend-font-lock-region ()
  "Extend the font lock region according to HTML sub-mode needs.

This is used via `font-lock-extend-region-functions'.  It ensures
that the font-lock region is extended to cover either whole
lines, or to the spot where the submode changes, whichever is
smallest."
  (let ((orig-beg font-lock-beg)
        (orig-end font-lock-end))
    ;; The logic here may look odd but it is needed to ensure that we
    ;; do the right thing when trying to limit the search.
    (save-excursion
      (goto-char font-lock-beg)
      ;; previous-single-property-change starts by looking at the
      ;; previous character, but we're trying to extend a region to
      ;; include just characters with the same submode as this
      ;; character.
      (unless (eobp)
        (forward-char))
      (setq font-lock-beg (previous-single-property-change
                           (point) 'svelte-submode nil
                           (line-beginning-position)))
      (unless (eq (get-text-property font-lock-beg 'svelte-submode)
                  (get-text-property orig-beg 'svelte-submode))
        (cl-incf font-lock-beg))

      (goto-char font-lock-end)
      (unless (bobp)
        (backward-char))
      (setq font-lock-end (next-single-property-change
                           (point) 'svelte-submode nil
                           (line-beginning-position 2)))
      (unless (eq (get-text-property font-lock-end 'svelte-submode)
                  (get-text-property orig-end 'svelte-submode))
        (cl-decf font-lock-end)))

    ;; Also handle the multiline property -- but handle it here, and
    ;; not via font-lock-extend-region-functions, to avoid the
    ;; situation where the two extension functions disagree.
    ;; See bug#29159.
    (font-lock-extend-region-multiline)

    (or (/= font-lock-beg orig-beg)
        (/= font-lock-end orig-end))))

(defun svelte--submode-fontify-one-region (submode beg end &optional loudly)
  "Fontify the text between BEG and END with SUBMODE locals bound.

If LOUDLY is non-nil, print status messages while fontifying."
  (if submode
      (svelte--with-locals submode
        (save-restriction
          (font-lock-fontify-region beg end loudly)))
    (font-lock-set-defaults)
    (font-lock-default-fontify-region beg end loudly)))

(defun svelte--submode-fontify-region (beg end loudly)
  "Fontify the text between BEG and END.

If LOUDLY is non-nil, print status message while fontifying."
  (syntax-propertize end)
  (let ((orig-beg beg)
        (orig-end end)
        (new-beg beg)
        (new-end end))
    (while (< beg end)
      (let ((submode (get-text-property beg 'svelte-submode))
            (this-end (next-single-property-change beg 'svelte-submode
                                                   nil end)))
        (let ((extended (svelte--submode-fontify-one-region submode beg
                                                           this-end loudly)))
          ;; If the call extended the region, take note.  We track the
          ;; bounds we were passed and take the union of any extended
          ;; bounds.
          (when (and (consp extended)
                     (eq (car extended) 'jit-lock-bounds))
            (setq new-beg (min new-beg (cadr extended)))
            ;; Make sure that the next region starts where the
            ;; extension of this region ends.
            (setq this-end (cddr extended))
            (setq new-end (max new-end this-end))))
        (setq beg this-end)))
    (when (or (/= orig-beg new-beg)
              (/= orig-end new-end))
      (cons 'jit-lock-bounds (cons new-beg new-end)))))

(setq svelte-block-re "\\({[#:/]\\).*\\(}\\)$")
(setq svelte-expression-re "\\({\\)[^}]+\\(}\\)")
(setq svelte-directive-prefix-re (concat
				  (regexp-opt svelte--directive-prefix)
				  ":[^=/> ]+"))

(setq svelte--font-lock-html-keywords
      `((,svelte-block-re
	 (1 font-lock-type-face)
	 (2 font-lock-type-face)
	 (,(regexp-opt svelte--block-keyword 'words)
	  (goto-char (match-end 1)) nil (0 font-lock-keyword-face)))
	(,svelte-expression-re
	 (1 font-lock-type-face)
	 (2 font-lock-type-face))
	(,svelte-directive-prefix-re
	 (0 font-lock-type-face))))

(add-hook 'html-mode-hook
	  (lambda ()
	    (font-lock-add-keywords
	     nil
	     svelte--font-lock-html-keywords)))

;;; Pug mode
(defun svelte--load-pug-submode ()
  "Load `pug-mode' and patch it."
  (require 'pug-mode nil t)
  (setq pug-tab-width sgml-basic-offset)

  (defconst svelte--pug-submode
    (svelte--construct-submode 'pug-mode
			       :name "Pug"
			       :end-tag "</template>"
			       :syntax-table pug-mode-syntax-table
			       :excluded-locals
			       '(font-lock-extend-region-functions)
			       :keymap pug-mode-map))

  (defun svelte--pug-compute-indentation-advice ()
    "Calculate the maximum sensible indentation for the current line."
    (save-excursion
      (beginning-of-line)
      (if (bobp) 0
	(pug-forward-through-whitespace t)
	(+ (current-indentation)
	   (or (funcall pug-indent-function)
	       ;; Take care of prog-indentation-context
	       (car prog-indentation-context)
	       0)))))

  (advice-add 'pug-compute-indentation
	      :around
	      #'svelte--pug-compute-indentation-advice)
  
  (svelte--mark-buffer-locals svelte--pug-submode)
  (svelte--mark-crucial-buffer-locals svelte--pug-submode)
  (setq svelte--crucial-variables (delete-dups svelte--crucial-variables)))

;;; Coffee mode
(defun svelte--load-coffee-submode ()
  "Load `coffee-mode' and patch it."
  (require 'coffee-mode nil t)
  (setq coffee-tab-with sgml-basic-offset)

  (defconst svelte--coffee-submode
    (svelte--construct-submode 'coffee-mode
			       :name "Coffee"
			       :end-tag "</script>"
			       :syntax-table coffee-mode-syntax-table
			       :keymap coffee-mode-map)))

;;; Emmet mode
(defun svelte--emmet-detect-style-tag-and-attr-advice ()
  "Detect style tag begin as `<style'."
  (let* ((style-attr-end "[^=][\"']")
	 (style-attr-begin "style=[\"']")
	 (style-tag-end "</style>")
	 ;; Generic style tag begin
	 (style-tag-begin "<style"))
    (and emmet-use-style-tag-and-attr-detection
	 (or
	  (emmet-check-if-between style-attr-begin style-attr-end)
	  (emmet-check-if-between style-tag-begin style-tag-end)))))

(advice-add
 'emmet-detect-style-tag-and-attr
 :around
 #'svelte--emmet-detect-style-tag-and-attr-advice)

;;; Flyspell
(declare-function flyspell-generic-progmode-verify "flyspell")

(defun svelte--flyspell-check-word ()
  "Flyspell check word."
  (let ((submode (get-text-property (point) 'svelte-submode)))
    (if submode
        (flyspell-generic-progmode-verify)
      t)))

;;;###autoload
(define-derived-mode svelte-mode html-mode
  '(("Svelte/") (:eval (or (svelte--submode-lighter) "HTML")))
  "Major mode based on `html-mode', but works with embedded JS and CSS.

Code inside a <script> element is indented using the rules from
`js-mode'; and code inside a <style> element is indented using
the rules from `css-mode'."
  (setq-local indent-line-function #'svelte-indent-line)
  (setq-local syntax-propertize-function #'svelte-syntax-propertize)
  (setq-local font-lock-fontify-region-function
              #'svelte--submode-fontify-region)
  (setq-local font-lock-extend-region-functions
              '(svelte--extend-font-lock-region))

  ;; Attach this to both pre- and post- hooks just in case it ever
  ;; changes a key binding that might be accessed from the menu bar.
  (add-hook 'pre-command-hook #'svelte--pre-command nil t)
  (add-hook 'post-command-hook #'svelte--pre-command nil t)

  ;; Make any captured variables buffer-local.
  (svelte--mark-buffer-locals svelte--css-submode)
  (svelte--mark-buffer-locals svelte--js-submode)

  (svelte--mark-crucial-buffer-locals svelte--css-submode)
  (svelte--mark-crucial-buffer-locals svelte--js-submode)
  (setq svelte--crucial-variables (delete-dups svelte--crucial-variables))

  ;: Hack
  (js--update-quick-match-re)

  ;; This is sort of a prog-mode as well as a text mode.
  (run-hooks 'prog-mode-hook))

(put 'svelte-mode 'flyspell-mode-predicate #'svelte--flyspell-check-word)

(add-to-list 'auto-mode-alist '("\\.svelte\\'" . svelte-mode))
(provide 'svelte-mode)

;;; svelte-mode.el ends here
