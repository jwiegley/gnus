;;; gnus-html.el --- Quoted-Printable functions

;; Copyright (C) 2010  Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: html, web

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

;; The idea is to provide a simple, fast and pretty minimal way to
;; render HTML (including links and images) in a buffer, based on an
;; external HTML renderer (i.e., w3m).

;;; Code:

(eval-when-compile (require 'cl))
(eval-when-compile (require 'mm-decode))
(require 'mm-url)

(defcustom gnus-html-cache-directory (nnheader-concat gnus-directory "html-cache/")
  "Where Gnus will cache images it downloads from the web."
  :version "24.1"
  :group 'gnus-art
  :type 'directory)

(defcustom gnus-html-cache-size 500000000
  "The size of the Gnus image cache."
  :version "24.1"
  :group 'gnus-art
  :type 'integer)

(defcustom gnus-html-frame-width 70
  "What width to use when rendering HTML."
  :version "24.1"
  :group 'gnus-art
  :type 'integer)

(defcustom gnus-blocked-images "."
  "Images that have URLs matching this regexp will be blocked."
  :version "24.1"
  :group 'gnus-art
  :type 'regexp)

(defcustom gnus-max-image-proportion 0.7
  "How big pictures displayed are in relation to the window they're in.
A value of 0.7 means that they are allowed to take up 70% of the
width and height of the window.  If they are larger than this,
and Emacs supports it, then the images will be rescaled down to
fit these criteria."
  :version "24.1"
  :group 'gnus-art
  :type 'float)

;;;###autoload
(defun gnus-article-html (handle)
  (let ((article-buffer (current-buffer)))
    (save-restriction
      (narrow-to-region (point) (point))
      (save-excursion
	(mm-with-part handle
	  (let* ((coding-system-for-read 'utf-8)
		 (coding-system-for-write 'utf-8)
		 (default-process-coding-system
		   (cons coding-system-for-read coding-system-for-write))
		 (charset (mail-content-type-get (mm-handle-type handle)
						 'charset)))
	    (when (and charset
		       (setq charset (mm-charset-to-coding-system charset))
		       (not (eq charset 'ascii)))
	      (mm-decode-coding-region (point-min) (point-max) charset))
	    (call-process-region (point-min) (point-max)
				 "w3m"
				 nil article-buffer nil
				 "-halfdump"
				 "-no-cookie"
				 "-I" "UTF-8"
				 "-O" "UTF-8"
				 "-o" "ext_halfdump=1"
				 "-o" "pre_conv=1"
				 "-t" (format "%s" tab-width)
				 "-cols" (format "%s" gnus-html-frame-width)
				 "-o" "display_image=on"
				 "-T" "text/html"))))
      (gnus-html-wash-tags))))

(defvar gnus-article-mouse-face)

(defun gnus-html-wash-tags ()
  (let (tag parameters string start end images url)
    (mm-url-decode-entities)
    (goto-char (point-min))
    (while (re-search-forward "<pre_int> *</pre_int>\n" nil t)
      (replace-match "" t t))
    (goto-char (point-min))
    (while (re-search-forward "<\\([^ />]+\\)\\([^>]*\\)>" nil t)
      (setq tag (match-string 1)
	    parameters (match-string 2)
	    start (match-beginning 0))
      (when (plusp (length parameters))
	(set-text-properties 0 (1- (length parameters)) nil parameters))
      (delete-region start (point))
      (when (search-forward (concat "</" tag ">") nil t)
	(delete-region (match-beginning 0) (match-end 0)))
      (setq end (point))
      (cond
       ;; Fetch and insert a picture.
       ((equal tag "img_alt")
        (when (string-match "src=\"\\([^\"]+\\)" parameters)
	  (setq url (match-string 1 parameters))
          (gnus-message 8 "gnus-html-wash-tags: fetching image URL %s" url)
	  (if (string-match "^cid:\\(.*\\)" url)
	      ;; URLs with cid: have their content stashed in other
	      ;; parts of the MIME structure, so just insert them
	      ;; immediately.
	      (let ((handle (mm-get-content-id
			     (setq url (match-string 1 url))))
		    image)
		(when handle
		  (mm-with-part handle
		    (setq image (gnus-create-image (buffer-string)
						   nil t))))
		(when image
		  (let ((string (buffer-substring start end)))
		    (delete-region start end)
		    (gnus-put-image image (gnus-string-or string "*")))))
	    ;; Normal, external URL.
	    (unless (gnus-html-image-url-blocked-p
		     url
		     (if (buffer-live-p gnus-summary-buffer)
			 (with-current-buffer gnus-summary-buffer
			   gnus-blocked-images)
		       gnus-blocked-images))
	      (let ((file (gnus-html-image-id url))
		    width height)
		(when (string-match "height=\"?\\([0-9]+\\)" parameters)
		  (setq height (string-to-number (match-string 1 parameters))))
		(when (string-match "width=\"?\\([0-9]+\\)" parameters)
		  (setq width (string-to-number (match-string 1 parameters))))
		;; Don't fetch images that are really small.  They're
		;; probably tracking pictures.
		(when (and (or (null height)
			       (> height 4))
			   (or (null width)
			       (> width 4)))
		  (if (file-exists-p file)
		      ;; It's already cached, so just insert it.
		      (let ((string (buffer-substring start end)))
			;; Delete the ALT text.
			(delete-region start end)
			(gnus-html-put-image file (point) string))
		    ;; We don't have it, so schedule it for fetching
		    ;; asynchronously.
		    (push (list url
				(set-marker (make-marker) start)
				(point-marker))
			  images))))))))
       ;; Add a link.
       ((or (equal tag "a")
	    (equal tag "A"))
	(when (string-match "href=\"\\([^\"]+\\)" parameters)
	  (setq url (match-string 1 parameters))
          (gnus-message 8 "gnus-html-wash-tags: fetching link URL %s" url)
	  (gnus-article-add-button start end
				   'browse-url url
				   url)
	  (let ((overlay (gnus-make-overlay start end)))
	    (gnus-overlay-put overlay 'evaporate t)
	    (gnus-overlay-put overlay 'gnus-button-url url)
	    (when gnus-article-mouse-face
	      (gnus-overlay-put overlay 'mouse-face gnus-article-mouse-face)))))
       ;; The upper-case IMG_ALT is apparently just an artifact that
       ;; should be deleted.
       ((equal tag "IMG_ALT")
	(delete-region start end))
       ;; Whatever.  Just ignore the tag.
       (t
	))
      (goto-char start))
    (goto-char (point-min))
    ;; The output from -halfdump isn't totally regular, so strip
    ;; off any </pre_int>s that were left over.
    (while (re-search-forward "</pre_int>" nil t)
      (replace-match "" t t))
    (when images
      (gnus-html-schedule-image-fetching (current-buffer) (nreverse images)))))

(defun gnus-html-schedule-image-fetching (buffer images)
  (gnus-message 8 "gnus-html-schedule-image-fetching: buffer %s, images %s"
                buffer images)
  (let* ((url (caar images))
	 (process (start-process
		   "images" nil "curl"
		   "-s" "--create-dirs"
		   "--location"
		   "--max-time" "60"
		   "-o" (gnus-html-image-id url)
		   url)))
    (process-kill-without-query process)
    (set-process-sentinel process 'gnus-html-curl-sentinel)
    (gnus-set-process-plist process (list 'images images
					  'buffer buffer))))

(defun gnus-html-image-id (url)
  (expand-file-name (sha1 url) gnus-html-cache-directory))

(defun gnus-html-curl-sentinel (process event)
  (when (string-match "finished" event)
    (let* ((images (gnus-process-get process 'images))
	   (buffer (gnus-process-get process 'buffer))
	   (spec (pop images))
	   (file (gnus-html-image-id (car spec))))
      (when (and (buffer-live-p buffer)
		 ;; If the position of the marker is 1, then that
		 ;; means that the text it was in has been deleted;
		 ;; i.e., that the user has selected a different
		 ;; article before the image arrived.
		 (not (= (marker-position (cadr spec)) (point-min))))
	(with-current-buffer buffer
	  (let ((inhibit-read-only t)
		(string (buffer-substring (cadr spec) (caddr spec))))
	    (delete-region (cadr spec) (caddr spec))
	    (gnus-html-put-image file (cadr spec) string))))
      (when images
	(gnus-html-schedule-image-fetching buffer images)))))

(defun gnus-html-put-image (file point string)
  (when (display-graphic-p)
    (let ((image (ignore-errors
		   (gnus-create-image file))))
      (save-excursion
	(goto-char point)
	(if (and image
		 ;; Kludge to avoid displaying 30x30 gif images, which
		 ;; seems to be a signal of a broken image.
		 (not (and (listp image)
			   (eq (plist-get (cdr image) :type) 'gif)
			   (= (car (image-size image t)) 30)
			   (= (cdr (image-size image t)) 30))))
	    (progn
	      (gnus-put-image (gnus-html-rescale-image image)
			      (gnus-string-or string "*"))
	      t)
	  (insert string)
	  (when (fboundp 'find-image)
	    (gnus-put-image (find-image
			     '((:type xpm :file "lock-broken.xpm")))
			    (gnus-string-or string "*")))
	  nil)))))

(defun gnus-html-rescale-image (image)
  (if (or (not (fboundp 'imagemagick-types))
	  (not (get-buffer-window (current-buffer))))
      image
    (let* ((width (car (image-size image t)))
	   (height (cdr (image-size image t)))
	   (edges (window-pixel-edges (get-buffer-window (current-buffer))))
	   (window-width (truncate (* gnus-max-image-proportion
				      (- (nth 2 edges) (nth 0 edges)))))
	   (window-height (truncate (* gnus-max-image-proportion
				       (- (nth 3 edges) (nth 1 edges)))))
	   scaled-image)
      (when (> height window-height)
	(setq image (or (create-image file 'imagemagick nil
				      :height window-height)
			image))
	(when (> (car (image-size image t)) window-width)
	  (setq image (or
		       (create-image file 'imagemagick nil
				     :width window-width)
		       image))))
      image)))

(defun gnus-html-prune-cache ()
  (let ((total-size 0)
	files)
    (dolist (file (directory-files gnus-html-cache-directory t nil t))
      (let ((attributes (file-attributes file)))
	(unless (nth 0 attributes)
	  (incf total-size (nth 7 attributes))
	  (push (list (time-to-seconds (nth 5 attributes))
		      (nth 7 attributes) file)
		files))))
    (when (> total-size gnus-html-cache-size)
      (setq files (sort files (lambda (f1 f2)
				(< (car f1) (car f2)))))
      (dolist (file files)
	(when (> total-size gnus-html-cache-size)
	  (decf total-size (cadr file))
	  (delete-file (nth 2 file)))))))

(defun gnus-html-image-url-blocked-p (url blocked-images)
"Find out if URL is blocked by BLOCKED-IMAGES."
  (let ((ret (and blocked-images
                  (string-match blocked-images url))))
    (if ret
        (gnus-message 8 "gnus-html-image-url-blocked-p: %s blocked by regex %s"
                      url blocked-images)
      (gnus-message 9 "gnus-html-image-url-blocked-p: %s passes regex %s"
                    url blocked-images))
    ret))

;;;###autoload
(defun gnus-html-prefetch-images (summary)
  (let (blocked-images urls)
    (when (buffer-live-p summary)
      (with-current-buffer summary
	(setq blocked-images gnus-blocked-images))
      (save-match-data
	(while (re-search-forward "<img.*src=[\"']\\([^\"']+\\)" nil t)
	  (let ((url (match-string 1)))
	    (unless (gnus-html-image-url-blocked-p url blocked-images)
              (unless (file-exists-p (gnus-html-image-id url))
                (push url urls)
                (push (gnus-html-image-id url) urls)
                (push "-o" urls)))))
	(let ((process
	       (apply 'start-process
		      "images" nil "curl"
		      "-s" "--create-dirs"
		      "--location"
		      "--max-time" "60"
		      urls)))
	  (process-kill-without-query process))))))

(provide 'gnus-html)

;;; gnus-html.el ends here
