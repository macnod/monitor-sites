(in-package :monitor-sites)

(defvar *swank-server* nil)
(defvar *swank-port* 4011)

;;; ================================================================
;;; Swank
;;; ================================================================

(defun start-swank-server ()
  (when (and *swank-port* (not *swank-server*))
    (pl:pinfo :in "run" :status "starting swank")
    (setf *swank-server*
      (swank:create-server
        :interface "0.0.0.0"
        :port *swank-port*
        :style :spawn
        :dont-close t))))

(defun stop-swank-server ()
  (when *swank-server*
    (swank:stop-server *swank-server*)))

;;; ================================================================
;;; Eval Safely
;;; ================================================================

(defun eval-safely (string)
  "Evaluate STRING in the :monitor-sites package.
Returns (OUTPUT VALUES-STRING ERROR-STRING).
Errors are always returned, never propagated to the debugger."
  (handler-case
      (let ((*package* (find-package :monitor-sites))
            (out (make-string-output-stream))
            (err (make-string-output-stream)))
        (let ((*standard-output* out)
              (*error-output* err)
              (*trace-output* out))
          (let ((vals (multiple-value-list
                       (eval (read-from-string string)))))
            (list (get-output-stream-string out)
                  (format nil "~{~S~^~%~}" vals)
                  nil))))
    (serious-condition (e)
      (list ""
            ""
            (format nil "~A: ~A" (type-of e) e)))))

