;;; dired-rsync.el --- Allow rsync from dired buffers
;;
;; Copyright (C) 2018 Alex Bennée
;;
;; Author: Alex Bennée <alex@bennee.com>
;; Maintainer: Alex Bennée <alex@bennee.com>
;; Version: 0.1
;; Package-Requires: ((s "1.12.0") (dash "2.0.0") (emacs "24"))
;; Homepage: https://github.com/stsquad/dired-rsync
;;
;; This file is not part of GNU Emacs.
;;
;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; There have been several attempts at doing this but I found them
;; wanting in usability. This attempts to clean up the ideas from:
;;
;;   https://truongtx.me/tmtxt-dired-async.html
;;   https://oremacs.com/2016/02/24/dired-rsync/
;;   https://vxlabs.com/2018/03/30/asynchronous-rsync-with-emacs-dired-and-tramp/
;;
;; in a hopefully cleaner and more idiomatic way.

(require 'dired-aux) ; for dired-dwim-target-directory
(require 'dash)
(require 's)

;;; Code:

(defvar dired-rsync-command
  "rsync"
  "The rsync binary that we are going to use.")

(defvar dired-rsync-options
  "-avz --progress"
  "The default options for the rsync command.")

(defvar dired-rsync-jobs
  '()
  "List of current rsync processes.")

(defvar dired-rsync-modeline-status
  ""
  "A string defining current dired-rsync status, useful for modelines.")

;; Helpers

(defun dired-path-is-remote-tramp (file-or-path)
  "Return true if FILE-OR-PATH is remote."
  (or (string-prefix-p "/scp:" file-or-path)
      (string-prefix-p "/ssh:" file-or-path)))

(defun dired-tramp-to-rsync (file-or-path)
  "Reformat a tramp FILE-OR-PATH to one usable for rsync."
  (if (dired-path-is-remote-tramp file-or-path)
      ;; tramp format is /method:remote:path
      (let ((parts (s-split ":" file-or-path)))
        (format "%s:\"%s\"" (nth 1 parts) (shell-quote-argument (nth 2 parts))))
    file-or-path))

;; Update status with count/speed
(defun dired-rsync-calculate-modeline ()
  "Display number of jobs and calculate throughput."
  (let ((jobs 0)
        (total-bandwidth))
    (mapc (lambda(job)
            (when (process-live-p (car job))
              (setq jobs (1+ jobs)))) dired-rsync-jobs)
    (if (> jobs 0)
        (format "R:%d %s" jobs (if (= jobs 1) "job" "jobs"))
      (format ""))))

;;
;; Running rsync: We need to take care of a couple of things here. We
;; need to ensure we run from the local host as you shouldn't expect
;; the remote target to be as aware of the ssh shortcuts home as from
;; the local system out (.ssh/config). We also want to track when it
;; is finished so we can inform the user the copy is complete.
;;

(defun dired--rsync-sentinel(proc desc)
  (let ((details (cdr (assoc proc dired-rsync-jobs))))
    (if (s-starts-with-p "finished" desc)
        (with-current-buffer (plist-get details ':dired-buffer)
          (dired-unmark-all-marks)
          (message "finished: %s" details))
      (message "%s: %s" proc desc))
    (setq dired-rsync-jobs
          (assq-delete-all proc dired-rsync-jobs)))
  (setq dired-rsync-modeline-status (dired-rsync-calculate-modeline)))

(defun dired--do-run-rsync (command details)
  "Run rsync COMMAND in a unique buffer, saving DETAILS in job list."
  (let* ((buf (format "*rsync @ %s" (current-time-string)))
         (proc (start-process-shell-command "*rsync*" buf command)))
    (setq dired-rsync-jobs (add-to-list 'dired-rsync-jobs (cons proc details)))
    (set-process-sentinel proc #'dired--rsync-sentinel)
    (setq dired-rsync-modeline-status (dired-rsync-calculate-modeline))))

;;;###autoload
(defun dired-rsync (dest)
  "Asynchronously copy files in dired to DEST using rsync.

This function runs the copy asynchronously so Emacs won't block whilst
the copy is running. It also handles both source and destinations on
ssh/scp tramp connections."
  ;; Interactively grab dest if not called with
  (interactive
   (list (read-file-name "rsync to:" (dired-dwim-target-directory))))

  (let ((src-files (dired-get-marked-files nil current-prefix-arg))
        (source))

    ;; check if the source is remote or destination is and munge
    ;; tramp style to rsync style appropriately.
    (if (dired-path-is-remote-tramp default-directory)
        (setq src-files (-map 'dired-tramp-to-rsync src-files)
              source (nth 1 (s-split ":" default-directory)))
      (when (dired-path-is-remote-tramp dest)
        (setq dest (dired-tramp-to-rsync dest)
              source "local")))

    ;; now build the rsync command
    (let ((cmd (s-join " "
                       (-flatten
                        (list dired-rsync-command
                              dired-rsync-options
                              src-files dest)))))
      (dired--do-run-rsync cmd
                           (list :marked-files src-files
                                 :dest dest
                                 :source source
                                 :dired-buffer (buffer-name))))))

(provide 'dired-rsync)
;;; dired-rsync.el ends here
