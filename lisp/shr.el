;;; shr.el --- Simple HTML Renderer

;; Copyright (C) 2010 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: html

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package takes a HTML parse tree (as provided by
;; libxml-parse-html-region) and renders it in the current buffer.  It
;; does not do CSS, JavaScript or anything advanced: It's geared
;; towards rendering typical short snippets of HTML, like what you'd
;; find in HTML email and the like.

;;; Code:

(require 'browse-url)

(defgroup shr nil
  "Simple HTML Renderer"
  :group 'mail)

(defcustom shr-max-image-proportion 0.9
  "How big pictures displayed are in relation to the window they're in.
A value of 0.7 means that they are allowed to take up 70% of the
width and height of the window.  If they are larger than this,
and Emacs supports it, then the images will be rescaled down to
fit these criteria."
  :version "24.1"
  :group 'shr
  :type 'float)

(defcustom shr-blocked-images nil
  "Images that have URLs matching this regexp will be blocked."
  :version "24.1"
  :group 'shr
  :type 'regexp)

(defvar shr-folding-mode nil)
(defvar shr-state nil)
(defvar shr-start nil)
(defvar shr-indentation 0)

(defvar shr-width 70)

(defvar shr-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a" 'shr-show-alt-text)
    (define-key map "i" 'shr-browse-image)
    (define-key map "I" 'shr-insert-image)
    (define-key map "u" 'shr-copy-url)
    (define-key map "v" 'shr-browse-url)
    (define-key map "\r" 'shr-browse-url)
    map))

(defun shr-transform-dom (dom)
  (let ((result (list (pop dom))))
    (dolist (arg (pop dom))
      (push (cons (intern (concat ":" (symbol-name (car arg))) obarray)
		  (cdr arg))
	    result))
    (dolist (sub dom)
      (if (stringp sub)
	  (push (cons :text sub) result)
	(push (shr-transform-dom sub) result)))
    (nreverse result)))

;;;###autoload
(defun shr-insert-document (dom)
  (let ((shr-state nil)
	(shr-start nil))
    (shr-descend (shr-transform-dom dom))))

(defun shr-descend (dom)
  (let ((function (intern (concat "shr-tag-" (symbol-name (car dom))) obarray)))
    (if (fboundp function)
	(funcall function (cdr dom))
      (shr-generic (cdr dom)))))

(defun shr-generic (cont)
  (dolist (sub cont)
    (cond
     ((eq (car sub) :text)
      (shr-insert (cdr sub)))
     ((listp (cdr sub))
      (shr-descend sub)))))

(defun shr-tag-p (cont)
  (shr-ensure-paragraph)
  (shr-generic cont)
  (shr-ensure-paragraph))

(defun shr-ensure-paragraph ()
  (unless (bobp)
    (if (bolp)
	(unless (save-excursion
		  (forward-line -1)
		  (looking-at " *$"))
	  (insert "\n"))
      (if (save-excursion
	    (beginning-of-line)
	    (looking-at " *$"))
	  (insert "\n")
	(insert "\n\n")))))

(defun shr-tag-b (cont)
  (shr-fontize-cont cont 'bold))

(defun shr-tag-i (cont)
  (shr-fontize-cont cont 'italic))

(defun shr-tag-u (cont)
  (shr-fontize-cont cont 'underline))

(defun shr-tag-s (cont)
  (shr-fontize-cont cont 'strike-through))

(defun shr-fontize-cont (cont &rest types)
  (let (shr-start)
    (shr-generic cont)
    (dolist (type types)
      (shr-add-font (or shr-start (point)) (point) type))))

(defun shr-add-font (start end type)
  (let ((overlay (make-overlay start end)))
    (overlay-put overlay 'face type)))

(defun shr-tag-a (cont)
  (let ((url (cdr (assq :href cont)))
	(start (point))
	shr-start)
    (shr-generic cont)
    (widget-convert-button
     'link (or shr-start start) (point)
     :help-echo url)
    (put-text-property (or shr-start start) (point) 'keymap shr-map)
    (put-text-property (or shr-start start) (point) 'shr-url url)))

(defun shr-browse-url ()
  "Browse the URL under point."
  (interactive)
  (let ((url (get-text-property (point) 'shr-url)))
    (if (not url)
	(message "No link under point")
      (browse-url url))))

(defun shr-copy-url ()
  "Copy the URL under point to the kill ring.
If called twice, then try to fetch the URL and see whether it
redirects somewhere else."
  (interactive)
  (let ((url (get-text-property (point) 'shr-url)))
    (cond
     ((not url)
      (message "No URL under point"))
     ;; Resolve redirected URLs.
     ((equal url (car kill-ring))
      (url-retrieve
       url
       (lambda (a)
	 (when (and (consp a)
		    (eq (car a) :redirect))
	   (with-temp-buffer
	     (insert (cadr a))
	     (goto-char (point-min))
	     ;; Remove common tracking junk from the URL.
	     (when (re-search-forward ".utm_.*" nil t)
	       (replace-match "" t t))
	     (message "Copied %s" (buffer-string))
	     (copy-region-as-kill (point-min) (point-max)))))))
     ;; Copy the URL to the kill ring.
     (t
      (with-temp-buffer
	(insert url)
	(copy-region-as-kill (point-min) (point-max))
	(message "Copied %s" url))))))

(defun shr-tag-img (cont)
  (when (and (> (current-column) 0)
	     (not (eq shr-state 'image)))
    (insert "\n"))
  (let ((start (point-marker)))
    (let ((alt (cdr (assq :alt cont)))
	  (url (cdr (assq :src cont))))
      (when (zerop (length alt))
	(setq alt "[img]"))
      (cond
       ((and shr-blocked-images
	     (string-match shr-blocked-images url))
	(insert alt))
       ((url-is-cached (browse-url-url-encode-chars url "[&)$ ]"))
	(shr-put-image (shr-get-image-data url) (point) alt))
       (t
	(insert alt)
	(url-retrieve url 'shr-image-fetched
		      (list (current-buffer) start (point-marker))
		      t)))
      (insert " ")
      (put-text-property start (point) 'keymap shr-map)
      (put-text-property start (point) 'shr-alt alt)
      (put-text-property start (point) 'shr-image url)
      (setq shr-state 'image))))

(defun shr-show-alt-text ()
  "Show the ALT text of the image under point."
  (interactive)
  (let ((text (get-text-property (point) 'shr-alt)))
    (if (not text)
	(message "No image under point")
      (message "%s" text))))

(defun shr-browse-image ()
  "Browse the image under point."
  (interactive)
  (let ((url (get-text-property (point) 'shr-image)))
    (if (not url)
	(message "No image under point")
      (message "Browsing %s..." url)
      (browse-url url))))

(defun shr-image-fetched (status buffer start end)
  (when (and (buffer-name buffer)
	     (not (plist-get status :error)))
    (url-store-in-cache (current-buffer))
    (when (or (search-forward "\n\n" nil t)
	      (search-forward "\r\n\r\n" nil t))
      (let ((data (buffer-substring (point) (point-max))))
        (with-current-buffer buffer
          (let ((alt (buffer-substring start end))
		(inhibit-read-only t))
	    (delete-region start end)
	    (shr-put-image data start alt))))))
  (kill-buffer (current-buffer)))

(defun shr-put-image (data point alt)
  (if (not (display-graphic-p))
      (insert alt)
    (let ((image (ignore-errors
		   (shr-rescale-image data))))
      (when image
	(put-image image point alt)))))

(defun shr-rescale-image (data)
  (if (or (not (fboundp 'imagemagick-types))
	  (not (get-buffer-window (current-buffer))))
      (create-image data nil t)
    (let* ((image (create-image data nil t))
	   (size (image-size image t))
	   (width (car size))
	   (height (cdr size))
	   (edges (window-inside-pixel-edges
		   (get-buffer-window (current-buffer))))
	   (window-width (truncate (* shr-max-image-proportion
				      (- (nth 2 edges) (nth 0 edges)))))
	   (window-height (truncate (* shr-max-image-proportion
				       (- (nth 3 edges) (nth 1 edges)))))
	   scaled-image)
      (when (> height window-height)
	(setq image (or (create-image data 'imagemagick t
				      :height window-height)
			image))
	(setq size (image-size image t)))
      (when (> (car size) window-width)
	(setq image (or
		     (create-image data 'imagemagick t
				   :width window-width)
		     image)))
      image)))

(defun shr-tag-pre (cont)
  (let ((shr-folding-mode 'none))
    (shr-ensure-newline)
    (shr-generic cont)
    (shr-ensure-newline)))

(defun shr-tag-blockquote (cont)
  (shr-ensure-paragraph)
  (let ((shr-indentation (+ shr-indentation 4)))
    (shr-generic cont)))

(defun shr-ensure-newline ()
  (unless (zerop (current-column))
    (insert "\n")))

(defun shr-insert (text)
  (when (eq shr-state 'image)
    (insert "\n")
    (setq shr-state nil))
  (cond
   ((eq shr-folding-mode 'none)
    (insert text))
   (t
    (let ((first t)
	  column)
      (when (and (string-match "\\`[ \t\n]" text)
		 (not (bolp)))
	(insert " "))
      (dolist (elem (split-string text))
	(setq column (current-column))
	(when (> column 0)
	  (cond
	   ((and (or (not first)
		     (eq shr-state 'space))
		 (> (+ column (length elem) 1) shr-width))
	    (insert "\n"))
	   ((not first)
	    (insert " "))))
	(setq first nil)
	(when (and (bolp)
		   (> shr-indentation 0))
	  (shr-indent))
	;; The shr-start is a special variable that is used to pass
	;; upwards the first point in the buffer where the text really
	;; starts.
	(unless shr-start
	  (setq shr-start (point)))
	(insert elem))
      (setq shr-state nil)
      (when (and (string-match "[ \t\n]\\'" text)
		 (not (bolp)))
	(insert " ")
	(setq shr-state 'space))))))

(defun shr-indent ()
  (insert (make-string shr-indentation ? )))

(defun shr-get-image-data (url)
  "Get image data for URL.
Return a string with image data."
  (with-temp-buffer
    (mm-disable-multibyte)
    (url-cache-extract (url-cache-create-filename url))
    (when (or (search-forward "\n\n" nil t)
              (search-forward "\r\n\r\n" nil t))
      (buffer-substring (point) (point-max)))))

(defvar shr-list-mode nil)

(defun shr-tag-ul (cont)
  (shr-ensure-paragraph)
  (let ((shr-list-mode 'ul))
    (shr-generic cont)))

(defun shr-tag-ol (cont)
  (let ((shr-list-mode 1))
    (shr-generic cont)))

(defun shr-tag-li (cont)
  (shr-ensure-newline)
  (let* ((bullet
	  (if (numberp shr-list-mode)
	      (prog1
		  (format "%d " shr-list-mode)
		(setq shr-list-mode (1+ shr-list-mode)))
	    "* "))
	 (shr-indentation (+ shr-indentation (length bullet))))
    (insert bullet)
    (shr-generic cont)))

(defun shr-tag-br (cont)
  (unless (bobp)
    (insert "\n"))
  (shr-generic cont))

(defun shr-tag-h1 (cont)
  (shr-heading cont 'bold 'underline))

(defun shr-tag-h2 (cont)
  (shr-heading cont 'bold))

(defun shr-tag-h3 (cont)
  (shr-heading cont 'italic))

(defun shr-tag-h4 (cont)
  (shr-heading cont))

(defun shr-tag-h5 (cont)
  (shr-heading cont))

(defun shr-tag-h6 (cont)
  (shr-heading cont))

(defun shr-heading (cont &rest types)
  (shr-ensure-paragraph)
  (apply #'shr-fontize-cont cont types)
  (shr-ensure-paragraph))

(defun shr-tag-table (cont)
  (shr-ensure-paragraph)
  (setq cont (or (cdr (assq 'tbody cont))
		 cont))
  (let* ((columns (shr-column-specs cont))
	 (suggested-widths (shr-pro-rate-columns columns))
	 (sketch (shr-make-table cont suggested-widths))
	 (sketch-widths (shr-table-widths sketch (length suggested-widths))))
    (shr-insert-table (shr-make-table cont sketch-widths t) sketch-widths)))

(defun shr-insert-table (table widths)
  (shr-insert-table-ruler widths)
  (dolist (row table)
    (let ((start (point))
	  (height (let ((max 0))
		    (dolist (column row)
		      (setq max (max max (cadr column))))
		    max)))
      (dotimes (i height)
	(shr-indent)
	(insert "|\n"))
      (dolist (column row)
	(goto-char start)
	(let ((lines (split-string (nth 2 column) "\n")))
	  (dolist (line lines)
	    (when (> (length line) 0)
	      (end-of-line)
	      (insert line "|")
	      (forward-line 1)))
	  ;; Add blank lines at padding at the bottom of the TD,
	  ;; possibly.
	  (dotimes (i (- height (length lines)))
	    (end-of-line)
	    (insert (make-string (length (car lines)) ? ) "|")
	    (forward-line 1)))))
    (shr-insert-table-ruler widths)))

(defun shr-insert-table-ruler (widths)
  (shr-indent)
  (insert "+")
  (dotimes (i (length widths))
    (insert (make-string (aref widths i) ?-) ?+))
  (insert "\n"))

(defun shr-table-widths (table length)
  (let ((widths (make-vector length 0)))
    (dolist (row table)
      (let ((i 0))
	(dolist (column row)
	  (aset widths i (max (aref widths i)
			      (car column)))
	  (incf i))))
    widths))

(defun shr-make-table (cont widths &optional fill)
  (let ((trs nil))
    (dolist (row cont)
      (when (eq (car row) 'tr)
	(let ((i 0)
	      (tds nil))
	  (dolist (column (cdr row))
	    (when (memq (car column) '(td th))
	      (push (shr-render-td (cdr column) (aref widths i) fill)
		    tds)
	      (setq i (1+ i))))
	  (push (nreverse tds) trs))))
    (nreverse trs)))

(defun shr-render-td (cont width fill)
  (with-temp-buffer
    (let ((shr-width width))
      (shr-generic cont))
    (while (re-search-backward "\n *$" nil t)
      (delete-region (match-beginning 0) (match-end 0)))
    (goto-char (point-min))
    (let ((max 0))
      (while (not (eobp))
	(end-of-line)
	(setq max (max max (current-column)))
	(forward-line 1))
      (when fill
	(goto-char (point-min))
	(while (not (eobp))
	  (end-of-line)
	  (insert (make-string (- width (current-column)) ? ))
	  (forward-line 1)))
      (list max (count-lines (point-min) (point-max)) (buffer-string)))))

(defun shr-pro-rate-columns (columns)
  (let ((total-percentage 0)
	(widths (make-vector (length columns) 0)))
    (dotimes (i (length columns))
      (incf total-percentage (aref columns i)))
    (setq total-percentage (/ 1.0 total-percentage))
    (dotimes (i (length columns))
      (aset widths i (max (truncate (* (aref columns i)
				       total-percentage
				       shr-width))
			  10)))
    widths))

;; Return a summary of the number and shape of the TDs in the table.
(defun shr-column-specs (cont)
  (let ((columns (make-vector (shr-max-columns cont) 1)))
    (dolist (row cont)
      (when (eq (car row) 'tr)
	(let ((i 0))
	  (dolist (column (cdr row))
	    (when (memq (car column) '(td th))
	      (let ((width (cdr (assq :width (cdr column)))))
		(when (and width
			   (string-match "\\([0-9]+\\)%" width))
		  (aset columns i
			(/ (string-to-number (match-string 1 width))
			   100.0)))))
	    (setq i (1+ i))))))
    columns))

(defun shr-count (cont elem)
  (let ((i 0))
    (dolist (sub cont)
      (when (eq (car sub) elem)
	(setq i (1+ i))))
    i))

(defun shr-max-columns (cont)
  (let ((max 0))
    (dolist (row cont)
      (when (eq (car row) 'tr)
	(setq max (max max (shr-count (cdr row) 'td)))))
    max))

(provide 'shr)

;;; shr.el ends here