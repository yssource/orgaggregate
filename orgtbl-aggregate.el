;; -*- coding:utf-8;-*-
;;; orgtbl-aggregate.el --- Create an aggregated Org table from another one

;; Copyright (C) 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020  Thierry Banel

;; Authors:
;;   Thierry Banel tbanelwebmin at free dot fr
;;   Michael Brand michael dot ch dot brand at gmail dot com
;; Contributors:
;;   Eric Abrahamsen
;;   Alejandro Erickson alejandro dot erickson at gmail dot com
;;   Uwe Brauer
;;   Peking Duck
;;   Bill Hunker

;; Version: 1.0
;; Keywords: org, table, aggregation, filtering

;; orgtbl-aggregate is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; orgtbl-aggregate is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; A new org-mode table is automatically updated,
;; based on another table acting as a data source
;; and user-given specifications for how to perform aggregation.
;;
;; Example:
;; Starting from a source table of activities and quantities
;; (whatever they are) over several days,
;; 
;; #+TBLNAME: original
;; | Day       | Color | Level | Quantity |
;; |-----------+-------+-------+----------|
;; | Monday    | Red   |    30 |       11 |
;; | Monday    | Blue  |    25 |        3 |
;; | Tuesday   | Red   |    51 |       12 |
;; | Tuesday   | Red   |    45 |       15 |
;; | Tuesday   | Blue  |    33 |       18 |
;; | Wednesday | Red   |    27 |       23 |
;; | Wednesday | Blue  |    12 |       16 |
;; | Wednesday | Blue  |    15 |       15 |
;; | Thursday  | Red   |    39 |       24 |
;; | Thursday  | Red   |    41 |       29 |
;; | Thursday  | Red   |    49 |       30 |
;; | Friday    | Blue  |     7 |        5 |
;; | Friday    | Blue  |     6 |        8 |
;; | Friday    | Blue  |    11 |        9 |
;; 
;; an aggregation is built for each day (because several rows
;; exist for each day), typing C-c C-c
;; 
;; #+BEGIN: aggregate :table original :cols "Day mean(Level) sum(Quantity)"
;; | Day       | mean(Level) | sum(Quantity) |
;; |-----------+-------------+---------------|
;; | Monday    |        27.5 |            14 |
;; | Tuesday   |          43 |            45 |
;; | Wednesday |          18 |            54 |
;; | Thursday  |          43 |            83 |
;; | Friday    |           8 |            22 |
;; #+END
;;
;; A wizard can be used:
;; M-x org-insert-dblock:aggregate
;;
;; Full documentation here:
;;   https://github.com/tbanel/orgaggregate/blob/master/README.org

