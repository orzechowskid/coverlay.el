;;; coverlay.el --- Test coverage overlay for Emacs

;; Copyright (C) 2011-2014 Takuto Wada

;; Author: Takuto Wada <takuto.wada at gmail com>
;; Keywords: coverage, overlay
;; Homepage: https://github.com/twada/coverlay.el
;; Version: 0.5.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(require 'filenotify)            ; File watching
(require 'tabulated-list)        ; To display statistics

;;; Commentary:
;; ------------
;;
;; Load coverlay.el in your .emacs
;;
;;     (require 'coverlay)
;;
;; Minor mode will toggle overlays in all buffers according to current lcov file
;;
;;     M-x coverlay-mode
;;
;; Load lcov file into coverlay buffer
;;
;;     M-x coverlay-load-file /path/to/lcov-file
;;
;; Load and watch a lcov file for changes
;;
;;     M-x coverlay-watch-file /path/to/lcov-file
;;
;; Toggle overlay for current buffer
;;
;;     M-x coverlay-toggle-overlays
;;

;;; Todo/Ideas:
;;
;; * add status view
;; * rework tested line handling to use actual lcov data
;; * better lcov data change detection on watch/load
;; * add branch coverage
;; * ability to load/watch multiple lcov files

;;; Code:

;; coverage data parsed from lcov-file-buffer
(defvar coverlay-alist nil)

;; coverage statistic data parsed from lcov-file-buffer
(defvar coverlay-stats-alist nil)

;; holds a token for the current watch (if any) for removal
(defvar coverlay--watch-descriptor nil)

;; name of the currently loaded lcov file
(defvar coverlay--loaded-filepath nil)

;;
;; Customizable variables

(defgroup coverlay nil
  "Test coverage overlay for Emacs."
  :group 'tools
  :prefix "coverlay:")

(defcustom coverlay:stats-buffer-name "*coverlay-stats*"
  "buffer name for coverage view."
  :type 'string
  :group 'coverlay)

(defcustom coverlay:untested-line-background-color "red4"
  "background-color for untested lines."
  :type 'string
  :group 'coverlay)

(defcustom coverlay:tested-line-background-color "green1"
  "background-color for tested lines."
  :type 'string
  :group 'coverlay)

(defcustom coverlay:mark-tested-lines t
  "background-color for tested lines."
  :type 'boolean
  :group 'coverlay)


;;
;; command: coverlay-load-file

;;;###autoload
(defun coverlay-load-file (filepath)
  "(re)load lcov coverage data from FILEPATH."
  (interactive (list (read-file-name "lcov file: ")))
  (coverlay--lcov-update filepath))

(defun coverlay-file-load-callback ()
  "Initialize overlays in buffer after loading."
  (let* ((filename (buffer-file-name))
         (buffer-coverage-data (coverlay-stats-tuples-for (current-buffer) coverlay-alist)))
    (when buffer-coverage-data
      (message (format "coverlay.el: loading coverlay for file: %s" filename))
      (coverlay-overlay-current-buffer-with-data buffer-coverage-data))))

;;
;; command: coverlay-watch-file

;;;###autoload
(defun coverlay-watch-file (filepath)
  "Watch file at FILEPATH for coverage data."
  (interactive (list (read-file-name "lcov file: ")))
  (if file-notify--library
      (coverlay--do-watch-file filepath)
    (message "coverlay.el: file notify not supported, please use coverlay-load-file instead")))

(defun coverlay--do-watch-file (filepath)
  "Use notify lib to Watch file at FILEPATH for coverage data."
  (coverlay-end-watch)
  (coverlay-load-file filepath)
  (message (format "coverlay.el: watching %s" filepath))
  (setq coverlay--watch-descriptor
        (file-notify-add-watch filepath '(change)
                               #'coverlay-watch-callback)))

(defun coverlay-end-watch ()
  "Remove the current filewatch if any."
  (file-notify-rm-watch coverlay--watch-descriptor))

(defun coverlay-watch-callback (args)
  "Reload data on coverage change in ARGS."
  (let ((filepath (nth 2 args)))
    (progn
      (message (format "coverlay.el: updating from %s" filepath))
      (coverlay--lcov-update filepath))))

(defun coverlay--lcov-update (filepath)
  "Update internal state and all buffers for new lcov data from FILEPATH."
  (coverlay--clear-all-buffers)
  (coverlay-create-alist-from-filepath filepath)
  (coverlay--update-stats-buffer)
  (coverlay--overlay-all-buffers))

(defun coverlay-create-alist-from-filepath (filepath)
  "Read stats into alist from FILEPATH."
  (with-temp-buffer
    (insert-file-contents filepath)
    (goto-char (point-min))
    (setq coverlay-alist (coverlay-create-stats-alist-from-current-buffer))
    (setq coverlay--loaded-filepath filepath)))

(defun coverlay-create-stats-alist-from-current-buffer ()
  "Create the alist from data in current buffer."
  (coverlay-tuplize-cdr-of-alist (coverlay-reverse-cdr-of-alist (coverlay-parse-current-buffer))))

(defun coverlay-reverse-cdr-of-alist (target-alist)
  "Convert '((Japanese . (hoge fuga piyo)) (English . (foo bar baz))) to '((Japanese . (piyo fuga hoge)) (English . (baz bar foo))) in TARGET-ALIST."
  (mapcar 'coverlay-reverse-cdr target-alist))

(defun coverlay-reverse-cdr (target-list)
  "Reverse CDR in TARGET-LIST."
  (cons
   (car target-list)
   (reverse (cdr target-list))))

(defun coverlay-tuplize-cdr-of-alist (target-alist)
  "Convert '((Japanese . (hoge fuga piyo moge)) (English . (foo bar baz moo)))  to '((Japanese . ((hoge fuga) (piyo moge)) (English . ((foo bar) (baz moo)))) in TARGET-ALIST."
  (mapcar 'coverlay-tuplize-cdr target-alist))

(defun coverlay-tuplize-cdr (target-list)
  "Tupelize cdr of TARGET-LIST."
  (progn
    (setcdr target-list (coverlay-create-tuple-pairs (cdr target-list)))
    target-list))

(defun coverlay-create-tuple-pairs (even-list)
  "Convert (foo bar baz hoge) to ((foo bar) (baz hoge)) in EVEN-LIST."
  (let ((result '()))
    (while even-list
      (setq result (cons (list (car even-list) (car (cdr even-list))) result))
      (setq even-list (nthcdr 2 even-list)))
    (nreverse result)))

(defun coverlay-parse-buffer (buffer)
  "Parse BUFFER into alist."
  (with-current-buffer buffer
    (coverlay-parse-current-buffer)))

(defun coverlay-parse-current-buffer ()
  "Parse current buffer to alist.  car of each element is filename, cdr is segment of lines."
  (let (alist filename)
    (while (not (eobp))
      (let ((current-line (coverlay-current-line)))
        (when (coverlay-source-file-p current-line)
          (setq filename (coverlay-extract-source-file current-line))
          (when (not (assoc filename alist))
            ;; (print (format "segments for %s does not exist" filename))
            (setq alist (cons (list filename) alist))))
        (when (coverlay-data-line-p current-line)
          (let* ((cols (coverlay-extract-data-list current-line))
                 (lineno (nth 0 cols))
                 (count (nth 1 cols)))
            (when (= count 0)
              ;; (print (format "count %d is zero" count))
              (coverlay-handle-uncovered-line alist filename lineno)))))
      (forward-line 1))
    alist))

(defun coverlay-handle-uncovered-line (alist filename lineno)
  "Add uncovered line at LINENO in FILENAME to ALIST."
  (let* ((file-segments (assoc filename alist))
         (segment-list-body (cdr file-segments)))
    (if (not segment-list-body)
        (setcdr file-segments (list lineno lineno))
      (if (= (car segment-list-body) (- lineno 1))
          (setcar segment-list-body lineno)
        (setcdr file-segments (append (list lineno lineno) segment-list-body))))))

(defun coverlay-current-line ()
  "Get current line of current buffer."
  (buffer-substring (point)
                    (save-excursion
                      (end-of-line)
                      (point))))

(defun coverlay-source-file-p (line)
  "Predicate if LINE contains lcov source data (SF)."
  (coverlay-string-starts-with line "SF:"))

(defun coverlay-data-line-p (line)
  "Predicate if LINE contains lcov line coverage data (DA)."
  (coverlay-string-starts-with line "DA:"))

(defun coverlay-end-of-record-p (line)
  "Predicate if LINE contains lcov end marker (end_of_record)."
  (coverlay-string-starts-with line "end_of_record"))

;; http://www.emacswiki.org/emacs/ElispCookbook#toc4
(defun coverlay-string-starts-with (s begins)
  "Return non-nil if string S starts with BEGINS."
  (cond ((>= (length s) (length begins))
         (string-equal (substring s 0 (length begins)) begins))
        (t nil)))

(defun coverlay-extract-source-file (line)
  "Extract file name from lcov source LINE."
  (coverlay-extract-rhs line))

(defun coverlay-extract-data-list (line)
  "Extract data list from lcov line coverage LINE."
  (mapcar 'string-to-number (split-string (coverlay-extract-rhs line) ",")))

(defun coverlay-extract-rhs (line)
  "Extract right hand lcov value from LINE."
  (substring line (+ (string-match "\:" line) 1)))


;;
;; command: coverlay-toggle-overlays

;;;###autoload
(defun coverlay-toggle-overlays (buffer)
  "Toggle coverage overlay in BUFFER."
  (interactive (list (current-buffer)))
  (if (not coverlay-alist)
      (message "coverlay.el: Coverage data not found. Please use `coverlay-load-file` to load them.")
    (with-current-buffer buffer
      (coverlay-toggle-overlays-current-buffer))))

(defun coverlay-toggle-overlays-current-buffer ()
  "Toggle overlay in current buffer."
  (if (coverlay-overlay-exists-p)
      (coverlay-clear-cov-overlays)
    (coverlay-overlay-current-buffer)))

(defun coverlay-overlay-buffer (buffer)
  "Overlay BUFFER."
  (with-current-buffer buffer
    (coverlay-overlay-current-buffer)))

(defun coverlay-overlay-current-buffer ()
  "Overlay current buffer."
  (let ((data (coverlay-stats-tuples-for (current-buffer) coverlay-alist)))
    (if data
        (coverlay-overlay-current-buffer-with-data data)
      (message (format "coverlay.el: no coverage data for %s in %s"
                       (buffer-file-name (current-buffer))
                       coverlay--loaded-filepath)))))

(defun coverlay-overlay-current-buffer-with-data (data)
  "Overlay current buffer with DATA."
  (coverlay-clear-cov-overlays)
  (when coverlay:mark-tested-lines
        (coverlay--make-covered-overlay))
  (coverlay-overlay-current-buffer-with-list data))

(defun coverlay-overlay-exists-p ()
  "Predicate if coverlay overlays exists in current buffer."
  (coverlay-overlay-exists-in-list-p (overlays-in (point-min) (point-max))))

(defun coverlay-overlay-exists-in-list-p (ovl-list)
  "Predicate if coverlay overlays exists in OVL-LIST."
  (catch 'loop
    (dolist (ovl ovl-list)
      (if (overlay-get ovl 'coverlay) (throw 'loop t) nil)
      nil)))

(defun coverlay-clear-cov-overlays ()
  "Clear all coverlay overlays in current buffer."
  (remove-overlays (point-min) (point-max) 'coverlay t))

(defun coverlay--make-covered-overlay ()
  "Mark all lines in current buffer as covered with overlay."
  (coverlay--overlay-put (make-overlay (point-min) (point-max)) coverlay:tested-line-background-color))

(defun coverlay-overlay-current-buffer-with-list (tuple-list)
  "Overlay current buffer acording to given TUPLE-LIST."
  (save-excursion
    (goto-char (point-min))
    (dolist (ovl (coverlay-map-overlays tuple-list))
      (coverlay--overlay-put ovl coverlay:untested-line-background-color))))

(defun coverlay--overlay-put (ovl color)
  "Record actual overlay in OVL with COLOR."
  (overlay-put ovl 'face (cons 'background-color color))
  (overlay-put ovl 'coverlay t))

(defun coverlay-map-overlays (tuple-list)
  "make-overlay for each of a TUPLE(two line-numbers) LIST."
  (mapcar 'coverlay-make-overlay tuple-list))

(defun coverlay-make-overlay (tuple)
  "Make overlay for values in TUPLE."
  (make-overlay (point-at-bol (car tuple)) (point-at-eol (cadr tuple))))

(defun coverlay-stats-tuples-for (buffer stats-alist)
  "Construct tuple for BUFFER and data in STATS-ALIST."
  (cdr (assoc (expand-file-name (buffer-file-name buffer)) stats-alist)))

(defun coverlay--get-filenames ()
  "Return all filenames from current lcov file."
  (mapcar #'car coverlay-alist))

(defun coverlay-overlay-all-buffers (filename)
  "Overlay all buffers visiting FILENAME."
  (let ((buffers (find-buffer-visiting filename)))
    (when buffers
        (message (format "coverlay.el: Marking buffers: %s" buffers))
        (coverlay-overlay-buffer buffers)
        filename)))

(defun coverlay-clear-all-buffers (filename)
  "Clear all buffers visiting FILENAME."
  (let ((buffers (find-buffer-visiting filename)))
    (when buffers
        (message (format "coverlay.el: Clearing buffers: %s" buffers))
        (with-current-buffer buffers
          (when (coverlay-overlay-exists-p)
            (coverlay-clear-cov-overlays)))
        filename)))

(defun coverlay--overlay-all-buffers ()
  "Toggle all overlays in open buffers contained in alist."
  (mapcar (lambda (file)
          (coverlay-overlay-all-buffers file))
        (coverlay--get-filenames)))

(defun coverlay--clear-all-buffers ()
  "Clear all overlays in open buffers contained in alist."
  (mapcar (lambda (file)
          (coverlay-clear-all-buffers file))
        (coverlay--get-filenames)))

;;(coverlay--overlay-all-buffers)

(defun coverlay--stats-tabulate-files ()
  "Tabulate statistics on file base."
  (mapcar (lambda (entry)
            (let* ((file (car entry))
                   (data (cdr entry)))
              (message (format "entry: %s: %s" file data))
              (list file (vector (if data "nope" "100%") file))))
          coverlay-alist))

(defun coverlay--stats-tabulate ()
  "Tabulate current statistics for major mode display."
  (cons (list "x" (vector "???%" "overall")) (coverlay--stats-tabulate-files)))

;; (coverlay-display-stats)


(define-derived-mode coverlay-stats-mode tabulated-list-mode "coverlay-stats"
  "Mode for listing statistics of coverlay-mode."
  (setq tabulated-list-format [("covered" 8 t)
                               ("File" 100 t)]
        tabulated-list-padding 1
        tabulated-list-entries #'coverlay--stats-tabulate)
  (tabulated-list-init-header))

(defun coverlay--update-stats-buffer ()
  "Refresh statistics, due to an update."
  (save-window-excursion
    (let ((buffer (get-buffer coverlay:stats-buffer-name)))
      (when buffer
        (with-current-buffer buffer
          (revert-buffer))))))

;;;###autoload
(defun coverlay-display-stats ()
  "Display buffer with current coverage statistics."
  (interactive)
  ;; (coverlay--update-stats-buffer)
  (pop-to-buffer coverlay:stats-buffer-name)
  (coverlay-stats-mode)
  (tabulated-list-print))

;;;###autoload
(define-minor-mode coverlay-mode
  "overlays for uncovered lines"
  :lighter " lcov"
  :global t
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c ll") 'coverlay-toggle-overlays)
            (define-key map (kbd "C-c lf") 'coverlay-load-file)
            (define-key map (kbd "C-c lw") 'coverlay-watch-file)
            (define-key map (kbd "C-c ls") 'coverlay-display-stats)
            map)
  (coverlay--switch-mode coverlay-mode))

(defun coverlay--switch-mode (enabled)
  "Switch global mode to be ENABLED or not."
  ;; missing: restore overlay state
  (if enabled
      (progn
        (add-hook 'coverlay-mode-hook #'coverlay--update-buffers)
        (add-hook 'find-file-hook #'coverlay-file-load-callback))
    ;; cleanup
    (coverlay-end-watch)
    (remove-hook 'find-file-hook #'coverlay-file-load-callback)
    (remove-hook 'coverlay-mode-hook #'coverlay--update-buffers)
    (coverlay--clear-all-buffers)))

;;(setq coverlay-mode-hook nil)

(defun coverlay--update-buffers ()
  "Update all buffers to current mode state."
  (mapcar (lambda (file)
            (if coverlay-mode
                (coverlay-overlay-all-buffers file)
              (coverlay-clear-all-buffers file)))
        (coverlay--get-filenames)))


(provide 'coverlay)
;;; coverlay.el ends here
