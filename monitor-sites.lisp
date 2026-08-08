(in-package :monitor-sites)

(defvar *http-server* nil)
(defvar *http-port* nil)

(defvar *conf* nil
  "The current valid configuration plist. NIL until first successful load.")

(defvar *cx-lost-notified* nil
  "Flag for connectivity-loss notification deduplication.")

(defvar *sites-down-notified* nil
  "List of site keys currently notified as down. Used for per-site
  alert deduplication — a site is added when first reported down and
  removed when it recovers.")

(defun http-get (url conf &optional (site-key :none))
  "Wrapper around DRAKMA:HTTP-REQUEST.
Sets user-agent from CONFIG, enables TLS verification.
Returns (VALUES body status-code) on success, or NIL on error."
  (handler-case
    (multiple-value-bind (body status-code)
      (dr:http-request
        url
        :method :get
        :user-agent (or
                      (u:tree-get conf :sites site-key :user-agent)
                      (u:tree-get conf :user-agent)
                      "Monitor Sites <macnod@gmail.com>")
        :verify :required
        :ca-file (or
                   (u:tree-get conf :sites site-key :ca-cert)
                   (u:tree-get conf :ca-cert))
        :ca-directory (or
                        (u:tree-get conf :sites site-key :ca-directory)
                        (u:tree-get conf :ca-directory))
        :want-stream nil)
      (values body status-code))
    (error (e)
      (pl:pinfo :in "http-get"
        :status "http get failed" :site site-key :url url :error e)
      nil)))

(defun site-up-p (site-key conf)
  "Check if SITE is up.
Returns T if HTTP status is 2xx and (if :EXPECT is present) the
response body contains that string. Returns NIL otherwise."
  (let ((url (u:tree-get conf :sites site-key :url))
         (name (u:tree-get conf :sites site-key :name))
         (expect (u:tree-get conf :sites site-key :expect)))
    (multiple-value-bind (body status)
      (http-get url conf site-key)
      (cond
        ((null status)
          (pl:pdebug :in "site-up-p"
            :site name :url url :status "request failed")
          nil)
        ((not (<= 200 status 299))
          (pl:pdebug :in "site-up-p"
            :site name :url url :status "site is down (bad status code)"
            :status-code status)
          nil)
        ((not (re:scan expect (or body "")))
          (pl:pdebug :in "site-up-p"
            :site name :url url :status "site is down (expect not found)"
            :status-code status)
          nil)
        (t
          (pl:pdebug :in "site-up-p"
            :site name :url url :status "site is up")
          t)))))

;;; ================================================================
;;; Connectivity Checking
;;; ================================================================

(defun connectivity-up-p (config)
  "Check if the monitoring host has internet connectivity.
Returns T if the connectivity URL returns 2xx, NIL otherwise."
  (multiple-value-bind (body status)
    (http-get (u:choose-one (getf config :connectivity-urls)) config)
    (declare (ignore body))
    (and status (<= 200 status 299))))

;;; ================================================================
;;; Mattermost Notification
;;; ================================================================

(defun escape-json-string (s)
  "Escape a string for embedding in a JSON string value."
  (with-output-to-string (out)
    (loop for ch across s
      do (case ch
           (#\" (write-string "\\\"" out))
           (#\\ (write-string "\\\\" out))
           (#\Newline (write-string "\\n" out))
           (#\Return (write-string "\\r" out))
           (#\Tab (write-string "\\t" out))
           (t (write-char ch out))))))

(defun build-mm-json (channel-id message)
  "Build the JSON body for a Mattermost post."
  (format nil "{\"channel_id\":\"~a\",\"message\":\"~a\"}"
    channel-id
    (escape-json-string message)))

(defun send-mm (message config)
  "Send a Mattermost message via the REST API.
POSTs to <mattermost-url>/api/v4/posts with channel_id and message.
Returns T on success, NIL on failure."
  (let ((url (format nil "~a/api/v4/posts"
               (string-right-trim "/" (getf config :mattermost-url))))
         (json (build-mm-json (getf config :mattermost-channel-id) message)))
    (handler-case
      (multiple-value-bind (body status-code)
        (dr:http-request url
          :method :post
          :user-agent (getf config :user-agent)
          :want-stream nil
          :content-type "application/json"
          :external-format-out :utf-8
          :additional-headers
            `(("Authorization" . ,(format nil "Bearer ~a"
                                    (getf config :mattermost-token))))
          :content json)
        (cond
          ((and (= status-code 200)
             (search "\"id\"" (or body "")))
            (pl:pinfo :in "send-mm"
              :status "sent mattermost message" :message message)
            t)
          (t
            (pl:perror :in "send-mm"
              :status "failed to send mattermost message"
              :status-code status-code
              :body (or body ""))
            nil)))
      (error (e)
        (pl:perror :in "send-mm"
          :status "failed to send mattermost message" :error e)
        nil))))

;;; ================================================================
;;; Per-Site Check Logic
;;; ================================================================

(defun connectivity-retry-loop (site-key config)
  "Handle the connectivity-check loop when a site is down.
If connectivity is up, notify about the site being down (once).
If connectivity is lost, notify once and sleep."
  (let* ((site-node (u:tree-get config :sites site-key))
          (name (getf site-node :name))
          (url (getf site-node :url))
          (cx-count 0)
          (max-retries (getf config :max-connectivity-retries))
          (retry-time (getf config :retry-connectivity-time))
          (lost-time (getf config :lost-connectivity-time)))
    (loop
      (cond
        ;; Connectivity is up
        ((connectivity-up-p config)
          (setq cx-count 0)
          ;; Re-check the site — it may have recovered too
          (if (site-up-p site-key config)
            (progn
              (pl:pinfo :in "connectivity-retry-loop"
                :site name :status "recovered")
              ;; Recovery notification handled by ping-site on next cycle,
              ;; but handle it here too since we return immediately
              (when (member site-key *sites-down-notified*)
                (when (send-mm (format nil "Site ~a has recovered." name)
                        config)
                  (setq *sites-down-notified*
                        (delete site-key *sites-down-notified*)))))
            (progn
              ;; Still down — notify once, now that connectivity
              ;; is confirmed up
              (unless (member site-key *sites-down-notified*)
                (when (send-mm
                        (format nil "Site ~a (~a) is not responding."
                          name url)
                        config)
                  (push site-key *sites-down-notified*)))
              (pl:pdebug :in "connectivity-retry-loop"
                :site name :status "still down")))
            (return))
        ;; Connectivity is down
        (t
          (incf cx-count)
          (cond
            ;; Exceeded retries: declare connectivity lost
            ((> cx-count max-retries)
              (unless *cx-lost-notified*
                (when (send-mm "evo-x2 has lost connectivity to the internet."
                        config)
                  (setq *cx-lost-notified* t)))
              (sleep lost-time))
            ;; Still within retry window
            (t
              (sleep retry-time))))))))

(defun ping-site (site-key config)
  "Check a single site and handle connectivity-loss logic.
If the site is up (and was previously down), notify recovery.
If down, enter the connectivity retry loop."
  (let ((name (u:tree-get config :sites site-key :name)))
    (cond
      ((site-up-p site-key config)
        (pl:pinfo :in "ping-site" :site name :status "up")
        (when (member site-key *sites-down-notified*)
          (when (send-mm (format nil "Site ~a has recovered." name) config)
            (setq *sites-down-notified*
                  (delete site-key *sites-down-notified*)))))
      (t
        (pl:pinfo :in "ping-site" :site name :status "down")
        (connectivity-retry-loop site-key config)))))

;;; ================================================================
;;; Log Truncation
;;; ================================================================

(defun split-lines (string)
  "Split STRING into a list of lines (without trailing newlines)."
  (let ((lines nil)
         (start 0))
    (loop for i from 0 below (length string)
      when (char= (char string i) #\Newline)
      do (push (subseq string start i) lines)
      (setq start (1+ i)))
    (push (subseq string start) lines)
    (nreverse lines)))

(defun truncate-log (config)
  "Truncate the log file if it exceeds :MAX-LOG-LINES.
Keeps only the most recent N lines."
  (let ((path (getf config :log-path))
         (max-lines (or (getf config :max-log-lines) 10000)))
    (when (and path (u:file-exists-p path))
      (handler-case
        (let* ((content (u:slurp path))
                (lines (split-lines content))
                (count (length lines)))
          (when (> count max-lines)
            (let ((kept (last lines max-lines)))
              (u:spew (format nil "~{~a~%~}" kept) path)
              (pl:pinfo :in "truncate-log"
                :before count :after (length kept)))))
        (error (e)
          (pl:perror :in "truncate-log"
            :error e :path path))))))

;;; ================================================================
;;; Control Server (Hunchentoot)
;;; ================================================================

(defun handle-health-get ()
  "Return 200 with body 'up'."
  (setf (h:return-code*) 200)
  "up")

(defun handle-health-delete ()
  "Return 200 then shut down the process."
  (setf (h:return-code*) 200)
  ;; Spawn a thread so the response completes first
  (sb-thread:make-thread
    (lambda ()
      (sleep 0.5)
      (pl:pinfo :in "control" :status "shutdown-requested")
      (sb-ext:exit)))
  "shutting down")

(defun start-control-server (&optional (port *http-port*))
  "Start the Hunchentoot control server on PORT.
Idempotent — no-op if already running."
  (unless *http-server*
    (setq *http-port* port)
    (let ((acceptor (make-instance 'h:easy-acceptor
                      :port port
                      :address "127.0.0.1")))
      ;; Define routes
      (h:define-easy-handler (health :uri "/health")
        ()
        (setf (h:content-type*) "text/plain")
        (ecase (h:request-method*)
          (:get (handle-health-get))
          (:delete (handle-health-delete))))
      (h:start acceptor)
      (setq *http-server* acceptor)
      (pl:pinfo :in "start-control-server"
        :status "started control server" :port port))))

(defun stop-control-server ()
  "Stop the Hunchentoot control server."
  (when *http-server*
    (h:stop *http-server*)
    (setq *http-server* nil)
    (pl:pinfo "stopped control server")))

;;; ================================================================
;;; Main Loop
;;; ================================================================

(defun run-cycle ()
  "Execute one full monitoring cycle.
Assumes *CONF* is non-nil."
  ;; Truncate log
  (when (getf *conf* :log-path) (truncate-log *conf*))
  ;; Check sites
  (let ((site-keys (u:plist-keys (getf *conf* :sites))))
    (pl:pinfo :in "main"
      :status "starting cycle" :site-count (length site-keys))
    (loop for site-key in site-keys do (ping-site site-key *conf*))
    ;; Check connectivity restoration
    (when (and *cx-lost-notified* (connectivity-up-p *conf*))
      (when (send-mm "evo-x2 connectivity to the internet has been restored."
              *conf*)
        (setq *cx-lost-notified* nil)))
    (pl:pinfo :in "main" :status "cycle complete")))

(defun main ()
  "Entry point. Infinite monitoring loop."
  (pl:pinfo :in "main" :status "starting")
  (start-swank-server)
  (loop do
    (handler-case
      (let* ((new-conf (load-config))
              (new-port (getf new-conf :http-port)))
        (when (or
                (not *conf*)
                (not (= *http-port* new-port)))
          (when *http-server*
            (stop-control-server))
          (start-control-server new-port))
        (setf
          *conf* new-conf
          *http-port* new-port)
        (run-cycle)
        (sleep (getf *conf* :check-interval)))
      (error (e)
        (if *conf*
          (progn
            (pl:perror :in "main" :status "invalid configuration file"
              :action "continuing with previous config" :error e)
            (sleep 60))
          (progn
            (pl:perror :in "main" :status "invalid configuration file"
              :action "terminating program" :error e)
            (sb-ext:quit)))))))