;;; Requires:
(require 'calc-ext)
(require 'org-table)
(eval-when-compile (require 'cl-lib))

;;; Code:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The function (org-table-to-lisp) have been greatly enhanced
;; in Org Mode version 9.4
;; To benefit from this speedup in older versions of Org Mode,
;; this function is copied here with a slightly different name

(defun org-table-to-lisp-9-4 (&optional txt)
  "Convert the table at point to a Lisp structure.

The structure will be a list.  Each item is either the symbol `hline'
for a horizontal separator line, or a list of field values as strings.
The table is taken from the parameter TXT, or from the buffer at point."
  (if txt
      (with-temp-buffer
        (insert txt)
        (goto-char (point-min))
        (org-table-to-lisp-9-4))
    (save-excursion
      (goto-char (org-table-begin))
      (let ((table nil))
        (while (re-search-forward "\\=[ \t]*|" nil t)
	  (let ((row nil))
	    (if (looking-at "-")
		(push 'hline table)
	      (while (not (progn (skip-chars-forward " \t") (eolp)))
		(push (buffer-substring-no-properties
		       (point)
		       (progn (re-search-forward "[ \t]*\\(|\\|$\\)")
			      (match-beginning 0)))
		      row))
	      (push (nreverse row) table)))
	  (forward-line))
        (nreverse table)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Here is a bunch of useful utilities,
;; generic enough to be detached from the orgtbl-aggregate package.
;; For the time being, they are here.

(defun orgtbl-list-local-tables ()
  "Search for available tables in the current file."
  (interactive)
  (let ((tables))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*#\\+\\(tbl\\)?name:[ \t]*\\(.*\\)" nil t)
	(push (match-string-no-properties 2) tables)))
    tables))

(defun orgtbl-get-distant-table (name-or-id)
  "Find a table in the current buffer named NAME-OR-ID
and returns it as a lisp list of lists.
An horizontal line is translated as the special symbol `hline'."
  (unless (stringp name-or-id)
    (setq name-or-id (format "%s" name-or-id)))
  (let (buffer loc)
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward
	   (concat "^[ \t]*#\\+\\(tbl\\)?name:[ \t]*"
		   (regexp-quote name-or-id)
		   "[ \t]*$")
	   nil t)
	  (setq buffer (current-buffer)
		loc (match-beginning 0))
	(let ((id-loc (org-id-find name-or-id 'marker)))
	  (unless (and id-loc (markerp id-loc))
	    (error "Can't find remote table \"%s\"" name-or-id))
	  (setq buffer (marker-buffer id-loc)
		loc (marker-position id-loc))
	  (move-marker id-loc nil))))
    (with-current-buffer buffer
      (save-excursion
	(goto-char loc)
	(forward-char 1)
	(unless (and (re-search-forward "^\\(\\*+ \\)\\|[ \t]*|" nil t)
		     (not (match-beginning 1)))
	  (user-error "Cannot find a table at NAME or ID %s" name-or-id))
	(org-table-to-lisp-9-4)))))

(defun orgtbl-get-header-distant-table (table &optional asstring)
  "Return the header of TABLE as a list, or as a string if
ASSTRING is true. TABLE names a table in the same buffer.  The
function takes care of possibly missing headers, and in this case
returns a list of $1, $2, $3... column names.  Actual column
names which are not fully alphanumeric are quoted."
  (setq table (orgtbl-get-distant-table table))
  (while (eq 'hline (car table))
    (setq table (cdr table)))
  (let ((header
	 (if (memq 'hline table)
	     (cl-loop for x in (car table)
		      collect
		      (if (string-match "^[[:word:]0-9_$]+$" x)
			  x
			(format "\"%s\"" x)))
	   (cl-loop for x in (car table)
		    for i from 1
		    collect (format "$%s" i)))))
    (if asstring
	(mapconcat #'identity header " ")
      header)))

(defun orgtbl-insert-elisp-table (table)
  "Insert TABLE in current buffer at point.
TABLE is a list of lists of cells.  The list may contain the
special symbol 'hline to mean an horizontal line."
  (let* ((nbrows (length table))
	 (nbcols (cl-loop
		  for row in table
		  maximize (if (listp row) (length row) 0)))
	 (maxwidths  (make-list nbcols 1))
	 (numbers    (make-list nbcols 0))
	 (non-empty  (make-list nbcols 0)))
    ;; remove text properties, compute maxwidths
    (cl-loop for row in table
	     do
	     (cl-loop for cell on row
		      for mx on maxwidths
		      for nu on numbers
		      for ne on non-empty
		      do
		      (progn
			(setcar
			 cell
			 (substring-no-properties (or (car cell) "")))
			(when (string-match-p org-table-number-regexp (car cell))
			  (cl-incf (car nu)))
			(unless (equal (car cell) "")
			  (cl-incf (car ne)))
			(if (< (car mx) (length (car cell)))
			    (setcar mx (length (car cell)))))))
    ;; pad cells with spaces to maxwidths,
    ;; either left or right according to alignement
    (cl-loop for row in table
	     do
	     (cl-loop for cell on row
		      for mx in maxwidths
		      for nu in numbers
		      for ne in non-empty
		      do
		      (let ((pad (- mx (length (car cell)))))
			(if (> pad 0)
			    (setcar
			     cell
			     (if (< nu (* org-table-number-fraction ne))
				 (concat (car cell) (make-string pad ? ))
			       (concat (make-string pad ? ) (car cell))))))))
    ;; inactivating jit-lock-after-change boosts performance a lot
    (cl-letf (((symbol-function 'jit-lock-after-change) (lambda (a b c)) ))
      ;; insert well padded and aligned cells at current buffer position
      (cl-loop for row in table
	       do
	       (if (listp row)
		   (cl-loop for cell in row
			    do (insert "| " cell " "))
		 (let ((bar "|"))
		   (cl-loop for mx in maxwidths
			    do (insert bar (make-string (+ mx 2) ?-))
			    do (setq bar "+"))))
	       (insert "|\n")))))

(defun org-time-string-to-calc (orgdate)
  "Convert a string in Org-date format to Calc internal representation
Returns nil if parameter is not a date."
  (and (string-match org-ts-regexp0 orgdate)
       (math-parse-date (replace-regexp-in-string " *[a-z]*[.] *" " " orgdate))))

;; creating long lists in the right order may be done
;; - by (nconc)  but behavior is quadratic
;; - by (cons) (nreverse)
;; a third way involves keeping track of the last cons of the growing list
;; a cons at the head of the list is used for housekeeping
;; the actual list is (cdr ls)

(defsubst -appendable-list-create ()
  (let ((x (cons nil nil)))
    (setcar x x)
    x))

(defmacro -appendable-list-append (ls value)
  `(setcar ,ls (setcdr (car ,ls) (cons ,value nil))))

(defmacro -appendable-list-get (ls)
  `(cdr ,ls))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The venerable Calc is used thoroughly by the Aggregate package.
;; A few bugs were found.
;; The fixes are here for the time being

(require 'calc-arith)

(defun math-max-list (a b)
  (if b
      (if (or (Math-anglep (car b)) (eq (caar b) 'date)
	      (and (eq (car (car b)) 'intv) (math-intv-constp (car b)))
	      (math-infinitep (car b)))
	  (math-max-list (math-max a (car b)) (cdr b))
	(math-reject-arg (car b) 'anglep))
    a))

(defun math-min-list (a b)
  (if b
      (if (or (Math-anglep (car b)) (eq (caar b) 'date)
	      (and (eq (car (car b)) 'intv) (math-intv-constp (car b)))
	      (math-infinitep (car b)))
	  (math-min-list (math-min a (car b)) (cdr b))
	(math-reject-arg (car b) 'anglep))
    a))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The Aggregation package

(defun orgtbl-to-aggregated-table-colname-to-int (colname table &optional err)
  "Convert the column name into an integer (first column is numbered 1)
COLNAME may be:
- a dollar form, like $5 which is converted to 5
- an alphanumeric name which appears in the column header (if any)
- the special symbol `hline' which is converted into 0
If COLNAME is quoted (single or double quotes),
quotes are removed beforhand.
When COLNAME does not match any actual column,
an error is generated if ERR optional parameter is true
otherwise nil is returned."
  (if (symbolp colname)
      (setq colname (symbol-name colname)))
  (if (or (string-match "^'\\(.*\\)'$" colname)
	  (string-match "^\"\\(.*\\)\"$" colname))
      (setq colname (match-string 1 colname)))
  ;; skip first hlines if any
  (while (not (listp (car table)))
    (setq table (cdr table)))
  (cond ((equal colname "hline")
	 0)
	((string-match "^\\$\\([0-9]+\\)$" colname)
	 (let ((n (string-to-number (match-string 1 colname))))
	   (if (<= n (length (car table)))
	       n
	     (if err
		 (user-error "Column %s outside table" colname)))))
	(t
	 (or
	  (cl-loop
	   for h in (car table)
	   for i from 1
	   thereis (and (equal h colname) i))
	  (and
	   err
	   (user-error "Column %s not found in table" colname))))))

(defun orgtbl-to-aggregated-replace-colnames (table expression)
  "Replace occurrences of column names in lisp EXPRESSION with
forms like (nth N row), N being the numbering of columns.  Doing
so, the EXPRESSION is ready to be computed against a table row."
  (cond
   ((listp expression)
    (cons (car expression)
	  (cl-loop for x in (cdr expression)
		   collect
		   (orgtbl-to-aggregated-replace-colnames table x))))
   ((numberp expression)
    expression)
   (t
    (let ((n (orgtbl-to-aggregated-table-colname-to-int expression table)))
      (if n
	  (list 'nth n 'row)
	expression)))))


(defun orgtbl-to-aggregated-replace-colnames-$ (table column)
  "Replace occurrences of column names in lisp COLUMN with
$N, N being the numbering of columns in the input table.  Doing
so, the COLUMN is ready to be computed computed by Calc."
  (replace-regexp-in-string
   (rx (or
	(group ?'  (* (not ?' )) ?')
	(group ?\" (* (not ?\")) ?\")
	(group bow (+ word)      eow)))
   (lambda (var)
     (cond
      ;; aggregate functions with or without the leading "v"
      ;; sum(X) and vsum(X) are equivalent
      ((member
	var
	'("mean" "meane" "gmean" "hmean" "median" "sum" "min" "max"
	  "prod" "pvar" "sdev" "psdev" "corr" "cov" "pcov"
	  "count"))
       (format "v%s" var))
      ((member
	var
	'("vmean" "vmeane" "vgmean" "vhmean" "vmedian" "vsum" "vmin" "vmax"
	  "vprod" "vpvar" "vsdev" "vpsdev" "vcorr" "vcov" "vpcov"
	  "vcount"))
       var)
      ;; compatibility: list(X) will be obsoleted for (X)
      ((equal var "list")
       "")
      (t ;; replace VAR if it is a column name
       (save-match-data ;; save because we are called within a replace-regexp
	 (let ((i (orgtbl-to-aggregated-table-colname-to-int
		   var
		   table)))
	   (if i
	       (format "$%s" i)
	     var))))))
   column))


(defun orgtbl-to-aggregated-table-parse-spec (column table)
  "Replace COLUMN name, which is a key-column, with a number
starting from 1, or 0 for the special 'hline column.  If COLUMN
is a Calc expression, nil is returned."
  (and (or (string-match "^\\([[:word:]0-9_$]+\\)$" column)
	   (string-match "^'\\(.*\\)'$" column)
	   (string-match "^\"\\(.*\\)\"$" column))
       (orgtbl-to-aggregated-table-colname-to-int
	(match-string 1 column)
	table
	t)))

(defun orgtbl-to-aggregated-table-add-group (groups hgroups row aggcond)
  "Add the source ROW to the GROUPS of rows.
If ROW fits a group within GROUPS, then it is added at the end
of this group. Otherwise a new group is added at the end of GROUPS,
containing this single ROW."
  (and (or (not aggcond)
	   (eval aggcond)) ;; this eval need the variable 'row to have a value
       (let ((gr (gethash row hgroups)))
	 (if gr
	     (-appendable-list-append gr row)
	   (setq gr (-appendable-list-create))
	   (puthash row gr hgroups)
	   (-appendable-list-append gr row)
	   (-appendable-list-append groups gr)))))

(defun orgtbl-aggregate-read-calc-expr (expr)
  "Interpret a string as either an org date or a calc expression"
  (let (date)
    (cond
     ;; nil happens when a table is malformed
     ;; some columns are missing in some rows
     ((not expr)
      nil)
     ;; empty cell returned as nil,
     ;; to be processed later depending on modifier flags
     ((equal expr "") nil)
     ;; the purely numerical cell case arises very often
     ;; short-circuiting general functions boosts performance (a lot)
     ((string-match "^[+-]?[0-9]*\.[0-9]\\(e[+-]?[0-9]+\\)?$" expr)
      (math-read-number expr))
     ;; a date
     ((setq date (org-time-string-to-calc expr))
      date)
     ;; generic case: symbolic calc expression
     (t
      (math-simplify
       (calcFunc-expand
	(math-read-expr expr)))))))

(defvar orgtbl-aggregate-variable-table)
(defvar orgtbl-aggregate-variable-group)
(defvar orgtbl-aggregate-variable-lists)

(defun orgtbl-to-aggregated-table-collect-list (var)
  "Replace VAR, which is a column name, with a $N expression.
If VAR is already in the $N form, VAR is left unchanged.  Collect
the cells at the crossing of the VAR column and the current GROUP
of rows, and store it in LISTS.  Assume that
`orgtbl-aggregate-variable-table',
`orgtbl-aggregate-variable-group' and
`orgtbl-aggregate-variable-lists' are bounded before calling this
function."
  (cond
   ;; aggregate functions with or without the leading "v"
   ;; sum(X) and vsum(X) are equivalent
   ((member
     var
     '("mean" "meane" "gmean" "hmean" "median" "sum" "min" "max"
       "prod" "pvar" "sdev" "psdev" "corr" "cov" "pcov"
       "count"))
    (format "v%s" var))
   ((member
     var
     '("vmean" "vmeane" "vgmean" "vhmean" "vmedian" "vsum" "vmin" "vmax"
       "vprod" "vpvar" "vsdev" "vpsdev" "vcorr" "vcov" "vpcov"
       "vcount"))
    var)
   ;; compatibility: list(X) will be obsoleted for (X)
   ((equal var "list")
    "")
   (t ;; replace VAR if it is a column name
    (save-match-data ;; save because we are called within a replace-regexp
      (let ((i (orgtbl-to-aggregated-table-colname-to-int
		var
		orgtbl-aggregate-variable-table)))
	(if i
	    (progn
	      (unless (aref orgtbl-aggregate-variable-lists i)
		(aset orgtbl-aggregate-variable-lists i
		      (cons 'vec
			    (cl-loop for row in
				     (-appendable-list-get
				      orgtbl-aggregate-variable-group)
				     collect
				     (orgtbl-aggregate-read-calc-expr
				      (nth i row))))))
	      (format "$%s" i))
	  var))))))

(defun orgtbl-to-aggregated-table-do-sums (group aggcols table)
  "Iterate over the expressions in AGGCOLS, evaluating each
expression with Calc using values found in the rows of the GROUP.
The result is a row identical to AGGCOLS, except expressions have
been evaluated."
  ;; inactivating math-read-preprocess-string boosts performance
  (cl-letf (((symbol-function 'math-read-preprocess-string) #'identity))
    (let ((lists (make-vector (1+ (length (car table))) nil)))
      (cl-loop
       for colspec in aggcols
       collect
       (if (or (string-match "^\\([[:word:]0-9_$]+\\)$" colspec)
	       (string-match "^'\\(.*\\)'$" colspec)
	       (string-match "^\"\\(.*\\)\"$" colspec))
	   ;; just a bare word, it is a key column
	   (nth (orgtbl-to-aggregated-table-colname-to-int
		 (match-string 1 colspec)
		 table)
		(car (-appendable-list-get group))) ; any row in group will do
	   ; otherwise it is a Calc aggregation expression
	 (orgtbl-to-aggregated-table-do-one-sum colspec group lists table))))))

(defun orgtbl-to-aggregated-table-do-one-sum (formula group lists table)
  (string-match "^\\(.*?\\)\\(;\\([^;']*\\)\\)?$" formula)
  ;; within this (let), we locally set Calc settings that must be active
  ;; for the all the calls to Calc:
  ;; (orgtbl-to-aggregated-table-collect-list) and (math-format-value)
  (let ((expression (match-string 1 formula))
	(fmt        (match-string 3 formula))
	(calc-internal-prec (or (cadr (memq 'calc-internal-prec org-calc-default-modes)) calc-internal-prec))
	(calc-float-format  (or (cadr (memq 'calc-float-format  org-calc-default-modes)) calc-float-format ))
	(calc-angle-mode    (or (cadr (memq 'calc-angle-mode    org-calc-default-modes)) calc-angle-mode   ))
	(calc-prefer-frac   (or (cadr (memq 'calc-prefer-frac   org-calc-default-modes)) calc-prefer-frac  ))
	(calc-symbolic-mode (or (cadr (memq 'calc-symbolic-mode org-calc-default-modes)) calc-symbolic-mode))
	(calc-date-format   (or (cadr (memq 'calc-date-format org-calc-default-modes))
				calc-date-format
				'(YYYY "-" MM "-" DD " " www (" " hh ":" mm))))
	(calc-display-working-message
	 (or (cadr (memq 'calc-display-working-message org-calc-default-modes)) calc-display-working-message))
	(duration-output-format)
	(duration)
	(numbers)
	(literal)
	(keep-empty)
	(noeval)
	(case-fold-search nil))
    ;; the following sexp was freely borrowed from org-table-eval-formula
    (when fmt
      (while (string-match "\\([pnfse]\\)\\(-?[0-9]+\\)" fmt)
	(let ((c (string-to-char   (match-string 1 fmt)))
	      (n (string-to-number (match-string 2 fmt))))
	  (if (= c ?p)
	      (setq calc-internal-prec n)
	    (setq calc-float-format
		  (list (cdr (assoc c '((?n . float) (?f . fix)
					(?s . sci) (?e . eng))))
			n)))
	  (setq fmt (replace-match "" t t fmt))))
      (if (string-match "T" fmt)
	  (setq duration t numbers t
		duration-output-format nil
		fmt (replace-match "" t t fmt)))
      (if (string-match "t" fmt)
	  (setq duration t
		duration-output-format org-table-duration-custom-format
		numbers t
		fmt (replace-match "" t t fmt)))
      (if (string-match "N" fmt)
	  (setq numbers t
		fmt (replace-match "" t t fmt)))
      (if (string-match "L" fmt)
	  (setq literal t
		fmt (replace-match "" t t fmt)))
      (if (string-match "E" fmt)
	  (setq keep-empty t
		fmt (replace-match "" t t fmt)))
      (while (string-match "[DRFSQ]" fmt)
	(cl-case (string-to-char (match-string 0 fmt))
	  (?D (setq calc-angle-mode 'deg))
	  (?R (setq calc-angle-mode 'rad))
	  (?F (setq calc-prefer-frac t))
	  (?S (setq calc-symbolic-mode t))
	  (?Q (setq noeval t)))
	(setq fmt (replace-match "" t t fmt)))
      (unless (string-match "\\S-" fmt)
	(setq fmt nil)))
    (let ((orgtbl-aggregate-variable-table table)
	  (orgtbl-aggregate-variable-group group)
	  (orgtbl-aggregate-variable-lists lists))
      (setq expression
	    (replace-regexp-in-string
	     (rx (or
		  (group ?'  (* (not ?' )) ?')
		  (group ?\" (* (not ?\")) ?\")
		  (group bow (+ word)      eow)))
	     'orgtbl-to-aggregated-table-collect-list
	     expression)))
    (setq expression
	  (replace-regexp-in-string
	   "\\<v?count()"
	   (lambda (var)
	     (format "%s" (length (-appendable-list-get group))))
	   expression))
    (if noeval
	expression
      (let ((calc-dollar-values (cdr (mapcar #'identity lists)))
	    (calc-command-flags nil)
	    (calc-next-why nil)
	    (calc-language 'flat)
	    (calc-dollar-used 0))
	(setq
	 calc-dollar-values
	 (cl-loop
	  for ls in calc-dollar-values
	  collect
	  (progn
	    (if (memq nil ls)
		(setq
		 ls
		 (if keep-empty
		     (cl-loop for x in ls collect (or x '(var nan var-nan)))
		   (cl-loop for x in ls nconc (if x (list x))))))
	    (if numbers
		(cons (car ls)
		      (cl-loop for x in (cdr ls)
			       collect (if (math-numberp x) x 0)))
	      ls))))
	(let ((ev
	       (math-format-value
		(math-simplify
		 (calcFunc-expand     ; yes, double expansion
		  (calcFunc-expand    ; otherwise it is not fully expanded
		   (math-read-expr expression))))
		1000)))
	  (if fmt
	      (format fmt (string-to-number ev))
	    ev))))))

(defun split-string-with-quotes (string)
  "Like `split-string', but also allows single or double quotes
to protect space characters, and also single quotes to protect
double quotes and the other way around"
  (let ((l (length string))
	(start 0)
	(result (-appendable-list-create))
	)
    (save-match-data
      (string-match "[ \f\t\n\r\v]*" string 0)
      (setq start (match-end 0))
      (while (and (< start l)
		  (string-match
		   (rx (* (not (any " '\"")))
		       (* (or
			   (group ?'  (* (not ?'))  ?' )
			   (group ?\" (* (not ?\")) ?\"))
			  (* (not (any " '\"")))))
		   string start))
	(-appendable-list-append result (match-string 0 string))
	(setq start (match-end 0))
	(string-match "[ \f\t\n\r\v]+" string start)
	(setq start (match-end 0))
	))
    (cdr result)))

(defun orgtbl-aggregate-hash-test-equal (row1 row2)
  "Are two rows from the source table equal regarding the
aggregation columns ?"
  (cl-loop for idx in keycols ;; keycols provided by (orgtbl-create-table-aggregated)
	   always (string= (nth idx row1) (nth idx row2))))

(defun orgtbl-aggregate-hash-test-hash (row)
  (let ((h 45235))
    ;; keycols provided by (orgtbl-create-table-aggregated)
    (cl-loop for idx in keycols
	     do
	     (cl-loop for c across (nth idx row)
		      do (setq h (% (* (+ h c) 127) 4227323))))
    h))

;; for hashes, try to stay within the 2^29 fixnums
;; see (info "(elisp) Integer Basics")
;; { prime_next 123 ==> 127 }
;; { prime_prev ((2^29 - 256) / 127 ) ==> 4227323 }

(defun orgtbl-create-table-aggregated (table aggcols aggcond)
  "Convert the source TABLE, which is a list of lists of cells,
into an aggregated table compliant with the AGGCOLS columns
specifications, ignoring source rows which do not pass the
AGGCOND."
  (while (eq 'hline (car table))
    (setq table (cdr table)))
  (if (stringp aggcols)
      (setq aggcols (split-string-with-quotes aggcols)))
  (when aggcond
    (if (stringp aggcond)
	(setq aggcond (read aggcond)))
    (setq aggcond (orgtbl-to-aggregated-replace-colnames table aggcond)))
  ;; set to t by orgtbl-to-aggregated-table-colname-to-int
  (define-hash-table-test
    'orgtbl-aggregate-hash-test-name
    'orgtbl-aggregate-hash-test-equal
    'orgtbl-aggregate-hash-test-hash)
  (let ((groups (-appendable-list-create))
	(hgroups (make-hash-table :test 'orgtbl-aggregate-hash-test-name))
	(keycols ;; beware, needs dynamic binding as provided by (let)
	 (cl-loop for column in aggcols
		  for idx = (orgtbl-to-aggregated-table-parse-spec column table)
		  if idx collect idx))
	(b 0)
	(bs "0"))
    ; split table into groups of rows
    (cl-loop for row in
	     (if (memq 'hline table) ;; skip header if any
		 (cdr (memq 'hline table))
	       table)
	     do
	     (cond ((eq row 'hline)
		    (setq b (1+ b)
			  bs (number-to-string b)))
		   ((listp row)
		    (orgtbl-to-aggregated-table-add-group
		     groups
		     hgroups
		     (cons bs row)
		     aggcond))))

    (let ((ttttt
	   (cl-loop for column in aggcols
		    collect
		    (orgtbl-to-aggregated-replace-colnames-$ table column)
		    )))
      (setq aggcols ttttt)
      (message "expressions = %s" ttttt))
      
    ; do the aggregations for each group of rows
    (cons
     aggcols
     (cons
      'hline
      (cl-loop for group in (-appendable-list-get groups)
	       collect
	       (orgtbl-to-aggregated-table-do-sums group aggcols table))))))

;; aggregation in Push mode

;;;###autoload
(defun orgtbl-to-aggregated-table (table params)
  "Convert the orgtbl-mode TABLE to another orgtbl-mode table
with material aggregated.
Grouping of rows is done for identical values of grouping columns.
For each group, aggregation (sum, mean, etc.) is done for other columns.
  
The source table must contain sending directives with the following format:
#+ORGTBL: SEND destination orgtbl-to-aggregated-table :cols ... :cond ...

The destination must be specified somewhere in the same file
with a block like this:
  #+BEGIN RECEIVE ORGTBL destination
  #+END RECEIVE ORGTBL destination

:cols     gives the specifications of the resulting columns.
          It is a space-separated list of column specifications.
          Example:
             P Q sum(X) max(X) mean(Y)
          Which means:
             group rows with similar values in columns P and Q,
             and for each group, compute the sum of elements in
             column X, etc.

          The specification for a resulting column may be:
             COL              the name of a grouping column in the source table
             hline            a special name for grouping rows separated
                              by horizontal lines
             count()          give the number of rows in each group
             list(COL)        list the values of the column for each group
             sum(COL)         compute the sum of the column for each group
             sum(COL1*COL2)   compute the sum of the product of two columns
                              for each group
             mean(COL)        compute the average of the column for each group
             mean(COL1*COL2)  compute the average of the product of two columns
                              for each group
             meane(COL)       compute the average along with the estimated error
             hmean(COL)       compute the harmonic average
             gmean(COL)       compute the geometric average
             median(COL)      give the middle element after sorting them
             max(COL)         gives the largest element of each group
             min(COL)         gives the smallest element of each group
             sdev(COL)        compute the standard deviation (divide by N-1)
             psdev(COL)       compute the population standard deviation (divide by N)
             pvar(COL)        compute the variance
             prod(COL)        compute the product
             cov(COL1,COL2)   compute the covariance of two columns
                              for each group (divide by N-1)
             pcov(COL1,COL2)  compute the population covariance of two columns
                              for each group (/N)
             corr(COL1,COL2)  compute the linear correlation of two columns

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal Q \"b\")
          Which means: keep only source rows for which the column Q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Example:
add a line like this one before your table
,#+ORGTBL: SEND aggregatedtable orgtbl-to-aggregated-table :cols \"sum(X) q sum(Y) mean(Z) sum(X*X)\"
then add somewhere in the same file the following lines:
,#+BEGIN RECEIVE ORGTBL aggregatedtable
,#+END RECEIVE ORGTBL aggregatedtable
Type C-c C-c into your source table

Note:
 This is the 'push' mode for aggregating a table.
 To use the 'pull' mode, look at the org-dblock-write:aggregate function.
"
  (interactive)
  (let ((aggregated-table
	 (orgtbl-create-table-aggregated
	  table
	  (plist-get params :cols)
	  (plist-get params :cond))))
    (with-temp-buffer
      (orgtbl-insert-elisp-table aggregated-table)
      (buffer-substring-no-properties (point-min) (1- (point-max))))))

;; aggregation in Pull mode

;;;###autoload
(defun org-dblock-write:aggregate (params)
  "Creates a table which is the aggregation of material from another table.
Grouping of rows is done for identical values of grouping columns.
For each group, aggregation (sum, mean, etc.) is done for other columns.

:table    name of the source table

:cols     gives the specifications of the resulting columns.
          It is a space-separated list of column specifications.
          Example:
             \"P Q sum(X) max(X) mean(Y)\"
          Which means:
             group rows with similar values in columns P and Q,
             and for each group, compute the sum of elements in
             column X, etc.

          The specification for a resulting column may be:
             COL              the name of a grouping column in the source table
             hline            a special name for grouping rows separated
                              by horizontal lines
             count()          give the number of rows in each group
             list(COL)        list the values of the column for each group
             sum(COL)         compute the sum of the column for each group
             sum(COL1*COL2)   compute the sum of the product of two columns
                              for each group
             mean(COL)        compute the average of the column for each group
             mean(COL1*COL2)  compute the average of the product of two columns
                              for each group
             meane(COL)       compute the average along with the estimated error
             hmean(COL)       compute the harmonic average
             gmean(COL)       compute the geometric average
             median(COL)      give the middle element after sorting them
             max(COL)         gives the largest element of each group
             min(COL)         gives the smallest element of each group
             sdev(COL)        compute the standard deviation (divide by N-1)
             psdev(COL)       compute the population standard deviation (divide by N)
             pvar(COL)        compute the variance
             prod(COL)        compute the product
             cov(COL1,COL2)   compute the covariance of two columns
                              for each group (divide by N-1)
             pcov(COL1,COL2)  compute the population covariance of two columns
                              for each group (/N)
             corr(COL1,COL2)  compute the linear correlation of two columns

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal Q \"b\")
          Which means: keep only source rows for which the column Q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Example:
- Create an empty dynamic block like this:
  #+BEGIN: aggregate :table originaltable :cols \"sum(X) Q sum(Y) mean(Z) sum(X*X)\"
  #+END
- Type C-c C-c over the BEGIN line
  this fills in the block with an aggregated table

Note:
 This is the 'pull' mode for aggregating a table.
 To use the 'push' mode, look at the orgtbl-to-aggregated-table function.
"
  (interactive)
  (let ((formula (plist-get params :formula))
	(content (plist-get params :content))
	(tblfm nil))
    (when (and content
	       (string-match "^[ \t]*\\(#\\+\\(tbl\\)?name:.*\\)" content))
      (insert (match-string 1 content) "\n"))
    (orgtbl-insert-elisp-table
     (orgtbl-create-table-aggregated
      (orgtbl-get-distant-table (plist-get params :table))
      (plist-get params :cols)
      (plist-get params :cond)))
    (delete-char -1) ;; remove trailing \n which Org Mode will add again
    (when (and content
	       (string-match "^[ \t]*\\(#\\+tblfm:.*\\)" content))
      (setq tblfm (match-string 1 content)))
    (when (stringp formula)
      (if tblfm
	  (unless (string-match (rx-to-string formula) tblfm)
	    (setq tblfm (format "%s::%s" tblfm formula)))
	(setq tblfm (format "#+TBLFM: %s" formula))))
    (when tblfm
      (end-of-line)
      (insert "\n" tblfm)
      (forward-line -1)
      (condition-case nil
	  (org-table-recalculate 'all)
	(args-out-of-range nil)))))

(defvar orgtbl-aggregate-history-cols ())

;;;###autoload
(defun org-insert-dblock:aggregate ()
  "Wizard to interactively insert an aggregate dynamic block."
  (interactive)
  (let* ((table
	  (org-icompleting-read "Table name: " (orgtbl-list-local-tables)))
	 (header (orgtbl-get-header-distant-table table t))
	 (aggcols
	  (replace-regexp-in-string
	   "\"" "'"
	   (read-string
	    (format
	     "target columns (operating on %s): "
	     header)
	    nil 'orgtbl-aggregate-history-cols)))
	 (aggcond
	  (read-string
	   (format
	    "condition (optional lisp function operating on %s): "
	    header)
	   nil 'orgtbl-aggregate-history-cols))
	 (params (list :name "aggregate" :table table :cols aggcols)))
    (unless (equal aggcond "")
      (nconc params (list :cond (read aggcond))))
    (org-create-dblock params)
    (org-update-dblock)))
  
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The Transposition package

(defun orgtbl-create-table-transposed (table cols aggcond)
  "Convert the source TABLE, which is a list of lists of cells,
into a transposed table compliant with the COLS source columns list,
ignoring source rows which do not pass the AGGCOND.
If COLS is nil, all source columns are taken.
If AGGCOND is nil, all source rows are taken"
  (if (stringp cols)
      (setq cols (split-string-with-quotes cols)))
  (setq cols
        (if cols
	    (cl-loop for column in cols
		     collect
		     (orgtbl-to-aggregated-table-colname-to-int column table t))
          (let ((head table))
	    (while (eq (car head) 'hline)
	      (setq head (cdr head)))
	    (cl-loop for x in (car head)
		     for i from 1
		     collect i))))
  (if aggcond
      (setq aggcond (orgtbl-to-aggregated-replace-colnames table aggcond)))
  (let ((result (cl-loop for x in cols collect (list t)))
        (nhline 0))
    (cl-loop for row in table
	     do
	     (if (eq row 'hline)
		 (setq nhline (1+ nhline))
	       (setq row (cons nhline row)))
	     do
	     (when (or (eq row 'hline) (not aggcond) (eval aggcond))
	       (let ((r result))
		 (cl-loop
		  for spec in cols
		  do
		  (nconc (pop r) (list (if (eq row 'hline) "" (nth spec row))))))))
    (cl-loop for row in result
	     do (pop row)
	     collect
	     (if (cl-loop for x in row
			  always (equal "" x))
		 'hline
	       row))))

;;;###autoload
(defun orgtbl-to-transposed-table (table params)
  "Convert the orgtbl-mode TABLE to a transposed version.
Rows become columns, columns become rows.

The source table must contain sending directives with the following format:
#+ORGTBL: SEND destination orgtbl-to-transposed-table :cols ... :cond ...

The destination must be specified somewhere in the same file
with a bloc like this:
  #+BEGIN RECEIVE ORGTBL destination
  #+END RECEIVE ORGTBL destination

:cols     optional, if omitted all source columns are taken.
          Columns specified here will become rows in the result.
          Valid specifications are
          - names as they appear in the first row of the source table
          - $N forms, starting from $1
          - the special hline column which is the numbering of
            blocks separated by horizontal lines in the source table

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal Q \"b\")
          Which means: keep only source rows for which the column Q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Horizontal lines are converted to empty columns,
and the other way around.

The destination must be specified somewhere in the same file
with a block like this:
  #+BEGIN RECEIVE ORGTBL destination_table_name
  #+END RECEIVE ORGTBL destination_table_name

Type C-c C-c in the source table to re-create the transposed version.

Note:
 This is the 'push' mode for transposing a table.
 To use the 'pull' mode, look at the org-dblock-write:transpose function.
"
  (interactive)
  (let ((transposed-table
	 (orgtbl-create-table-transposed
	  table
	  (plist-get params :cols)
	  (plist-get params :cond))))
    (with-temp-buffer
      (orgtbl-insert-elisp-table transposed-table)
      (buffer-substring-no-properties (point-min) (1- (point-max))))))

;;;###autoload
(defun org-dblock-write:transpose (params)
  "Create a transposed version of the orgtbl TABLE
Rows become columns, columns become rows.

:table    names the source table

:cols     optional, if omitted all source columns are taken.
          Columns specified here will become rows in the result.
          Valid specifications are
          - names as they appear in the first row of the source table
          - $N forms, starting from $1
          - the special hline column which is the numbering of
            blocks separated by horizontal lines in the source table

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal q \"b\")
          Which means: keep only source rows for which the column q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Horizontal lines are converted to empty columns,
and the other way around.

- Create an empty dynamic block like this:
  #+BEGIN: aggregate :table originaltable
  #+END
- Type C-c C-c over the BEGIN line
  this fills in the block with the transposed table

Note:
 This is the 'pull' mode for transposing a table.
 To use the 'push' mode, look at the orgtbl-to-transposed-table function.
"
  (interactive)
  (let ((formula (plist-get params :formula))
	(content (plist-get params :content))
	(tblfm nil))
    (when (and content
	       (string-match "^[ \t]*\\(#\\+\\(tbl\\)?name:.*\\)" content))
      (insert (match-string 1 content) "\n"))
    (orgtbl-insert-elisp-table
     (orgtbl-create-table-transposed
      (orgtbl-get-distant-table (plist-get params :table))
      (plist-get params :cols)
      (plist-get params :cond)))
    (delete-char -1) ;; remove trailing \n which Org Mode will add again
    (when (and content
	       (string-match "^[ \t]*\\(#\\+tblfm:.*\\)" content))
      (setq tblfm (match-string 1 content)))
    (when (stringp formula)
      (if tblfm
	  (unless (string-match (rx-to-string formula) tblfm)
	    (setq tblfm (format "%s::%s" tblfm formula)))
	(setq tblfm (format "#+TBLFM: %s" formula))))
    (when tblfm
      (end-of-line)
      (insert "\n" tblfm)
      (forward-line -1)
      (condition-case nil
	  (org-table-recalculate 'all)
	(args-out-of-range nil)))))

;;;###autoload
(defun org-insert-dblock:transpose ()
  "Wizard to interactively insert a transpose dynamic block."
  (interactive)
  (let* ((table
	  (org-icompleting-read "Table name: " (orgtbl-list-local-tables)))
         (header (orgtbl-get-header-distant-table table t))
	 (aggcols
	  (replace-regexp-in-string
	   "\"" "'"
	   (read-string
	    (format
	     "target columns (empty for all) (source columns are %s): "
	     header)
	    nil 'orgtbl-aggregate-history-cols)))
	 (aggcond
	  (read-string
	   (format
	    "condition (optional lisp function) (source columns %s): "
	    header)
	   nil 'orgtbl-aggregate-history-cols))
	 (params (list :name "transpose" :table table)))
    (unless (equal aggcols "")
      (nconc params (list :cols aggcols)))
    (unless (equal aggcond "")
      (nconc params (list :cond (read aggcond))))
    (org-create-dblock params)
    (org-update-dblock)))

(provide 'orgtbl-aggregate)
;;; orgtbl-aggregate.el ends here
